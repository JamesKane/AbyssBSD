//! The session's authenticator in Rust (RUST.md R3; PHASE16 P16.1), ported
//! from Login.swift, Service.swift and Sessions.swift beside it.
//!
//! Nothing unprivileged on FreeBSD can check a password: OpenPAM's
//! `pam_unix` reads `master.passwd`, which only root can, so even a person
//! checking their **own** password is refused (PHASE16 §4.2). One root
//! daemon, `abyss-loginwindow`, answers on a socket every user can reach,
//! to exactly one question: *is this my password?*
//!
//! Three rules carry the security, and each lives here, where it is tested:
//!
//!   - **The caller is who the kernel says.** The uid comes from the
//!     socket; the request names nobody, so there is nothing to forge.
//!   - **Guessing is slow.** After a couple of typos each further failure
//!     doubles a wait (2 s, 4 s, … five minutes), per uid, during which the
//!     daemon refuses without asking PAM at all; a success clears it.
//!   - **The password is never written down.** It is not logged, and the
//!     request's copy is taken out of the message and wiped when the answer
//!     is known.

mod service;
mod sessions;

pub use service::{LoginService, PowerCommands, PowerPolicy};
pub use sessions::{SessionConfig, SessionManager, VTPlan, Who};

use abyss_sys::pam;
use current_ipc::Msg;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::os::unix::net::UnixStream;
use std::sync::OnceLock;
use std::time::Instant;

/// Where the daemon listens: system-wide, outside any session's runtime
/// directory, because every session, and the login window's own user,
/// asks it.
pub const DEFAULT_SOCKET: &str = "/var/run/abyss-loginwindow.sock";
/// The PAM service: its own stack in `/etc/pam.d/abyss`, **not** an
/// `include` of `login`, whose `pam_self` passes when the caller is the
/// target user, and the caller here is root.
pub const DEFAULT_SERVICE: &str = "abyss";
/// The greeter's account (P16.5): the login window runs as it, and only it
/// may ask about *another* account's password.
pub const GREETER_USER: &str = "_loginwindow";

/// Monotonic nanoseconds, for the limiter.
pub fn now_ns() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_nanos() as u64
}

// MARK: the limiter

/// How long a uid must wait before it may try again. Pure: tested with a
/// clock it is handed.
#[derive(Clone, Debug, Default)]
pub struct Limiter {
    failures: HashMap<u32, u32>,
    wait_until: HashMap<u32, u64>,
}

impl Limiter {
    /// Failures in a row that cost nothing: a typo, and another.
    pub const FREE: u32 = 2;
    /// The longest wait, however many failures.
    pub const CAP_NS: u64 = 300_000_000_000;

    /// Nanoseconds `uid` must still wait at `now`; zero when it may ask.
    pub fn wait(&self, uid: u32, now: u64) -> u64 {
        self.wait_until.get(&uid).map_or(0, |&until| until.saturating_sub(now))
    }

    /// The answer was no: the next attempt waits longer.
    pub fn failed(&mut self, uid: u32, now: u64) {
        let n = self.failures.entry(uid).or_insert(0);
        *n += 1;
        if *n <= Self::FREE {
            return;
        }
        let shift = (*n - Self::FREE).min(20);
        self.wait_until.insert(uid, now.wrapping_add((1_000_000_000u64 << shift).min(Self::CAP_NS)));
    }

    /// The answer was yes: start over.
    pub fn succeeded(&mut self, uid: u32) {
        self.failures.remove(&uid);
        self.wait_until.remove(&uid);
    }

    pub fn failures(&self, uid: u32) -> u32 {
        self.failures.get(&uid).copied().unwrap_or(0)
    }
}

// MARK: the wire

/// What the daemon says.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Accepted,
    Refused,
    /// Too many failures: ask again after this many milliseconds.
    Wait(u64),
    /// The daemon cannot answer (no PAM, or PAM failed), and says why.
    Unavailable(String),
}

pub mod wire {
    use super::Verdict;
    use current_ipc::Msg;

    pub fn request(password: &[u8]) -> Msg {
        let mut m = Msg::new();
        m.set_string("method", "verify");
        m.set_bytes("password", password);
        m
    }

    pub fn reply(v: &Verdict) -> Msg {
        let mut m = Msg::new();
        m.set_bool("ok", true);
        match v {
            Verdict::Accepted => m.set_string("verdict", "accepted"),
            Verdict::Refused => m.set_string("verdict", "refused"),
            Verdict::Wait(ms) => {
                m.set_string("verdict", "wait");
                m.set_u64("retry_after_ms", *ms);
            }
            Verdict::Unavailable(why) => {
                m.set_string("verdict", "unavailable");
                m.set_string("why", why);
            }
        }
        m
    }

    /// An `ok: false` reply, the CurrentIPC idiom.
    pub fn error(why: &str) -> Msg {
        let mut m = Msg::new();
        m.set_bool("ok", false);
        m.set_string("error", why);
        m
    }

    pub fn decode(m: &Msg) -> Option<Verdict> {
        Some(match m.string("verdict")? {
            "accepted" => Verdict::Accepted,
            "refused" => Verdict::Refused,
            "wait" => Verdict::Wait(m.u64("retry_after_ms").unwrap_or(0)),
            "unavailable" => Verdict::Unavailable(m.string("why").unwrap_or("").into()),
            _ => return None,
        })
    }
}

/// Take the password out of a message: the only copy, wiped on drop.
struct Secret(Vec<u8>);

impl Drop for Secret {
    fn drop(&mut self) {
        pam::wipe(&mut self.0);
    }
}

fn take_password(m: &mut Msg) -> Option<Secret> {
    m.take_bytes("password").map(Secret)
}

// MARK: the decision

/// What PAM said, as the authenticator needs it.
pub type Check = pam::PamAnswer;

type UserName = Box<dyn Fn(u32) -> Option<String>>;
type Checker = Box<dyn FnMut(&str, &[u8]) -> Check>;

/// One request → one verdict, and the line to log, which never contains
/// the password. Everything it needs is handed to it, so the tests drive
/// it with no root, no PAM and no socket.
pub struct Authenticator {
    pub limiter: Limiter,
    user_name: UserName,
    check: Checker,
}

/// A name that is no account still gets a limiter key of its own, so it
/// costs a wait like a wrong password.
fn ghost_key(name: &str) -> u32 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    name.hash(&mut h);
    0x8000_0000 | (h.finish() as u32 & 0x7fff_ffff)
}

fn ms_of(ns: u64) -> u64 {
    ns.div_ceil(1_000_000)
}

impl Authenticator {
    pub fn new(user_name: impl Fn(u32) -> Option<String> + 'static, check: impl FnMut(&str, &[u8]) -> Check + 'static) -> Authenticator {
        Authenticator { limiter: Limiter::default(), user_name: Box::new(user_name), check: Box::new(check) }
    }

    /// The real thing: the password database and PAM service `service`.
    pub fn system(service: &str) -> Authenticator {
        let service = service.to_owned();
        Authenticator::new(|uid| abyss_sys::users::by_uid(uid).map(|a| a.name), move |user, pw| pam::check(&service, user, pw))
    }

    /// The login window's question (P16.5): is this **that account's**
    /// password? Only the greeter may ask about an account not its own, and
    /// the wait is per *account asked about*.
    pub fn handle_login(&mut self, caller_is_greeter: bool, request: &mut Msg, now: u64, uid_of: &dyn Fn(&str) -> Option<u32>) -> (Msg, String, Option<String>) {
        if !caller_is_greeter {
            return (wire::error("only the login window may ask about another account"), "login refused: the caller is not the login window".into(), None);
        }
        let Some(name) = request.string("user").filter(|n| !n.is_empty()).map(str::to_owned) else {
            return (wire::error("login needs an account name"), "login: no account named".into(), None);
        };
        let Some(password) = take_password(request) else {
            return (wire::error("login needs a password"), format!("login {name}: no password given"), None);
        };
        let uid = uid_of(&name);
        let key = uid.unwrap_or_else(|| ghost_key(&name));
        let w = self.limiter.wait(key, now);
        if w > 0 {
            let ms = ms_of(w);
            return (wire::reply(&Verdict::Wait(ms)), format!("login {name}: asked again too soon — wait {ms} ms"), None);
        }
        // An account that does not exist is refused like a wrong password,
        // so the window cannot be used to learn which names are accounts.
        if uid.is_none() {
            self.limiter.failed(key, now);
            return (wire::reply(&Verdict::Refused), format!("login {name}: refused (no such account)"), None);
        }
        match (self.check)(&name, &password.0) {
            Check::Yes => {
                self.limiter.succeeded(key);
                (wire::reply(&Verdict::Accepted), format!("login {name}: accepted"), Some(name))
            }
            Check::No(why) => {
                self.limiter.failed(key, now);
                let next = self.limiter.wait(key, now);
                let tail = if next > 0 { format!("; the next try waits {} s", next / 1_000_000_000) } else { String::new() };
                (wire::reply(&Verdict::Refused), format!("login {name}: refused ({why}){tail}"), None)
            }
            Check::Unavailable(why) => (wire::reply(&Verdict::Unavailable(why.clone())), format!("login {name}: could not ask PAM — {why}"), None),
        }
    }

    /// `uid` is the kernel's answer for the caller, None if it would not say.
    pub fn handle(&mut self, uid: Option<u32>, request: &mut Msg, now: u64) -> (Msg, String) {
        // Never fall back to "allow", or to anyone's account.
        let Some(uid) = uid else {
            return (wire::error("the kernel would not identify the caller"), "refused a caller the kernel would not identify".into());
        };
        if request.string("method") != Some("verify") {
            return (wire::error(&format!("unknown method {}", request.string("method").unwrap_or("(none)"))), format!("uid {uid}: unknown method"));
        }
        let Some(password) = take_password(request) else {
            return (wire::error("verify needs a password"), format!("uid {uid}: no password given"));
        };
        let w = self.limiter.wait(uid, now);
        if w > 0 {
            let ms = ms_of(w);
            return (wire::reply(&Verdict::Wait(ms)), format!("uid {uid}: asked again too soon — wait {ms} ms"));
        }
        let Some(user) = (self.user_name)(uid) else {
            return (wire::reply(&Verdict::Refused), format!("uid {uid}: no such account"));
        };
        match (self.check)(&user, &password.0) {
            Check::Yes => {
                self.limiter.succeeded(uid);
                (wire::reply(&Verdict::Accepted), format!("uid {uid} ({user}): accepted"))
            }
            Check::No(why) => {
                self.limiter.failed(uid, now);
                let next = self.limiter.wait(uid, now);
                let tail = if next > 0 { format!("; the next try waits {} s", next / 1_000_000_000) } else { String::new() };
                (wire::reply(&Verdict::Refused), format!("uid {uid} ({user}): refused ({why}){tail}"))
            }
            Check::Unavailable(why) => (wire::reply(&Verdict::Unavailable(why.clone())), format!("uid {uid} ({user}): could not ask PAM — {why}")),
        }
    }
}

// MARK: accounts

/// An account the login window offers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LoginAccount {
    pub name: String,
    pub full_name: String,
    pub uid: u32,
}

/// One passwd(5) entry, as much as the window needs.
pub struct Entry<'a> {
    pub name: &'a str,
    pub uid: u32,
    pub gecos: &'a str,
    pub shell: &'a str,
}

pub mod accounts {
    use super::{Entry, LoginAccount};
    use std::collections::BTreeSet;

    /// Who may log in at the window: people, not the system's accounts:
    /// uid 1000 and up (FreeBSD's first user), not `nobody`, and with a
    /// shell that lets them in.
    pub fn offered(entries: &[Entry<'_>]) -> Vec<LoginAccount> {
        let mut out: Vec<LoginAccount> = entries
            .iter()
            .filter(|e| e.uid >= 1000 && e.uid < 65534 && !e.name.starts_with('_') && !e.shell.ends_with("/nologin") && !e.shell.ends_with("/false") && !e.shell.is_empty())
            .map(|e| {
                let full = e.gecos.split(',').next().unwrap_or("");
                LoginAccount { name: e.name.into(), full_name: if full.is_empty() { e.name.into() } else { full.into() }, uid: e.uid }
            })
            .collect();
        out.sort_by_key(|a| a.full_name.to_lowercase());
        out
    }

    /// From a passwd(5) file's text: a scratch root's, in a test (P16.6a).
    pub fn parse(passwd: &str) -> Vec<LoginAccount> {
        let entries: Vec<Entry<'_>> = passwd
            .lines()
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .filter_map(|l| {
                let f: Vec<&str> = l.split(':').collect();
                (f.len() >= 7).then_some(())?;
                Some(Entry { name: f[0], uid: f[2].parse().ok()?, gecos: f[4], shell: f[6] })
            })
            .collect();
        offered(&entries)
    }

    /// Who is in `group`, from a group(5) file's text.
    pub fn members(group: &str, text: &str) -> BTreeSet<String> {
        for line in text.lines() {
            let f: Vec<&str> = line.split(':').collect();
            if f.len() >= 4 && f[0] == group {
                return f[3].split(',').filter(|s| !s.is_empty()).map(str::to_owned).collect();
            }
        }
        BTreeSet::new()
    }

    /// Who logs in at boot, from rc.conf's text: `abyss_desktop_user`, when
    /// `abyss_desktop_enable` says so; None for the login window.
    pub fn auto_login(rc_conf: &str) -> Option<String> {
        let (mut enabled, mut user) = (false, None);
        for raw in rc_conf.lines() {
            let line = raw.trim_start_matches([' ', '\t']);
            let value = |key: &str| line.strip_prefix(key)?.strip_prefix('=').map(|v| v.replace(['"', '\''], ""));
            if let Some(v) = value("abyss_desktop_enable") {
                enabled = v.eq_ignore_ascii_case("YES");
            }
            if let Some(v) = value("abyss_desktop_user") {
                user = (!v.is_empty()).then_some(v);
            }
        }
        if enabled { user } else { None }
    }

    /// This machine's, from the password database.
    pub fn system() -> Vec<LoginAccount> {
        let all = abyss_sys::users::all();
        offered(&all.iter().map(|a| Entry { name: &a.name, uid: a.uid, gecos: &a.gecos, shell: &a.shell }).collect::<Vec<_>>())
    }
}

// MARK: power

/// What the session may ask the root daemon to do to the machine: the idle
/// policy's sleep (P16.3), the system menu's three and the machine's own
/// buttons (P16.4).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowerAction {
    Sleep,
    Restart,
    ShutDown,
    /// From devd (P16.4b): root's to send.
    Lid,
    SleepKey,
    PowerKey,
}

impl PowerAction {
    pub fn as_str(self) -> &'static str {
        match self {
            PowerAction::Sleep => "sleep",
            PowerAction::Restart => "restart",
            PowerAction::ShutDown => "shut-down",
            PowerAction::Lid => "lid",
            PowerAction::SleepKey => "sleep-key",
            PowerAction::PowerKey => "power-key",
        }
    }

    pub fn from_name(s: &str) -> Option<PowerAction> {
        [PowerAction::Sleep, PowerAction::Restart, PowerAction::ShutDown, PowerAction::Lid, PowerAction::SleepKey, PowerAction::PowerKey].into_iter().find(|a| a.as_str() == s)
    }

    /// An event from the hardware rather than a person's choice.
    pub fn is_hardware(self) -> bool {
        matches!(self, PowerAction::Lid | PowerAction::SleepKey | PowerAction::PowerKey)
    }
}

// MARK: the client

#[derive(Debug)]
pub enum LoginError {
    /// The daemon answered, and said no.
    Service(String),
    /// The answer could not be read.
    Garbled,
    Ipc(current_ipc::Error),
}

impl std::fmt::Display for LoginError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoginError::Service(s) => f.write_str(s),
            LoginError::Garbled => f.write_str("the authenticator's answer could not be read"),
            LoginError::Ipc(e) => write!(f, "{e}"),
        }
    }
}

impl From<current_ipc::Error> for LoginError {
    fn from(e: current_ipc::Error) -> LoginError {
        LoginError::Ipc(e)
    }
}

pub mod client {
    use super::*;

    /// The socket a session asks: `$ABYSS_LOGIN_SOCKET` (a test's own
    /// authenticator), else the system's.
    pub fn socket() -> String {
        std::env::var("ABYSS_LOGIN_SOCKET").unwrap_or_else(|_| DEFAULT_SOCKET.into())
    }

    fn send_wiped(mut m: Msg, socket: &str) -> Result<UnixStream, LoginError> {
        let s = current_ipc::connect_path(socket);
        let sent = s.and_then(|s| current_ipc::send(&m, &s).map(|_| s));
        // The request's copy goes either way.
        drop(take_password(&mut m));
        Ok(sent?)
    }

    /// Ask whether `password` is this process's user's, and wait.
    pub fn verify(password: &[u8], socket: &str) -> Result<Verdict, LoginError> {
        finish(&begin(password, socket)?)
    }

    /// The first half, for a run loop: connect and ask; poll what comes back.
    pub fn begin(password: &[u8], socket: &str) -> Result<UnixStream, LoginError> {
        send_wiped(wire::request(password), socket)
    }

    /// The login window's question (P16.5a): only the greeter may ask it.
    pub fn login(user: &str, password: &[u8], socket: &str) -> Result<UnixStream, LoginError> {
        let mut m = wire::request(password);
        m.set_string("method", "login");
        m.set_string("user", user);
        send_wiped(m, socket)
    }

    /// The second half: the answer on a socket `begin` or `login` returned.
    pub fn finish(s: &UnixStream) -> Result<Verdict, LoginError> {
        let reply = current_ipc::receive(s)?;
        if reply.bool("ok") != Some(true) {
            return Err(LoginError::Service(reply.string("error").unwrap_or("refused").into()));
        }
        wire::decode(&reply).ok_or(LoginError::Garbled)
    }

    /// Ask for `action`: the reply, `ok` or why not.
    pub fn power(action: PowerAction, socket: &str) -> Result<Msg, LoginError> {
        let mut m = Msg::new();
        m.set_string("method", "power");
        m.set_string("action", action.as_str());
        call(m, socket)
    }

    /// One request, one reply.
    pub fn call(m: Msg, socket: &str) -> Result<Msg, LoginError> {
        let s = current_ipc::connect_path(socket)?;
        current_ipc::send(&m, &s)?;
        Ok(current_ipc::receive(&s)?)
    }
}

#[cfg(test)]
mod tests;
