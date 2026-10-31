//! JailKeeper in Rust: the session's half of confinement (PHASE18 P18.5),
//! ported from Keeper.swift beside it.
//!
//! `abyss-jail serve`, a session component beside the portal and the bridge.
//! It answers `launch class=C argv=…` on the session's `jails` socket:
//!
//!   1. the class's jail, opened from abyss-jaild once and **held for the
//!      session**: pooled, never one per launch. The keeper holds the owning
//!      descriptor, so the jails end with the session, and so does
//!      everything in them;
//!   2. the first time, the jail's own Wayland socket, bound inside its
//!      runtime directory from outside and registered with the compositor as
//!      a security context (P18.3); its own D-Bus *bridge* (never a bus)
//!      listening inside the jail, with the jail's portal, an `abyss-dbus
//!      --jail`, on the bridge's services socket, outside the jail where
//!      nothing jailed can reach it (P18.4). All are this process's children
//!      by descriptor, so they die with it;
//!   3. any argument that names one of the person's files is granted into
//!      the jail first and rewritten to where it is there;
//!   4. the program, started in the jail as the person.
//!
//! For an agent class (P18.8) it answers `agent class=C`: a session of its
//! own, `abyss-model` outside the jail with its socket inside, and
//! `abyss-agent` in the jail on it. When a launched program dies of a
//! signal (P18.9) it keeps the crash, and `debug N` starts a `debug` session
//! with that core. And it watches `jails.ini` (P18.6): when `[apps]` changes
//! it runs `abyss-appgen` again.
//!
//! Anyone in the session may ask it: they are the person already. A jailed
//! process cannot: the socket is in the session's runtime directory, which
//! no jail can see.

mod crash;
#[cfg(test)]
mod tests;

pub use crash::{launch_files, regular_file, Crash};

use abyss_sys::proc::{self, Child};
use abyss_sys::wl::Display;
use current_ipc::{Msg, Server};
use jaild::client::{self, Opened, Start};
use jaild::wire;
use jails::{under, JailClass, JailLayout, APPS_SECTION, BASE_SYSTEM};
use pool_config::Agents;
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{File, OpenOptions};
use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;
use std::time::Duration;

pub const SERVICE: &str = "jails";
pub const ENGINE: &str = "org.abyssbsd.jail";

/// A class's jail, held for the session, and what serves it.
pub struct Held {
    pub opened: Opened,
    /// Held, not read: closed, the compositor stops listening on the
    /// jail's socket.
    _closer: Option<OwnedFd>,
    /// Its bridge, portal and menu bridge: children by descriptor, so they
    /// die with this process.
    _children: Vec<Child>,
}

/// Something running in a jail, and what ends with it.
struct Running {
    proc: OwnedFd,
    pid: u64,
    name: String,
    jail: String,
    /// An agent's model: an agent's exit is not a crash to show.
    model: Option<Child>,
    root: String,
    home: String,
    helpers: Vec<Child>,
}

/// An agent session, as the chat window needs it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentSession {
    pub id: String,
    /// The agent's socket, as the chat window outside reaches it.
    pub socket: String,
    pub transcript: String,
    pub pid: u64,
    /// Whether applications can be given to it (P18.10).
    pub vocabulary: bool,
    /// Its budget in tokens (P18.11).
    pub budget: i64,
}

fn stop(mut c: Child) {
    let _ = c.signal(libc::SIGTERM);
    c.reap();
}

fn kill(mut c: Child) {
    let _ = c.signal(libc::SIGKILL);
    c.reap();
}

fn me() -> String {
    abyss_sys::users::by_uid(abyss_sys::platform::euid()).map(|a| a.name).unwrap_or_default()
}

pub struct JailKeeper {
    pub jaild_socket: String,
    /// Where abyss-dbus, abyss-model and the rest are (this binary's
    /// directory).
    pub bin_dir: String,
    held: BTreeMap<String, Held>,
    /// `abyss-appgen` and its arguments, run when `[apps]` changes (P18.6).
    pub appgen: Option<Vec<String>>,
    apps_seen: String,
    procs: Vec<Running>,
    /// Agent sessions' control sockets, by session ID: vocabulary (P18.10),
    /// model (P18.11) and fetch bridge (P18.12b).
    vocabularies: BTreeMap<String, String>,
    models: BTreeMap<String, String>,
    fetches: BTreeMap<String, String>,
    /// Grants the keeper made for itself, not for the person (a developer's
    /// abyss-agent handed into a jail), as "JAIL<TAB>N": not shown as the
    /// person's, nor offered to revoke (P18.11b).
    own_grants: BTreeSet<String>,
    /// Crashes seen this session, by number (P18.9).
    crashes: BTreeMap<u64, Crash>,
    /// What shows a crash to the person (P18.9b): AquaDemo's Crash Reporter.
    /// None without a display, when nobody would see it.
    pub crash_dialog: Option<Vec<String>>,
    sessions: u64,
    /// Where agent transcripts are kept: outside every jail, and past the
    /// session.
    pub agent_logs: String,
    server: Server,
    display: Option<Display>,
    runtime_dir: String,
    classes: Vec<JailClass>,
    say: Box<dyn Fn(&str)>,
}

impl JailKeeper {
    pub fn new(server: Server, display: Option<Display>, runtime_dir: &str, bin_dir: &str, classes: Vec<JailClass>, log: impl Fn(&str) + 'static) -> JailKeeper {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        JailKeeper {
            jaild_socket: wire::DEFAULT_SOCKET.into(),
            bin_dir: bin_dir.into(),
            held: BTreeMap::new(),
            appgen: None,
            apps_seen: String::new(),
            procs: vec![],
            vocabularies: BTreeMap::new(),
            models: BTreeMap::new(),
            fetches: BTreeMap::new(),
            own_grants: BTreeSet::new(),
            crashes: BTreeMap::new(),
            crash_dialog: None,
            sessions: 0,
            agent_logs: format!("{home}/Library/Logs/Agents"),
            server,
            display,
            runtime_dir: runtime_dir.into(),
            classes,
            say: Box::new(log),
        }
    }

    fn class(&self, name: &str) -> Option<&JailClass> {
        self.classes.iter().find(|c| c.name == name)
    }

    fn system_of(&self, cls: &str) -> Vec<String> {
        self.class(cls).map_or_else(|| BASE_SYSTEM.iter().map(|s| (*s).to_owned()).collect(), |c| c.system.clone())
    }

    // MARK: the jail, once per class

    fn ensure(&mut self, cls: &str) -> Result<&Held, String> {
        if self.held.contains_key(cls) {
            return Ok(&self.held[cls]);
        }
        let opened = client::open(cls, &self.jaild_socket)?;
        let wayland = self.class(cls).is_none_or(|c| c.wayland);
        let mut closer = None;
        // Wayland: a socket of the jail's own, made from outside.
        if wayland && let Some(d) = &self.display {
            let path = format!("{}/{}", opened.runtime, JailLayout::WAYLAND_DISPLAY);
            match d.jail_listen(&path, ENGINE, cls, &opened.jid.to_string()) {
                Ok(c) => closer = Some(c),
                Err(rc) => return Err(format!("the compositor would not take {}'s socket ({})", opened.name, -rc)),
            }
        }
        // A class without a display (an agent's) has no GTK application, so
        // no bridge, portal or menus: nothing it does not need.
        if !wayland {
            (self.say)(&format!("jails: {} is jail {}; no display, so no socket or bus", opened.name, opened.jid));
            return Ok(self.held.entry(cls.into()).or_insert(Held { opened, _closer: closer, _children: vec![] }));
        }
        // On failure the socket's closer and the jail descriptor drop here.
        let children = self.gtk_side(cls, &opened)?;
        (self.say)(&format!("jails: {} is jail {}; its socket, bus, portal and menus are up", opened.name, opened.jid));
        Ok(self.held.entry(cls.into()).or_insert(Held { opened, _closer: closer, _children: children }))
    }

    /// Its D-Bus bridge (never a bus: §5.6), the jail's portal on the
    /// bridge's services socket, outside the jail, and its menu bridge: a
    /// confined GTK application's menus are on this bus, which the session's
    /// menu bridge cannot reach.
    fn gtk_side(&self, cls: &str, opened: &Opened) -> Result<Vec<Child>, String> {
        let dir = format!("{}/jails/{cls}", self.runtime_dir);
        let _ = std::fs::create_dir_all(&dir);
        let services = format!("{dir}/dbus-services");
        let dbus = format!("{}/abyss-dbus", self.bin_dir);
        let mut out = vec![];
        let fail = |out: Vec<Child>, e: String| {
            out.into_iter().for_each(kill);
            Err(e)
        };
        match self.child(&[&dbus, "--endpoint", "--listen", &format!("{}/bus", opened.runtime), "--services", &services], &format!("{dir}/endpoint.log")) {
            Ok(c) => out.push(c),
            Err(e) => return fail(out, e),
        }
        for _ in 0..100 {
            if std::path::Path::new(&services).exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let bus = format!("unix:path={services}");
        let rest: [(Vec<&str>, &str); 2] = [
            (vec![&dbus, "--bus", &bus, "--jail", &opened.name, "--jaild", &self.jaild_socket], "bridge.log"),
            (vec![&dbus, "--menus", "--bus", &bus, "--class", cls], "menus.log"),
        ];
        for (argv, log) in rest {
            match self.child(&argv, &format!("{dir}/{log}")) {
                Ok(c) => out.push(c),
                Err(e) => return fail(out, e),
            }
        }
        Ok(out)
    }

    /// A helper, its output to `log`, with this process's environment.
    fn child(&self, argv: &[&str], log: &str) -> Result<Child, String> {
        let f = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(log).ok();
        let env: Vec<String> = std::env::vars().map(|(k, v)| format!("{k}={v}")).collect();
        let argv: Vec<String> = argv.iter().map(|a| (*a).to_owned()).collect();
        Child::spawn(&argv, &env, f.as_ref().map(|f| f.as_fd())).map_err(|e| format!("cannot start {}: {e}", argv[0]))
    }

    /// Grant `path` read-only: the desktop's own (a core, a binary, a
    /// developer's abyss-agent), never the person's to edit through it.
    fn grant_read_only(&self, jail: &str, path: &str) -> Result<(String, u64), String> {
        let f = File::open(path).map_err(|_| format!("cannot open {path}"))?;
        client::grant(jail, path, f.as_fd(), &self.jaild_socket)
    }

    // MARK: launch

    pub fn launch(&mut self, cls: &str, argv: &[String]) -> Result<u64, String> {
        if argv.is_empty() {
            return Err("nothing to launch".into());
        }
        let system = self.system_of(cls);
        let name = self.ensure(cls)?.opened.name.clone();
        let mut args = argv.to_vec();
        for (i, real) in launch_files(argv, &system, regular_file) {
            // Edited in place when the person may write it; read-only if
            // not. A file that cannot be opened is passed as it is; a grant
            // jaild refuses refuses the launch.
            let Ok(f) = OpenOptions::new().read(true).write(true).open(&real).or_else(|_| File::open(&real)) else { continue };
            let (inside, _) = client::grant(&name, &real, f.as_fd(), &self.jaild_socket)?;
            (self.say)(&format!("jails: {real} is {inside} in {name}"));
            args[i] = inside;
        }
        let h = &self.held[cls];
        let (pid, proc) = client::spawn(h.opened.jail.as_fd(), &Start { argv: &args, ..Start::default() }, &self.jaild_socket)?;
        let (root, home) = (h.opened.root.clone(), h.opened.home.clone());
        self.procs.push(Running { proc, pid, name: args[0].clone(), jail: name.clone(), model: None, root, home, helpers: vec![] });
        (self.say)(&format!("jails: launched {} as pid {pid} in {name}", argv[0]));
        Ok(pid)
    }

    // MARK: agents (P18.8)

    /// `abyss-model serve`'s backend arguments for a class's `model=`.
    pub fn model_args(spec: &str) -> Option<Vec<String>> {
        let two = |a: &str, b: &str| Some(vec![a.to_owned(), b.to_owned()]);
        if let Some(p) = spec.strip_prefix("local:") {
            two("--local", p)
        } else if let Some(p) = spec.strip_prefix("stub:") {
            two("--stub", p)
        } else if spec.starts_with("http://") {
            two("--backend", spec)
        } else {
            None
        }
    }

    // MARK: crashes (P18.9)

    fn crashed(&mut self, r: &Running, signal: i32, core_dumped: bool) {
        // Named by the home's source, not its mount in the root: jaild grants
        // nothing from inside a jail's root (no jail-to-jail through a tree).
        let core = format!("{}/{}", r.home, Crash::core_name(&r.name));
        let inside = Crash::binary_inside(&r.name, &r.root).unwrap_or_else(|| r.name.clone());
        let home_inside = format!("/home/{}", me());
        let binary = if under(&inside, &home_inside) { format!("{}{}", r.home, &inside[home_inside.len()..]) } else { format!("{}{inside}", r.root) };
        let c = Crash {
            id: self.crashes.len() as u64 + 1,
            program: r.name.clone(),
            jail: r.jail.clone(),
            signal,
            core_dumped: core_dumped && File::open(&core).is_ok(),
            core: core.clone(),
            binary_inside: inside,
            binary,
        };
        (self.say)(&format!("jails: crash {}: {} in {}{}", c.id, c.summary(), r.jail, if c.core_dumped { format!(" (core {core})") } else { String::new() }));
        if let Some(argv) = &self.crash_dialog {
            let app = r.name.rsplit('/').next().unwrap_or(&r.name).to_owned();
            let env = BTreeMap::from([
                ("AQUA_SCENE".to_owned(), "crashreport".to_owned()),
                ("ABYSS_CRASH_ID".to_owned(), c.id.to_string()),
                ("ABYSS_CRASH_APP".to_owned(), app),
                ("ABYSS_CRASH_SIGNAL".to_owned(), Crash::signal_name(signal)),
                ("ABYSS_CRASH_CORE".to_owned(), if c.core_dumped { "1" } else { "0" }.to_owned()),
                ("ABYSS_AGENTS".to_owned(), if Agents::on(None) { "1" } else { "0" }.to_owned()),
            ]);
            let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
            let shown = spawn::detached(&argv, &env);
            (self.say)(&format!("jails: crash {} {}", c.id, if shown { "shown" } else { "could not be shown" }));
        }
        self.crashes.insert(c.id, c);
    }

    /// A `debug` session for crash `id`: its core, and its binary if the
    /// debug jail does not see it anyway, granted read-only: that crash, no
    /// other.
    pub fn debug(&mut self, id: u64) -> Result<AgentSession, String> {
        if !Agents::on(None) {
            return Err("agents are off: there is no agents.ini".into());
        }
        let c = self.crashes.get(&id).cloned().ok_or(format!("there is no crash {id}"))?;
        if !c.core_dumped {
            return Err(format!("{}: there is nothing to read", c.summary()));
        }
        let cls = "debug";
        let system = self.system_of(cls);
        let (name, home) = {
            let h = self.ensure(cls)?;
            (h.opened.name.clone(), h.opened.home.clone())
        };
        let core = self.grant_read_only(&name, &c.core)?.0;
        let mut binary = c.binary_inside.clone();
        if !system.iter().any(|s| under(&c.binary_inside, s)) {
            let granted = self.grant_read_only(&name, &c.binary)?.0;
            // **lldb wants the binary where the core says it ran** (base lldb
            // 21 asserts in ResolveContainedAddress otherwise; HANDOFF
            // §2.130). A program from the person's home ran at /home/NAME/…,
            // and the debug jail's /home/NAME is its own home: a link there,
            // made from outside in the home's source, to the read-only grant.
            let home_inside = format!("/home/{}", me());
            binary = granted.clone();
            if under(&c.binary_inside, &home_inside) && !home.is_empty() {
                let link = format!("{home}{}", &c.binary_inside[home_inside.len()..]);
                if std::fs::symlink_metadata(&link).is_ok_and(|m| m.file_type().is_symlink()) {
                    let _ = std::fs::remove_file(&link);
                }
                if std::fs::symlink_metadata(&link).is_err() && std::os::unix::fs::symlink(&granted, &link).is_ok() {
                    (self.say)(&format!("jails: {} in {name} is a link to {granted}", c.binary_inside));
                    binary = c.binary_inside.clone();
                }
            }
        }
        (self.say)(&format!("jails: crash {id}'s core is {core} in {name}, its binary {binary}"));
        self.agent(cls, &["--core".into(), core, "--binary".into(), binary, "--crash".into(), c.summary()])
    }

    pub fn agent(&mut self, cls: &str, extra: &[String]) -> Result<AgentSession, String> {
        // Off is one file, absent (P18.13): no agent process at all.
        if !Agents::on(None) {
            return Err("agents are off: there is no agents.ini".into());
        }
        let k = self.class(cls).filter(|k| k.agent).cloned().ok_or(format!("{cls} is not an agent class"))?;
        if k.model.is_empty() {
            return Err(format!("no model is set for {cls}: set model= in jails.ini [{cls}]"));
        }
        let backend = JailKeeper::model_args(&k.model).ok_or(format!("{cls}'s model= is not local:, stub: or http://: {}", k.model))?;
        let (name, runtime, jail_fd) = {
            let h = self.ensure(cls)?;
            (h.opened.name.clone(), h.opened.runtime.clone(), h.opened.jail.try_clone().map_err(|e| e.to_string())?)
        };
        self.sessions += 1;
        let n = self.sessions;
        let stamp: String = abyss_sys::platform::local_timestamp().chars().filter(|c| *c != '-' && *c != ':').map(|c| if c == ' ' { '-' } else { c }).collect();
        let id = format!("{stamp}-{cls}-{}-{n}", std::process::id());
        let transcript = format!("{}/{id}", self.agent_logs);
        let _ = std::fs::DirBuilder::new().recursive(true).create(&transcript);
        for d in [&self.agent_logs, &transcript] {
            let _ = std::fs::set_permissions(d, std::os::unix::fs::PermissionsExt::from_mode(0o700));
        }
        let bin = |b: &str| format!("{}/{b}", self.bin_dir);

        // The model, outside the jail, on a socket inside it.
        let (model_sock, agent_sock) = (format!("model-{n}.sock"), format!("agent-{n}.sock"));
        let outside = format!("{runtime}/{model_sock}");
        let model_control = format!("{transcript}/model.sock");
        let budget = k.budget.to_string();
        let model_bin = bin("abyss-model");
        let mut argv: Vec<&str> =
            vec![&model_bin, "serve", "--listen", &outside, "--session", &id, "--budget", &budget, "--transcript", &transcript, "--control", &model_control];
        argv.extend(backend.iter().map(String::as_str));
        let model = self.child(&argv, &format!("{transcript}/abyss-model.log"))?;
        if !wait_for_socket(&outside, 300, Some(&model)) {
            stop(model);
            return Err(format!("abyss-model did not start for {id}"));
        }
        self.models.insert(id.clone(), model_control);

        let mut helpers: Vec<Child> = vec![];
        let mut more: Vec<String> = vec![];
        let fail = |model: Child, helpers: Vec<Child>, why: String| {
            helpers.into_iter().for_each(stop);
            stop(model);
            Err(why)
        };
        // Its vocabulary (P18.10) and its way to the web (P18.12b), when the
        // class has them: each bridge outside, answering inside, with the
        // person's answers on a control socket beside the transcript.
        for (on, tool, flag) in [(k.vocabulary, "vocab", "--vocab"), (k.fetch, "fetch", "--fetch")] {
            if !on {
                continue;
            }
            let sock = format!("{tool}-{n}.sock");
            let control = format!("{transcript}/{}.sock", if tool == "vocab" { "vocabulary" } else { tool });
            let exe = bin(&format!("abyss-{tool}"));
            let listen = format!("{runtime}/{sock}");
            let c = match self.child(&[&exe, "serve", "--listen", &listen, "--control", &control, "--session", &id, "--transcript", &transcript], &format!("{transcript}/abyss-{tool}.log")) {
                Ok(c) => c,
                Err(e) => return fail(model, helpers, e),
            };
            if !wait_for_socket(&control, 10, Some(&c)) {
                stop(c);
                return fail(model, helpers, format!("abyss-{tool} did not start for {id}"));
            }
            helpers.push(c);
            if tool == "vocab" { &mut self.vocabularies } else { &mut self.fetches }.insert(id.clone(), control);
            more.extend([flag.to_owned(), format!("{}/{sock}", JailLayout::RUNTIME)]);
        }

        // The agent, in the jail. A build outside what the jail sees (a
        // developer's) comes in as a read-only grant, like a document.
        let mut agent_path = bin("abyss-agent");
        if !k.system.iter().any(|s| under(&agent_path, s)) {
            match self.grant_read_only(&name, &agent_path) {
                Ok((inside, g)) => {
                    agent_path = inside;
                    self.own_grants.insert(format!("{name}\t{g}"));
                }
                Err(e) => return fail(model, helpers, format!("cannot give the jail abyss-agent: {e}")),
            }
        }
        let mut agent_argv = vec![
            agent_path,
            "serve".into(),
            "--model".into(),
            format!("{}/{model_sock}", JailLayout::RUNTIME),
            "--listen".into(),
            format!("{}/{agent_sock}", JailLayout::RUNTIME),
            "--class".into(),
            cls.into(),
        ];
        agent_argv.extend(extra.iter().cloned());
        agent_argv.extend(more);
        let (pid, proc) = match client::spawn(jail_fd.as_fd(), &Start { argv: &agent_argv, ..Start::default() }, &self.jaild_socket) {
            Ok(x) => x,
            Err(e) => return fail(model, helpers, format!("cannot start abyss-agent: {e}")),
        };
        let h = &self.held[cls];
        let (root, home) = (h.opened.root.clone(), h.opened.home.clone());
        self.procs.push(Running { proc, pid, name: "abyss-agent".into(), jail: name.clone(), model: Some(model), root, home, helpers });
        let socket = format!("{runtime}/{agent_sock}");
        if !wait_for_socket(&socket, 30, None) {
            return Err(format!("abyss-agent did not start in {name}"));
        }
        (self.say)(&format!("jails: agent session {id} in {name}: agent pid {pid}, transcript {transcript}"));
        Ok(AgentSession { id, socket, transcript, pid, vocabulary: k.vocabulary, budget: k.budget })
    }

    /// One request on a session's control socket, outside its jail.
    fn control(path: Option<&String>, m: &Msg, what: &str) -> Result<Msg, String> {
        let path = path.ok_or(format!("there is no agent session with {what}"))?;
        client::call(m, path)
    }

    /// Give an application to an agent session (P18.10): `app` as a person
    /// names it, or by its menu service, told to that session's bridge.
    pub fn give(&self, session: &str, app: &str) -> Result<String, String> {
        let control = self.vocabularies.get(session).ok_or(format!("there is no agent session {session} with a vocabulary"))?;
        let service = menu_wire::client::resolve(app).map_err(|e| format!("no running application {app}: {e}"))?;
        let mut m = Msg::new();
        m.set_string("method", "give");
        m.set_string("service", &service);
        let r = client::call(&m, control).map_err(|e| if e == "refused" { "the bridge refused".into() } else { e })?;
        let name = r.string("app").ok_or("the bridge refused")?.to_owned();
        (self.say)(&format!("jails: gave {name} ({service}) to agent session {session}"));
        Ok(name)
    }

    /// The person allowed more (P18.11): `tokens` more for the session's
    /// model. The new budget.
    pub fn raise(&self, session: &str, tokens: u64) -> Result<u64, String> {
        if tokens == 0 {
            return Err("a raise needs tokens".into());
        }
        let mut m = Msg::new();
        m.set_string("method", "raise");
        m.set_u64("tokens", tokens);
        let r = JailKeeper::control(self.models.get(session), &m, &format!("a model {session}"))?;
        let budget = r.u64("budget").unwrap_or(0);
        (self.say)(&format!("jails: agent session {session} may use {tokens} more tokens (budget {budget})"));
        Ok(budget)
    }

    /// The person's answer to requester 1 (P18.11), may `app` write for the
    /// session's agent; or to requester 3 (P18.12b), may it reach `host`.
    fn answer(&self, session: &str, key: &str, value: &str, allow: bool) -> Result<(), String> {
        let mut m = Msg::new();
        m.set_string("method", "permit");
        m.set_string(key, value);
        m.set_bool("allow", allow);
        let (to, what) = if key == "host" { (self.fetches.get(session), "a fetch bridge") } else { (self.vocabularies.get(session), "a vocabulary") };
        JailKeeper::control(to, &m, &format!("{what} {session}"))?;
        let verb = if allow { "allowed" } else { "did not allow" };
        let said = if key == "host" { format!("agent session {session} to reach {value}") } else { format!("{value} to write for agent session {session}") };
        (self.say)(&format!("jails: {verb} {said}"));
        Ok(())
    }

    /// Take a given application back from a session (P18.11).
    pub fn take(&self, session: &str, app: &str) -> Result<(), String> {
        let mut m = Msg::new();
        m.set_string("method", "take");
        m.set_string("app", app);
        JailKeeper::control(self.vocabularies.get(session), &m, &format!("a vocabulary {session}"))?;
        (self.say)(&format!("jails: took {app} back from agent session {session}"));
        Ok(())
    }

    // MARK: the loop

    /// `[apps]` as it stands, one row per line.
    fn apps_rows() -> String {
        let c = pool_config::load("jails", None).unwrap_or_default();
        c.pairs(APPS_SECTION).iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("\n")
    }

    fn apps_may_have_changed(&mut self) {
        let now = JailKeeper::apps_rows();
        if now == self.apps_seen {
            return;
        }
        self.apps_seen = now;
        if let Some(appgen) = &self.appgen {
            (self.say)("jails: jails.ini's [apps] changed; making the applications again");
            let argv: Vec<&str> = appgen.iter().map(String::as_str).collect();
            spawn::detached(&argv, &BTreeMap::new());
        }
    }

    pub fn run(&mut self) {
        self.apps_seen = JailKeeper::apps_rows();
        let watcher = pool_config::Watcher::new(None).ok();
        loop {
            if let Some(d) = &self.display {
                d.flush();
            }
            let wl = self.display.as_ref().map_or(-1, |d| d.fd());
            let mut fds = vec![
                proc::poll_fd(self.server.fd(), proc::POLLIN),
                proc::poll_fd(wl, proc::POLLIN),
                proc::poll_fd(watcher.as_ref().map_or(-1, |w| w.as_raw_fd()), proc::POLLIN),
            ];
            fds.extend(self.procs.iter().map(|p| proc::poll_fd(p.proc.as_raw_fd(), proc::POLLHUP | proc::POLLIN)));
            match proc::poll(&mut fds, -1) {
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return,
                Ok(_) => {}
            }
            if fds[2].revents != 0 && watcher.as_ref().is_some_and(|w| w.drain()) {
                self.apps_may_have_changed();
            }
            // The compositor went away: the session is over.
            if fds[1].revents != 0 && self.display.as_ref().is_some_and(|d| !d.dispatch()) {
                (self.say)("jails: the compositor is gone");
                return;
            }
            for i in (0..self.procs.len()).rev() {
                if fds[i + 3].revents == 0 {
                    continue;
                }
                let p = self.procs.remove(i);
                let status = abyss_sys::jail::wait(p.proc.as_fd());
                if p.model.is_none()
                    && let Ok(s) = status
                    && let Some((sig, dumped)) = Crash::signal_of(s)
                {
                    self.crashed(&p, sig, dumped);
                }
                (self.say)(&format!("jails: {} (pid {}) in {} exited", p.name, p.pid, p.jail));
                if let Some(m) = p.model {
                    stop(m);
                    (self.say)("jails: its model stopped");
                }
                if !p.helpers.is_empty() {
                    p.helpers.into_iter().for_each(stop);
                    (self.say)("jails: its vocabulary and fetch bridges stopped");
                }
            }
            if fds[0].revents != 0 {
                self.serve_one();
            }
        }
    }

    fn session_reply(r: Result<AgentSession, String>, what: &str, say: &dyn Fn(&str)) -> Msg {
        match r {
            Ok(a) => {
                let mut m = ok();
                m.set_string("session", &a.id);
                m.set_string("socket", &a.socket);
                m.set_string("transcript", &a.transcript);
                m.set_u64("pid", a.pid);
                m.set_bool("vocabulary", a.vocabulary);
                m.set_u64("budget", a.budget.max(0) as u64);
                m
            }
            Err(e) => refused(what, &e, say),
        }
    }

    fn serve_one(&mut self) {
        let Ok(c) = self.server.accept() else { return };
        let Ok(mut req) = current_ipc::receive(&c) else { return };
        req.close_fds();
        let s = |k: &str| req.string(k).unwrap_or("").to_owned();
        let reply = match req.string("method").unwrap_or("") {
            "launch" => match self.launch(&s("class"), &wire::unlist(req.bytes("argv").unwrap_or(&[]))) {
                Ok(pid) => {
                    let mut m = ok();
                    m.set_u64("pid", pid);
                    m
                }
                Err(e) => refused("launch", &e, &*self.say),
            },
            "agent" => {
                let r = self.agent(&s("class"), &[]);
                JailKeeper::session_reply(r, "agent", &*self.say)
            }
            "debug" => {
                let r = self.debug(req.u64("crash").unwrap_or(0));
                JailKeeper::session_reply(r, "debug", &*self.say)
            }
            "give" => match self.give(&s("session"), &s("app")) {
                Ok(name) => {
                    let mut m = ok();
                    m.set_string("app", &name);
                    m
                }
                Err(e) => refused("give", &e, &*self.say),
            },
            "raise" => match self.raise(&s("session"), req.u64("tokens").unwrap_or(0)) {
                Ok(b) => {
                    let mut m = ok();
                    m.set_u64("budget", b);
                    m
                }
                Err(e) => refused("raise", &e, &*self.say),
            },
            "permit" => self.answer(&s("session"), "app", &s("app"), req.bool("allow") == Some(true)).map_or_else(|e| refused("permit", &e, &*self.say), |_| ok()),
            "permit-host" => {
                self.answer(&s("session"), "host", &s("host"), req.bool("allow") == Some(true)).map_or_else(|e| refused("permit-host", &e, &*self.say), |_| ok())
            }
            "take" => self.take(&s("session"), &s("app")).map_or_else(|e| refused("take", &e, &*self.say), |_| ok()),
            // The files given to the session's jails (P18.4), for the
            // Preferences pane (P18.11b): "JAIL<TAB>N<TAB>ro|rw<TAB>inside<TAB>source".
            "grants" => {
                let mut rows = vec![];
                for h in self.held.values() {
                    for g in client::grants(&h.opened.name, &self.jaild_socket).unwrap_or_default() {
                        let n = g.split('\t').next().unwrap_or("");
                        if !self.own_grants.contains(&format!("{}\t{n}", h.opened.name)) {
                            rows.push(format!("{}\t{g}", h.opened.name));
                        }
                    }
                }
                rows.sort();
                let mut m = ok();
                m.set_bytes("grants", &wire::list(&rows));
                m
            }
            // A grant taken back, from the Preferences pane: only in a jail
            // this session holds, and never the desktop's own.
            "revoke" => {
                let (name, n) = (s("jail"), req.u64("grant").unwrap_or(0));
                if !self.held.values().any(|h| h.opened.name == name) {
                    wire::error(&format!("{name} is not one of this session's jails"))
                } else if self.own_grants.contains(&format!("{name}\t{n}")) {
                    wire::error(&format!("grant {n} in {name} is the desktop's own, not one of your files"))
                } else {
                    match client::revoke(&name, n, &self.jaild_socket) {
                        Ok(()) => {
                            (self.say)(&format!("jails: revoked grant {n} in {name}"));
                            ok()
                        }
                        Err(e) => refused("revoke", &e, &*self.say),
                    }
                }
            }
            "crashes" => {
                let rows: Vec<String> = self.crashes.values().map(|c| format!("{} {} in {}", c.id, c.summary(), c.jail)).collect();
                let mut m = ok();
                m.set_bytes("crashes", &wire::list(&rows));
                m
            }
            "held" => {
                let rows: Vec<String> = self.held.values().map(|h| format!("{} jid={}", h.opened.name, h.opened.jid)).collect();
                let mut m = ok();
                m.set_bytes("jails", &wire::list(&rows));
                m
            }
            _ => wire::error("unknown method"),
        };
        let _ = current_ipc::send(&reply, &c);
    }
}

fn ok() -> Msg {
    let mut m = Msg::new();
    m.set_bool("ok", true);
    m
}

fn refused(what: &str, why: &str, say: &dyn Fn(&str)) -> Msg {
    say(&format!("jails: {what} refused: {why}"));
    wire::error(why)
}

/// Wait for a socket to appear, giving up if `child` exits first.
fn wait_for_socket(path: &str, seconds: u64, child: Option<&Child>) -> bool {
    for _ in 0..seconds * 20 {
        if std::path::Path::new(path).exists() {
            return true;
        }
        if let Some(c) = child {
            let mut p = [proc::poll_fd(c.fd(), proc::child_exit_events())];
            if proc::poll(&mut p, 0).unwrap_or(0) > 0 {
                return false;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}
