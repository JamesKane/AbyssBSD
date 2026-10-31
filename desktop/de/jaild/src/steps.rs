//! A plan as the steps that build it, and the steps that undo it
//! (Steps.swift, PHASE18 P18.2).
//!
//! Pure: the order is the design, so it is what the tests read. The
//! performer carries steps out and decides nothing. The order matters in
//! three places:
//!
//!   - the tmpfs goes over the root *before* anything is made in it, or the
//!     directories land on the host's /var/run and are hidden by the mount;
//!   - the accounts are compiled by `pwd_mkdb` and then `master.passwd` and
//!     `spwd.db` are deleted *before* the jail exists, so nothing inside
//!     ever sees them (§4.5);
//!   - teardown unmounts the deepest first (a granted file under /run
//!     before the tmpfs it sits on), and only then removes the root.

use jails::{under, JailLayout, JailPlan, JailUser, MountKind};
use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JailStep {
    /// `mkdir -p` on the host, then owner and mode.
    Mkdir { path: String, uid: u32, gid: u32, mode: u16 },
    /// A ZFS dataset with this mountpoint, created if it is missing.
    Dataset { name: String, mountpoint: String },
    Run(Vec<String>),
    Write { path: String, contents: String, mode: u16 },
    /// Copied if the source exists; skipped if not (§4.5: /etc/localtime).
    CopyIfPresent { source: String, target: String },
    Remove(String),
    /// Remove an empty directory; a non-empty one is left and reported.
    Rmdir(String),
}

impl fmt::Display for JailStep {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            JailStep::Mkdir { path, uid, gid, mode } => write!(f, "mkdir {path} ({uid}:{gid} {mode:o})"),
            JailStep::Dataset { name, mountpoint } => write!(f, "dataset {name} at {mountpoint}"),
            JailStep::Run(argv) => f.write_str(&argv.join(" ")),
            JailStep::Write { path, mode, .. } => write!(f, "write {path} ({mode:o})"),
            JailStep::CopyIfPresent { source, target } => write!(f, "copy {source} to {target}"),
            JailStep::Remove(p) => write!(f, "remove {p}"),
            JailStep::Rmdir(p) => write!(f, "rmdir {p}"),
        }
    }
}

/// The base tools the steps run, by path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JailCommands {
    pub mount: String,
    pub umount: String,
    pub devfs: String,
    pub pwd_mkdb: String,
    pub zfs: String,
}

impl Default for JailCommands {
    fn default() -> JailCommands {
        JailCommands {
            mount: "/sbin/mount".into(),
            umount: "/sbin/umount".into(),
            devfs: "/sbin/devfs".into(),
            pwd_mkdb: "/usr/sbin/pwd_mkdb".into(),
            zfs: "/sbin/zfs".into(),
        }
    }
}

fn run(argv: &[&str]) -> JailStep {
    JailStep::Run(argv.iter().map(|a| (*a).to_owned()).collect())
}

fn mkdir(path: String, uid: u32, gid: u32, mode: u16) -> JailStep {
    JailStep::Mkdir { path, uid, gid, mode }
}

/// Everything up to the jail itself, for `user`. The jail is created after
/// these, by the service.
pub fn build(p: &JailPlan, user: &JailUser, c: &JailCommands) -> Vec<JailStep> {
    let (uid, gid, r) = (user.uid, user.gid, p.root.as_str());
    let mut s = vec![];

    // The root's directory, and the private home, on the host.
    s.push(mkdir(r.into(), 0, 0, 0o755));
    if let Some(ds) = &p.home_dataset {
        s.push(JailStep::Dataset { name: ds.clone(), mountpoint: p.home_source.clone() });
    }
    s.push(mkdir(p.home_source.clone(), uid, gid, 0o700));

    // The tmpfs first, then everything on it.
    s.push(run(&[&c.mount, "-t", "tmpfs", "-o", "mode=755", "tmpfs", r]));
    for d in &p.dirs {
        s.push(mkdir(format!("{r}{}", d.path), d.uid, if d.uid == 0 { 0 } else { gid }, d.mode));
    }
    for m in p.mounts.iter().skip(1) {
        let target = format!("{r}{}", m.target);
        match m.kind {
            MountKind::Tmpfs => s.push(run(&[&c.mount, "-t", "tmpfs", "tmpfs", &target])),
            // nosuid on everything: a setuid binary has nothing to do in an
            // application's jail, and root inside is still root of a jail.
            MountKind::Nullfs => {
                s.push(run(&[&c.mount, "-t", "nullfs", "-o", if m.read_only { "ro,nosuid" } else { "nosuid" }, &m.source, &target]))
            }
            MountKind::Devfs => {
                s.push(run(&[&c.mount, "-t", "devfs", "devfs", &target]));
                s.push(run(&[&c.devfs, "-m", &target, "ruleset", "4"]));
                s.push(run(&[&c.devfs, "-m", &target, "rule", "applyset"]));
                for path in &p.unhide {
                    s.push(run(&[&c.devfs, "-m", &target, "rule", "apply", "path", path, "unhide"]));
                }
            }
        }
    }

    for (path, contents) in &p.files {
        s.push(JailStep::Write { path: format!("{r}{path}"), contents: contents.clone(), mode: 0o644 });
    }
    for (source, target) in &p.copies {
        s.push(JailStep::CopyIfPresent { source: source.clone(), target: format!("{r}{target}") });
    }
    let master = format!("{r}/etc/master.passwd");
    s.push(JailStep::Write { path: master.clone(), contents: p.accounts.clone(), mode: 0o600 });
    s.push(run(&[&c.pwd_mkdb, "-p", "-d", &format!("{r}/etc"), &master]));
    s.push(JailStep::Remove(master));
    s.push(JailStep::Remove(format!("{r}/etc/spwd.db")));
    s
}

/// Undo a root: every mount at or under it, deepest first, then the
/// directory. `mounted` is the host's mount points (from the kernel); a
/// point mounted twice is unmounted twice.
pub fn teardown(root: &str, mounted: &[String], c: &JailCommands) -> Vec<JailStep> {
    let mut mine: Vec<&String> = mounted.iter().filter(|m| under(m, root)).collect();
    let depth = |p: &str| p.split('/').filter(|x| !x.is_empty()).count();
    mine.sort_by(|a, b| (depth(b), b.as_str()).cmp(&(depth(a), a.as_str())));
    let mut s: Vec<JailStep> = mine.into_iter().map(|m| run(&[&c.umount, "-f", m])).collect();
    s.push(JailStep::Rmdir(root.into()));
    s
}

/// A granted file's name inside: its own, unless that could not be one.
pub fn grant_name(source: &str) -> &str {
    let base = source.rsplit('/').next().unwrap_or("");
    if base.is_empty() || base == "." || base == ".." { "file" } else { base }
}

/// Where grant `n` of `source` is, inside the jail.
pub fn grant_path(n: u64, source: &str) -> String {
    format!("{}/{n}/{}", JailLayout::GRANTED, grant_name(source))
}

/// Mount one file into a running jail (P18.4, §4.4): a directory of its
/// own, a placeholder to mount over, and nullfs, read-only unless the
/// person's own descriptor of it was writable.
pub fn grant(root: &str, n: u64, source: &str, writable: bool, c: &JailCommands) -> Vec<JailStep> {
    let target = format!("{root}{}", grant_path(n, source));
    vec![
        mkdir(format!("{root}{}/{n}", JailLayout::GRANTED), 0, 0, 0o755),
        JailStep::Write { path: target.clone(), contents: String::new(), mode: 0o644 },
        run(&[&c.mount, "-t", "nullfs", "-o", if writable { "nosuid" } else { "ro,nosuid" }, source, &target]),
    ]
}

/// Take grant `n` back: unmount it, and remove what held it.
pub fn revoke(root: &str, n: u64, source: &str, c: &JailCommands) -> Vec<JailStep> {
    let target = format!("{root}{}", grant_path(n, source));
    vec![run(&[&c.umount, "-f", &target]), JailStep::Remove(target), JailStep::Rmdir(format!("{root}{}/{n}", JailLayout::GRANTED))]
}

/// The roots under `base` (`<base>/<uid>/<class>`) with anything mounted in
/// them: what a daemon that died left behind.
pub fn left_roots(base: &str, points: &[String]) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for p in points.iter().filter(|p| under(p, base) && p.as_str() != base) {
        let rest: Vec<&str> = p[base.len() + 1..].split('/').filter(|x| !x.is_empty()).collect();
        if rest.len() < 2 {
            continue;
        }
        let root = format!("{base}/{}/{}", rest[0], rest[1]);
        if !out.contains(&root) {
            out.push(root);
        }
    }
    out
}

/// The jail a root belongs to: `<base>/1001/app` is `abyss-1001-app`.
pub fn jail_name(root: &str, base: &str) -> Option<String> {
    if !under(root, base) || root == base {
        return None;
    }
    let rest: Vec<&str> = root[base.len() + 1..].split('/').filter(|x| !x.is_empty()).collect();
    if rest.len() != 2 || rest[0].parse::<u32>().is_err() {
        return None;
    }
    Some(format!("abyss-{}-{}", rest[0], rest[1]))
}
