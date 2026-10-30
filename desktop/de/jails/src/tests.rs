//! The JailClass and JailPlan half of JailsTests.swift, ported (the crash
//! and keeper tests are jaild's and the keeper's, R3). Each guarantee is
//! checked twice: a sound plan has no violations, and the same plan broken
//! in exactly that way is refused.

use super::plan::secret;
use super::*;
use pool_config::Config;

const HOST_HOME: &str = "/home/abyss";

fn me() -> JailUser {
    JailUser { name: "abyss".into(), uid: 1001, gid: 1001 }
}

fn cls(n: &str) -> JailClass {
    JailClass::shipped().into_iter().find(|c| c.name == n).unwrap()
}

fn plan(c: &JailClass) -> JailPlan {
    JailPlan::make(c, &me(), None, &JailLayout::default())
}

fn env<'a>(p: &'a JailPlan, k: &str) -> Option<&'a str> {
    p.env.iter().find(|(key, _)| key == k).map(|(_, v)| v.as_str())
}

fn names(t: &[JailClass]) -> Vec<&str> {
    t.iter().map(|c| c.name.as_str()).collect()
}

// MARK: classes

#[test]
fn the_shipped_classes() {
    let t = JailClass::shipped();
    assert_eq!(names(&t), ["app", "app-gl", "app-net", "agent", "debug"]);
    assert_eq!(cls("app").network, Network::None);
    assert!(cls("app").devices.is_empty());
    assert_eq!(cls("app-gl").devices, ["dri"]);
    assert_eq!(cls("app-net").network, Network::Host);
    assert!(t.iter().all(|c| c.system == BASE_SYSTEM));
}

#[test]
fn a_file_section_overrides_only_what_it_says() {
    let t = JailClass::table(Some(&Config::parse("[app]\ndevices = dsp\n[editor]\nnetwork = host\nwayland = no\n")));
    let app = t.iter().find(|c| c.name == "app").unwrap();
    assert_eq!(app.devices, ["dsp"]);
    assert_eq!(app.network, Network::None, "an override keeps what it does not name");
    assert_eq!(app.system, BASE_SYSTEM);
    let ed = t.iter().find(|c| c.name == "editor").unwrap();
    assert_eq!(ed.network, Network::Host);
    assert!(!ed.wayland);
    assert_eq!(t.iter().filter(|c| c.name == "app").count(), 1, "an override replaces, it does not duplicate");
}

#[test]
fn the_apps_section_is_not_a_class() {
    let t = JailClass::table(Some(&Config::parse("[apps]\ngalculator = app\n")));
    assert_eq!(names(&t), ["app", "app-gl", "app-net", "agent", "debug"]);
}

/// An agent's jail (P18.8): a model socket and nothing else, and no model
/// until the person sets one.
#[test]
fn the_agent_classes() {
    for n in ["agent", "debug"] {
        let k = cls(n);
        assert!(k.agent && !k.wayland && k.devices.is_empty() && k.network == Network::None, "{n}");
        assert_eq!((k.model.as_str(), k.budget), ("", DEFAULT_BUDGET), "{n}");
        assert_eq!(k.vocabulary, n == "agent", "{n}: only agent drives applications");
        assert_eq!(k.fetch, n == "agent", "{n}: only agent reaches the web");
    }
    assert!(!cls("app").agent);
    let p = plan(&cls("agent"));
    assert!(env(&p, "DBUS_SESSION_BUS_ADDRESS").is_none() && env(&p, "WAYLAND_DISPLAY").is_none(), "no bus and no display");
    assert_eq!(p.violations(&cls("agent"), HOST_HOME), Vec::<String>::new());
}

#[test]
fn an_agent_rows_keys() {
    let t = JailClass::table(Some(&Config::parse("[agent]\nmodel = local:/m/granite.gguf\nbudget = 5000\n[helper]\nagent = yes\nwayland = no\nbudget = nonsense\n")));
    let a = t.iter().find(|c| c.name == "agent").unwrap();
    assert_eq!((a.model.as_str(), a.budget), ("local:/m/granite.gguf", 5000));
    assert!(!a.wayland, "the override keeps the shipped row's other keys");
    let h = t.iter().find(|c| c.name == "helper").unwrap();
    assert!(h.agent);
    assert_eq!(h.budget, DEFAULT_BUDGET, "a budget that is not a number keeps the default");
}

#[test]
fn an_unknown_network_word_keeps_the_safe_value() {
    let t = JailClass::table(Some(&Config::parse("[app]\nnetwork = everything\n")));
    assert_eq!(t.iter().find(|c| c.name == "app").unwrap().network, Network::None);
}

// MARK: the plan

#[test]
fn the_plan_for_app() {
    let p = plan(&cls("app"));
    assert_eq!(p.name, "abyss-1001-app");
    assert_eq!(p.root, "/var/run/abyss-jails/1001/app");
    assert_eq!(p.mounts[0].kind, MountKind::Tmpfs, "the root is a tmpfs, mounted first");
    let ro: Vec<&str> = p.mounts.iter().filter(|m| m.kind == MountKind::Nullfs && m.read_only).map(|m| m.target.as_str()).collect();
    assert_eq!(ro, BASE_SYSTEM);
    let home = p.mounts.iter().find(|m| m.target == "/home/abyss").unwrap();
    assert_eq!(home.source, "/var/db/abyss-jails/abyss/app");
    assert!(!home.read_only);
    assert!(p.unhide.is_empty());
    assert!(p.params.contains(&("ip4".into(), Some("disable".into()))));
    assert!(p.params.contains(&("devfs_ruleset".into(), Some("4".into()))));
    assert_eq!(env(&p, "XDG_RUNTIME_DIR"), Some("/run/user"));
    assert_eq!(env(&p, "WAYLAND_DISPLAY"), Some("wayland-0"));
    assert_eq!(env(&p, "DBUS_SESSION_BUS_ADDRESS"), Some("unix:path=/run/user/bus"), "the jail's own bus");
    assert_eq!(env(&p, "GTK_USE_PORTAL"), Some("1"));
    assert_eq!(p.home_dataset, None);
    assert!(!p.copies.iter().any(|(_, t)| t == "/etc/resolv.conf"), "no network, no resolver");
    assert_eq!(p.violations(&cls("app"), HOST_HOME), Vec::<String>::new());
}

#[test]
fn the_other_shipped_classes_are_sound() {
    let gl = JailPlan::make(&cls("app-gl"), &me(), Some("zroot"), &JailLayout::default());
    assert!(gl.unhide.iter().any(|u| u == "dri/*"));
    assert_eq!(gl.home_dataset.as_deref(), Some("zroot/abyss/jails/abyss/app-gl"));
    assert_eq!(gl.violations(&cls("app-gl"), HOST_HOME), Vec::<String>::new());
    let net = plan(&cls("app-net"));
    assert!(net.params.contains(&("ip4".into(), Some("inherit".into()))));
    assert!(net.copies.iter().any(|(_, t)| t == "/etc/resolv.conf"));
    assert_eq!(net.violations(&cls("app-net"), HOST_HOME), Vec::<String>::new());
}

#[test]
fn etc_knows_two_accounts_and_no_passwords() {
    let p = plan(&cls("app"));
    let rows: Vec<&str> = p.accounts.lines().collect();
    assert_eq!(rows.iter().map(|r| r.split(':').next().unwrap()).collect::<Vec<_>>(), ["root", "abyss"]);
    assert!(rows.iter().all(|r| r.split(':').nth(1) == Some("*")));
    assert_eq!(rows[1], "abyss:*:1001:1001::0:0:abyss:/home/abyss:/bin/sh", "master.passwd form, for pwd_mkdb");
    assert!(!p.files.iter().any(|(path, _)| path.contains("passwd")));
    assert_eq!(p.files.iter().find(|(path, _)| path == "/etc/group").unwrap().1, "wheel:*:0:root\nabyss:*:1001:\n", "not wheel");
    assert!(!p.copies.iter().any(|(s, _)| s.starts_with("/etc/pwd") || s.starts_with("/etc/spwd")));
}

#[test]
fn the_home_is_the_only_writable_mount_and_is_owned_by_the_person() {
    let p = plan(&cls("app"));
    let rw: Vec<&str> = p.mounts.iter().filter(|m| m.kind == MountKind::Nullfs && !m.read_only).map(|m| m.target.as_str()).collect();
    assert_eq!(rw, ["/home/abyss"]);
    let dir = |path: &str| p.dirs.iter().find(|d| d.path == path).unwrap().clone();
    assert_eq!((dir("/home/abyss").uid, dir("/home/abyss").mode), (1001, 0o700));
    assert_eq!(dir("/run/user").uid, 1001);
    assert_eq!(dir("/tmp").mode, 0o1777);
}

// MARK: what no plan may do (each a fault injected into a sound plan)

fn assert_refused(p: &JailPlan, c: Option<&JailClass>, why: &str) {
    let v = p.violations(c.unwrap_or(&cls("app")), HOST_HOME);
    assert!(v.iter().any(|s| s.contains(why)), "expected a violation containing '{why}', got {v:?}");
}

#[test]
fn a_writable_system_mount_is_refused() {
    let mut p = plan(&cls("app"));
    p.mounts[1].read_only = false;
    assert_refused(&p, None, "is writable from inside");
}

#[test]
fn the_real_home_is_refused_however_it_arrives() {
    for source in ["/home/abyss/Documents", "/home"] {
        let mut p = plan(&cls("app"));
        p.mounts.push(JailMount { kind: MountKind::Nullfs, source: source.into(), target: "/docs".into(), read_only: true });
        assert_refused(&p, None, "reaches the person's own home");
    }
    // A component that begins with a combining mark, which Swift's
    // Character-wise `hasPrefix` lets through.
    let mut p = plan(&cls("app"));
    p.mounts.push(JailMount { kind: MountKind::Nullfs, source: "/home/abyss/\u{301}docs".into(), target: "/docs".into(), read_only: true });
    assert_refused(&p, None, "reaches the person's own home");
}

/// FreeBSD's UFS layout puts homes in /usr/home: there, mounting /usr is
/// mounting every home.
#[test]
fn on_ufs_with_homes_under_usr_the_system_mount_is_refused() {
    let v = plan(&cls("app")).violations(&cls("app"), "/usr/home/abyss");
    assert!(v.iter().any(|s| s.contains("/usr reaches the person's own home")), "{v:?}");
}

#[test]
fn a_home_elsewhere_is_refused() {
    let mut p = plan(&cls("app"));
    p.home_source = "/home/abyss".into();
    p.mounts.iter_mut().find(|m| m.target == "/home/abyss").unwrap().source = "/home/abyss".into();
    assert_refused(&p, None, "is not under /var/db/abyss-jails");
}

#[test]
fn secrets_are_refused() {
    let mut p = plan(&cls("app"));
    p.copies.push(("/etc/master.passwd".into(), "/etc/master.passwd".into()));
    assert_refused(&p, None, "/etc/master.passwd is copied into the jail");
    let mut q = plan(&cls("app"));
    q.files.push(("/etc/spwd.db".into(), String::new()));
    assert_refused(&q, None, "/etc/spwd.db is written into the jail");
    for (from, to, why) in [
        ("abyss:*:", "abyss:$6$salt$hash:", "an account carries a password"),
        ("abyss:*:", "abyss::", "an account carries a password"),
        (":1001:1001:", ":0:1001:", "abyss has uid 0"),
        ("::0:0:abyss", ":abyss", "not in master.passwd form"),
    ] {
        let mut r = plan(&cls("app"));
        r.accounts = r.accounts.replace(from, to);
        assert_refused(&r, None, why);
    }
    assert!(secret("/home/x/.ssh/id_ed25519") && secret("/root/.profile") && !secret("/rootx"));
}

#[test]
fn a_networkless_class_with_an_address_is_refused() {
    let mut p = plan(&cls("app"));
    p.params.iter_mut().find(|(k, _)| k == "ip4").unwrap().1 = Some("inherit".into());
    assert_refused(&p, None, "has no network, but the jail has an address");
    let mut q = plan(&cls("app"));
    q.params.retain(|(k, _)| k != "ip6");
    assert_refused(&q, None, "has no network, but the jail has an address");
}

#[test]
fn another_ruleset_or_runtime_is_refused() {
    let mut p = plan(&cls("app"));
    p.params.iter_mut().find(|(k, _)| k == "devfs_ruleset").unwrap().1 = Some("0".into());
    assert_refused(&p, None, "the devfs ruleset is not 4");
    let mut q = plan(&cls("app"));
    q.env.iter_mut().find(|(k, _)| k == "XDG_RUNTIME_DIR").unwrap().1 = "/var/run/abyss-abyss".into();
    assert_refused(&q, None, "the runtime directory is /var/run/abyss-abyss");
}

#[test]
fn an_unknown_device_is_refused_not_passed_on() {
    let c = JailClass { devices: vec!["dri".into(), "mem".into()], ..JailClass::new("odd") };
    let p = plan(&c);
    assert!(!p.unhide.iter().any(|u| u.contains("mem")), "an unknown device must not reach devfs");
    assert_refused(&p, Some(&c), "unknown device 'mem'");
}

#[test]
fn a_strange_system_directory_is_refused() {
    for dir in ["/", "/etc", "/root", "/var/db", "/var/run/abyss-jails/1002/app"] {
        let mut c = JailClass::new("odd");
        c.system.push(dir.into());
        assert_refused(&plan(&c), Some(&c), &format!("{dir} is not a system directory"));
    }
}

#[test]
fn under_is_component_wise() {
    assert!(under("/usr/local", "/usr") && under("/usr", "/usr") && under("/usr", "/usr/") && under("/anything", "/"));
    assert!(!under("/usrx", "/usr") && !under("/usr", "") && !under("usr", "/"));
    assert!(under("/home/abyss/\u{301}x", "/home/abyss"), "by bytes, not Characters");
}
