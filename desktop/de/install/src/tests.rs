//! InstallTests.swift and KeymapTests.swift, ported. Every test runs on
//! Linux, where `gpart`, `zpool` and `zfs` do not exist: the machine is an
//! argument, so the exact machine on which a refusal must fire is built in
//! three lines.

use super::steps::steps;
use super::*;
use PlanRefusal::*;

const GIB: u64 = 1 << 30;
const MIB: u64 = 1 << 20;

/// An ordinary machine: one empty 64 GiB disk, the live system elsewhere.
fn machine() -> DiskInventory {
    DiskInventory::new(vec![Disk { description: "QEMU HARDDISK".into(), ..Disk::new("ada0", 64 * GIB) }])
}

fn with_disk(f: impl FnOnce(&mut Disk)) -> DiskInventory {
    let mut m = machine();
    f(&mut m.disks[0]);
    m
}

/// A plan that is fine, so a test can break exactly one thing about it.
fn good_plan() -> InstallPlan {
    let jkane = Account { full_name: "J Kane".into(), groups: vec!["wheel".into()], ..Account::new("jkane", "$6$fake") };
    InstallPlan { accounts: vec![jkane], ..InstallPlan::new("ada0") }
}

fn with_pool(pool: &str) -> InstallPlan {
    InstallPlan { pool_name: pool.into(), ..good_plan() }
}

fn rooted(disk: &str) -> InstallPlan {
    InstallPlan { root_password_hash: "$6$y".into(), ..InstallPlan::new(disk) }
}

fn argvs(s: &[Step]) -> Vec<&[String]> {
    s.iter().filter_map(|st| if let Action::Run { argv, .. } = &st.action { Some(&argv[..]) } else { None }).collect()
}

fn index_of(s: &[Step], needle: &str) -> Option<usize> {
    s.iter().position(|st| matches!(&st.action, Action::Run { argv, .. } if argv.join(" ").contains(needle)))
}

fn runs(s: &[Step], words: &[&str]) -> bool {
    argvs(s).iter().any(|a| words.iter().all(|w| a.iter().any(|x| x == w)))
}

// MARK: the refusals

#[test]
fn an_ordinary_plan_on_an_ordinary_machine_is_accepted() {
    // The positive control, without which every refusal below would pass
    // against a predicate that refuses everything.
    assert_eq!(problems(&good_plan(), &machine()), []);
    assert!(compile(&good_plan(), &machine()).is_ok());
}

#[test]
fn the_disk_you_are_running_from_is_refused() {
    let ps = problems(&good_plan(), &with_disk(|d| d.holds_running_root = true));
    assert!(ps.contains(&DiskHoldsRunningRoot("ada0".into())), "{ps:?}");
}

#[test]
fn a_disk_with_something_mounted_from_it_is_refused() {
    let ps = problems(&good_plan(), &with_disk(|d| d.mounted_at = vec!["/media/photos".into()]));
    assert!(ps.contains(&DiskIsMounted { disk: "ada0".into(), at: vec!["/media/photos".into()] }), "{ps:?}");
}

#[test]
fn the_running_root_outranks_a_merely_mounted_disk() {
    let ps = problems(
        &good_plan(),
        &with_disk(|d| {
            d.mounted_at = vec!["/".into()];
            d.holds_running_root = true;
        }),
    );
    assert!(ps.contains(&DiskHoldsRunningRoot("ada0".into())));
    assert!(!ps.iter().any(|p| matches!(p, DiskIsMounted { .. })));
}

/// A disk with a table and no room: the shape of all three fixed disks on
/// the bring-up machine.
fn full_disk(pools: &[&str], kinds: &[&str]) -> DiskInventory {
    DiskInventory::new(vec![Disk {
        description: "Samsung".into(),
        existing_pools: pools.iter().map(|p| (*p).into()).collect(),
        partition_kinds: kinds.iter().map(|k| (*k).into()).collect(),
        free_bytes: 2 * MIB,
        has_partition_table: true,
        ..Disk::new("ada0", 64 * GIB)
    }])
}

fn roomy() -> DiskInventory {
    DiskInventory::new(vec![Disk {
        description: "Samsung".into(),
        partition_kinds: vec!["efi".into(), "ntfs".into()],
        free_bytes: 200 * GIB,
        has_partition_table: true,
        ..Disk::new("ada0", 512 * GIB)
    }])
}

#[test]
fn a_full_disk_is_refused_whatever_is_on_it() {
    // **The rule that generalises**: the old one offered somebody's Windows
    // as a clean target.
    for kinds in [&["efi", "ms-basic-data", "ms-recovery"][..], &["ntfs", "ntfs"]] {
        let ps = problems(&good_plan(), &full_disk(&[], kinds));
        assert!(ps.iter().any(|p| matches!(p, DiskIsFull { .. })), "{kinds:?} was offered as a clean target: {ps:?}");
    }
}

#[test]
fn the_refusal_says_what_is_on_it_and_how_short_it_is() {
    let ps = problems(&good_plan(), &full_disk(&["zroot"], &["efi", "freebsd-swap", "freebsd-zfs"]));
    let msg = ps.iter().find(|p| matches!(p, DiskIsFull { .. })).unwrap().message();
    assert_eq!(
        msg,
        "ada0 is fully partitioned (ZFS pool zroot, efi, freebsd-swap, freebsd-zfs) — 0.0 GiB free, and this install needs 6.2 GiB in one piece. Choose a disk with room, or confirm that this one is to be erased"
    );
}

#[test]
fn a_disk_with_room_is_installable_without_destroying_anything() {
    assert_eq!(problems(&good_plan(), &roomy()), []);
}

#[test]
fn a_blank_disk_is_empty_not_full() {
    assert_eq!(problems(&good_plan(), &DiskInventory::new(vec![Disk::new("ada0", 64 * GIB)])), []);
}

#[test]
fn saying_erase_lifts_it_and_nothing_else() {
    let erase = InstallPlan { erase_existing_data: true, ..good_plan() };
    assert_eq!(problems(&erase, &full_disk(&["zroot"], &["efi", "ntfs"])), []);
    let still_root = problems(
        &erase,
        &DiskInventory::new(vec![Disk { holds_running_root: true, partition_kinds: vec!["efi".into()], has_partition_table: true, ..Disk::new("ada0", 64 * GIB) }]),
    );
    assert!(still_root.contains(&DiskHoldsRunningRoot("ada0".into())), "{still_root:?}");
}

#[test]
fn a_partition_is_not_a_disk() {
    for name in ["ada0p2", "da0s1", "nvd0p1", "da0s1a"] {
        assert!(names_a_partition(name), "{name}");
        assert!(problems(&InstallPlan { disk: name.into(), ..good_plan() }, &machine()).contains(&NotAWholeDisk(name.into())), "{name}");
    }
    for name in ["ada0", "da0", "nvd0", "md0", "vtbd1", "ada0p", "p1", ""] {
        assert!(!names_a_partition(name), "{name}");
    }
}

#[test]
fn a_disk_that_is_not_there_names_the_ones_that_are() {
    let ps = problems(&InstallPlan { disk: "ada9".into(), ..good_plan() }, &machine());
    assert_eq!(ps, [NoSuchDisk { disk: "ada9".into(), available: vec!["ada0".into()] }]);
    assert_eq!(ps[0].message(), "there is no disk called ada9; this machine has ada0");
    assert_eq!(
        problems(&good_plan(), &DiskInventory::default())[0].message(),
        "this machine has no disks, so there is nowhere to install"
    );
}

#[test]
fn a_too_small_disk_is_refused_before_anything_is_written() {
    let ps = problems(&good_plan(), &with_disk(|d| d.bytes = 3 * GIB));
    assert!(ps.iter().any(|p| matches!(p, DiskTooSmall { .. })), "{ps:?}");
}

#[test]
fn a_pool_name_already_imported_is_refused() {
    let mut m = machine();
    m.imported_pools = vec!["zroot".into()];
    assert!(problems(&with_pool("zroot"), &m).contains(&PoolNameInUse("zroot".into())));
    assert_eq!(problems(&with_pool("zroot"), &machine()), []);
}

#[test]
fn pool_names_zfs_itself_would_reject() {
    // Each fails at `zpool create`, AFTER `gpart` has written the disk.
    let bad = |n: &str| problems(&with_pool(n), &machine()).iter().any(|p| matches!(p, BadPoolName { .. }));
    // libzfs reserves prefixes, not just names: `zpool create mirror2` fails.
    for name in ["mirror", "raidz2", "spare", "9lives", "c0d0", "c9x", "", "a/b", "mirror2", "raidzpool", "draid1", "spares", "log", &"a".repeat(240)] {
        assert!(bad(name), "expected {name} to be refused");
    }
    for name in ["abyss", "zroot", "tank", "abyss-2", "a.b", "cache2", "logs", "amirror", &"a".repeat(239)] {
        assert!(!bad(name), "expected {name} to be accepted");
    }
    // ZFS's letters are ASCII (Swift's are Unicode's, and pass these).
    for name in ["école", "pool²", "zé"] {
        assert!(bad(name), "expected {name} to be refused");
    }
}

/// The settings refused, as `(what, value)`.
fn bad_settings(p: &InstallPlan) -> Vec<(String, String)> {
    problems(p, &machine()).into_iter().filter_map(|r| if let BadSetting { what, value, .. } = r { Some((what, value)) } else { None }).collect()
}

#[test]
fn a_hostname_is_a_hostname_and_writes_no_lines_of_its_own() {
    let bad = |h: &str| bad_settings(&InstallPlan { hostname: h.into(), ..rooted("ada0") }) == [("the computer's name".to_owned(), h.to_owned())];
    for h in ["x\"\nabyss_desktop_user=\"root", "", "a b", "-a", "a-", "a..b", ".a", "a.", "`id`", "$(id)", "é", &"a".repeat(64), &["a"; 128].join(".")] {
        assert!(bad(h), "expected {h:?} to be refused");
    }
    for h in ["abyss", "jaguar", "abyss-2", "a.example.org", "9lives", &"a".repeat(63)] {
        assert!(bad_settings(&InstallPlan { hostname: h.into(), ..rooted("ada0") }).is_empty(), "expected {h:?} to be accepted");
    }
}

#[test]
fn a_timezone_or_keymap_is_a_name_not_a_path() {
    let tz = |t: &str| bad_settings(&InstallPlan { timezone: t.into(), ..rooted("ada0") });
    for t in ["../..", "../../etc/master.passwd", "/etc/passwd", "America/../../x", "./UTC", "America/", "Ame rica", "x\"y"] {
        assert_eq!(tz(t), [("the time zone".to_owned(), t.to_owned())], "{t:?}");
    }
    for t in ["", "UTC", "America/Chicago", "America/Argentina/Buenos_Aires", "Etc/GMT+5", "Etc/GMT-14", "GMT0"] {
        assert_eq!(tz(t), [], "{t:?}");
    }
    let km = |k: &str| bad_settings(&InstallPlan { keymap: k.into(), ..rooted("ada0") });
    for k in ["../x", "a/b", "us.kbd\"\nx=\"y", ".kbd", "us kbd"] {
        assert_eq!(km(k), [("the keyboard layout".to_owned(), k.to_owned())], "{k:?}");
    }
    for k in ["", "us.kbd", "fr.acc.kbd", "us.dvorak.kbd", "de.noacc.kbd", "uk.kbd"] {
        assert_eq!(km(k), [], "{k:?}");
    }
}

#[test]
fn account_names_are_ones_pw_takes_and_full_names_keep_to_one_line() {
    let with = |a: Account| bad_settings(&InstallPlan { accounts: vec![a], ..rooted("ada0") });
    for n in ["", "-jo", "jo smith", "jo:x", "jo\"x", "jo`id`", "jo$x", "jö", "jo\n", &"j".repeat(33)] {
        assert_eq!(with(Account::new(n, "$6$x")), [("the account name".to_owned(), n.to_owned())], "{n:?}");
    }
    for n in ["jkane", "jo.o-neil", "_svc", "samba$", "J_Kane", &"j".repeat(32)] {
        assert_eq!(with(Account::new(n, "$6$x")), [], "{n:?}");
    }
    let full = |f: &str| with(Account { full_name: f.into(), ..Account::new("jo", "$6$x") });
    for f in ["Jo:x", "Jo\nroot::0:0::/:/bin/sh", "Jo\t"] {
        assert_eq!(full(f), [("the full name".to_owned(), f.to_owned())], "{f:?}");
    }
    for f in ["", "Jo O'Neil", "Zoë", "J. Kane, Esq."] {
        assert_eq!(full(f), [], "{f:?}");
    }
}

#[test]
fn a_machine_nobody_can_log_into_is_refused() {
    assert!(problems(&InstallPlan::new("ada0"), &machine()).contains(&NoAdministrator));
    let guest = InstallPlan { accounts: vec![Account::new("guest", "$6$x")], ..InstallPlan::new("ada0") };
    assert!(problems(&guest, &machine()).contains(&NoAdministrator), "a non-administrator is not enough");
    let wheel = InstallPlan { accounts: vec![Account { groups: vec!["wheel".into()], ..Account::new("jkane", "$6$x") }], ..InstallPlan::new("ada0") };
    assert!(!problems(&wheel, &machine()).contains(&NoAdministrator));
    assert!(!problems(&rooted("ada0"), &machine()).contains(&NoAdministrator));
}

#[test]
fn an_install_that_installs_nothing_is_refused() {
    assert!(problems(&InstallPlan { sets: vec![], ..rooted("ada0") }, &machine()).contains(&NoSets));
    let backwards = vec!["kernel.txz".to_owned(), "base.txz".to_owned()];
    assert!(problems(&InstallPlan { sets: backwards.clone(), ..rooted("ada0") }, &machine()).contains(&BaseSetNotFirst(backwards)));
}

#[test]
fn partition_sizes_must_be_whole_mib() {
    let p = InstallPlan { esp_bytes: 260 * MIB + 1, ..rooted("ada0") };
    assert!(problems(&p, &machine()).contains(&SizeNotWholeMiB { what: "the EFI partition".into(), bytes: 260 * MIB + 1 }));
}

#[test]
fn every_problem_is_reported_not_just_the_first() {
    let p = InstallPlan { pool_name: "mirror".into(), sets: vec![], ..InstallPlan::new("ada0p1") };
    let ps = problems(&p, &machine());
    assert!(ps.len() >= 4, "{ps:?}");
    assert!(ps.contains(&NotAWholeDisk("ada0p1".into())) && ps.contains(&NoSets) && ps.contains(&NoAdministrator));
}

#[test]
fn every_refusal_says_something_a_person_could_act_on() {
    let all = [
        EmptyDisk,
        NotAWholeDisk("ada0p1".into()),
        NoSuchDisk { disk: "ada9".into(), available: vec!["ada0".into()] },
        DiskIsMounted { disk: "ada0".into(), at: vec!["/media".into()] },
        DiskHoldsRunningRoot("ada0".into()),
        DiskTooSmall { disk: "ada0".into(), has: GIB, needs: 8 * GIB },
        BadPoolName { name: "mirror".into(), why: "that name is reserved by ZFS".into() },
        BadSetting { what: "the time zone".into(), value: "../..".into(), why: "it must be a name under /usr/share/zoneinfo, not a path".into() },
        PoolNameInUse("zroot".into()),
        NoSets,
        BaseSetNotFirst(vec!["kernel.txz".into()]),
        SizeNotWholeMiB { what: "swap".into(), bytes: 3 },
        RelativePath { what: "the mount point".into(), path: "mnt".into() },
        NoAdministrator,
    ];
    for r in all {
        assert!(r.message().chars().count() > 15, "{r:?}: {r}");
    }
    assert!(DiskTooSmall { disk: "ada0".into(), has: GIB, needs: 8 * GIB }.message().contains("1.0 GiB"));
}

#[test]
fn no_step_list_exists_for_a_refused_plan() {
    assert_eq!(compile(&good_plan(), &with_disk(|d| d.holds_running_root = true)), Err(DiskHoldsRunningRoot("ada0".into())));
}

/// Sizes from the wire that Swift's arithmetic traps on.
#[test]
fn sizes_too_big_to_add_are_refused_not_fatal() {
    let p = InstallPlan { esp_bytes: u64::MAX - (MIB - 1), swap_bytes: u64::MAX - (MIB - 1), ..good_plan() };
    assert_eq!(p.minimum_disk_bytes(), u64::MAX, "Swift traps here");
    let ps = problems(&p, &machine());
    let small = ps.iter().find(|r| matches!(r, DiskTooSmall { .. })).unwrap();
    assert_eq!(small.message(), "ada0 holds 64.0 GiB and this install needs at least 17179869183.9 GiB");
}

// MARK: the step list

#[test]
fn the_first_destructive_step_is_where_the_disk_changes() {
    let s = compile(&good_plan(), &machine()).unwrap();
    assert_eq!(s.iter().position(|st| st.destructive), Some(0));
    assert_eq!(argvs(&s)[0][0], "gpart");
}

#[test]
fn the_disk_is_partitioned_before_it_is_formatted_and_the_boot_flag_is_set_before_extraction() {
    let s = compile(&good_plan(), &machine()).unwrap();
    let i = |n: &str| index_of(&s, n).unwrap_or_else(|| panic!("no {n}"));
    assert!(i("gpart create") < i("-t freebsd-zfs"));
    assert!(i("-t freebsd-zfs") < i("zpool create"));
    // Extract before mounting the root and base lands in the pool's
    // mountpoint and looks installed.
    assert!(i("zfs mount abyss/ROOT/default") < i("base.txz"));
    assert!(i("base.txz") < i("zpool export"));
    assert_eq!(i("zpool export"), s.len() - 1, "the export has to be last");
}

#[test]
fn the_root_dataset_is_mounted_by_hand_because_it_does_not_auto_mount() {
    let s = compile(&good_plan(), &machine()).unwrap();
    let a = argvs(&s);
    let root = a.iter().find(|a| a[..2] == ["zfs", "create"] && a.last().unwrap() == "abyss/ROOT/default").unwrap();
    assert!(root.iter().any(|x| x == "canmount=noauto"), "{root:?}");
    assert!(a.iter().any(|a| *a == ["zfs", "mount", "abyss/ROOT/default"]));
}

#[test]
fn the_root_is_mounted_before_any_other_dataset_is_created() {
    let s = compile(&good_plan(), &machine()).unwrap();
    let a = argvs(&s);
    let mount_root = a.iter().position(|a| *a == ["zfs", "mount", "abyss/ROOT/default"]).unwrap();
    let first_other = a.iter().position(|a| a.len() > 2 && a[..2] == ["zfs", "create"] && !a.last().unwrap().starts_with("abyss/ROOT")).unwrap();
    assert!(mount_root < first_other, "a dataset is created before the root it belongs in is mounted");
    let make_root = a.iter().position(|a| a.last().unwrap() == "abyss/ROOT/default" && a.iter().any(|x| x == "create")).unwrap();
    assert!(make_root < mount_root);
}

#[test]
fn we_mount_our_own_datasets_and_nobody_elses_entirely() {
    let s = compile(&good_plan(), &machine()).unwrap();
    let a = argvs(&s);
    assert!(!a.iter().any(|a| *a == ["zfs", "mount", "-a"] || *a == ["zfs", "umount", "-a"]), "swept the whole machine");
    let mounted: Vec<&str> = a.iter().filter(|a| a.len() == 3 && a[..2] == ["zfs", "mount"]).map(|a| a[2].as_str()).collect();
    assert_eq!(mounted, ["abyss/ROOT/default"]);
    assert_eq!(*a.last().unwrap(), ["zpool", "export", "abyss"]);
}

#[test]
fn the_pool_cache_is_written_before_it_is_copied() {
    let s = compile(&good_plan(), &machine()).unwrap();
    let write = index_of(&s, "zpool set cachefile=").expect("nothing asks ZFS to write the cache");
    let copy = argvs(&s).iter().position(|a| a[0] == "cp" && a.last().unwrap().ends_with("/boot/zfs/zpool.cache")).unwrap();
    assert!(write < copy);
}

#[test]
fn a_swapless_plan_has_no_swap_partition_and_no_fstab_entry() {
    let p = InstallPlan { swap_bytes: 0, ..rooted("ada0") };
    assert_eq!(p.pool_partition(), 2);
    assert_eq!(p.swap_partition(), None);
    let s = compile(&p, &machine()).unwrap();
    assert!(!runs(&s, &["freebsd-swap"]));
    assert!(!fstab(&p).contains("swap\tsw"));
    // ...and the pool is addressed **by label**, so the index is irrelevant.
    assert!(runs(&s, &["zpool", "/dev/gpt/abysszfs"]));
}

#[test]
fn installing_into_free_space_destroys_no_partition_table() {
    let s = compile(&good_plan(), &roomy()).unwrap();
    assert!(!runs(&s, &["gpart", "destroy"]), "an install into free space destroyed the table");
    assert!(!runs(&s, &["gpart", "create"]), "an install into free space replaced the table");
    assert!(runs(&s, &["gpart", "add", "efi"]) && runs(&s, &["gpart", "add", "freebsd-zfs"]));
}

#[test]
fn a_blank_disk_gets_a_table_but_nothing_is_destroyed() {
    let s = compile(&good_plan(), &DiskInventory::new(vec![Disk::new("ada0", 64 * GIB)])).unwrap();
    assert!(!runs(&s, &["gpart", "destroy"]), "there was no table to destroy");
    assert!(runs(&s, &["gpart", "create"]), "a blank disk still needs a GPT");
}

#[test]
fn erasing_is_the_only_path_that_destroys_a_table() {
    let s = compile(&InstallPlan { erase_existing_data: true, ..good_plan() }, &full_disk(&[], &["ntfs"])).unwrap();
    assert!(runs(&s, &["destroy"]));
}

#[test]
fn a_password_hash_never_appears_in_argv() {
    let s = compile(&good_plan(), &machine()).unwrap();
    for st in &s {
        if let Action::Run { argv, stdin } = &st.action {
            assert!(!argv.iter().any(|a| a.contains("$6$fake")), "hash leaked into argv: {argv:?}");
            if argv.iter().any(|a| a == "useradd") && argv.iter().any(|a| a == "jkane") {
                assert_eq!(stdin.as_deref(), Some("$6$fake"));
            }
        }
    }
    assert!(!render(&s).contains("$6$fake"), "hash leaked into the rendered list");
}

#[test]
fn the_loader_is_taken_from_what_we_installed_not_from_the_live_system() {
    let s = compile(&good_plan(), &machine()).unwrap();
    let cp = argvs(&s).into_iter().find(|a| a[0] == "cp" && a.last().unwrap().ends_with("BOOTX64.efi")).expect("no loader copy");
    assert_eq!(cp[1], "/mnt/boot/loader.efi");
}

#[test]
fn the_labels_we_write_into_fstab_are_labels_the_machine_will_have() {
    let p = with_pool("tank");
    assert!(fstab(&p).contains("/dev/gpt/tankswap"));
    assert!(loader_conf(&p, None).contains("kern.geom.label.disk_ident.enable=\"0\""));
}

fn mac_pro() -> MachineIdentity {
    MachineIdentity { maker: "Apple Inc.".into(), product: "MacPro6,1".into() }
}

fn msi() -> MachineIdentity {
    MachineIdentity { maker: "Micro-Star International Co., Ltd.".into(), product: "MS-7D25".into() }
}

#[test]
fn a_mac_pro_still_gets_its_power_fault_workaround() {
    assert!(loader_conf(&good_plan(), Some(&mac_pro())).contains("hw.pci.enable_pcie_hp=\"0\""));
}

#[test]
fn every_other_machine_no_longer_inherits_it() {
    assert!(!loader_conf(&good_plan(), Some(&msi())).contains("enable_pcie_hp"));
    assert!(!loader_conf(&good_plan(), None).contains("enable_pcie_hp"), "a machine that will not say does not get it");
}

#[test]
fn the_rest_of_loader_conf_is_unchanged_either_way() {
    for m in [Some(mac_pro()), Some(msi()), None] {
        let c = loader_conf(&good_plan(), m.as_ref());
        assert!(c.contains("zfs_load=\"YES\"") && c.contains("kern.geom.label.disk_ident.enable=\"0\"") && c.contains("vfs.root.mountfrom="), "{m:?}");
    }
}

fn desktop(accounts: Vec<Account>) -> InstallPlan {
    InstallPlan { sets: vec!["base.txz".into(), "kernel.txz".into(), InstallPlan::DESKTOP_SET.into()], accounts, ..InstallPlan::new("ada0") }
}

fn guest_and_admin() -> Vec<Account> {
    vec![Account::new("guest", "$6$g"), Account { groups: vec!["wheel".into()], ..Account::new("jkane", "$6$j") }]
}

#[test]
fn a_plain_freebsd_install_does_not_start_a_desktop_it_does_not_have() {
    assert!(!good_plan().installs_desktop());
    assert!(!rc_conf(&good_plan()).contains("abyss_desktop"));
}

/// **An installed desktop starts at the login window** (PHASE16 §6.2).
#[test]
fn installing_the_desktop_starts_the_login_window() {
    let p = desktop(guest_and_admin());
    assert!(p.installs_desktop());
    assert!(!p.auto_login, "automatic login is never the default");
    let rc = rc_conf(&p);
    assert!(rc.contains("abyss_loginwindow_enable=\"YES\"") && rc.contains("abyss_loginwindow_greeter=\"YES\""), "{rc}");
    // **Never `abyss_loginwindow_flags`**: daemon(8) refused `--greeter`.
    assert!(!rc.contains("abyss_loginwindow_flags"), "{rc}");
    assert!(rc.contains("abyss_desktop_enable=\"NO\""), "said, not left unset: {rc}");
    assert!(!rc.contains("abyss_desktop_user"), "{rc}");
    let s = compile(&p, &machine()).unwrap();
    let made = argvs(&s).into_iter().find(|a| a.iter().any(|x| x == "_loginwindow")).unwrap();
    assert!(made.iter().any(|x| x == "/usr/sbin/nologin") && made.iter().any(|x| x == "no"), "{made:?}");
}

#[test]
fn automatic_login_is_a_choice_and_starts_the_owners_desktop() {
    let p = InstallPlan { auto_login: true, ..desktop(guest_and_admin()) };
    let rc = rc_conf(&p);
    assert!(rc.contains("abyss_desktop_enable=\"YES\"") && rc.contains("abyss_desktop_user=\"jkane\""), "{rc}");
    assert!(!rc.contains("abyss_loginwindow_greeter=\"YES\""), "{rc}");
    // Asked for with nobody to log in as: the login window.
    let nobody = InstallPlan { root_password_hash: "$6$r".into(), auto_login: true, ..desktop(vec![]) };
    assert!(!rc_conf(&nobody).contains("abyss_desktop_user"));
    assert!(rc_conf(&nobody).contains("abyss_loginwindow_greeter=\"YES\""));
    // No administrator: the first account.
    let first = InstallPlan { root_password_hash: "$6$r".into(), auto_login: true, ..desktop(vec![Account::new("guest", "$6$g")]) };
    assert!(rc_conf(&first).contains("abyss_desktop_user=\"guest\""));
}

#[test]
fn the_settings_helper_starts_for_the_administrator_and_only_for_one() {
    let rc = rc_conf(&desktop(guest_and_admin()));
    assert!(rc.contains("abyss_settings_enable=\"YES\"") && rc.contains("abyss_settings_admin=\"jkane\""), "{rc}");
    let no_admin = InstallPlan { root_password_hash: "$6$r".into(), ..desktop(vec![Account::new("guest", "$6$g")]) };
    assert!(!rc_conf(&no_admin).contains("abyss_settings"));
    assert!(!rc_conf(&good_plan()).contains("abyss_settings"), "no desktop, no settings helper");
}

#[test]
fn the_authenticator_starts_whenever_the_desktop_is_installed() {
    let d = rc_conf(&desktop(vec![Account::new("guest", "$6$g")]));
    assert!(d.contains("abyss_loginwindow_enable=\"YES\"") && d.contains("abyss_jaild_enable=\"YES\""), "{d}");
    let plain = InstallPlan { sets: vec!["base.txz".into()], accounts: vec![Account::new("guest", "$6$g")], ..InstallPlan::new("ada0") };
    assert!(!rc_conf(&plain).contains("abyss_loginwindow"), "a plain FreeBSD gets no desktop services");
}

#[test]
fn the_files_we_write_say_where_the_root_is() {
    let p = with_pool("tank");
    assert!(loader_conf(&p, None).contains("vfs.root.mountfrom=\"zfs:tank/ROOT/default\""));
    assert!(rc_conf(&p).contains("zfs_enable=\"YES\""));
    assert!(!fstab(&p).contains("tank/ROOT"));
    assert!(fstab(&p).contains("/dev/gpt/tankswap"));
}

#[test]
fn partition_labels_carry_the_pool_name_so_the_live_medium_does_not_collide() {
    let s = compile(&good_plan(), &machine()).unwrap();
    let labels: Vec<&str> = argvs(&s).iter().filter_map(|a| a.get(a.iter().position(|x| x == "-l")? + 1).map(String::as_str)).collect();
    assert_eq!(labels, ["abyssesp", "abyssswap", "abysszfs"]);
}

#[test]
fn an_argument_renders_unambiguously() {
    let s = steps(
        &InstallPlan {
            accounts: vec![Account { full_name: "Jo O'Neil".into(), groups: vec!["wheel".into()], ..Account::new("jo", "$6$x") }],
            mountpoint: "/mnt x".into(),
            ..InstallPlan::new("ada0")
        },
        &machine(),
    );
    let text = render(&s);
    assert!(text.contains("$ pw -R '/mnt x' useradd -n jo -m -s /bin/sh -H 0 -c 'Jo O'\\''Neil' -G wheel\n"), "{text}");
}

// MARK: the golden list

#[test]
fn the_step_list_is_what_it_was_last_time_somebody_looked_at_it() {
    // On a Mac Pro, erasing an occupied disk: the longest and most
    // dangerous shape, so a change to it has to be defended.
    let p = InstallPlan {
        hostname: "jaguar".into(),
        timezone: "America/Chicago".into(),
        keymap: "us.kbd".into(),
        root_password_hash: "$6$root".into(),
        accounts: vec![Account { full_name: "J Kane".into(), groups: vec!["wheel".into(), "operator".into()], ..Account::new("jkane", "$6$user") }],
        erase_existing_data: true,
        ..InstallPlan::new("ada0")
    };
    let mut occupied = full_disk(&[], &["efi", "ntfs"]);
    occupied.disks[0].description = "QEMU HARDDISK".into();
    occupied.disks[0].free_bytes = MIB;
    occupied.machine = Some(mac_pro());
    // The same list Swift's InstallTests holds.
    assert_eq!(render(&compile(&p, &occupied).unwrap()), include_str!("golden-steps.txt"));
}

// MARK: keymaps

mod keymap {
    use crate::keymaps::*;
    use std::fs;
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("abyss-keymap-{}-{name}", std::process::id()));
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn the_installers_own_line_is_read() {
        let d = scratch("own");
        let rc = d.join("rc.conf");
        fs::write(&rc, "# Written by the AbyssBSD installer.\nzfs_enable=\"YES\"\nkeymap=\"uk.kbd\"\n").unwrap();
        assert_eq!(configured(&[rc.to_str().unwrap()]).as_deref(), Some("uk.kbd"));
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn the_last_assignment_wins_and_quoting_is_optional() {
        assert_eq!(last_assignment("keymap", "keymap=us.kbd\nkeymap='de.kbd'\n").as_deref(), Some("de.kbd"));
        assert_eq!(last_assignment("keymap", "  keymap=fr.kbd   # the console too\n").as_deref(), Some("fr.kbd"));
        assert_eq!(last_assignment("keymap", "#keymap=\"uk.kbd\"\nkeymapx=\"uk.kbd\"\n"), None, "a comment, and a longer name, are not the setting");
        // CRLF reads as its lines (to Swift the file is one line).
        assert_eq!(last_assignment("keymap", "keymap=uk.kbd\r\nhostname=x\r\n").as_deref(), Some("uk.kbd"));
    }

    #[test]
    fn rc_conf_local_is_read_after_rc_conf() {
        let d = scratch("local");
        let (rc, local) = (d.join("rc.conf"), d.join("rc.conf.local"));
        fs::write(&rc, "keymap=\"uk.kbd\"\n").unwrap();
        fs::write(&local, "keymap=\"de.kbd\"\n").unwrap();
        assert_eq!(configured(&[rc.to_str().unwrap(), local.to_str().unwrap()]).as_deref(), Some("de.kbd"));
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn no_file_no_setting_and_no_all_mean_none() {
        let d = scratch("none");
        let rc = d.join("rc.conf");
        let rcs = rc.to_str().unwrap();
        assert_eq!(configured(&[d.join("absent").to_str().unwrap()]), None, "Linux has no rc.conf at all");
        fs::write(&rc, "hostname=\"abyss\"\n").unwrap();
        assert_eq!(configured(&[rcs]), None);
        fs::write(&rc, "keymap=\"NO\"\n").unwrap();
        assert_eq!(configured(&[rcs]), None, "NO is /etc/defaults/rc.conf's way of saying none");
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn every_offered_layout_translates_exactly() {
        for k in offered() {
            assert_eq!(xkb(&k.kbdmap), Some((k.clone(), true)), "{}", k.kbdmap);
        }
        assert_eq!(xkb("uk.kbd").unwrap().0.layout, "gb", "XKB calls the United Kingdom gb");
    }

    #[test]
    fn a_hand_written_name_is_guessed_from_its_prefix() {
        assert_eq!(xkb("de.acc.kbd").map(|(k, exact)| (k.layout, exact)), Some(("de".into(), false)));
        assert_eq!(xkb("uk.macbook.kbd").unwrap().0.layout, "gb");
        assert_eq!(xkb("german"), None, "not a kbdmap name at all");
    }

    /// **Every name offered must be a file FreeBSD ships**; only checkable
    /// where the keymaps are.
    #[test]
    fn every_offered_name_is_a_keymap_freebsd_ships() {
        let keymaps = std::path::Path::new("/usr/share/vt/keymaps");
        if !keymaps.is_dir() {
            eprintln!("no {}: FreeBSD only", keymaps.display());
            return;
        }
        for k in offered() {
            assert!(keymaps.join(&k.kbdmap).exists(), "{} is not in {}", k.kbdmap, keymaps.display());
        }
    }

    #[test]
    fn every_offered_layout_has_a_name_and_no_two_share_one() {
        let names: Vec<String> = offered().into_iter().map(|k| k.name).collect();
        assert!(!names.iter().any(String::is_empty));
        let mut unique = names.clone();
        unique.sort();
        unique.dedup();
        assert_eq!(unique.len(), names.len());
        assert_eq!(display_name("us.dvorak.kbd"), "Dvorak");
        assert_eq!(display_name("uk.kbd"), "British");
    }

    #[test]
    fn a_keymap_the_installer_does_not_offer_is_shown_by_its_file() {
        assert_eq!(display_name("de.acc.kbd"), "de.acc.kbd");
    }
}
