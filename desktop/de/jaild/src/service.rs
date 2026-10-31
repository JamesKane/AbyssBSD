//! abyss-jaild's loop, as a library (Service.swift, PHASE18 P18.2).
//!
//! It watches every jail it made through a non-owning descriptor of its own,
//! and when one is removed (its owner closed it, or died) it unmounts and
//! removes the root. On start it does the same for whatever a previous run
//! left (`sweep`), and adopts the jails still alive.
//!
//! The classes are the shipped ones and a root-owned file's, never a
//! user's: a person's own `jails.ini` is a request, and what a root daemon
//! mounts is the system's decision.

use crate::performer::Performer;
use crate::steps::{self, JailCommands};
use crate::{wire, JailAccount};
use abyss_sys::{jail, platform, proc};
use current_ipc::{Msg, Server};
use jails::{under, JailClass, JailLayout, JailPlan};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::Read;
use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::os::unix::fs::MetadataExt;

/// A file granted into a jail.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Grant {
    pub n: u64,
    pub source: String,
    pub inside: String,
    pub writable: bool,
}

struct Live {
    /// Our non-owning descriptor, watched for the jail's removal.
    watch: Option<OwnedFd>,
    plan: JailPlan,
    uid: u32,
    grants: Vec<Grant>,
    next_grant: u64,
}

impl Live {
    fn new(watch: Option<OwnedFd>, plan: JailPlan, uid: u32) -> Live {
        Live { watch, plan, uid, grants: vec![], next_grant: 1 }
    }
}

pub type AccountOf = Box<dyn Fn(u32) -> Option<JailAccount>>;

pub struct JailService {
    server: Server,
    pub layout: JailLayout,
    pub classes: Vec<JailClass>,
    pub pool: Option<String>,
    pub account_of: AccountOf,
    performer: Performer,
    say: Box<dyn Fn(&str)>,
    watch: Option<jail::Watch>,
    live: BTreeMap<String, Live>,
}

impl JailService {
    pub fn new(server: Server, layout: JailLayout, classes: Vec<JailClass>, pool: Option<String>, commands: JailCommands, log: impl Fn(&str) + 'static) -> JailService {
        JailService {
            server,
            layout,
            classes,
            pool,
            account_of: Box::new(JailAccount::system),
            performer: Performer { commands },
            say: Box::new(log),
            watch: jail::Watch::new().ok(),
            live: BTreeMap::new(),
        }
    }

    fn plan(&self, cls: &JailClass, acct: &JailAccount) -> JailPlan {
        JailPlan::make(cls, &acct.user, self.pool.as_deref(), &self.layout)
    }

    fn watch(&self, desc: &OwnedFd) {
        if let Some(w) = &self.watch {
            let _ = w.add(desc.as_fd());
        }
    }

    // MARK: start: what a previous run left

    /// Adopt the jails still alive under our roots; tear down the roots of
    /// those that are gone.
    pub fn sweep(&mut self) {
        for root in steps::left_roots(&self.layout.root_base, &jail::mount_points()) {
            let Some(name) = steps::jail_name(&root, &self.layout.root_base) else { continue };
            let parts: Vec<&str> = name.splitn(3, '-').collect();
            let desc = jail::desc_by_name(&name).ok();
            let adopt = (|| {
                let uid: u32 = parts.get(1)?.parse().ok()?;
                let acct = (self.account_of)(uid)?;
                let cls = self.classes.iter().find(|c| Some(&c.name.as_str()) == parts.get(2))?;
                Some((uid, self.plan(cls, &acct)))
            })();
            match (desc, adopt) {
                (Some(d), Some((uid, plan))) => {
                    self.watch(&d);
                    self.live.insert(name.clone(), Live::new(Some(d), plan, uid));
                    (self.say)(&format!("jaild: adopted {name}, still running"));
                }
                _ => self.teardown(&root, &name, "left by a previous run"),
            }
        }
    }

    fn teardown(&self, root: &str, name: &str, why: &str) {
        let failures = self.performer.perform_all(&steps::teardown(root, &jail::mount_points(), &self.performer.commands));
        if failures.is_empty() {
            (self.say)(&format!("jaild: {name} removed ({why}); its root is gone"));
        }
        for f in failures {
            (self.say)(&format!("jaild: {name}: teardown: {f}"));
        }
    }

    // MARK: the loop

    /// Serve until `once` has answered one request (a test), or for ever.
    ///
    /// **Every program a jail runs is this daemon's child** (pdfork), and on
    /// FreeBSD closing a process descriptor does not reap one (HANDOFF
    /// §2.108): without a `waitpid` here it stays a zombie, inside its jail,
    /// which then never finishes dying (§2.123). So SIGCHLD comes in on a
    /// self-pipe, and every exited child is reaped.
    pub fn run(&mut self, once: bool) {
        let mut chld = proc::signal_pipe(&[libc::SIGCHLD]).ok().map(File::from);
        loop {
            let kq = self.watch.as_ref().map_or(-1, |w| w.fd());
            let pipe = chld.as_ref().map_or(-1, |f| f.as_raw_fd());
            let mut fds = [proc::poll_fd(self.server.fd(), proc::POLLIN), proc::poll_fd(kq, proc::POLLIN), proc::poll_fd(pipe, proc::POLLIN)];
            match proc::poll(&mut fds, -1) {
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return,
                Ok(_) => {}
            }
            if fds[2].revents != 0
                && let Some(f) = chld.as_mut()
            {
                let mut b = [0u8; 64];
                let _ = f.read(&mut b);
                proc::reap_exited();
            }
            if fds[1].revents != 0 {
                self.reap();
            }
            if fds[0].revents != 0 {
                self.serve_one();
                if once {
                    return;
                }
            }
        }
    }

    /// Jails whose owners let go: tear their roots down.
    fn reap(&mut self) {
        while let Some(gone) = self.watch.as_ref().and_then(|w| w.removed()) {
            let Some(name) = self.live.iter().find(|(_, l)| l.watch.as_ref().is_some_and(|w| w.as_raw_fd() == gone)).map(|(n, _)| n.clone()) else {
                continue;
            };
            let l = self.live.remove(&name).expect("found above");
            drop(l.watch);
            self.teardown(&l.plan.root, &name, "its owner let go");
        }
    }

    fn serve_one(&mut self) {
        let Ok(client) = self.server.accept() else { return };
        let Ok(mut request) = current_ipc::receive(&client) else { return };
        // The descriptors handed over go when this returns: an owning jail
        // descriptor kept here would keep every jail alive for ever.
        let (reply, _handed) = match platform::peer_uid(client.as_fd()) {
            Err(_) => (wire::error("the kernel would not identify the caller"), None),
            Ok(0) => (wire::error("root is not confined"), None),
            Ok(uid) => match request.string("method").unwrap_or("") {
                "open" => {
                    let class = request.string("class").unwrap_or("").to_owned();
                    self.open(uid, &class)
                }
                "spawn" => self.spawn(uid, &mut request),
                "grant" => (self.grant(uid, &mut request), None),
                "revoke" => (self.revoke(uid, &request), None),
                "grants" => (self.grants(uid, &request), None),
                other => (wire::error(&format!("unknown method '{other}'")), None),
            },
        };
        let _ = current_ipc::send(&reply, &client);
        request.close_fds();
    }

    // MARK: open

    fn open(&mut self, uid: u32, class: &str) -> (Msg, Option<OwnedFd>) {
        let Some(acct) = (self.account_of)(uid) else { return (wire::error(&format!("uid {uid} has no account")), None) };
        let Some(cls) = self.classes.iter().find(|c| c.name == class) else {
            let names: Vec<&str> = self.classes.iter().map(|c| c.name.as_str()).collect();
            return (wire::error(&format!("no class '{class}' (there are: {})", names.join(", "))), None);
        };
        let plan = self.plan(cls, &acct);
        let v = plan.violations(cls, &acct.home);
        if !v.is_empty() {
            (self.say)(&format!("jaild: refused {}: {}", plan.name, v.join("; ")));
            return (wire::error(&format!("refused: {}", v.join("; "))), None);
        }

        if self.live.contains_key(&plan.name) {
            return match jail::desc_by_name(&plan.name) {
                Ok(shared) => (opened(&plan, &shared, true), Some(shared)),
                Err(e) => (wire::error(&format!("{} is live but cannot be named: {e}", plan.name)), None),
            };
        }
        if jail::desc_by_name(&plan.name).is_ok() {
            return (wire::error(&format!("a jail named {} exists and is not ours", plan.name)), None);
        }

        if let Err(f) = self.performer.perform(&steps::build(&plan, &acct.user, &self.performer.commands)) {
            (self.say)(&format!("jaild: {}: {f}", plan.name));
            self.teardown(&plan.root, &plan.name, "its build failed");
            return (wire::error(&format!("cannot build {}: {f}", plan.name)), None);
        }

        let params: Vec<(String, String)> = plan.params.iter().map(|(k, v)| (k.clone(), v.clone().unwrap_or_else(|| "true".into()))).collect();
        let (jid, desc) = match jail::create(&params) {
            Ok(j) => j,
            Err(why) => {
                (self.say)(&format!("jaild: {}: {why}", plan.name));
                self.teardown(&plan.root, &plan.name, "the jail was refused");
                return (wire::error(&format!("cannot create {}: {why}", plan.name)), None);
            }
        };
        let watch = jail::desc_by_name(&plan.name).ok();
        if let Some(w) = &watch {
            self.watch(w);
        }
        (self.say)(&format!("jaild: {} is jail {jid}, for uid {uid}", plan.name));
        let m = opened(&plan, &desc, false);
        self.live.insert(plan.name.clone(), Live::new(watch, plan, uid));
        (m, Some(desc))
    }

    // MARK: spawn

    fn spawn(&mut self, uid: u32, request: &mut Msg) -> (Msg, Option<OwnedFd>) {
        let Some(jail_fd) = request.take_fd("jail") else { return (wire::error("spawn needs a jail descriptor"), None) };
        let name = match jail::identify(jail_fd.as_fd()) {
            Ok((_, name)) => name,
            Err(e) => return (wire::error(&format!("that is not a jail descriptor: {e}")), None),
        };
        let Some(l) = self.live.get(&name).filter(|l| wire::owns(uid, &name) && l.uid == uid) else {
            (self.say)(&format!("jaild: uid {uid} refused a spawn in {name}"));
            return (wire::error(&format!("{name} is not yours")), None);
        };
        let argv = wire::unlist(request.bytes("argv").unwrap_or(&[]));
        if argv.first().is_none_or(|a| a.is_empty()) {
            return (wire::error("spawn needs argv"), None);
        }
        let env = wire::environment(&l.plan.env, &wire::unlist(request.bytes("env").unwrap_or(&[])));
        let home = l.plan.env.iter().find(|(k, _)| k == "HOME").map_or("/", |(_, v)| v.as_str()).to_owned();
        let Some(acct) = (self.account_of)(uid) else { return (wire::error(&format!("uid {uid} has no account")), None) };
        // The person's login-class limits, not jaild's own (P18.9): under
        // some rc setups jaild's core size is 0, and a confined crash would
        // leave nothing to read.
        let limits = match jail::Limits::of_class(uid) {
            Ok(l) => Some(l),
            Err(e) => {
                (self.say)(&format!("jaild: no login class for uid {uid} ({e}): {} keeps jaild's limits", argv[0]));
                None
            }
        };
        let stdio = ["stdin", "stdout", "stderr"].map(|k| request.fd(k));
        let start = jail::Spawn {
            uid,
            gid: acct.user.gid,
            argv: &argv,
            env: &env,
            cwd: &home,
            stdio,
            daemon: request.bool("daemon") == Some(true),
            limits: limits.as_ref(),
        };
        match jail::spawn(jail_fd.as_fd(), &start) {
            Ok((pid, proc)) => {
                (self.say)(&format!("jaild: {} is pid {pid} in {name}", argv[0]));
                let mut m = Msg::new();
                m.set_bool("ok", true);
                m.set_u64("pid", pid as u64);
                m.set_fd("proc", proc.as_raw_fd());
                (m, Some(proc))
            }
            Err(e) => (wire::error(&format!("cannot start {} in {name}: {e}", argv[0])), None),
        }
    }

    // MARK: grants (P18.4)

    /// The caller's live jail named in `request`, or why not.
    fn owned(&self, uid: u32, request: &Msg) -> Result<String, Msg> {
        let name = request.string("jail").unwrap_or("");
        match self.live.get(name) {
            Some(l) if wire::owns(uid, name) && l.uid == uid => Ok(name.to_owned()),
            _ => Err(wire::error(&if name.is_empty() { "no jail named".to_owned() } else { format!("{name} is not yours") })),
        }
    }

    fn grant(&mut self, uid: u32, request: &mut Msg) -> Msg {
        let name = match self.owned(uid, request) {
            Ok(n) => n,
            Err(m) => return m,
        };
        let path = request.string("path").filter(|p| p.starts_with('/')).map(str::to_owned);
        let (Some(fd), Some(path)) = (request.take_fd("file"), path) else {
            return wire::error("grant needs the file's absolute path and the caller's descriptor of it");
        };
        // The descriptor and the path must be the same regular file, and the
        // path must be the file itself, not a way round to another.
        let file = File::from(fd);
        let Ok(held) = file.metadata().map_err(drop).and_then(|m| if m.is_file() { Ok(m) } else { Err(()) }) else {
            return wire::error("the descriptor is not a regular file");
        };
        if std::fs::canonicalize(&path).ok().as_deref() != Some(std::path::Path::new(&path)) {
            return wire::error(&format!("{path} is not a resolved path (a link, or gone)"));
        }
        match std::fs::symlink_metadata(&path) {
            Ok(named) if named.dev() == held.dev() && named.ino() == held.ino() => {}
            _ => return wire::error(&format!("{path} is not the file the descriptor is")),
        }
        if under(&path, &self.layout.root_base) {
            return wire::error(&format!("{path} is inside a jail"));
        }
        let writable = platform::is_writable(file.as_fd()).unwrap_or(false);

        let Some(l) = self.live.get(&name) else { return wire::error(&format!("{name} is gone")) };
        let (n, root) = (l.next_grant, l.plan.root.clone());
        let c = &self.performer.commands;
        if let Err(f) = self.performer.perform(&steps::grant(&root, n, &path, writable, c)) {
            self.performer.perform_all(&steps::revoke(&root, n, &path, c));
            return wire::error(&format!("cannot grant {path}: {f}"));
        }
        // And what was mounted is what was proven: the same inode through
        // the jail's side, or it comes straight back out.
        let inside = steps::grant_path(n, &path);
        if std::fs::metadata(format!("{root}{inside}")).map(|m| m.ino()).ok() != Some(held.ino()) {
            self.performer.perform_all(&steps::revoke(&root, n, &path, c));
            return wire::error(&format!("{path} changed while it was being granted"));
        }
        let l = self.live.get_mut(&name).expect("checked above");
        l.next_grant += 1;
        l.grants.push(Grant { n, source: path.clone(), inside: inside.clone(), writable });
        (self.say)(&format!("jaild: granted {path} to {name} at {inside} ({})", if writable { "read-write" } else { "read-only" }));
        let mut m = Msg::new();
        m.set_bool("ok", true);
        m.set_string("path", &inside);
        m.set_u64("grant", n);
        m.set_bool("writable", writable);
        m
    }

    fn revoke(&mut self, uid: u32, request: &Msg) -> Msg {
        let name = match self.owned(uid, request) {
            Ok(n) => n,
            Err(m) => return m,
        };
        let l = self.live.get_mut(&name).expect("owned says it is live");
        let Some(g) = request.u64("grant").and_then(|n| l.grants.iter().find(|g| g.n == n)).cloned() else {
            return wire::error("no such grant");
        };
        let failures = self.performer.perform_all(&steps::revoke(&l.plan.root, g.n, &g.source, &self.performer.commands));
        if let Some(f) = failures.first() {
            return wire::error(&format!("cannot revoke: {f}"));
        }
        l.grants.retain(|x| x.n != g.n);
        (self.say)(&format!("jaild: revoked {} from {name}", g.source));
        let mut m = Msg::new();
        m.set_bool("ok", true);
        m
    }

    fn grants(&self, uid: u32, request: &Msg) -> Msg {
        let name = match self.owned(uid, request) {
            Ok(n) => n,
            Err(m) => return m,
        };
        let lines: Vec<String> = self.live[&name]
            .grants
            .iter()
            .map(|g| format!("{}\t{}\t{}\t{}", g.n, if g.writable { "rw" } else { "ro" }, g.inside, g.source))
            .collect();
        let mut m = Msg::new();
        m.set_bool("ok", true);
        m.set_bytes("grants", &wire::list(&lines));
        m
    }
}

fn opened(plan: &JailPlan, desc: &OwnedFd, shared: bool) -> Msg {
    let jid = jail::identify(desc.as_fd()).map_or(0, |(j, _)| j.max(0));
    let mut m = Msg::new();
    m.set_bool("ok", true);
    m.set_fd("jail", desc.as_raw_fd());
    m.set_u64("jid", jid as u64);
    m.set_string("name", &plan.name);
    m.set_string("root", &plan.root);
    m.set_string("runtime", &format!("{}{}", plan.root, JailLayout::RUNTIME));
    // The jail's home as it really is on the host (its source, not its mount
    // in the root): where a file the jail wrote, a core, can be named for a
    // grant (P18.9); a path in a root is refused.
    m.set_string("home", &plan.home_source);
    m.set_bool("shared", shared);
    m
}
