//! abyss-idle: the session's idle policy (PHASE16 P16.3), ported from
//! main.swift beside it.
//!
//! Turns idleness into what a person asked for in Energy Saver:
//!
//!   - when the display sleeps, **lock**, if "require a password to wake
//!     this computer" is on (energy.ini `require_password`, on by default);
//!   - after the computer's delay, **ask the machine to sleep**: a `power
//!     sleep` request to the root daemon (P16.4a).
//!
//! It is also the session's **power agent**: it keeps a `watch` connection
//! to the daemon, which tells it before the machine sleeps, whoever asked
//! (the system menu, this, the lid), and does not sleep until it answers
//! that the session is locked, or needs no lock. So the lock before sleep is
//! here, once, for every way to sleep.
//!
//! Idleness is the compositor's, through ext-idle-notify v1, so a video that
//! holds the displays awake holds this too (HANDOFF §2.86). energy.ini is
//! watched; a change re-arms both timers. anchor supervises this as the
//! `idle` component.
//!
//! ABYSS_IDLE_MINUTE=SECONDS makes a minute that long, for a test, which
//! cannot wait ten real minutes for a lock.

use abyss_sys::proc;
use abyss_sys::wl::{Display, Idle};
use current_ipc::Msg;
use login::{client, PowerAction};
use pool_config::EnergyPrefs;
use std::collections::BTreeMap;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::process::exit;
use std::time::Duration;

const LOCK: i32 = 0;
const SLEEP: i32 = 1;

fn say(s: &str) {
    eprintln!("abyss-idle: {s}");
}

fn words(ms: Option<u64>) -> String {
    match ms {
        None => "never".into(),
        Some(ms) if ms % 1000 == 0 => format!("{} s", ms / 1000),
        Some(ms) => format!("{} s", ms as f64 / 1000.0),
    }
}

fn request(method: &str) -> Msg {
    let mut m = Msg::new();
    m.set_string("method", method);
    m
}

struct Policy<'a> {
    idle: Idle<'a>,
    minute_ms: u64,
    prefs: EnergyPrefs,
    /// The `power sleep` asked and not yet answered.
    asking: Option<UnixStream>,
    /// The watch connection to the daemon.
    watch: Option<UnixStream>,
    retrying: bool,
}

impl Policy<'_> {
    fn arm(&self) {
        let (lock, sleep) = self.prefs.idle_timeouts(self.minute_ms);
        for (slot, ms) in [(LOCK, lock), (SLEEP, sleep)] {
            match ms {
                Some(ms) => {
                    self.idle.arm(slot, ms.min(u64::from(u32::MAX)) as u32);
                }
                None => self.idle.disarm(slot),
            }
        }
        let note = if self.prefs.require_password { "" } else { " (no password required: no lock)" };
        say(&format!("armed: lock after {}, sleep after {}{note}", words(lock), words(sleep)));
    }

    fn lock(&self, why: &str) -> bool {
        let r = match current_ipc::call("anchor", &request("lock")) {
            Ok(r) => r,
            Err(_) => {
                say(&format!("{why}: anchor did not answer — not locked"));
                return false;
            }
        };
        if r.bool("ok") != Some(true) {
            say(&format!("{why}: anchor would not lock: {}", r.string("error").unwrap_or("?")));
            return false;
        }
        say(&format!("{why}: {}", if r.bool("already") == Some(true) { "already locked" } else { "locking" }));
        true
    }

    /// Lock, and wait for anchor to say the **compositor** has locked: a
    /// running lock screen is not enough (HANDOFF §2.104). Ok, or why not.
    fn lock_and_confirm(&self, why: &str) -> Result<(), String> {
        if !self.lock(why) {
            return Err("the session could not be locked".into());
        }
        for _ in 0..50 {
            if current_ipc::call("anchor", &request("status")).is_ok_and(|r| r.bool("locked") == Some(true)) {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        Err("the session did not lock in 5 s".into())
    }

    /// Ask the machine to sleep. **Not a blocking call**: the daemon asks
    /// this very process, on its watch connection, to lock before it
    /// answers, and waiting here would hold the answer up until it gave up.
    fn sleep(&mut self) {
        if self.asking.is_some() {
            return;
        }
        let mut m = request("power");
        m.set_string("action", PowerAction::Sleep.as_str());
        match current_ipc::connect_path(&client::socket()).and_then(|s| current_ipc::send(&m, &s).map(|_| s)) {
            Ok(s) => {
                // The answer may be a while: the lock comes first.
                let _ = s.set_read_timeout(None);
                self.asking = Some(s);
                say("idle (the computer sleeps): asking the machine to sleep");
            }
            Err(e) => say(&format!("idle (the computer sleeps): nobody to ask the machine to sleep: {e}")),
        }
    }

    fn sleep_answered(&mut self) {
        let Some(s) = self.asking.take() else { return };
        match current_ipc::receive(&s) {
            Ok(r) if r.bool("ok") == Some(true) => say("idle (the computer sleeps): the machine is going to sleep"),
            Ok(r) => say(&format!("idle (the computer sleeps): the machine did not sleep: {}", r.string("error").unwrap_or("?"))),
            Err(_) => say("idle (the computer sleeps): no answer"),
        }
    }

    // MARK: the power agent

    fn start_watching(&mut self) {
        if self.watch.is_some() {
            return;
        }
        let watched = current_ipc::connect_path(&client::socket()).map_err(|e| e.to_string()).and_then(|s| {
            current_ipc::send(&request("watch"), &s).map_err(|e| e.to_string())?;
            let r = current_ipc::receive(&s).map_err(|e| e.to_string())?;
            if r.bool("ok") != Some(true) {
                return Err("refused".to_owned());
            }
            Ok(s)
        });
        match watched {
            Ok(s) => {
                // No receive timeout from here on: events come when they come.
                let _ = s.set_read_timeout(None);
                self.watch = Some(s);
                self.retrying = false;
                say("watching for the machine's sleep");
            }
            Err(e) => {
                if !self.retrying {
                    say(&format!("cannot watch for the machine's sleep yet ({e}) — retrying"));
                    self.retrying = true;
                }
            }
        }
    }

    fn event(&mut self) {
        let Some(m) = self.watch.as_ref().and_then(|w| current_ipc::receive(w).ok()) else {
            self.watch = None;
            say("the daemon went away — watching again when it is back");
            self.start_watching();
            return;
        };
        match m.string("event").unwrap_or("") {
            ev @ ("sleep" | "lock") => {
                // "lock" (P16.6b): the person is switching to the login
                // window, and their session must be locked behind it,
                // whatever the password setting, or one VT switch opens it.
                let mut answer = Msg::new();
                if self.prefs.require_password || ev == "lock" {
                    let why = if ev == "lock" { "switching to the login window" } else { "the machine is about to sleep" };
                    match self.lock_and_confirm(why) {
                        Ok(()) => {
                            answer.set_bool("ready", true);
                            answer.set_string("why", "locked");
                            say("the machine is about to sleep: locked, ready");
                        }
                        Err(why) => {
                            answer.set_bool("ready", false);
                            answer.set_string("why", &why);
                            say(&format!("the machine is about to sleep: NOT ready — {why}"));
                        }
                    }
                } else {
                    answer.set_bool("ready", true);
                    answer.set_string("why", "no password required");
                    say("the machine is about to sleep: no password required, ready");
                }
                if let Some(w) = &self.watch {
                    let _ = current_ipc::send(&answer, w);
                }
            }
            "resumed" => say("the machine is awake"),
            // Jaguar's question (P16.4b), in this session: Restart, Sleep,
            // Cancel, Shut Down. The dialog asks the daemon itself.
            "power-key" => {
                let Ok(exe) = std::env::var("ABYSS_APP_BINARY") else {
                    say("the power key: no application binary to ask with");
                    return;
                };
                let env = BTreeMap::from([("AQUA_SCENE".to_owned(), "powerdialog".to_owned()), ("ABYSS_POWER_ASK".to_owned(), "power-key".to_owned())]);
                let ok = spawn::detached(&[&exe], &env);
                say(&format!("the power key: {}", if ok { "asking what to do" } else { "could not open the dialog" }));
            }
            _ => {}
        }
    }

    fn config_changed(&mut self) {
        let p = EnergyPrefs::load(None);
        if p == self.prefs {
            return;
        }
        self.prefs = p;
        say("energy.ini changed");
        self.arm();
    }

    fn idled(&mut self) {
        let fired = self.idle.take();
        if fired & (1 << LOCK) != 0 {
            self.lock("idle (the display sleeps)");
        }
        if fired & (1 << SLEEP) != 0 {
            self.sleep();
        }
    }
}

fn main() {
    let minute_ms = std::env::var("ABYSS_IDLE_MINUTE").ok().and_then(|s| s.parse::<f64>().ok()).map_or(60_000, |s| (s.max(0.05) * 1000.0) as u64);
    let Some(display) = Display::connect() else {
        say("cannot connect to the compositor");
        exit(1)
    };
    let Some(idle) = Idle::new(&display) else {
        say("the compositor offers no ext-idle-notify — there is no idleness to act on");
        exit(1)
    };
    let mut p = Policy { idle, minute_ms, prefs: EnergyPrefs::load(None), asking: None, watch: None, retrying: false };
    p.arm();
    p.start_watching();
    let watcher = pool_config::Watcher::new(None).ok();
    loop {
        display.dispatch_pending();
        p.idled();
        display.flush();
        let fd = |s: &Option<UnixStream>| s.as_ref().map_or(-1, |s| s.as_raw_fd());
        let mut fds = [
            proc::poll_fd(display.fd(), proc::POLLIN),
            proc::poll_fd(watcher.as_ref().map_or(-1, |w| w.as_raw_fd()), proc::POLLIN),
            proc::poll_fd(fd(&p.asking), proc::POLLIN),
            proc::poll_fd(fd(&p.watch), proc::POLLIN),
        ];
        // Until the daemon is watched, look again every 2 s.
        let timeout = if p.watch.is_none() { 2000 } else { -1 };
        match proc::poll(&mut fds, timeout) {
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => exit(1),
            Ok(_) => {}
        }
        if fds[0].revents != 0 && !display.dispatch() {
            // The compositor went away: the session is over.
            exit(0)
        }
        p.idled();
        if fds[1].revents != 0 && watcher.as_ref().is_some_and(|w| w.drain()) {
            p.config_changed();
        }
        if fds[2].revents != 0 {
            p.sleep_answered();
        }
        if fds[3].revents != 0 {
            p.event();
        }
        if p.watch.is_none() {
            p.start_watching();
        }
    }
}
