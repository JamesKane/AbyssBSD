//! JailD's tests (Tests/JailsTests/JailDTests.swift): the order a root is
//! built and undone in, and the wire. Pure; the daemon itself is
//! live-jaild.sh's, in the guest.

use crate::steps::{self, JailCommands, JailStep};
use crate::wire;
use jails::{JailClass, JailLayout, JailPlan, JailUser, BASE_SYSTEM};

fn me() -> JailUser {
    JailUser { name: "abyss".into(), uid: 1001, gid: 1001 }
}

fn c() -> JailCommands {
    JailCommands::default()
}

fn plan(cls: &str, pool: Option<&str>) -> JailPlan {
    let class = JailClass::shipped().into_iter().find(|k| k.name == cls).unwrap();
    JailPlan::make(&class, &me(), pool, &JailLayout::default())
}

fn build(cls: &str, pool: Option<&str>) -> (JailPlan, Vec<JailStep>) {
    let p = plan(cls, pool);
    let s = steps::build(&p, &me(), &c());
    (p, s)
}

fn index(s: &[JailStep], f: impl Fn(&JailStep) -> bool) -> usize {
    s.iter().position(f).expect("no such step")
}

fn run(argv: &[&str]) -> JailStep {
    JailStep::Run(argv.iter().map(|a| (*a).to_owned()).collect())
}

fn is_run(s: &JailStep, prefix: &[&str]) -> bool {
    matches!(s, JailStep::Run(a) if a.len() >= prefix.len() && a.iter().zip(prefix).all(|(x, y)| x == y))
}

fn mkdir(path: String, uid: u32, gid: u32, mode: u16) -> JailStep {
    JailStep::Mkdir { path, uid, gid, mode }
}

fn strings(xs: &[&str]) -> Vec<String> {
    xs.iter().map(|x| (*x).to_owned()).collect()
}

// MARK: build

#[test]
fn the_tmpfs_goes_over_the_root_before_anything_is_made_in_it() {
    let (p, s) = build("app", None);
    let tmpfs = index(&s, |x| is_run(x, &[&c().mount, "-t", "tmpfs"]));
    let first_inside = index(&s, |x| matches!(x, JailStep::Mkdir { path, .. } if path.starts_with(&format!("{}/", p.root))));
    assert!(tmpfs < first_inside);
    assert_eq!(s[0], mkdir(p.root.clone(), 0, 0, 0o755));
}

#[test]
fn the_system_is_mounted_read_only_and_nosuid_and_the_home_writable_nosuid() {
    let (p, s) = build("app", None);
    for dir in BASE_SYSTEM {
        assert!(s.contains(&run(&[&c().mount, "-t", "nullfs", "-o", "ro,nosuid", dir, &format!("{}{dir}", p.root)])), "{dir}");
    }
    assert!(s.contains(&run(&[&c().mount, "-t", "nullfs", "-o", "nosuid", &p.home_source, &format!("{}/home/abyss", p.root)])));
    assert!(!s.iter().any(|x| matches!(x, JailStep::Run(a) if a.iter().any(|w| w == "rw"))));
}

#[test]
fn devfs_gets_ruleset_4_and_only_the_named_devices() {
    let (p, s) = build("app-gl", None);
    let dev = format!("{}/dev", p.root);
    let (cm, cd) = (c().mount, c().devfs);
    let mount = index(&s, |x| *x == run(&[&cm, "-t", "devfs", "devfs", &dev]));
    let ruleset = index(&s, |x| *x == run(&[&cd, "-m", &dev, "ruleset", "4"]));
    let apply = index(&s, |x| *x == run(&[&cd, "-m", &dev, "rule", "applyset"]));
    let dri = index(&s, |x| *x == run(&[&cd, "-m", &dev, "rule", "apply", "path", "dri/*", "unhide"]));
    assert!(mount < ruleset && ruleset < apply && apply < dri);
    let (_, plain) = build("app", None);
    assert!(!plain.iter().any(|x| is_run(x, &[&cd]) && matches!(x, JailStep::Run(a) if a.iter().any(|w| w == "unhide"))));
}

#[test]
fn the_accounts_are_compiled_and_their_secrets_deleted_before_the_jail_exists() {
    let (p, s) = build("app", None);
    let master = format!("{}/etc/master.passwd", p.root);
    let write = index(&s, |x| *x == JailStep::Write { path: master.clone(), contents: p.accounts.clone(), mode: 0o600 });
    let mkdb = index(&s, |x| *x == run(&[&c().pwd_mkdb, "-p", "-d", &format!("{}/etc", p.root), &master]));
    let rm_master = index(&s, |x| *x == JailStep::Remove(master.clone()));
    let rm_spwd = index(&s, |x| *x == JailStep::Remove(format!("{}/etc/spwd.db", p.root)));
    assert!(write < mkdb && mkdb < rm_master && mkdb < rm_spwd);
    let mut last = [rm_master, rm_spwd];
    last.sort();
    assert_eq!(last, [s.len() - 2, s.len() - 1], "the last thing done, so nothing follows it in");
}

#[test]
fn the_home_is_made_for_the_person_and_a_dataset_comes_first_where_there_is_a_pool() {
    let (p, s) = build("app", Some("zroot"));
    let ds = index(&s, |x| *x == JailStep::Dataset { name: "zroot/abyss/jails/abyss/app".into(), mountpoint: p.home_source.clone() });
    let home = index(&s, |x| *x == mkdir(p.home_source.clone(), 1001, 1001, 0o700));
    assert!(ds < home);
    let (_, ufs) = build("app", None);
    assert!(!ufs.iter().any(|x| matches!(x, JailStep::Dataset { .. })));
}

#[test]
fn directories_inside_are_owned_as_the_plan_says() {
    let (p, s) = build("app", None);
    let r = &p.root;
    assert!(s.contains(&mkdir(format!("{r}/home/abyss"), 1001, 1001, 0o700)));
    assert!(s.contains(&mkdir(format!("{r}/run/user"), 1001, 1001, 0o700)));
    assert!(s.contains(&mkdir(format!("{r}/tmp"), 0, 0, 0o1777)));
    assert!(s.contains(&mkdir(format!("{r}/usr"), 0, 0, 0o755)));
}

// MARK: teardown

#[test]
fn teardown_unmounts_deepest_first_and_only_its_own() {
    let root = "/var/run/abyss-jails/1001/app";
    let mounted: Vec<String> = ["/", "/home", root]
        .iter()
        .map(|s| (*s).to_owned())
        .chain(["/usr", "/dev", "/home/abyss", "/run/granted/1/a.txt"].iter().map(|s| format!("{root}{s}")))
        .chain(strings(&["/var/run/abyss-jails/1001/app-gl", "/var/run/abyss-jails/1001/app-gl/usr"]))
        .collect();
    let s = steps::teardown(root, &mounted, &c());
    let order: Vec<&str> = s.iter().filter_map(|x| if let JailStep::Run(a) = x { a.last().map(String::as_str) } else { None }).collect();
    assert_eq!(order.first().copied(), Some(format!("{root}/run/granted/1/a.txt").as_str()));
    assert_eq!(order.last().copied(), Some(root), "the tmpfs last");
    let mut got: Vec<&str> = order.clone();
    got.sort();
    let mut want = vec![root.to_owned(), format!("{root}/usr"), format!("{root}/dev"), format!("{root}/home/abyss"), format!("{root}/run/granted/1/a.txt")];
    want.sort();
    assert_eq!(got, want, "nothing of app-gl's (a prefix of the name is not a parent)");
    assert_eq!(s.last(), Some(&JailStep::Rmdir(root.into())));
    assert!(s[..s.len() - 1].iter().all(|x| is_run(x, &[&c().umount, "-f"])));
}

#[test]
fn a_point_mounted_twice_is_unmounted_twice() {
    let root = "/r";
    let s = steps::teardown(root, &strings(&["/r", "/r/usr", "/r/usr"]), &c());
    assert_eq!(s.iter().filter(|x| **x == run(&[&c().umount, "-f", "/r/usr"])).count(), 2);
}

// MARK: grants (P18.4)

#[test]
fn a_grant_is_one_file_in_a_directory_of_its_own_read_only_unless_writable() {
    let root = "/var/run/abyss-jails/1001/app";
    let ro = steps::grant(root, 3, "/home/abyss/Documents/notes.txt", false, &c());
    assert_eq!(
        ro,
        [
            mkdir(format!("{root}/run/granted/3"), 0, 0, 0o755),
            JailStep::Write { path: format!("{root}/run/granted/3/notes.txt"), contents: String::new(), mode: 0o644 },
            run(&[&c().mount, "-t", "nullfs", "-o", "ro,nosuid", "/home/abyss/Documents/notes.txt", &format!("{root}/run/granted/3/notes.txt")]),
        ]
    );
    let rw = steps::grant(root, 4, "/home/abyss/a.txt", true, &c());
    assert_eq!(rw.last(), Some(&run(&[&c().mount, "-t", "nullfs", "-o", "nosuid", "/home/abyss/a.txt", &format!("{root}/run/granted/4/a.txt")])));
    assert_eq!(steps::grant_path(3, "/home/abyss/Documents/notes.txt"), "/run/granted/3/notes.txt");
}

#[test]
fn revoke_undoes_a_grant_in_reverse() {
    assert_eq!(
        steps::revoke("/r", 2, "/h/x.txt", &c()),
        [run(&[&c().umount, "-f", "/r/run/granted/2/x.txt"]), JailStep::Remove("/r/run/granted/2/x.txt".into()), JailStep::Rmdir("/r/run/granted/2".into())]
    );
}

#[test]
fn a_grants_name_cannot_climb() {
    assert_eq!(steps::grant_name("/a/b.txt"), "b.txt");
    for climb in ["/", "/a/..", "/a/."] {
        assert_eq!(steps::grant_name(climb), "file", "{climb}");
    }
    assert!(!steps::grant_path(1, "/a/..").contains(".."));
}

// MARK: the mount table

/// Mount points come from the kernel as whole strings (getmntinfo), so a
/// granted "A chosen file.txt" is one path, and teardown finds it under its
/// root (HANDOFF §2.127: `mount -p` split it into three).
#[test]
fn left_roots_and_teardown_find_paths_with_spaces() {
    let root = "/var/run/abyss-jails/1001/app-net";
    let pts = strings(&["/", "/dev", root, &format!("{root}/usr"), &format!("{root}/run/granted/1/A chosen file.txt"), "/var/run/abyss-jails/1002/app/usr", "/mnt/a b"]);
    assert_eq!(steps::left_roots("/var/run/abyss-jails", &pts), [root, "/var/run/abyss-jails/1002/app"]);
    let s = steps::teardown(root, &pts, &c());
    assert_eq!(s[0], run(&[&c().umount, "-f", &format!("{root}/run/granted/1/A chosen file.txt")]), "the granted file, spaces and all, is unmounted first");
    assert_eq!(steps::jail_name("/var/run/abyss-jails/1002/app-net", "/var/run/abyss-jails").as_deref(), Some("abyss-1002-app-net"));
    assert_eq!(steps::jail_name("/var/run/abyss-jails/x/app", "/var/run/abyss-jails"), None);
}

// MARK: the wire

#[test]
fn lists_survive_anything() {
    let xs = strings(&["zenity", "--text", "a b", "", "x=y\tz"]);
    assert_eq!(wire::unlist(&wire::list(&xs)), xs);
    assert!(wire::unlist(&[]).is_empty());
}

#[test]
fn the_caller_cannot_move_the_jails_home_or_runtime() {
    let plan = [("HOME", "/home/abyss"), ("XDG_RUNTIME_DIR", "/run/user"), ("PATH", "/bin")].map(|(k, v)| (k.to_owned(), v.to_owned()));
    let env = wire::environment(&plan, &strings(&["HOME=/", "XDG_RUNTIME_DIR=/tmp", "LANG=en_US.UTF-8", "=x", "junk"]));
    assert_eq!(env, ["HOME=/home/abyss", "XDG_RUNTIME_DIR=/run/user", "PATH=/bin", "LANG=en_US.UTF-8"]);
}

#[test]
fn only_the_owner_may_use_a_jail() {
    assert!(wire::owns(1001, "abyss-1001-app"));
    assert!(!wire::owns(1001, "abyss-10011-app"));
    assert!(!wire::owns(100, "abyss-1001-app"));
    assert!(!wire::owns(1001, "other-1001-app"));
}

/// Off FreeBSD there are no jails, and every call says so rather than
/// pretending: ENOSYS.
#[test]
fn off_freebsd_the_jail_calls_refuse() {
    if cfg!(target_os = "freebsd") {
        return;
    }
    assert_eq!(abyss_sys::jail::desc_by_name("abyss-1-app").unwrap_err().raw_os_error(), Some(libc::ENOSYS));
    assert!(abyss_sys::jail::Watch::new().is_err());
    assert!(abyss_sys::jail::mount_points().is_empty());
}
