//! The session supervisor (Supervisor.swift): start the compositor and the
//! shell, keep them alive, tear the whole thing down together.
//!
//! No systemd, no D-Bus, no polling of pids: every child is a **pollable
//! descriptor** (pdfork on FreeBSD, a pidfd on Linux: `abyss_sys::proc`), so
//! supervision is one poll loop that also holds the control socket and the
//! signal pipe. The session's environment is a value: every child gets it
//! and its own overrides, and `status` reports the bus from it, which is
//! exactly what a child sees.

use crate::policy::{environment_block, monotonic_seconds, ComponentSpec, Decision, RestartPolicy};
use abyss_sys::proc::{self as sys, Child};
use current_ipc::{Msg, Server};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::time::Duration;

struct Running {
    spec: ComponentSpec,
    child: Option<Child>,
    started_at: f64,
    failures: u32,
    restarts: u32,
}

impl Running {
    fn is_up(&self) -> bool {
        self.child.as_ref().is_some_and(Child::is_live)
    }
}

/// Where the control service listens: in the runtime directory anchor was
/// told, or `current_ipc`'s own choice.
#[derive(Clone, Debug)]
pub enum ControlSocket {
    At(String),
    Default,
}

/// What a poll entry belongs to.
#[derive(Clone, Copy)]
enum Owner {
    Compositor,
    Component(usize),
    Control,
    Signal,
    Lock,
    LockPipe,
    FirstRun,
}

const LOCK_OUTCOME_PREFIX: &str = "abyss-lock-outcome: ";
/// Lock-screen crashes within `LOCK_CRASH_WINDOW` seconds before anchor
/// stops restarting it.
const LOCK_CRASH_LIMIT: usize = 5;
const LOCK_CRASH_WINDOW: f64 = 60.0;
/// How long a component waits for something it requires: long enough for a
/// cold start in the FreeBSD guest, short enough that a session that will
/// never compose says so.
const DEPENDENCY_TIMEOUT: f64 = 10.0;

pub struct Supervisor {
    policy: RestartPolicy,
    components: Vec<Running>,
    compositor: Option<ComponentSpec>,
    compositor_child: Option<Child>,
    control_at: ControlSocket,
    control: Option<Server>,
    signals: Option<File>,
    stopping: bool,
    exit_code: i32,
    environment: BTreeMap<String, String>,
    /// Log lines also go here, so tests assert on decisions.
    pub journal: Vec<String>,
    lock_screen: Option<ComponentSpec>,
    first_run: Option<ComponentSpec>,
    first_run_child: Option<Child>,
    lock_child: Option<Child>,
    lock_pipe: Option<UnixStream>,
    lock_pending: Vec<u8>,
    lock_outcome: Option<String>,
    /// The lock screen said the compositor has locked: `status` says
    /// `locked` only then, before it only `locking` (P16.3).
    lock_confirmed: bool,
    lock_crashes: Vec<f64>,
}

fn live(c: &Option<Child>) -> bool {
    c.as_ref().is_some_and(Child::is_live)
}

impl Supervisor {
    /// `environment` is what every child starts from: this process's, with
    /// the session's exports over it.
    pub fn new(
        compositor: Option<ComponentSpec>,
        components: Vec<ComponentSpec>,
        lock_screen: Option<ComponentSpec>,
        first_run: Option<ComponentSpec>,
        policy: RestartPolicy,
        environment: BTreeMap<String, String>,
        control_at: ControlSocket,
    ) -> Supervisor {
        Supervisor {
            policy,
            components: components.into_iter().map(|spec| Running { spec, child: None, started_at: 0.0, failures: 0, restarts: 0 }).collect(),
            compositor,
            compositor_child: None,
            control_at,
            control: None,
            signals: None,
            stopping: false,
            exit_code: 0,
            environment,
            journal: vec![],
            lock_screen,
            first_run,
            first_run_child: None,
            lock_child: None,
            lock_pipe: None,
            lock_pending: vec![],
            lock_outcome: None,
            lock_confirmed: false,
            lock_crashes: vec![],
        }
    }

    fn log(&mut self, msg: String) {
        eprintln!("anchor: {msg}");
        self.journal.push(msg);
    }

    // MARK: spawning

    /// Start one child: argv and envp are built here, before the fork.
    fn spawn(&self, spec: &ComponentSpec, stdout: Option<std::os::fd::BorrowedFd<'_>>) -> Result<Child, String> {
        let Some(path) = spec.argv.first() else { return Err(format!("malformed: component '{}' has no command", spec.name)) };
        if !path.starts_with('/') {
            return Err(format!("malformed: component '{}' needs an absolute path, got '{path}'", spec.name));
        }
        Child::spawn(&spec.argv, &environment_block(&self.environment, &spec.env), stdout).map_err(|e| format!("spawn {} ({path}): {}", spec.name, words(&e)))
    }

    fn start(&mut self, i: usize) -> Result<(), String> {
        let needs = self.components[i].spec.requires.clone();
        for socket in needs {
            if !self.wait_for_socket(&socket, DEPENDENCY_TIMEOUT) {
                return Err(format!("malformed: {} needs {socket}, which never accepted a connection", self.components[i].spec.name));
            }
        }
        let child = self.spawn(&self.components[i].spec, None)?;
        let r = &mut self.components[i];
        r.child = Some(child);
        r.started_at = monotonic_seconds();
        Ok(())
    }

    /// Wait until `path` accepts a connection, or give up. **Connecting is
    /// the readiness test**: the socket file exists between bind and
    /// listen, and a sleep is the same race with better manners (§2.26).
    fn wait_for_socket(&mut self, path: &str, seconds: f64) -> bool {
        let deadline = monotonic_seconds() + seconds;
        let mut announced = false;
        loop {
            if UnixStream::connect(path).is_ok() {
                return true;
            }
            if monotonic_seconds() >= deadline {
                return false;
            }
            if !announced {
                self.log(format!("waiting for {path}"));
                announced = true;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    // MARK: running the session

    /// Bring the session up and supervise it: the process's exit code.
    pub fn run(&mut self) -> i32 {
        if let Err(e) = self.bring_up() {
            self.log(format!("failed to start the session: {e}"));
            self.teardown();
            return 1;
        }
        self.run_loop();
        self.teardown();
        self.exit_code
    }

    fn bring_up(&mut self) -> Result<(), String> {
        // Rust ignores SIGPIPE in every binary already: a reader that went
        // away is EPIPE, never the supervisor's death.
        if let Some(comp) = self.compositor.clone() {
            self.compositor_child = Some(self.spawn(&comp, None)?);
            self.log(format!("compositor up ({})", comp.argv.first().map_or("?", String::as_str)));
        }
        for i in 0..self.components.len() {
            self.start(i)?;
            let name = self.components[i].spec.name.clone();
            self.log(format!("{name} up"));
        }
        // Best effort: a session without a control socket still runs.
        let server = match &self.control_at {
            ControlSocket::At(path) => Server::bind(path, 0o600),
            ControlSocket::Default => Server::new("anchor"),
        };
        match server.and_then(|s| s.set_nonblocking(true).map(|_| s)) {
            Ok(s) => {
                self.log(format!("control service on {} — abyssctl status|quit", s.path));
                self.control = Some(s);
            }
            Err(e) => self.log(format!("no control service ({e}) — the session runs without it")),
        }
        match sys::signal_pipe(&[15, 2]) {
            Ok(fd) => self.signals = Some(File::from(fd)),
            Err(_) => self.log("warning: no signal pipe — Ctrl-C won't tear down cleanly".into()),
        }
        let n = self.components.len();
        self.log(format!("session is live ({n} component(s))"));
        // The Setup Assistant, once, now that there is a desktop to set up.
        if let Some(spec) = self.first_run.clone() {
            let ready = spec.requires.iter().all(|s| self.wait_for_socket(s, DEPENDENCY_TIMEOUT));
            match ready.then(|| self.spawn(&spec, None).ok()).flatten() {
                Some(c) => {
                    self.first_run_child = Some(c);
                    self.log("the Setup Assistant is up (first login)".into());
                }
                None => self.log("the Setup Assistant could not start — the desktop runs without it".into()),
            }
        }
        Ok(())
    }

    /// The loop: children, the control socket and signals all arrive as
    /// readable descriptors, so there is exactly one place that waits.
    fn run_loop(&mut self) {
        let exit = sys::child_exit_events();
        let input = sys::POLLIN;
        while !self.stopping {
            let mut fds = vec![];
            let mut owners = vec![];
            let mut add = |fd: i32, ev: i16, o: Owner| {
                fds.push(sys::poll_fd(fd, ev));
                owners.push(o);
            };
            if let Some(c) = self.compositor_child.as_ref().filter(|c| c.is_live()) {
                add(c.fd(), exit, Owner::Compositor);
            }
            for (i, r) in self.components.iter().enumerate() {
                if let Some(c) = r.child.as_ref().filter(|c| c.is_live()) {
                    add(c.fd(), exit, Owner::Component(i));
                }
            }
            if let Some(s) = &self.control {
                add(s.fd(), input, Owner::Control);
            }
            if let Some(c) = self.lock_child.as_ref().filter(|c| c.is_live()) {
                add(c.fd(), exit, Owner::Lock);
            }
            if let Some(p) = &self.lock_pipe {
                add(p.as_raw_fd(), input, Owner::LockPipe);
            }
            if let Some(c) = self.first_run_child.as_ref().filter(|c| c.is_live()) {
                add(c.fd(), exit, Owner::FirstRun);
            }
            if let Some(f) = &self.signals {
                add(f.as_raw_fd(), input, Owner::Signal);
            }
            if fds.is_empty() {
                self.log("nothing left to supervise".into());
                return;
            }
            if let Err(e) = sys::poll(&mut fds, -1) {
                if e.kind() == ErrorKind::Interrupted {
                    continue;
                }
                self.log(format!("poll failed: {}", words(&e)));
                return;
            }
            for (p, o) in fds.iter().zip(owners) {
                if p.revents == 0 {
                    continue;
                }
                match o {
                    Owner::Compositor => self.compositor_exited(),
                    Owner::Control => self.handle_control(),
                    Owner::Signal => self.handle_signal(),
                    Owner::Lock => self.lock_exited(),
                    Owner::LockPipe => self.drain_lock(false),
                    Owner::FirstRun => {
                        // Finished, skipped or closed: not a component, and not
                        // restarted; the next login decides from setup.ini.
                        if let Some(c) = self.first_run_child.as_mut() {
                            c.reap();
                        }
                        self.log("the Setup Assistant has closed".into());
                    }
                    Owner::Component(i) => self.component_exited(i),
                }
                if self.stopping && !matches!(o, Owner::LockPipe | Owner::FirstRun) {
                    return;
                }
            }
        }
    }

    fn compositor_exited(&mut self) {
        if let Some(c) = self.compositor_child.as_mut() {
            c.reap();
        }
        // The compositor *is* the session: when it goes, everything goes.
        self.log("compositor exited — ending the session".into());
        self.stopping = true;
    }

    /// Whether the compositor's exit is already waiting, asked without
    /// blocking.
    fn compositor_is_gone(&self) -> bool {
        let Some(c) = self.compositor_child.as_ref().filter(|c| c.is_live()) else { return false };
        sys::poll(&mut [sys::poll_fd(c.fd(), sys::child_exit_events())], 0).is_ok_and(|n| n > 0)
    }

    fn component_exited(&mut self, i: usize) {
        let ran = monotonic_seconds() - self.components[i].started_at;
        if let Some(c) = self.components[i].child.as_mut() {
            c.reap();
        }
        // **A client whose compositor is leaving has not failed** (§2.97).
        if self.compositor_is_gone() {
            return self.compositor_exited();
        }
        let name = self.components[i].spec.name.clone();
        match self.policy.decide(ran, self.components[i].failures) {
            Decision::GiveUp(n) => {
                self.log(format!("{name} failed {n} times in a row — giving up, tearing down"));
                self.exit_code = 1;
                self.stopping = true;
            }
            Decision::Restart(n) => {
                let r = &mut self.components[i];
                r.failures = n;
                r.restarts += 1;
                let secs = (ran * 10.0).round() / 10.0;
                let max = self.policy.max_consecutive_failures;
                self.log(format!("{name} exited after {}s — restarting ({n}/{max})", swift_double(secs)));
                if let Err(e) = self.start(i) {
                    // The same race, caught late.
                    if self.compositor_is_gone() {
                        return self.compositor_exited();
                    }
                    self.log(format!("could not restart {name}: {e} — tearing down"));
                    self.exit_code = 1;
                    self.stopping = true;
                }
            }
        }
    }

    fn handle_signal(&mut self) {
        let mut b = [0u8; 1];
        let Some(f) = self.signals.as_mut() else { return };
        if f.read(&mut b).ok() != Some(1) {
            return;
        }
        self.log(format!("signal {} received — tearing down the session", b[0]));
        self.stopping = true;
    }

    /// One request on the control service; the listener is non-blocking and
    /// poll said it was readable, so accept returns at once.
    fn handle_control(&mut self) {
        let Some(server) = self.control.take() else { return };
        let _ = server.serve_one(&mut |request: &mut Msg| self.answer(request));
        self.control = Some(server);
        if self.stopping {
            self.log("shutdown requested over the control plane".into());
        }
    }

    fn answer(&mut self, request: &Msg) -> Msg {
        let mut reply = Msg::new();
        match request.string("method").unwrap_or("") {
            "status" => {
                reply.set_bool("ok", true);
                reply.set_bool("running", true);
                reply.set_u64("components", self.components.len() as u64);
                // name=up(restarts): enough to see a flapping one.
                let detail: Vec<String> = self.components.iter().map(|r| format!("{}={}({})", r.spec.name, if r.is_up() { "up" } else { "down" }, r.restarts)).collect();
                reply.set_string("detail", &detail.join(","));
                let locking = live(&self.lock_child);
                reply.set_bool("locking", locking);
                reply.set_bool("locked", locking && self.lock_confirmed);
                // The bus a child of this session sees: the environment it is given.
                if let Some(bus) = self.environment.get("DBUS_SESSION_BUS_ADDRESS").filter(|b| !b.is_empty()) {
                    reply.set_string("bus", bus);
                }
            }
            "quit" | "shutdown" => {
                reply.set_bool("ok", true);
                self.stopping = true;
            }
            "lock" => {
                if self.lock_screen.is_none() {
                    reply.set_bool("ok", false);
                    reply.set_string("error", "this session has no lock screen");
                } else if live(&self.lock_child) {
                    reply.set_bool("ok", true);
                    reply.set_bool("already", true);
                } else if let Some(why) = self.start_lock() {
                    reply.set_bool("ok", false);
                    reply.set_string("error", &why);
                } else {
                    reply.set_bool("ok", true);
                }
            }
            _ => {
                reply.set_bool("ok", false);
                reply.set_string("error", "unknown method");
            }
        }
        reply
    }

    // MARK: the lock screen (P16.2c)

    /// Start the lock screen; None, or why it could not be. Its stdout and
    /// stderr are a socket only anchor holds: before it exits it writes
    /// `abyss-lock-outcome: unlocked` or `…: refused`, and **an exit that
    /// wrote neither is a crash** (a process descriptor reaps with no
    /// status on FreeBSD, so the status cannot say it).
    fn start_lock(&mut self) -> Option<String> {
        let spec = self.lock_screen.clone()?;
        let (ours, theirs) = match UnixStream::pair() {
            Ok(p) => p,
            Err(e) => return Some(format!("no pipe: {}", words(&e))),
        };
        let _ = ours.set_nonblocking(true);
        let theirs: OwnedFd = theirs.into();
        match self.spawn(&spec, Some(theirs.as_fd())) {
            Ok(c) => {
                drop(theirs);
                let pid = c.pid();
                self.lock_child = Some(c);
                self.lock_pipe = Some(ours);
                self.lock_pending.clear();
                self.lock_outcome = None;
                self.lock_confirmed = false;
                self.log(format!("lock screen up (pid {pid}) — the session is locking"));
                None
            }
            Err(e) => {
                self.log(format!("could not start the lock screen: {e}"));
                Some("could not start the lock screen".into())
            }
        }
    }

    /// Read what the lock screen wrote: pass its lines on, keep its outcome.
    /// Read as it runs: a pipe nobody empties fills, and a lock screen
    /// blocked writing its log is a hung lock screen.
    fn drain_lock(&mut self, final_: bool) {
        let Some(pipe) = self.lock_pipe.as_mut() else { return };
        let mut buf = [0u8; 4096];
        let mut eof = false;
        loop {
            match pipe.read(&mut buf) {
                Ok(0) => {
                    eof = true;
                    break;
                }
                Ok(n) => self.lock_pending.extend_from_slice(&buf[..n]),
                Err(e) if e.kind() == ErrorKind::Interrupted => {}
                Err(_) => break, // WouldBlock: nothing more for now
            }
        }
        while let Some(nl) = self.lock_pending.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.lock_pending.drain(..=nl).collect();
            let text = String::from_utf8_lossy(&line[..nl]).into_owned();
            match text.strip_prefix(LOCK_OUTCOME_PREFIX) {
                Some("locked") => {
                    self.lock_confirmed = true;
                    self.log("the session is locked".into());
                }
                Some(word) => self.lock_outcome = Some(word.to_owned()),
                None => {
                    let _ = std::io::stderr().write_all(format!("{text}\n").as_bytes());
                }
            }
        }
        if eof || final_ {
            self.lock_pipe = None;
        }
    }

    fn lock_exited(&mut self) {
        if let Some(c) = self.lock_child.as_mut() {
            c.reap();
        }
        self.drain_lock(true);
        self.lock_confirmed = false;
        let said = self.lock_outcome.clone().unwrap_or_default();
        if self.compositor_is_gone() {
            return self.compositor_exited();
        }
        match said.as_str() {
            "unlocked" => {
                self.log("the lock screen unlocked the session".into());
                self.lock_crashes.clear();
                return;
            }
            "refused" => {
                self.log("the lock screen could not lock (the compositor refused it) — not restarting".into());
                return;
            }
            _ => {}
        }
        let now = monotonic_seconds();
        self.lock_crashes.retain(|t| now - t < LOCK_CRASH_WINDOW);
        self.lock_crashes.push(now);
        let n = self.lock_crashes.len();
        if n > LOCK_CRASH_LIMIT {
            self.log(format!("the lock screen died {n} times in a minute — not restarting it; the compositor keeps the session locked"));
            return;
        }
        self.log(format!("the lock screen died while the session was locked — restarting it ({n}/{LOCK_CRASH_LIMIT}); the session stays locked"));
        let _ = self.start_lock();
    }

    // MARK: teardown

    /// SIGTERM everything at once, one shared beat to exit, then reap. The
    /// components go before the compositor, so they aren't killed by their
    /// display vanishing and logged as crashes.
    fn teardown(&mut self) {
        self.stopping = true;
        let mut any = false;
        let mut term = |c: &Option<Child>| {
            if let Some(c) = c.as_ref().filter(|c| c.is_live()) {
                let _ = c.signal(15);
                any = true;
            }
        };
        for r in &self.components {
            term(&r.child);
        }
        term(&self.lock_child);
        term(&self.first_run_child);
        term(&self.compositor_child);
        if any {
            std::thread::sleep(Duration::from_millis(200)); // one shared grace period
        }
        for r in &mut self.components {
            if let Some(c) = r.child.as_mut() {
                c.reap();
            }
        }
        for c in [&mut self.lock_child, &mut self.first_run_child].into_iter().flatten() {
            c.reap();
        }
        self.lock_pipe = None;
        if let Some(c) = self.compositor_child.as_mut() {
            c.reap();
        }
        if let Some(mut s) = self.control.take() {
            s.shutdown_and_unlink();
        }
        self.log("session down".into());
    }
}

/// A Double as Swift interpolates one: `0.0`, `2.5`, `12.0`.
fn swift_double(v: f64) -> String {
    if v == v.trunc() && v.abs() < 1e16 { format!("{v:.1}") } else { format!("{v}") }
}

fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}
