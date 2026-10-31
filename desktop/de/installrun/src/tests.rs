//! The doing half's tests, from Tests/InstallRunTests. The **parsers** are
//! pure functions over text captured from a real FreeBSD machine, not
//! invented; the **runner** is real processes, which is fine anywhere:
//! `echo` and `false` exist everywhere, and a step list of harmless commands
//! takes exactly the code path of one that repartitions a disk. The wire's
//! round trips are `install-wire`'s tests.
//!
//! What is NOT here is an install. That needs a disk, and it is
//! `abyss/tests/live-install.sh`.

use super::probe::*;
use super::*;
use install::{Action, InstallPlan, Step};
use install_wire::RunEvent;
use std::collections::BTreeMap;
use std::path::Path;

/// `geom disk list`: note `descr: (null)` (virtio) and a CD with no media.
const GEOM: &str = r#"Geom name: vtbd0
Providers:
1. Name: vtbd0
   Mediasize: 85899345920 (80G)
   Sectorsize: 512
   Mode: r3w3e7
   descr: (null)
   ident: (null)
   rotationrate: unknown
   fwsectors: 63
   fwheads: 16

Geom name: vtbd1
Providers:
1. Name: vtbd1
   Mediasize: 69632 (68K)
   Sectorsize: 512
   Mode: r0w0e0
   descr: (null)
   ident: (null)

Geom name: cd0
Providers:
1. Name: cd0
   Mediasize: 0 (0B)
   Sectorsize: 2048
   Mode: r0w0e0
"#;

/// `mount -p`: the first column is a *device* for msdosfs and a *dataset*
/// for ZFS, which is the whole reason the pool map is needed.
const MOUNT: &str = r#"zroot/ROOT/default	/			zfs	rw,nfsv4acls 	0 0
devfs			/dev			devfs	rw		0 0
/dev/gpt/efiboot0	/boot/efi		msdosfs	rw		2 2
zroot/home		/home			zfs	rw,nfsv4acls 	0 0
zroot/var/log		/var/log		zfs	rw,noexec,nosuid,nfsv4acls 	0 0"#;

/// `glabel status -s`: without this, `/dev/gpt/efiboot0` cannot be traced
/// to a disk and vtbd0 would look free.
const LABELS: &str = r#"gpt/bootfs  N/A  vtbd0p1
gptid/c1eea66a-cc1b-11f0-067b-ff9d86f8dced  N/A  vtbd0p1
gpt/efiboot0  N/A  vtbd0p2
gpt/swapfs  N/A  vtbd0p3
gpt/config-drive  N/A  vtbd0s4
iso9660/CIDATA  N/A  vtbd1"#;

/// `zpool list -Hv zroot`: the pool's own line first, then its vdevs,
/// distinguished only by a leading tab.
const ZPOOL: &str = r#"zroot	78.5G	12.2G	66.3G	-	-	5%	15%	1.00x	ONLINE	-
	vtbd0p5	79.0G	12.2G	66.3G	-	-	5%	15.5%	-	ONLINE"#;

/// `gpart show`, captured from the bring-up machine on 2026-09-05. Three
/// disks, three shapes: a GPT full of Windows, an **MBR** whose rows carry
/// an extra `[active]`, and a GPT full of FreeBSD.
const GPART: &str = r#"=>        34  1953525101  nda0  GPT  (932G)
          34        2014        - free -  (1.0M)
        2048      204800     1  efi  (100M)
      206848       32768     2  ms-reserved  (16M)
      239616  1951543296     3  ms-basic-data  (931G)
  1951782912     1738752     4  ms-recovery  (849M)
  1953521664        3471        - free -  (1.7M)

=>       63  468862065  ada0  MBR  (224G)
         63       1985        - free -  (993K)
       2048     204800     1  ntfs  [active]  (100M)
     206848  467603877     2  ntfs  (223G)
  467810725       1627        - free -  (814K)
  467812352    1046528     3  !39  (511M)
  468858880       3248        - free -  (1.6M)

=>        40  1953525095  nda1  GPT  (932G)
          40      532480     1  efi  (260M)
      532520        1024     2  freebsd-boot  (512K)
      533544         984        - free -  (492K)
      534528     4194304     3  freebsd-swap  (2.0G)
     4728832  1948794880     4  freebsd-zfs  (929G)
  1953523712        1423        - free -  (712K)"#;

/// `zpool import`, captured in the build VM on a machine carrying three pool
/// shapes at once: a mirror, a single device, and one on a partition.
const ZPOOL_IMPORT: &str = r#"  pool: capmirror
    id: 15841513621478346893
 state: ONLINE
action: The pool can be imported using its name or numeric identifier.
config:

	capmirror   ONLINE
	  mirror-0  ONLINE
	    md0     ONLINE
	    md1     ONLINE

  pool: capsingle
    id: 2816878795490912526
 state: ONLINE
action: The pool can be imported using its name or numeric identifier.
config:

	capsingle   ONLINE
	  md2       ONLINE

  pool: abyssp52
    id: 3911584180507105418
 state: ONLINE
action: The pool can be imported using its name or numeric identifier.
config:

	abyssp52    ONLINE
	  vtbd2p3   ONLINE"#;

/// The scratch disk, captured from the same machine (appended to GEOM): an
/// installed system that nothing has mounted. The live-medium case in
/// miniature.
const SCRATCH_GEOM: &str = r#"
Geom name: vtbd2
Providers:
1. Name: vtbd2
   Mediasize: 12884901888 (12G)
   Sectorsize: 512
   Mode: r0w0e0
   descr: (null)
   ident: (null)
   rotationrate: unknown
   fwsectors: 63
   fwheads: 16
"#;

/// Its labels (appended to LABELS).
const SCRATCH_LABELS: &str = r#"
gpt/abyssp52esp  N/A  vtbd2p1
gpt/abyssp52swap  N/A  vtbd2p2
gpt/abyssp52zfs  N/A  vtbd2p3"#;

fn real_machine() -> DiskInventory {
    let vdevs = BTreeMap::from([("zroot".to_owned(), parse_zpool_vdevs(ZPOOL))]);
    inventory(GEOM, MOUNT, LABELS, &vdevs, &BTreeMap::new(), None, &BTreeMap::new())
}

fn names(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_owned()).collect()
}

// MARK: parsing a real machine

#[test]
fn the_disks_and_their_sizes_come_out_of_geom() {
    let disks = parse_geom_disk_list(GEOM);
    assert_eq!(disks.iter().map(|d| d.name.as_str()).collect::<Vec<_>>(), ["vtbd0", "vtbd1", "cd0"]);
    assert_eq!(disks[0].bytes, 85_899_345_920);
    assert_eq!(disks[2].bytes, 0, "an empty CD drive is a disk of no size");
    // "(null)" is what virtio reports; showing that is worse than nothing.
    assert_eq!(disks[0].descr, "");
}

/// `mount -p` says the root is `zroot/ROOT/default`, a dataset, not a
/// device. Only the pool's vdev list connects that to vtbd0, and getting it
/// wrong means offering the user the disk they are running from.
#[test]
fn a_zfs_root_is_traced_to_its_disk_through_the_pool() {
    let inv = real_machine();
    let vtbd0 = inv.disk("vtbd0").unwrap();
    assert!(vtbd0.holds_running_root);
    assert!(vtbd0.mounted_at.contains(&"/".to_owned()));
    assert!(vtbd0.mounted_at.contains(&"/home".to_owned()));
}

/// /dev/gpt/efiboot0 names no disk at all. Without glabel it resolves to
/// nothing and the disk holding /boot/efi looks free.
#[test]
fn a_gpt_label_mount_is_traced_to_its_disk() {
    let disks = names(&["vtbd0", "vtbd1", "cd0"]);
    assert_eq!(disk_of("/dev/gpt/efiboot0", &parse_label_components(LABELS), &disks).as_deref(), Some("vtbd0"));
    assert!(real_machine().disk("vtbd0").unwrap().mounted_at.contains(&"/boot/efi".to_owned()));
}

#[test]
fn the_other_disks_are_left_alone() {
    let inv = real_machine();
    // vtbd1 is the cloud-init seed: iso9660-labelled but not mounted.
    assert!(inv.disk("vtbd1").unwrap().mounted_at.is_empty());
    assert!(!inv.disk("vtbd1").unwrap().holds_running_root);
    assert!(inv.disk("cd0").unwrap().mounted_at.is_empty());
    assert_eq!(inv.imported_pools, ["zroot"]);
}

/// `ada1` must not swallow `ada10p1`, which a naive prefix match does, and
/// then somebody is told the wrong disk is busy.
#[test]
fn a_longer_disk_name_is_not_claimed_by_a_shorter_one() {
    let disks = names(&["ada1", "ada10"]);
    assert_eq!(disk_of("ada10p1", &BTreeMap::new(), &disks).as_deref(), Some("ada10"));
    assert_eq!(disk_of("ada1p1", &BTreeMap::new(), &disks).as_deref(), Some("ada1"));
}

#[test]
fn a_vdev_kind_is_not_a_device() {
    // A mirrored pool lists `mirror-0` as a parent of the real providers.
    let text = "tank\t1T\t-\t-\t-\n\tmirror-0\t1T\t-\n\t\tada0p3\t1T\t-\n\t\tada1p3\t1T\t-";
    assert_eq!(parse_zpool_vdevs(text), ["ada0p3", "ada1p3"]);
}

// MARK: what is on a disk, and where it is not

#[test]
fn gpart_show_is_parsed_into_contents_and_gaps() {
    let l = parse_gpart_show(GPART);
    assert_eq!(l["nda0"].scheme, "GPT");
    assert_eq!(l["nda0"].kinds, ["efi", "ms-reserved", "ms-basic-data", "ms-recovery"]);
    assert_eq!(l["nda1"].kinds, ["efi", "freebsd-boot", "freebsd-swap", "freebsd-zfs"]);
    assert_eq!(l.keys().collect::<Vec<_>>(), ["ada0", "nda0", "nda1"]);
}

/// `2048  204800  1  ntfs  [active]  (100M)`: a parse that took a fixed
/// column would report the boot partition's type as "[active]".
#[test]
fn an_mbr_rows_extra_active_flag_is_not_read_as_a_partition_type() {
    let l = parse_gpart_show(GPART);
    assert_eq!(l["ada0"].scheme, "MBR");
    assert_eq!(l["ada0"].kinds, ["ntfs", "ntfs", "!39"]);
}

/// An install needs room in one piece. nda0's gaps are 2014 and 3471
/// sectors; the answer is 3471, not 5485.
#[test]
fn the_largest_gap_is_contiguous_and_not_a_total() {
    let l = parse_gpart_show(GPART);
    assert_eq!(l["nda0"].largest_free_sectors(), 3471);
    assert_eq!(l["nda1"].largest_free_sectors(), 1423);
}

/// Three disks, ~2 TB between them, and the largest contiguous gap
/// anywhere is 1.7 MiB: not one can take an install without destroying
/// something, and the installer says so.
#[test]
fn every_disk_on_the_bring_up_machine_is_full() {
    let l = parse_gpart_show(GPART);
    for d in ["nda0", "nda1", "ada0"] {
        let bytes = l[d].largest_free_sectors() * 512;
        assert!(bytes < 4 << 20, "{d} has {bytes} bytes free");
    }
}

#[test]
fn a_disk_with_no_table_parses_as_nothing_rather_than_failing() {
    assert!(parse_gpart_show("").is_empty());
    assert!(parse_gpart_show("gpart: No such geom: ada9.").is_empty());
}

#[test]
fn sector_size_comes_from_the_disk_and_not_from_an_assumption() {
    let text = "Geom name: nda0\nProviders:\n1. Name: nda0\n   Mediasize: 1000204886016 (932G)\n   Sectorsize: 4096\n   descr: WD_BLACK SN850X 1000GB\n";
    let d = &parse_geom_disk_list(text)[0];
    assert_eq!(d.sector_bytes, 4096);
    assert_eq!(d.descr, "WD_BLACK SN850X 1000GB");
    // And the inventory counts gpart's sectors in it: 10 sectors of 4 KiB.
    let layouts = BTreeMap::from([("nda0".to_owned(), DiskLayout { scheme: "GPT".into(), kinds: vec![], free_sectors: vec![10] })]);
    let inv = inventory(text, "", "", &BTreeMap::new(), &BTreeMap::new(), None, &layouts);
    assert_eq!(inv.disk("nda0").unwrap().free_bytes, 40960);
}

// MARK: pools that are here but not imported

#[test]
fn importable_pools_are_parsed_into_their_devices() {
    let got = parse_importable_pools(ZPOOL_IMPORT);
    assert_eq!(got["capmirror"], ["md0", "md1"], "a mirror's two leaves are both real devices");
    assert_eq!(got["capsingle"], ["md2"]);
    assert_eq!(got["abyssp52"], ["vtbd2p3"]);
    assert_eq!(got.keys().collect::<Vec<_>>(), ["abyssp52", "capmirror", "capsingle"]);
}

/// `mirror-0` is a structural row of the config tree; taken for a device,
/// it attributes the pool to a disk that does not exist.
#[test]
fn the_vdev_kind_row_is_not_mistaken_for_a_device() {
    assert!(!parse_importable_pools(ZPOOL_IMPORT)["capmirror"].contains(&"mirror-0".to_owned()));
    for kind in ["mirror-0", "raidz2-1", "logs", "draid2:4d:1c:0s-0"] {
        assert!(is_vdev_type_node(kind), "{kind}");
    }
    // ...and a real device whose name merely starts the same way is not one.
    for dev in ["mirrordisk0", "da0", "vtbd2p3"] {
        assert!(!is_vdev_type_node(dev), "{dev}");
    }
}

/// "No pools" is the answer that lets an install proceed, so it has to be
/// reachable, and distinguishable from a parse that went wrong.
#[test]
fn a_scan_that_found_nothing_parses_as_nothing() {
    assert!(parse_importable_pools("").is_empty());
    assert!(parse_importable_pools("no pools available to import").is_empty());
}

/// The live-medium case, end to end: the target disk carries somebody's
/// whole installed system, and NOTHING else in the inventory says so.
#[test]
fn an_unimported_pool_is_attributed_to_its_disk() {
    let vdevs = BTreeMap::from([("zroot".to_owned(), parse_zpool_vdevs(ZPOOL))]);
    let geom = format!("{GEOM}{SCRATCH_GEOM}");
    let labels = format!("{LABELS}{SCRATCH_LABELS}");
    let inv = inventory(&geom, MOUNT, &labels, &vdevs, &parse_importable_pools(ZPOOL_IMPORT), None, &BTreeMap::new());
    let target = inv.disk("vtbd2").unwrap();
    assert_eq!(target.existing_pools, ["abyssp52"], "vtbd2p3 belongs to vtbd2");
    assert!(target.mounted_at.is_empty(), "and it is not mounted,");
    assert!(!target.holds_running_root, "nor is it the running root.");
    assert!(!inv.imported_pools.contains(&"abyssp52".to_owned()), "scanning must not make it look imported");
}

/// A kernel with no ZFS has no imported pools, and `zpool` is not asked,
/// because asking makes it try to load the module, which a non-root caller
/// cannot (the Q8B, 2026-10-01). With ZFS present, a failing `zpool list`
/// still fails the probe.
#[test]
fn no_zfs_means_no_pools_and_a_failing_zpool_still_fails() {
    let mut asked = false;
    assert_eq!(imported_pool_names(false, || { asked = true; Ok("zroot\n".into()) }), Ok(vec![]));
    assert!(!asked, "zpool must not be run where there is no ZFS");
    assert_eq!(imported_pool_names(true, || Ok("zroot\nbackup\n".into())), Ok(names(&["zroot", "backup"])));
    let failed = imported_pool_names(true, || Err(ProbeError::CommandFailed("zpool list -H -o name".into(), "internal error".into())));
    assert!(failed.is_err());
}

/// Not a skip. An installer whose disk discovery quietly does nothing on the
/// machine you develop on is one that ships broken.
#[test]
fn the_probe_refuses_loudly_where_it_cannot_work() {
    if cfg!(target_os = "linux") {
        let Err(ProbeError::NotSupported(why)) = probe_machine() else { panic!("expected NotSupported") };
        assert!(why.contains("Linux") && why.contains("geom"), "{why}");
    } else if cfg!(target_os = "freebsd") {
        // On the target it must actually work, and find the disk it booted from.
        let inv = probe_machine().unwrap();
        assert!(!inv.disks.is_empty(), "no disks found on a running FreeBSD");
        assert!(inv.disks.iter().any(|d| d.holds_running_root), "nothing claims to hold the running root");
    }
}

// MARK: who may command an installer

fn me() -> u32 {
    abyss_sys::platform::euid()
}

#[test]
fn the_kernel_is_asked_who_is_calling() {
    let (a, _b) = UnixStream::pair().unwrap();
    assert_eq!(abyss_sys::platform::peer_uid(a.as_fd()).unwrap(), me());
    assert!(Authority::new(me()).admits(&a).is_ok());
    assert!(Authority::own().admits(&a).is_ok());
}

#[test]
fn another_user_is_refused_and_told_why() {
    let (a, _b) = UnixStream::pair().unwrap();
    let why = Authority::new(me().wrapping_add(1)).admits(&a).unwrap_err();
    assert!(why.contains(&me().to_string()), "{why}");
}

/// A descriptor the kernel cannot name a peer for (here, a regular file
/// where a socket should be) is refused. Failing *open* would be worse than
/// having no check at all, because it would look like one.
#[test]
fn a_mechanism_that_cannot_identify_the_caller_says_no() {
    let path = std::env::temp_dir().join(format!("installrun-not-a-socket-{}", std::process::id()));
    let file = std::fs::File::create(&path).unwrap();
    let _ = std::fs::remove_file(&path);
    let not_a_socket = UnixStream::from(std::os::fd::OwnedFd::from(file));
    assert!(abyss_sys::platform::peer_uid(not_a_socket.as_fd()).is_err());
    let why = Authority::new(me()).admits(&not_a_socket).unwrap_err();
    assert_eq!(why, "the kernel would not identify the caller");
}

/// The inventory of a real machine, not a hand-made one, crosses the wire.
#[test]
fn the_machine_survives_the_wire() {
    let inv = real_machine();
    let mut m = Msg::new();
    install_wire::encode_inventory(&inv, &mut m);
    assert_eq!(install_wire::decode_inventory(&Msg::unpack(&m.pack(), vec![]).unwrap()), inv);
}

/// There is no method on an installer that a caller who may not command it
/// should get to attempt, so the check is at the connection, not per method.
#[test]
fn an_unauthorised_caller_is_refused_before_its_request_is_even_read() {
    let (a, b) = UnixStream::pair().unwrap();
    let service = InstallService::with_machine(Authority::new(me().wrapping_add(1)), true, Box::new(|| Ok(real_machine())));
    let mut request = Msg::new();
    request.set_string("method", "install");
    install_wire::encode_plan(&InstallPlan::new("vtbd1"), &mut request);
    current_ipc::send(&request, &b).unwrap();
    let note = service.serve(&a, &mut |_| {});
    assert!(note.starts_with("refused a caller"), "{note}");
    assert_eq!(service.installs_run(), 0, "an install was started for a refused caller");
    let reply = current_ipc::receive(&b).unwrap();
    assert_eq!(reply.bool("ok"), Some(false));
    assert!(reply.string("error").unwrap_or("").contains("may not command"), "{reply:?}");
}

#[test]
fn check_refuses_the_disk_you_are_running_from_over_the_wire() {
    let (a, b) = UnixStream::pair().unwrap();
    let service = InstallService::with_machine(Authority::new(me()), true, Box::new(|| Ok(real_machine())));
    let mut request = Msg::new();
    request.set_string("method", "check");
    let mut plan = InstallPlan::new("vtbd0");
    plan.root_password_hash = "$6$x".into();
    install_wire::encode_plan(&plan, &mut request);
    current_ipc::send(&request, &b).unwrap();
    service.serve(&a, &mut |_| {});
    let reply = current_ipc::receive(&b).unwrap();
    assert_eq!(reply.bool("ok"), Some(false));
    assert_eq!(reply.u64("problems.count"), Some(1));
    assert!(reply.string("problem.0").unwrap_or("").contains("running from"), "{:?}", reply.string("problem.0"));
    assert_eq!(reply.string("render"), None, "a refused plan must not come with a step list");
}

/// The probe's refusal reaches the caller in its words, for `disks` and
/// for `check` alike.
#[test]
fn a_machine_that_cannot_be_probed_is_said_so_to_the_caller() {
    let refuse = || Box::new(|| Err(ProbeError::NotSupported("no geom here".into()))) as Machine;
    for method in ["disks", "check"] {
        let (a, b) = UnixStream::pair().unwrap();
        let mut request = Msg::new();
        request.set_string("method", method);
        current_ipc::send(&request, &b).unwrap();
        InstallService::with_machine(Authority::new(me()), true, refuse()).serve(&a, &mut |_| {});
        let reply = current_ipc::receive(&b).unwrap();
        assert_eq!((reply.bool("ok"), reply.string("error")), (Some(false), Some("no geom here")), "{method}");
    }
}

// MARK: running steps

fn run(argv: &[&str], what: &str, on_failure: &str) -> Step {
    Step {
        action: Action::Run { argv: names(argv), stdin: None },
        what: what.into(),
        on_failure: on_failure.into(),
        destructive: false,
        may_fail: false,
    }
}

fn with_stdin(mut s: Step, input: &str) -> Step {
    if let Action::Run { stdin, .. } = &mut s.action {
        *stdin = Some(input.into());
    }
    s
}

fn may_fail(mut s: Step) -> Step {
    s.may_fail = true;
    s
}

fn write(path: &str, contents: &str, what: &str, on_failure: &str) -> Step {
    Step { action: Action::Write { path: path.into(), contents: contents.into(), mode: 0o644 }, ..run(&[], what, on_failure) }
}

fn events_of(steps: &[Step], dry_run: bool) -> (Option<String>, Vec<RunEvent>) {
    let mut events = vec![];
    let failure = execute(steps, dry_run, &mut |e| events.push(e));
    (failure, events)
}

#[test]
fn the_steps_run_in_order_and_every_one_is_reported() {
    let steps = [run(&["echo", "one"], "the first", "no"), run(&["echo", "two"], "the second", "no")];
    let (failure, events) = events_of(&steps, false);
    assert_eq!(failure, None);
    assert_eq!(
        events,
        [
            RunEvent::Starting { index: 0, total: 2, what: "the first".into(), destructive: false },
            RunEvent::Ok { index: 0 },
            RunEvent::Starting { index: 1, total: 2, what: "the second".into(), destructive: false },
            RunEvent::Ok { index: 1 },
            RunEvent::Finished { ok: true, error: String::new() },
        ]
    );
}

/// An installer that carries on past a failed `gpart add` finishes with a
/// confident summary and a machine that will not boot.
#[test]
fn it_stops_at_the_first_real_failure() {
    let steps = [
        run(&["false"], "the one that fails", "the partition could not be created"),
        run(&["echo", "should not happen"], "the one after", "no"),
    ];
    let (failure, events) = events_of(&steps, false);
    let failure = failure.unwrap();
    assert!(failure.contains("the partition could not be created"), "{failure}");
    assert!(!events.iter().any(|e| matches!(e, RunEvent::Starting { index: 1, .. })), "it kept going after a failure");
}

/// `gpart destroy` on a disk with no table is a success for our purposes,
/// and the plan is what says so.
#[test]
fn a_step_the_plan_allowed_to_fail_does_not_stop_the_install() {
    let steps = [may_fail(run(&["false"], "clear the old table", "no")), run(&["echo", "carried on"], "the one after", "no")];
    let (failure, events) = events_of(&steps, false);
    assert_eq!(failure, None);
    assert!(events.iter().any(|e| matches!(e, RunEvent::Failed { ignored: true, .. })));
    assert!(events.contains(&RunEvent::Ok { index: 1 }));
}

/// The plan's sentence, with the kernel's underneath it. A failure reported
/// as "exited 1" is one nobody can act on.
#[test]
fn what_a_command_said_is_what_the_user_is_told() {
    let steps = [run(&["sh", "-c", "echo 'Device busy' >&2; exit 1"], "add swap", "the swap partition failed")];
    let failure = events_of(&steps, false).0.unwrap();
    assert!(failure.contains("the swap partition failed") && failure.contains("Device busy"), "{failure}");
}

#[test]
fn a_command_that_does_not_exist_fails_like_any_other() {
    let failure = events_of(&[run(&["abyss-no-such-command-anywhere"], "run nothing", "it is not there")], false).0.unwrap();
    assert!(failure.contains("it is not there"), "{failure}");
}

/// How a password hash gets to `pw` without every process on the machine
/// reading it out of `ps`.
#[test]
fn stdin_reaches_the_command_and_stays_out_of_argv() {
    let check = ["sh", "-c", "read line; test \"$line\" = secret"];
    assert_eq!(events_of(&[with_stdin(run(&check, "feed a secret", "the hash did not arrive"), "secret")], false).0, None);
    // ...and without it the same command fails, so the test is not passing
    // for some other reason.
    assert!(events_of(&[run(&check, "feed nothing", "no hash")], false).0.is_some());
}

/// A command that decides to ask a question would otherwise hang the
/// install for ever with nothing on screen to say why.
#[test]
fn a_step_never_inherits_the_installers_own_stdin() {
    let steps = [may_fail(run(&["sh", "-c", "read line; echo \"$line\""], "try to ask", "it read something"))];
    let events = events_of(&steps, false).1;
    assert!(events.contains(&RunEvent::Finished { ok: true, error: String::new() }), "a command that reads stdin did not get EOF");
}

fn scratch(name: &str) -> String {
    let dir = std::env::temp_dir().join(format!("abyss-installrun-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.to_string_lossy().into_owned()
}

#[test]
fn a_file_step_writes_the_content_and_the_mode() {
    use std::os::unix::fs::PermissionsExt;
    let dir = scratch("write");
    let path = format!("{dir}/loader.conf");
    // A file already there with another mode gets the plan's.
    std::fs::write(&path, "old").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(events_of(&[write(&path, "zfs_load=\"YES\"\n", "write loader.conf", "could not write it")], false).0, None);
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o644, "the mode the plan asked for was not applied");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "zfs_load=\"YES\"\n");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The plan makes its directories explicitly. A runner that quietly
/// `mkdir -p`s would hide a step list that forgot to.
#[test]
fn writing_where_there_is_no_directory_fails_rather_than_inventing_one() {
    let path = format!("/tmp/abyss-no-such-dir-{}/x", std::process::id());
    let failure = events_of(&[write(&path, "x", "write into nowhere", "the directory is missing")], false).0.unwrap();
    assert!(failure.contains("the directory is missing"), "{failure}");
}

/// Same events, no side effects: what lets a caller be developed, and its
/// confirmations exercised, against a machine it is not touching.
#[test]
fn a_dry_run_reports_everything_and_does_nothing() {
    let dir = scratch("dry");
    let witness = format!("{dir}/trace");
    let mut touch = run(&["sh", "-c", &format!("touch {witness}")], "leave a trace", "no");
    touch.destructive = true;
    let steps = [touch, write(&format!("{witness}.2"), "x", "write a file", "no")];
    let (failure, dry) = events_of(&steps, true);
    assert_eq!(failure, None);
    assert!(!Path::new(&witness).exists(), "a dry run touched the disk");
    assert!(!Path::new(&format!("{witness}.2")).exists(), "a dry run wrote a file");
    let (failure, wet) = events_of(&steps, false);
    assert_eq!(failure, None);
    assert!(Path::new(&witness).exists(), "the control did not run either");
    assert_eq!(dry, wet, "a dry run must be indistinguishable from the outside");
    let _ = std::fs::remove_dir_all(&dir);
}
