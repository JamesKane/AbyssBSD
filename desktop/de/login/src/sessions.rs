//! The login window's second job (Sessions.swift, PHASE16 P16.5b),
//! greetd's shape, and fast user switching (P16.6b).
//!
//! While nobody is logged in, the root daemon runs the **greeter session**
//! (`abyss-session` in greeter mode) as `_loginwindow`. When the window's
//! `login` is accepted, the greeter is ended and **that person's session**
//! started, as them (`setusercontext(LOGIN_SETALL)` through
//! `ap_child_spawn_as`), in their own runtime directory. When it ends, the
//! greeter comes back.
//!
//! **Fast user switching**: sessions run side by side, one in front.
//! "Login Window…" asks the daemon to switch; the session is **locked
//! first** and stays running behind the greeter. A person who already has a
//! session is taken back to it, where their own lock screen asks.
//!
//! **One VT each, on metal.** The greeter on VT 9 (ttyv8, which /etc/ttys
//! leaves for a display manager), people on 10 and up. The VT switch is a
//! command a test can replace, to record the switches.

use crate::GREETER_USER;
use abyss_sys::proc::{child_exit_events, poll, poll_fd, vt_activate, Child};
use abyss_sys::{platform, users};
use std::collections::BTreeMap;
use std::fs::{self, DirBuilder, OpenOptions};
use std::os::fd::{AsFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::time::{Duration, Instant};

/// Which VT each session has: pure, tested without a console.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct VTPlan {
    pub assigned: BTreeMap<String, i32>,
}

impl VTPlan {
    pub const GREETER: i32 = 9;
    pub const FIRST: i32 = 10;
    pub const LAST: i32 = 16;

    /// A VT for `user`: theirs if they have one, else the lowest free; None
    /// when every one is taken.
    pub fn vt(&mut self, user: &str) -> Option<i32> {
        if let Some(v) = self.assigned.get(user) {
            return Some(*v);
        }
        let v = (Self::FIRST..=Self::LAST).find(|v| !self.assigned.values().any(|u| u == v))?;
        self.assigned.insert(user.into(), v);
        Some(v)
    }

    pub fn release(&mut self, user: &str) {
        self.assigned.remove(user);
    }
}

#[derive(Clone, Debug)]
pub struct SessionConfig {
    /// The session program: the greeter's and everyone's.
    pub command: String,
    pub greeter_user: String,
    /// Where runtime directories go: `<root>/abyss-<user>`.
    pub runtime_root: String,
    /// Where each session's output goes: `<dir>/abyss-session-<user>.log`.
    pub log_directory: String,
    pub path: String,
    /// Given to every session as well (a test's stand-in daemon socket).
    pub extra_environment: BTreeMap<String, String>,
    /// Bring VT n to the front: None for the console's own `VT_ACTIVATE`;
    /// a command (given n) for a test's stand-in.
    pub vt_command: Option<String>,
    /// A test's: every named user's session runs as this process's own
    /// account, each in its own runtime directory and with its own name.
    /// Never the daemon's.
    pub sessions_as_self: bool,
}

impl Default for SessionConfig {
    fn default() -> SessionConfig {
        SessionConfig {
            command: "/usr/local/libexec/abyss-session".into(),
            greeter_user: GREETER_USER.into(),
            runtime_root: "/var/run".into(),
            log_directory: "/var/log".into(),
            path: "/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin".into(),
            extra_environment: BTreeMap::new(),
            vt_command: None,
            sessions_as_self: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Who {
    Greeter,
    User(String),
}

pub struct SessionManager {
    config: SessionConfig,
    say: Box<dyn Fn(&str)>,
    greeter: Option<Child>,
    users: BTreeMap<String, Child>,
    vts: VTPlan,
    /// Which session is on the screen.
    pub front: Option<Who>,
    greeter_failures: Vec<Instant>,
}

/// Wait up to `ms` for a child's exit descriptor.
fn exited_within(c: &Child, ms: i32) -> bool {
    let mut p = [poll_fd(c.fd(), child_exit_events())];
    matches!(poll(&mut p, ms), Ok(n) if n > 0)
}

impl SessionManager {
    pub fn new(config: SessionConfig, log: impl Fn(&str) + 'static) -> SessionManager {
        SessionManager { config, say: Box::new(log), greeter: None, users: BTreeMap::new(), vts: VTPlan::default(), front: None, greeter_failures: vec![] }
    }

    fn say(&self, s: &str) {
        (self.say)(s)
    }

    pub fn sessions_as_self(&self) -> bool {
        self.config.sessions_as_self
    }

    /// The people with a session running, by name.
    pub fn logged_in(&self) -> Vec<String> {
        self.users.keys().cloned().collect()
    }

    /// Every descriptor to poll, with whose it is.
    pub fn child_fds(&self) -> Vec<(RawFd, Who)> {
        let mut out: Vec<(RawFd, Who)> = self.greeter.iter().map(|c| (c.fd(), Who::Greeter)).collect();
        out.extend(self.users.iter().map(|(u, c)| (c.fd(), Who::User(u.clone()))));
        out
    }

    // MARK: VTs

    fn activate(&self, vt: i32) {
        if let Some(cmd) = &self.config.vt_command {
            if let Ok(mut c) = Child::spawn(&[cmd.clone(), vt.to_string()], &[format!("PATH={}", self.config.path)], None) {
                exited_within(&c, 5000);
                c.reap();
            }
        } else if let Err(e) = vt_activate(vt) {
            return self.say(&format!("sessions: could not bring VT {vt} to the front: {}", words(&e)));
        }
        self.say(&format!("sessions: VT {vt} to the front"));
    }

    // MARK: starting

    pub fn start_greeter(&mut self) {
        if self.greeter.is_some() {
            self.activate(VTPlan::GREETER);
            self.front = Some(Who::Greeter);
            return self.say("sessions: the login window, to the front");
        }
        self.activate(VTPlan::GREETER);
        let g = self.config.greeter_user.clone();
        if let Some(c) = self.spawn(&g, &g, "greeter") {
            self.greeter = Some(c);
            self.front = Some(Who::Greeter);
            self.say(&format!("sessions: the login window is up, as {g}"));
        }
    }

    /// "Login Window…" (P16.6b): the session in front, already locked by
    /// the daemon, stays running; the login window comes forward.
    pub fn show_login_window(&mut self, user: &str) {
        if self.front != Some(Who::User(user.into())) {
            return self.say(&format!("sessions: {user} asked for the login window but is not in front — ignored"));
        }
        self.start_greeter();
    }

    /// At the login window, someone whose session is running chose
    /// themselves: back to it, **asking nothing here**; their session is
    /// locked, and its own lock screen asks. One password, not two.
    pub fn resume(&mut self, user: &str) -> bool {
        if self.front != Some(Who::Greeter) || !self.users.contains_key(user) {
            return false;
        }
        let Some(vt) = self.vts.vt(user) else { return false };
        self.end_greeter(&format!("back to {user}'s session"));
        self.activate(vt);
        self.front = Some(Who::User(user.into()));
        self.say(&format!("sessions: back to {user}'s session (VT {vt}) — locked; its own lock screen asks"));
        true
    }

    /// The login window accepted `user`.
    pub fn login(&mut self, user: &str) {
        if self.front != Some(Who::Greeter) {
            return self.say(&format!("sessions: a login for {user} with no login window showing — ignored"));
        }
        self.end_greeter(&format!("{user} logged in"));
        if self.users.contains_key(user)
            && let Some(vt) = self.vts.vt(user)
        {
            // Theirs is running, locked: back to it.
            self.activate(vt);
            self.front = Some(Who::User(user.into()));
            return self.say(&format!("sessions: back to {user}'s session (VT {vt}) — it is locked; their password opens it"));
        }
        let Some(vt) = self.vts.vt(user) else {
            self.say(&format!("sessions: every VT is taken — {user} cannot have a session of their own now"));
            return self.start_greeter();
        };
        self.activate(vt);
        match self.spawn(user, user, "desktop") {
            Some(c) => {
                self.users.insert(user.into(), c);
                self.front = Some(Who::User(user.into()));
                let n = self.users.len();
                self.say(&format!("sessions: {user}'s session started on VT {vt}{}", if n > 1 { format!(" — {n} sessions") } else { String::new() }));
            }
            None => {
                self.vts.release(user);
                self.start_greeter();
            }
        }
    }

    /// The runtime directory, the environment, and the spawn, as `user` (or
    /// as ourselves, named `name`, in a test).
    fn spawn(&self, user: &str, name: &str, mode: &str) -> Option<Child> {
        let me = platform::euid();
        let account = if self.config.sessions_as_self { users::by_uid(me).map_or(user.to_owned(), |a| a.name) } else { user.to_owned() };
        let Some(pw) = users::by_name(&account) else {
            self.say(&format!("sessions: no account {account}"));
            return None;
        };
        // **The runtime directory is made here, because the session cannot**:
        // /var/run is root's. Theirs, 0700.
        let dir = format!("{}/abyss-{name}", self.config.runtime_root);
        let _ = DirBuilder::new().mode(0o700).create(&dir);
        if me == 0 {
            let _ = std::os::unix::fs::chown(&dir, Some(pw.uid), Some(pw.gid));
        }
        let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
        if fs::metadata(&dir).map(|m| m.uid()).ok() != Some(pw.uid) {
            self.say(&format!("sessions: {dir} is not {account}'s — not starting a session there"));
            return None;
        }
        let mut env: BTreeMap<String, String> = [
            ("HOME", pw.home.as_str()),
            ("USER", name),
            ("LOGNAME", name),
            ("SHELL", pw.shell.as_str()),
            ("PATH", self.config.path.as_str()),
            ("ABYSS_RUNTIME_DIR", dir.as_str()),
            ("XDG_RUNTIME_DIR", dir.as_str()),
            ("ABYSS_SESSION_MODE", mode),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect();
        env.extend(self.config.extra_environment.clone());
        let log = format!("{}/abyss-session-{name}.log", self.config.log_directory);
        let out = OpenOptions::new().append(true).create(true).mode(0o600).open(&log).ok();
        if me == 0
            && let Some(f) = &out
        {
            let _ = std::os::unix::fs::fchown(f, Some(pw.uid), Some(pw.gid));
        }
        let envp: Vec<String> = env.iter().map(|(k, v)| format!("{k}={v}")).collect();
        match Child::spawn_as(&account, std::slice::from_ref(&self.config.command), &envp, out.as_ref().map(|f| f.as_fd())) {
            Ok(c) => {
                if mode != "greeter" {
                    self.say(&format!("sessions: {name}'s session runs as uid {}, in {dir}", pw.uid));
                }
                Some(c)
            }
            Err(e) => {
                let what = if mode == "greeter" { "the login window".to_owned() } else { format!("{name}'s session") };
                self.say(&format!("sessions: could not start {what}: {}", words(&e)));
                None
            }
        }
    }

    // MARK: ending

    /// SIGTERM, five seconds, then SIGKILL; anchor takes its whole session
    /// down on SIGTERM.
    fn end(&self, mut c: Child, what: &str, why: &str) {
        self.say(&format!("sessions: ending {what} — {why}"));
        let _ = c.signal(libc::SIGTERM);
        if !exited_within(&c, 5000) {
            self.say("sessions: it did not end in 5 s — killing it");
            let _ = c.signal(libc::SIGKILL);
            exited_within(&c, 2000);
        }
        c.reap();
    }

    fn end_greeter(&mut self, why: &str) {
        if let Some(c) = self.greeter.take() {
            self.end(c, "the login window", why);
        }
        if self.front == Some(Who::Greeter) {
            self.front = None;
        }
    }

    /// A session's descriptor said it ended.
    pub fn child_exited(&mut self, who: &Who) {
        match who {
            Who::User(u) => {
                let Some(mut c) = self.users.remove(u) else { return };
                c.reap();
                self.vts.release(u);
                let n = self.users.len();
                self.say(&format!("sessions: {u} logged out{}", if n == 0 { String::new() } else { format!(" — {n} session(s) still running") }));
                if self.front == Some(who.clone()) {
                    self.front = None;
                    self.say("sessions: the login window again");
                    self.start_greeter();
                }
            }
            Who::Greeter => {
                if let Some(mut c) = self.greeter.take() {
                    c.reap();
                }
                if !matches!(self.front, Some(Who::Greeter) | None) {
                    return;
                }
                self.front = None;
                let now = Instant::now();
                self.greeter_failures.retain(|t| now.duration_since(*t) < Duration::from_secs(60));
                self.greeter_failures.push(now);
                let n = self.greeter_failures.len();
                if n > 5 {
                    return self.say(&format!("sessions: the login window died {n} times in a minute — giving up"));
                }
                self.say(&format!("sessions: the login window ended — starting it again ({n}/5)"));
                self.start_greeter();
            }
        }
    }

    /// The daemon is stopping: end everything.
    pub fn shutdown(&mut self) {
        self.end_greeter("the daemon is stopping");
        for (u, c) in std::mem::take(&mut self.users) {
            self.end(c, &format!("{u}'s session"), "the daemon is stopping");
        }
    }
}

fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}
