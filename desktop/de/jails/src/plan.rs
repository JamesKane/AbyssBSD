//! A class plus a person, made into the steps that build the jail
//! (JailPlan.swift, PHASE18 P18.1).
//!
//! Pure, so it is read and tested on Linux, where there are no jails:
//! `abyss-jaild` performs a plan and makes no decisions of its own. What the
//! jail can reach is settled here, and `violations` says what a plan must
//! never do: the checks a root daemon runs before it mounts anything.
//!
//! PHASE18 §4.1's shape: a tmpfs root, the system read-only by nullfs, a
//! generated `/etc` that knows two accounts and no passwords, devfs ruleset
//! 4 with named devices unhidden, a private home, and a runtime directory
//! holding the jail's own Wayland socket and nothing of undertow's.

use crate::class::{known_devices, JailClass, Network};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JailUser {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MountKind {
    Tmpfs,
    Nullfs,
    Devfs,
}

impl MountKind {
    pub fn as_str(self) -> &'static str {
        match self {
            MountKind::Tmpfs => "tmpfs",
            MountKind::Nullfs => "nullfs",
            MountKind::Devfs => "devfs",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JailMount {
    pub kind: MountKind,
    /// Host path for nullfs; empty otherwise.
    pub source: String,
    /// Path inside the jail, absolute, or "/" for the root itself.
    pub target: String,
    pub read_only: bool,
}

/// A directory made inside the root: its owner (0 = root) and mode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JailDir {
    pub path: String,
    pub uid: u32,
    pub mode: u16,
}

/// Where jails are kept on the host. A test passes temporary directories,
/// and the plan's checks follow the layout it was made with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JailLayout {
    /// Where roots live: under /var/run, so a reboot leaves none.
    pub root_base: String,
    /// Where private homes live (a ZFS dataset's mountpoint, or a
    /// directory, §6.3).
    pub home_base: String,
}

impl Default for JailLayout {
    fn default() -> JailLayout {
        JailLayout { root_base: "/var/run/abyss-jails".into(), home_base: "/var/db/abyss-jails".into() }
    }
}

impl JailLayout {
    /// The runtime directory inside: the jail's own Wayland socket.
    pub const RUNTIME: &str = "/run/user";
    /// Where granted files are mounted (P18.4).
    pub const GRANTED: &str = "/run/granted";
    /// The jail's own D-Bus (P18.4): the portal is the only service on it.
    pub const BUS: &str = "/run/user/bus";
    pub const WAYLAND_DISPLAY: &str = "wayland-0";
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JailPlan {
    /// `abyss-<uid>-<class>`: one per person and class (pooled, P18.2).
    pub name: String,
    /// The jail's root on the host.
    pub root: String,
    /// In order: the root's tmpfs first, everything else on it.
    pub mounts: Vec<JailMount>,
    /// devfs paths unhidden on top of ruleset 4.
    pub unhide: Vec<String>,
    /// Mount points, and the places the person writes.
    pub dirs: Vec<JailDir>,
    /// The jail's accounts in `master.passwd(5)` form, every password `*`.
    /// jaild compiles them with `pwd_mkdb -p -d <root>/etc` and deletes the
    /// `master.passwd` and `spwd.db` that writes (§4.5).
    pub accounts: String,
    /// Files written into the root: (path inside, contents).
    pub files: Vec<(String, String)>,
    /// Host files copied in as they are, (source, target). A missing source
    /// is skipped: a jail without `/etc/localtime` is UTC.
    pub copies: Vec<(String, String)>,
    /// `jail_set(2)` parameters; None is a boolean parameter.
    pub params: Vec<(String, Option<String>)>,
    /// The environment a process started in it gets, and nothing else.
    pub env: Vec<(String, String)>,
    pub layout: JailLayout,
    /// The private home: a host directory mounted at the person's home.
    pub home_source: String,
    /// Created by jaild when the host has ZFS; None on UFS.
    pub home_dataset: Option<String>,
}

fn own(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs.iter().map(|(a, b)| ((*a).to_owned(), (*b).to_owned())).collect()
}

impl JailPlan {
    /// The plan for `user` in `cls`; `pool` is the ZFS pool to keep homes
    /// in, or None on UFS.
    pub fn make(cls: &JailClass, user: &JailUser, pool: Option<&str>, layout: &JailLayout) -> JailPlan {
        let name = format!("abyss-{}-{}", user.uid, cls.name);
        let root = format!("{}/{}/{}", layout.root_base, user.uid, cls.name);
        let home = format!("/home/{}", user.name);
        let home_source = format!("{}/{}/{}", layout.home_base, user.name, cls.name);

        let mount = |kind, source: &str, target: &str, read_only| JailMount { kind, source: source.into(), target: target.into(), read_only };
        let mut mounts = vec![mount(MountKind::Tmpfs, "", "/", false)];
        mounts.extend(cls.system.iter().map(|d| mount(MountKind::Nullfs, d, d, true)));
        mounts.push(mount(MountKind::Devfs, "", "/dev", false));
        mounts.push(mount(MountKind::Nullfs, &home_source, &home, false));

        let dir = |path: &str, uid, mode| JailDir { path: path.into(), uid, mode };
        let mut dirs = vec![
            dir("/etc", 0, 0o755),
            dir("/var", 0, 0o755),
            dir("/var/run", 0, 0o755),
            dir("/dev", 0, 0o555),
            dir("/tmp", 0, 0o1777),
            dir("/home", 0, 0o755),
            dir(&home, user.uid, 0o700),
            dir("/run", 0, 0o755),
            dir(JailLayout::RUNTIME, user.uid, 0o700),
            dir(JailLayout::GRANTED, 0, 0o755),
        ];
        // Each inserted after /etc, so the system's come out reversed.
        for d in &cls.system {
            dirs.insert(1, dir(d, 0, 0o755));
        }

        // Two accounts and no passwords: getpwuid answers for the person, and
        // there is nothing for anything inside to crack. The person is in
        // their own group only: not wheel, even when they are outside.
        let accounts = format!(
            "root:*:0:0::0:0:Charlie &:/root:/usr/sbin/nologin\n{0}:*:{1}:{2}::0:0:{0}:{home}:/bin/sh\n",
            user.name, user.uid, user.gid
        );
        let files = vec![("/etc/group".to_owned(), format!("wheel:*:0:root\n{}:*:{}:\n", user.name, user.gid))];
        let mut copies = own(&[
            ("/etc/nsswitch.conf", "/etc/nsswitch.conf"),
            ("/etc/libmap.conf", "/etc/libmap.conf"),
            ("/etc/localtime", "/etc/localtime"),
            ("/var/run/ld-elf.so.hints", "/var/run/ld-elf.so.hints"),
        ]);
        if cls.network == Network::Host {
            copies.extend(own(&[("/etc/resolv.conf", "/etc/resolv.conf")]));
        }

        let p = |k: &str, v: Option<&str>| (k.to_owned(), v.map(str::to_owned));
        let mut params = vec![
            p("name", Some(&name)),
            p("path", Some(&root)),
            p("host.hostname", Some(&name)),
            p("persist", None),
            p("enforce_statfs", Some("2")),
            p("devfs_ruleset", Some("4")),
        ];
        let ip = if cls.network == Network::Host { "inherit" } else { "disable" };
        params.extend([p("ip4", Some(ip)), p("ip6", Some(ip))]);

        let mut env = own(&[
            ("HOME", &home),
            ("USER", &user.name),
            ("LOGNAME", &user.name),
            ("SHELL", "/bin/sh"),
            ("PATH", "/bin:/usr/bin:/usr/local/bin"),
            ("TMPDIR", "/tmp"),
            ("XDG_RUNTIME_DIR", JailLayout::RUNTIME),
        ]);
        if cls.wayland {
            // Files come in through the Open panel (P18.4): GTK asks the
            // portal on the jail's own bus, which grants the file it was given.
            env.extend(own(&[
                ("WAYLAND_DISPLAY", JailLayout::WAYLAND_DISPLAY),
                ("GDK_BACKEND", "wayland"),
                ("DBUS_SESSION_BUS_ADDRESS", &format!("unix:path={}", JailLayout::BUS)),
                ("GTK_USE_PORTAL", "1"),
                ("GDK_DEBUG", "portals"),
            ]));
        }

        JailPlan {
            name,
            root,
            mounts,
            unhide: cls.devices.iter().flat_map(|d| known_devices(d).unwrap_or(&[])).map(|s| (*s).to_owned()).collect(),
            dirs,
            accounts,
            files,
            copies,
            params,
            env,
            layout: layout.clone(),
            home_source,
            home_dataset: pool.map(|p| format!("{p}/abyss/jails/{}/{}", user.name, cls.name)),
        }
    }

    fn param(&self, key: &str) -> Option<Option<&str>> {
        self.params.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_deref())
    }

    fn env_var(&self, key: &str) -> Option<&str> {
        self.env.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }

    /// What this plan would do that no plan may, each a sentence a refusal
    /// can show. Empty is the only answer jaild acts on.
    pub fn violations(&self, cls: &JailClass, host_home: &str) -> Vec<String> {
        let mut out = vec![];
        let home = self.env_var("HOME").unwrap_or("");
        for unknown in cls.devices.iter().filter(|d| known_devices(d).is_none()) {
            out.push(format!("class {} names an unknown device '{unknown}'", cls.name));
        }
        for m in self.mounts.iter().filter(|m| m.kind == MountKind::Nullfs) {
            if m.target == home {
                if m.source != self.home_source || m.read_only {
                    out.push(format!("the home is not the private one: {}", m.source));
                }
                continue;
            }
            if !m.read_only {
                out.push(format!("{} is writable from inside", m.target));
            }
            if under(&m.source, host_home) || under(host_home, &m.source) {
                out.push(format!("{} reaches the person's own home", m.source));
            }
            if under(&m.source, &self.layout.root_base)
                || under(&m.source, &self.layout.home_base)
                || m.source == "/"
                || m.source == "/etc"
                || under(&m.source, "/root")
                || under(&m.source, "/var")
            {
                out.push(format!("{} is not a system directory", m.source));
            }
        }
        if under(&self.home_source, host_home) || !under(&self.home_source, &self.layout.home_base) {
            out.push(format!("the private home {} is not under {}", self.home_source, self.layout.home_base));
        }
        for (path, _) in self.files.iter().filter(|(p, _)| secret(p)) {
            out.push(format!("{path} is written into the jail"));
        }
        for (source, _) in self.copies.iter().filter(|(s, t)| secret(s) || secret(t)) {
            out.push(format!("{source} is copied into the jail"));
        }
        let rows = || self.accounts.split('\n').filter(|r| !r.is_empty());
        // The password is the second non-empty field: an empty one is not `*`.
        if rows().any(|r| r.split(':').filter(|f| !f.is_empty()).nth(1) != Some("*")) {
            out.push("an account carries a password".into());
        }
        for row in rows() {
            let f: Vec<&str> = row.split(':').collect();
            if f.len() != 10 {
                out.push(format!("an account is not in master.passwd form: {}", f[0]));
            }
            if f.len() > 2 && f[2] == "0" && f[0] != "root" {
                out.push(format!("{} has uid 0", f[0]));
            }
        }
        if cls.network == Network::None && (self.param("ip4") != Some(Some("disable")) || self.param("ip6") != Some(Some("disable"))) {
            out.push(format!("class {} has no network, but the jail has an address", cls.name));
        }
        if self.param("devfs_ruleset") != Some(Some("4")) {
            out.push("the devfs ruleset is not 4".into());
        }
        if let Some(wd) = self.env_var("XDG_RUNTIME_DIR").filter(|wd| *wd != JailLayout::RUNTIME) {
            out.push(format!("the runtime directory is {wd}, not the jail's own"));
        }
        out
    }
}

/// A path no plan may write or copy into a jail. By bytes: Swift's
/// `contains` is by Character, so `/.ssh` followed by a combining mark is
/// not `/.ssh` to it.
pub(crate) fn secret(path: &str) -> bool {
    matches!(path, "/etc/master.passwd" | "/etc/spwd.db") || path.starts_with("/root/") || path.contains("/.ssh")
}

/// Whether `path` is `dir` or below it, component-wise, so /usr/localx is
/// not under /usr/local. By bytes: Swift's `hasPrefix` is by Character, so
/// a component that begins with a combining mark joins the `/` before it,
/// and `/home/abyss/◌́docs` is not under `/home/abyss` to Swift.
pub fn under(path: &str, dir: &str) -> bool {
    if dir.is_empty() {
        return false;
    }
    let d = if dir.len() > 1 { dir.strip_suffix('/').unwrap_or(dir) } else { dir };
    if d == "/" {
        return path.starts_with('/');
    }
    path == d || path.strip_prefix(d).is_some_and(|rest| rest.starts_with('/'))
}
