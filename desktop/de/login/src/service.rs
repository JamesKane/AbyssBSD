//! The root daemon's loop (Service.swift, PHASE16 P16.4a).
//!
//! `abyss-loginwindow` answers on its one socket:
//!
//!   - `verify`: is this my password? (the `Authenticator`)
//!   - `watch`: a session's agent (`abyss-idle`) keeps this connection
//!     open, and is told before the machine sleeps;
//!   - `power`: sleep, restart or shut down the machine;
//!   - `login`, `sessions`, `resume`, `switch-user`: the login window's.
//!
//! **The machine does not sleep with a session showing.** Whoever asks,
//! every watching session is told `sleep` first and must answer that it is
//! locked (or needs no lock). One that answers no, or not in time, stops
//! the sleep: a computer that stays awake is better than one that wakes
//! unlocked (HANDOFF §2.104). Only then is `acpiconf -s 3` run; when it
//! returns, the machine has woken, and the sessions are told.
//!
//! **Who may**: anyone at the machine may put it to sleep, as on the Mac.
//! Restart and shut down need root, `wheel` or `operator`: shutdown(8)'s
//! own rule. The commands are arguments, so a test runs stand-ins that
//! record what was asked (PHASE16 §6.3).
//!
//! One request at a time: a power request holds the loop while the
//! sessions lock, which is the point.

use crate::sessions::{SessionManager, Who};
use crate::{now_ns, wire, Authenticator, PowerAction};
use abyss_sys::proc::{child_exit_events, poll, poll_fd};
use abyss_sys::{platform, users};
use current_ipc::{Msg, Server};
use std::os::fd::{AsFd, AsRawFd, RawFd};
use std::os::unix::net::UnixStream;

/// Who may ask for what: pure, tested without accounts.
pub struct PowerPolicy;

impl PowerPolicy {
    pub fn may(action: PowerAction, uid: u32, groups: &[String], system_uid: u32, greeter_uid: Option<u32>) -> bool {
        // The lid and the keys are devd's, root's: anyone else saying "the
        // power key was pressed" could, with no session watching, shut the
        // machine down.
        if action.is_hardware() {
            return uid == system_uid;
        }
        if action == PowerAction::Sleep || uid == 0 {
            return true;
        }
        // The login window: nobody is logged in at the console, and the
        // Mac's login window has always offered Restart and Shut Down.
        if greeter_uid == Some(uid) {
            return true;
        }
        groups.iter().any(|g| g == "wheel" || g == "operator")
    }

    /// The command that does `action`.
    pub fn argv(action: PowerAction, commands: &PowerCommands) -> Vec<String> {
        let v = |c: &str, a: &[&str]| std::iter::once(c.to_owned()).chain(a.iter().map(|s| s.to_string())).collect();
        match action {
            PowerAction::Sleep | PowerAction::Lid | PowerAction::SleepKey => v(&commands.acpiconf, &["-s", "3"]),
            PowerAction::Restart => v(&commands.shutdown, &["-r", "now"]),
            // The power key with no session to ask: what the kernel's own
            // `power_button_state=S5` would have done.
            PowerAction::ShutDown | PowerAction::PowerKey => v(&commands.shutdown, &["-p", "now"]),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PowerCommands {
    pub acpiconf: String,
    pub shutdown: String,
}

impl Default for PowerCommands {
    fn default() -> PowerCommands {
        PowerCommands { acpiconf: "/usr/sbin/acpiconf".into(), shutdown: "/sbin/shutdown".into() }
    }
}

type Log = Box<dyn Fn(&str)>;
/// An account's uid by name.
pub type UidOf = Box<dyn Fn(&str) -> Option<u32>>;

pub struct LoginService {
    server: Server,
    auth: Authenticator,
    commands: PowerCommands,
    groups_of: Box<dyn Fn(u32) -> Vec<String>>,
    say: Log,
    /// How long the sessions have to lock before a sleep is called off.
    pub lock_timeout: f64,
    /// Who reports the machine's buttons: root (devd). Only a test's
    /// stand-in names another.
    pub system_uid: u32,
    /// The login window's account (P16.5): the only caller that may ask
    /// about another account's password. None: no login window here.
    pub greeter_uid: Option<u32>,
    /// The login window's sessions (P16.5b), when this daemon runs them.
    pub sessions: Option<SessionManager>,
    /// An account's uid by name; a test's sessions-as-self maps every name
    /// to its own.
    pub uid_of: UidOf,
    watchers: Vec<(UnixStream, u32)>,
}

fn reply(s: &UnixStream, m: &Msg) {
    let _ = current_ipc::send(m, s);
}

fn ok() -> Msg {
    let mut m = Msg::new();
    m.set_bool("ok", true);
    m
}

fn event(e: &str) -> Msg {
    let mut m = Msg::new();
    m.set_string("event", e);
    m
}

impl LoginService {
    pub fn new(server: Server, auth: Authenticator, commands: PowerCommands, log: impl Fn(&str) + 'static) -> LoginService {
        LoginService {
            server,
            auth,
            commands,
            groups_of: Box::new(users::group_names),
            say: Box::new(log),
            lock_timeout: 8.0,
            system_uid: 0,
            greeter_uid: None,
            sessions: None,
            uid_of: Box::new(|name| users::by_name(name).map(|a| a.uid)),
            watchers: vec![],
        }
    }

    fn say(&self, s: &str) {
        (self.say)(s)
    }

    /// Serve until `once` has answered one request (a test), or for ever.
    pub fn run(&mut self, once: bool) {
        if let Some(s) = self.sessions.as_mut() {
            s.start_greeter();
        }
        loop {
            let mut fds = vec![poll_fd(self.server.fd(), libc::POLLIN)];
            // Every session's end (P16.6b: several at once).
            let session_fds: Vec<(RawFd, Who)> = self.sessions.as_ref().map(|s| s.child_fds()).unwrap_or_default();
            fds.extend(session_fds.iter().map(|(fd, _)| poll_fd(*fd, child_exit_events())));
            let watcher_fds: Vec<RawFd> = self.watchers.iter().map(|(s, _)| s.as_raw_fd()).collect();
            fds.extend(watcher_fds.iter().map(|&fd| poll_fd(fd, libc::POLLIN)));
            match poll(&mut fds, -1) {
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return,
            }
            let base = 1 + session_fds.len();
            for (i, (_, who)) in session_fds.iter().enumerate() {
                if fds[1 + i].revents != 0
                    && let Some(s) = self.sessions.as_mut()
                {
                    s.child_exited(who);
                }
            }
            // A watcher readable outside a sleep has hung up, or is answering
            // a sleep that was already called off (it was too slow): a late
            // answer is read and set aside; anything else ends the watch.
            for (i, fd) in watcher_fds.iter().enumerate() {
                if fds[base + i].revents == 0 {
                    continue;
                }
                let late = self.watchers.iter().find(|(s, _)| s.as_raw_fd() == *fd).and_then(|(s, _)| current_ipc::receive(s).ok());
                if late.is_some_and(|m| m.bool("ready").is_some()) {
                    self.say("loginwindow: a late answer from a session, after its sleep was called off — ignored");
                } else {
                    self.drop_watcher(*fd, "hung up");
                }
            }
            if fds[0].revents != 0 {
                self.serve_one();
                if once {
                    return;
                }
            }
        }
    }

    fn drop_watcher(&mut self, fd: RawFd, why: &str) {
        let Some(i) = self.watchers.iter().position(|(s, _)| s.as_raw_fd() == fd) else { return };
        let (_, uid) = self.watchers.remove(i);
        self.say(&format!("loginwindow: uid {uid}'s session stopped watching ({why})"));
    }

    fn serve_one(&mut self) {
        let Ok(client) = self.server.accept() else { return };
        let uid = platform::peer_uid(client.as_fd()).ok();
        let Ok(mut request) = current_ipc::receive(&client) else { return };
        match request.string("method") {
            Some("watch") => {
                let Some(uid) = uid else { return reply(&client, &wire::error("the kernel would not identify the caller")) };
                if current_ipc::send(&ok(), &client).is_err() {
                    return;
                }
                self.watchers.push((client, uid));
                self.say(&format!("loginwindow: uid {uid}'s session is watching ({} watching)", self.watchers.len()));
            }
            Some("power") => self.power(&client, uid, &request),
            Some("switch-user") => self.switch_user(&client, uid),
            Some(m @ ("sessions" | "resume")) => {
                // The login window's alone: who is logged in, and back to one.
                let sessions_only = m == "sessions";
                let (Some(uid), Some(g)) = (uid, self.greeter_uid) else { return reply(&client, &wire::error("only the login window may ask that")) };
                let Some(s) = self.sessions.as_mut().filter(|_| uid == g) else { return reply(&client, &wire::error("only the login window may ask that")) };
                let mut r = ok();
                if sessions_only {
                    r.set_string("users", &s.logged_in().join(" "));
                } else {
                    let user = request.string("user").unwrap_or("").to_owned();
                    if !s.resume(&user) {
                        return reply(&client, &wire::error(&format!("{user} has no session to go back to")));
                    }
                }
                reply(&client, &r);
            }
            Some("login") => {
                let is_greeter = uid.is_some() && uid == self.greeter_uid;
                let (r, line, user) = self.auth.handle_login(is_greeter, &mut request, now_ns(), &*self.uid_of);
                drop(request);
                reply(&client, &r);
                drop(client);
                let who = if is_greeter { String::new() } else { format!("uid {}: ", uid.map_or("?".into(), |u| u.to_string())) };
                self.say(&format!("loginwindow: {who}{line}"));
                if let (Some(user), Some(s)) = (user, self.sessions.as_mut()) {
                    s.login(&user);
                }
            }
            _ => {
                let (r, line) = self.auth.handle(uid, &mut request, now_ns());
                drop(request);
                reply(&client, &r);
                drop(client);
                self.say(&format!("loginwindow: {line}"));
            }
        }
    }

    fn power(&mut self, client: &UnixStream, uid: Option<u32>, request: &Msg) {
        let Some(uid) = uid else { return reply(client, &wire::error("the kernel would not identify the caller")) };
        let Some(action) = request.string("action").and_then(PowerAction::from_name) else {
            return reply(client, &wire::error(&format!("power: no such action {}", request.string("action").unwrap_or("(none)"))));
        };
        if !PowerPolicy::may(action, uid, &(self.groups_of)(uid), self.system_uid, self.greeter_uid) {
            let why = if action.is_hardware() { "not root" } else { "not an administrator" };
            self.say(&format!("loginwindow: uid {uid}: {} refused — {why}", action.as_str()));
            let text = if action.is_hardware() {
                "only the system reports the machine's buttons".to_owned()
            } else {
                format!("only an administrator can {} this computer", if action == PowerAction::Restart { "restart" } else { "shut down" })
            };
            return reply(client, &wire::error(&text));
        }
        // **The power key asks** (Jaguar's dialog: Restart, Sleep, Cancel,
        // Shut Down) in every watching session; it does nothing itself. With
        // no session to ask, it shuts down, as the kernel would have.
        if action == PowerAction::PowerKey && !self.watchers.is_empty() {
            self.tell_all("power-key", "gone");
            self.say(&format!("loginwindow: the power key — asking {} session(s) what to do", self.watchers.len()));
            return reply(client, &ok());
        }
        let sleeps = matches!(action, PowerAction::Sleep | PowerAction::Lid | PowerAction::SleepKey);
        if sleeps && let Some(why) = self.lock_every_session(None, "sleep") {
            self.say(&format!("loginwindow: uid {uid}: sleep called off — {why}"));
            return reply(client, &wire::error(&format!("the computer did not sleep: {why}")));
        }
        reply(client, &ok());
        let argv = PowerPolicy::argv(action, &self.commands);
        self.say(&format!("loginwindow: uid {uid}: {} — {}", action.as_str(), argv.join(" ")));
        let r = spawn::run(&argv.iter().map(String::as_str).collect::<Vec<_>>());
        if !r.succeeded() {
            let how = r.failure.clone().unwrap_or_else(|| format!("status {}", r.raw_status.unwrap_or(-1)));
            self.say(&format!("loginwindow: {} failed ({how}): {}", argv[0], r.stderr_text()));
        }
        if sleeps {
            // `acpiconf -s 3` returns once the machine is awake again.
            self.say("loginwindow: awake");
            self.tell_all("resumed", "gone while asleep");
        }
    }

    /// Send `e` to every watcher; those that cannot hear it go.
    fn tell_all(&mut self, e: &str, why: &str) {
        let gone: Vec<RawFd> = self.watchers.iter().filter(|(s, _)| current_ipc::send(&event(e), s).is_err()).map(|(s, _)| s.as_raw_fd()).collect();
        for fd in gone {
            self.drop_watcher(fd, why);
        }
    }

    /// "Login Window…" from a session (P16.6b): that session is locked, by
    /// its agent as before a sleep, and only then does the login window come
    /// forward; the session keeps running behind it. Refused if it cannot
    /// lock: an open session one VT switch from anyone is not a switch.
    fn switch_user(&mut self, client: &UnixStream, uid: Option<u32>) {
        let front = match (&uid, self.sessions.as_ref().and_then(|s| s.front.clone())) {
            (Some(_), Some(Who::User(u))) => u,
            _ => return reply(client, &wire::error("there is no session in front to switch from")),
        };
        let uid = uid.unwrap();
        let as_self = self.sessions.as_ref().is_some_and(|s| s.sessions_as_self());
        let front_uid = users::by_name(&front).map(|a| a.uid);
        if !(front_uid == Some(uid) || (as_self && uid == platform::euid())) {
            return reply(client, &wire::error("only the session in front may switch away from itself"));
        }
        // Nobody watching for that account is nobody to lock it: refused,
        // never "nobody objected".
        if !self.watchers.iter().any(|(_, u)| *u == uid) {
            self.say(&format!("loginwindow: {front} asked for the login window — refused: no agent to lock the session"));
            return reply(client, &wire::error("not switched: the session has nothing to lock it"));
        }
        if let Some(why) = self.lock_every_session(Some(uid), "lock") {
            self.say(&format!("loginwindow: {front} asked for the login window — refused: {why}"));
            return reply(client, &wire::error(&format!("not switched: {why}")));
        }
        reply(client, &ok());
        self.say(&format!("loginwindow: {front} is locked — the login window"));
        if let Some(s) = self.sessions.as_mut() {
            s.show_login_window(&front);
        }
    }

    /// Tell every watching session the machine is about to sleep (or, for a
    /// switch, one account's sessions to lock), and wait for each to say it
    /// is locked. None when all did, else why not.
    fn lock_every_session(&mut self, only: Option<u32>, e: &str) -> Option<String> {
        let mut waiting: Vec<(RawFd, u32)> = vec![];
        let mut gone = vec![];
        for (s, uid) in &self.watchers {
            if only.is_some_and(|o| o != *uid) {
                continue;
            }
            if current_ipc::send(&event(e), s).is_ok() {
                waiting.push((s.as_raw_fd(), *uid));
            } else {
                gone.push(s.as_raw_fd());
            }
        }
        for fd in gone {
            self.drop_watcher(fd, "gone");
        }
        if !waiting.is_empty() {
            self.say(&format!("loginwindow: asking {} session(s) to lock before sleeping", waiting.len()));
        }
        let deadline = now_ns().wrapping_add((self.lock_timeout * 1e9) as u64);
        while !waiting.is_empty() {
            let now = now_ns();
            if now >= deadline {
                let who: Vec<String> = waiting.iter().map(|(_, u)| u.to_string()).collect();
                return Some(format!("uid {} did not lock in {} s", who.join(", "), self.lock_timeout as i64));
            }
            let mut fds: Vec<_> = waiting.iter().map(|(fd, _)| poll_fd(*fd, libc::POLLIN)).collect();
            match poll(&mut fds, ((deadline - now) / 1_000_000) as i32) {
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return Some("poll failed".into()),
            }
            for p in fds.iter().filter(|p| p.revents != 0) {
                let Some(i) = waiting.iter().position(|(fd, _)| *fd == p.fd) else { continue };
                let (fd, uid) = waiting.remove(i);
                let answer = self.watchers.iter().find(|(s, _)| s.as_raw_fd() == fd).and_then(|(s, _)| current_ipc::receive(s).ok());
                let Some(answer) = answer else {
                    self.drop_watcher(fd, "hung up instead of locking");
                    return Some(format!("uid {uid}'s session went away instead of locking"));
                };
                if answer.bool("ready") != Some(true) {
                    return Some(format!("uid {uid}'s session could not lock: {}", answer.string("why").unwrap_or("?")));
                }
                self.say(&format!("loginwindow: uid {uid}'s session is ready ({})", answer.string("why").unwrap_or("locked")));
            }
        }
        None
    }
}
