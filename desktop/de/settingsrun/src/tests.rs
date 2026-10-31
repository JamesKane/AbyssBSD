//! The runner's and the service's tests, from Tests/SettingsTests: what runs
//! without root on either platform. Where `sysrc` exists (FreeBSD) the
//! writes land; where it does not (Linux) the plan stops at the first and
//! nothing is changed, and each test checks the half its platform shows.

use super::*;
use settings::{EnergyPlan, IPv4, IPv4Config, NetworkPlan, SettingsStep, SoundPlan, WifiAction, WifiPlan};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

struct Scratch(String);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir = std::env::temp_dir().join(format!("abyss-settings-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Scratch(dir.to_string_lossy().into_owned())
    }
    fn file(&self, name: &str, text: Option<&str>) -> String {
        let p = format!("{}/{name}", self.0);
        if let Some(t) = text {
            fs::write(&p, t).unwrap();
        }
        p
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn read(p: &str) -> Option<String> {
    fs::read_to_string(p).ok()
}

fn staged(p: &str) -> bool {
    Path::new(&format!("{p}.abyss-staged")).exists()
}

fn count(events: &[SettingsEvent], f: fn(&SettingsEvent) -> bool) -> usize {
    events.iter().filter(|e| f(e)).count()
}

fn me() -> u32 {
    platform::euid()
}

// MARK: who may change the machine

#[test]
fn an_administrator_is_a_member_of_the_group_and_nobody_else_is() {
    let groups = users::group_names(me());
    let Some(mine) = groups.first() else { panic!("no group for this process") };
    assert!(Authority::is_member(me(), mine), "a user's own group counts");
    assert!(!Authority::is_member(me(), &format!("abyss-no-such-group-{}", std::process::id())));
}

/// **On Linux the helper refuses, and says why** (§6.4): a positive
/// control, not a skip; on FreeBSD it does not.
#[test]
fn the_helper_refuses_a_machine_that_is_not_freebsd() {
    let s = SettingsService::new(Authority::new(me()));
    if cfg!(target_os = "freebsd") {
        assert_eq!(s.platform_refusal(), None);
    } else {
        assert!(s.platform_refusal().is_some_and(|w| w.contains("not FreeBSD")));
    }
}

/// The two locks, over a real socket: the wrong uid, then the right uid not
/// an administrator. Each is told why, and nothing is read from it.
#[test]
fn the_wrong_caller_and_a_non_administrator_are_refused_in_words() {
    let ask = |authority: Authority| {
        let (a, b) = UnixStream::pair().unwrap();
        let s = SettingsService::new(authority);
        let note = s.serve(&a, &mut |_| {});
        let reply = current_ipc::receive(&b).unwrap();
        assert_eq!(reply.bool("ok"), Some(false));
        (note, reply.string("error").unwrap_or("").to_owned())
    };
    let (note, error) = ask(Authority::new(me() + 1));
    assert_eq!(error, format!("refused: uid {} may not use a settings helper started for uid {}", me(), me() + 1));
    assert!(note.starts_with("refused a caller: uid"), "{note}");

    let group = format!("abyss-no-such-group-{}", std::process::id());
    let (_, error) = ask(Authority { allowed: me(), admin_group: group.clone() });
    assert!(error.contains(&format!("is not an administrator (not in {group})")), "{error}");
}

/// Admitted, and asked for something there is no method for.
#[test]
fn an_administrator_asking_for_no_such_method_is_told_so() {
    let group = users::group_names(me()).into_iter().next().unwrap();
    let (a, b) = UnixStream::pair().unwrap();
    let mut m = Msg::new();
    m.set_string("method", "reboot");
    current_ipc::send(&m, &b).unwrap();
    let note = SettingsService::new(Authority { allowed: me(), admin_group: group }).serve(&a, &mut |_| {});
    assert_eq!(note, "unknown method 'reboot'");
    assert_eq!(current_ipc::receive(&b).unwrap().string("error"), Some("no such method: reboot"));
}

// MARK: the runner's promise

/// Dry run: every step reported, nothing written, not even a staged copy.
#[test]
fn a_dry_run_reports_every_step_and_writes_nothing() {
    let dir = Scratch::new("dry");
    let original = "hostname=\"abyss\"\n";
    let rc = dir.file("rc.conf", Some(original));
    let mut events = vec![];
    let steps = settings::compile(&SettingsPlan::Energy(EnergyPlan::new(true))).unwrap();
    assert!(apply_rc_conf(&steps, &rc, true, &mut |e| events.push(e)));
    assert_eq!(count(&events, |e| matches!(e, SettingsEvent::Ok { .. })), 3);
    assert_eq!(read(&rc).as_deref(), Some(original));
    assert!(!staged(&rc));
}

/// The promise: a plan that fails half-way leaves rc.conf exactly as it
/// was, and no staged copy behind. On FreeBSD, a real apply to a scratch
/// file shows the other half: the change lands, all of it.
#[test]
fn rc_conf_is_replaced_whole_or_not_at_all() {
    let dir = Scratch::new("whole");
    let original = "hostname=\"abyss\"\npowerd_flags=\"-a max\"\n";
    let rc = dir.file("rc.conf", Some(original));
    let mut events = vec![];
    let steps = settings::compile(&SettingsPlan::Energy(EnergyPlan::new(false))).unwrap();
    let ok = apply_rc_conf(&steps, &rc, false, &mut |e| events.push(e));
    assert!(!staged(&rc), "a staged copy was left behind");
    if cfg!(target_os = "freebsd") {
        assert!(ok, "{events:?}");
        let now = read(&rc).unwrap_or_default();
        assert!(now.contains("powerd_enable=\"NO\""), "{now}");
        assert!(!now.contains("powerd_flags"), "the policy was not removed: {now}");
        assert!(now.contains("hostname=\"abyss\""), "the rest of rc.conf was not kept: {now}");
    } else {
        // No sysrc here: the first write fails, and the file is untouched.
        assert!(!ok);
        assert_eq!(read(&rc).as_deref(), Some(original), "a failed plan changed rc.conf");
        let Some(SettingsEvent::Finished { ok: false, error }) = events.last() else { panic!("{events:?}") };
        assert!(error.contains("sysrc: not found"), "{error}");
    }
}

/// **The reason for staging.** A plan whose second write fails must leave
/// the first one unwritten too: on FreeBSD the second variable's name is one
/// `sysrc` refuses, after the first write has succeeded in the staged copy.
/// A runner that wrote straight into rc.conf passes the test above and
/// fails this one.
#[test]
fn a_plan_that_fails_half_way_leaves_rc_conf_as_it_was() {
    let dir = Scratch::new("half");
    let original = "hostname=\"abyss\"\n";
    let rc = dir.file("rc.conf", Some(original));
    let mut events = vec![];
    let steps = [SettingsStep::rc_conf("abyss_first", Some("1")), SettingsStep::rc_conf("not a variable", Some("x"))];
    let ok = apply_rc_conf(&steps, &rc, false, &mut |e| events.push(e));
    assert!(!ok, "{events:?}");
    assert_eq!(read(&rc).as_deref(), Some(original), "the first write reached rc.conf though the plan failed");
    assert!(!staged(&rc), "a staged copy was left behind");
    if cfg!(target_os = "freebsd") {
        assert!(events.contains(&SettingsEvent::Ok { index: 0 }), "the first write did succeed, in the staged copy");
    }
}

/// Two files, one promise: both land, or neither.
#[test]
fn two_files_are_staged_and_replaced_together() {
    let dir = Scratch::new("two");
    let (rc_before, rv_before) = ("hostname=\"abyss\"\n", "# resolvconf\n");
    let rc = dir.file("rc.conf", Some(rc_before));
    let rv = dir.file("resolvconf.conf", Some(rv_before));
    let ip = |s: &str| IPv4::parse(s).unwrap();
    let plan = SettingsPlan::Network(NetworkPlan {
        interface: "em0".into(),
        ipv4: IPv4Config::Manual { address: ip("10.0.0.5"), prefix: 24, router: Some(ip("10.0.0.1")) },
        dns: vec![ip("1.1.1.1")],
    });
    let steps = settings::compile(&plan).unwrap();
    let mut events = vec![];
    let path = |f: ConfFile| if f == ConfFile::RcConf { rc.clone() } else { rv.clone() };
    let ok = apply(&steps, &path, &How { write_only: true, ..How::default() }, &mut |e| events.push(e));
    assert!(!staged(&rc) && !staged(&rv));
    if cfg!(target_os = "freebsd") {
        assert!(ok, "{events:?}");
        let (rc_now, rv_now) = (read(&rc).unwrap_or_default(), read(&rv).unwrap_or_default());
        assert!(rc_now.contains("ifconfig_em0=\"inet 10.0.0.5 netmask 255.255.255.0\""), "{rc_now}");
        assert!(rc_now.contains("defaultrouter=\"10.0.0.1\""));
        assert!(rv_now.contains("name_servers=\"1.1.1.1\""), "{rv_now}");
        assert_eq!(
            count(&events, |e| matches!(e, SettingsEvent::Skipped { .. })),
            3,
            "write-only: netif, routing and resolvconf -u are skipped, and said to be"
        );
    } else {
        assert!(!ok);
        assert_eq!(read(&rc).as_deref(), Some(rc_before));
        assert_eq!(read(&rv).as_deref(), Some(rv_before));
    }
}

/// The edit is the helper's own code, not a tool, so it runs for real on
/// both platforms, into a staged copy, and the tool after it is skipped.
#[test]
fn sysctl_conf_is_written_whole_and_the_sysctl_skipped_when_write_only() {
    let dir = Scratch::new("sysctl");
    let sc = dir.file("sysctl.conf", Some("# kernel\nkern.foo=1\n"));
    fs::set_permissions(&sc, fs::Permissions::from_mode(0o600)).unwrap();
    let steps = settings::compile(&SettingsPlan::Sound(SoundPlan { default_unit: 1 })).unwrap();
    let mut events = vec![];
    let ok = apply(&steps, &|_| sc.clone(), &How { write_only: true, ..How::default() }, &mut |e| events.push(e));
    assert!(ok, "{events:?}");
    assert_eq!(read(&sc).as_deref(), Some("# kernel\nkern.foo=1\nhw.snd.default_unit=1\n"));
    assert!(!staged(&sc));
    assert_eq!(fs::metadata(&sc).unwrap().permissions().mode() & 0o777, 0o600, "the file keeps its mode");
    assert_eq!(count(&events, |e| matches!(e, SettingsEvent::Skipped { .. })), 1, "write-only: the sysctl is skipped, and said to be");
}

/// wpa_supplicant.conf is the helper's own edit, like sysctl.conf: real on
/// both platforms, into a staged copy, and a new one is root's alone.
#[test]
fn wpa_supplicant_conf_is_written_whole_and_privately() {
    let dir = Scratch::new("wpa");
    let rc = dir.file("rc.conf", Some("hostname=\"abyss\"\n"));
    let wpa = dir.file("wpa_supplicant.conf", None);
    let psk = settings::key::psk("correct horse battery", "abyss-lab");
    let plan = SettingsPlan::Wifi(WifiPlan::new("wtap1", WifiAction::Join { ssid: "abyss-lab".into(), psk }));
    let steps = settings::compile(&plan).unwrap();
    let mut events = vec![];
    let path = |f: ConfFile| if f == ConfFile::WpaSupplicant { wpa.clone() } else { rc.clone() };
    let ok = apply(&steps, &path, &How { write_only: true, ..How::default() }, &mut |e| events.push(e));
    if cfg!(target_os = "freebsd") {
        assert!(ok, "{events:?}");
        let now = read(&rc).unwrap_or_default();
        assert!(now.contains("wlans_wtap1=\"wlan0\""), "{now}");
    } else {
        assert!(!ok, "sysrc is FreeBSD's; the plan stops at rc.conf");
    }
    match read(&wpa) {
        Some(text) => {
            assert_eq!(settings::wpa::networks(&text), ["abyss-lab"]);
            assert_eq!(fs::metadata(&wpa).unwrap().permissions().mode() & 0o777, 0o600, "a file of network keys is root's alone");
        }
        None => assert!(!cfg!(target_os = "freebsd"), "wpa_supplicant.conf was not written"),
    }
}
