//! SettingsTests.swift and AccountsPlanTests.swift, ported: the plans, their
//! refusals and steps, the files the helper edits itself, and the key. (The
//! wire's tests are settings-wire's; the runner's are settingsrun's, R3.)

use super::*;

fn ip(s: &str) -> IPv4 {
    IPv4::parse(s).unwrap()
}

fn rc(key: &str, value: Option<&str>) -> SettingsStep {
    SettingsStep::rc_conf(key, value)
}

fn values(kv: &[(&str, &str)]) -> HashMap<String, String> {
    kv.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

fn why(plan: SettingsPlan) -> Vec<String> {
    problems(&plan).into_iter().map(|r| r.message).collect()
}

// MARK: plans compile to exact steps

#[test]
fn powerd_on_compiles_to_its_variables_and_a_restart() {
    let plan = EnergyPlan { powerd: true, on_ac: PowerdMode::Maximum, on_battery: PowerdMode::Adaptive, modes_from_profile: false };
    let steps = compile(&SettingsPlan::Energy(plan)).unwrap();
    assert_eq!(
        steps,
        [rc("powerd_enable", Some("YES")), rc("powerd_flags", Some("-a max -b adaptive")), SettingsStep::service("powerd", &["onerestart"], false)]
    );
    assert_eq!(steps[1].command_rc_conf("/etc/rc.conf"), ["sysrc", "-f", "/etc/rc.conf", "powerd_flags=-a max -b adaptive"]);
}

/// Off: stopping what may not be running is allowed to fail, and the policy
/// is removed rather than left behind for the next person to find.
#[test]
fn powerd_off_removes_its_policy_and_may_fail_to_stop() {
    let steps = compile(&SettingsPlan::Energy(EnergyPlan::new(false))).unwrap();
    assert_eq!(steps, [rc("powerd_enable", Some("NO")), rc("powerd_flags", None), SettingsStep::service("powerd", &["onestop"], true)]);
    assert_eq!(steps[1].command_rc_conf("/x"), ["sysrc", "-f", "/x", "-x", "powerd_flags"]);
    assert!(render_etc(&steps).contains("$ sysrc -f /etc/rc.conf powerd_enable=NO"));
}

#[test]
fn the_machines_powerd_is_read_back_as_a_plan() {
    assert_eq!(
        EnergyPlan::from(Some("YES"), Some("-a max -b min")),
        EnergyPlan { powerd: true, on_ac: PowerdMode::Maximum, on_battery: PowerdMode::Minimum, modes_from_profile: false }
    );
    assert_eq!(EnergyPlan::from(Some("NO"), Some("")), EnergyPlan::new(false));
    assert_eq!(EnergyPlan::from(None, None), EnergyPlan::new(false), "unset is FreeBSD's default: off");
    assert_eq!(EnergyPlan::from(Some("yes"), None), EnergyPlan::new(true));
    assert_eq!(EnergyPlan::from(Some("YES"), Some("-a turbo -i 50")), EnergyPlan::new(true), "flags it does not understand are not guessed at");
}

/// The profile, powerd's own flags cleared so the profile chooses its mode,
/// then applied as boot would.
#[test]
fn a_power_profile_compiles_to_its_variable_cleared_flags_and_a_start() {
    assert_eq!(
        compile(&SettingsPlan::PowerProfile(PowerProfile::PowerSaver)).unwrap(),
        [rc("power_profile", Some("power-saver")), rc("powerd_flags", None), SettingsStep::service("power_profile", &["start"], false)]
    );
}

/// powerd turned on under a profile runs with no flags, so the profile
/// keeps choosing its mode; the per-source modes are not written.
#[test]
fn powerd_under_a_profile_runs_with_no_flags() {
    let plan = EnergyPlan { on_ac: PowerdMode::Maximum, modes_from_profile: true, ..EnergyPlan::new(true) };
    assert_eq!(compile(&SettingsPlan::Energy(plan)).unwrap()[1], rc("powerd_flags", None));
}

/// Read back through `sysrc -n`, which answers from the defaults: a profile
/// is a plan; no variable at all is upstream FreeBSD, and is said in words.
#[test]
fn a_power_profile_is_read_back_or_the_base_is_said_to_lack_them() {
    assert_eq!(
        current("power-profile", "", &values(&[("power_profile", "performance")])),
        Some(SettingsPlan::PowerProfile(PowerProfile::Performance))
    );
    assert_eq!(unavailable("power-profile", &values(&[("power_profile", "balanced")])), None);
    assert_eq!(current("power-profile", "", &values(&[])), None);
    assert_eq!(
        unavailable("power-profile", &values(&[])).as_deref(),
        Some("this FreeBSD offers no power profiles — its rc.d/power_profile is the older AC-line script")
    );
    assert_eq!(
        unavailable("power-profile", &values(&[("power_profile", "NONE")])).as_deref(),
        Some("power profiles are turned off on this machine (power_profile=NONE)")
    );
    assert_eq!(
        unavailable("power-profile", &values(&[("power_profile", "turbo")])).as_deref(),
        Some("power_profile is \"turbo\", which is not a profile this pane knows")
    );
    assert_eq!(unavailable("energy", &values(&[])), None);
    let k: Vec<String> = keys("power-profile", "").unwrap().into_iter().map(|(_, k)| k).collect();
    assert_eq!(k, ["power_profile"]);
}

// MARK: network (P14.4)

#[test]
fn an_ipv4_address_is_parsed_strictly() {
    assert_eq!(ip("192.168.1.10").to_string(), "192.168.1.10");
    for bad in ["192.168.1", "192.168.1.256", "192.168.01.1", "1.2.3.4.5", "a.b.c.d", "", " 1.2.3.4", "1.2.3.+4", "١.2.3.4"] {
        assert_eq!(IPv4::parse(bad), None, "{bad}");
    }
    assert_eq!(ip("255.255.255.0").prefix_length(), Some(24));
    assert_eq!(ip("255.255.254.0").prefix_length(), Some(23));
    assert_eq!(ip("0.0.0.0").prefix_length(), Some(0));
    assert_eq!(ip("255.255.255.255").prefix_length(), Some(32));
    assert_eq!(ip("255.0.255.0").prefix_length(), None, "not contiguous: not a mask");
    assert_eq!(IPv4::mask(20).to_string(), "255.255.240.0");
}

#[test]
fn a_manual_address_compiles_to_ifconfig_router_name_servers_and_a_restart() {
    let plan = NetworkPlan {
        interface: "em0".into(),
        ipv4: IPv4Config::Manual { address: ip("10.0.0.5"), prefix: 24, router: Some(ip("10.0.0.1")) },
        dns: vec![ip("1.1.1.1"), ip("9.9.9.9")],
    };
    assert_eq!(
        compile(&SettingsPlan::Network(plan)).unwrap(),
        [
            rc("ifconfig_em0", Some("inet 10.0.0.5 netmask 255.255.255.0")),
            rc("defaultrouter", Some("10.0.0.1")),
            SettingsStep::set_var(ConfFile::Resolvconf, "name_servers", Some("1.1.1.1 9.9.9.9")),
            SettingsStep::service("netif", &["restart", "em0"], false),
            SettingsStep::service("routing", &["restart"], false),
            SettingsStep::tool(&["resolvconf", "-u"], false),
        ]
    );
}

#[test]
fn dhcp_drops_the_router_and_the_name_servers_a_person_set() {
    let steps = compile(&SettingsPlan::Network(NetworkPlan { interface: "igc0".into(), ipv4: IPv4Config::Dhcp, dns: vec![] })).unwrap();
    assert_eq!(
        steps[..3],
        [rc("ifconfig_igc0", Some("SYNCDHCP")), rc("defaultrouter", None), SettingsStep::set_var(ConfFile::Resolvconf, "name_servers", None)]
    );
    assert_eq!(steps[2].command(&|f| format!("/x/{}", f.name())), ["sysrc", "-f", "/x/resolvconf.conf", "-x", "name_servers"]);
}

/// Each refusal, by its words: a pane shows them as they are.
#[test]
fn a_network_plan_is_refused_in_words() {
    let dhcp = |i: &str, dns: &[&str]| SettingsPlan::Network(NetworkPlan {
        interface: i.into(),
        ipv4: IPv4Config::Dhcp,
        dns: dns.iter().map(|d| ip(d)).collect(),
    });
    let manual = |a: &str, p: u32, r: Option<&str>| SettingsPlan::Network(NetworkPlan {
        interface: "em0".into(),
        ipv4: IPv4Config::Manual { address: ip(a), prefix: p, router: r.map(ip) },
        dns: vec![],
    });
    assert_eq!(why(dhcp("lo0", &[])), ["lo0 is not a wired interface's name"]);
    assert_eq!(why(dhcp("em", &[])), ["em is not a wired interface's name"]);
    assert_eq!(why(dhcp("", &[])), ["no interface is not a wired interface's name"]);
    assert_eq!(why(dhcp("Em0", &[])), ["Em0 is not a wired interface's name"]);
    assert_eq!(why(manual("10.0.0.0", 24, None)), ["10.0.0.0 is the network's own address, not a host's"]);
    assert_eq!(why(manual("10.0.0.255", 24, None)), ["10.0.0.255 is the network's broadcast address"]);
    assert_eq!(
        why(manual("10.0.0.5", 24, Some("10.0.1.1"))),
        ["the router 10.0.1.1 is not on 10.0.0.5's network (/24) — it could not be reached"]
    );
    assert_eq!(why(manual("10.0.0.5", 24, Some("10.0.0.5"))), ["the router cannot be this machine's own address"]);
    assert_eq!(why(manual("127.0.0.5", 24, None)), ["127.0.0.5 cannot be an interface's address"]);
    assert_eq!(why(manual("10.0.0.5", 31, None)), ["a /31 network is not one a wired interface is given (8 to 30)"]);
    assert_eq!(
        why(dhcp("em0", &["1.1.1.1", "1.0.0.1", "8.8.8.8", "9.9.9.9"])),
        ["4 name servers: the resolver uses three at most"]
    );
    assert_eq!(why(dhcp("em0", &["0.0.0.0", "224.0.0.1"])), ["0.0.0.0 cannot be a name server", "224.0.0.1 cannot be a name server"]);
    assert!(why(manual("10.0.0.5", 24, Some("10.0.0.1"))).is_empty());
}

#[test]
fn the_machines_network_is_read_back_as_a_plan() {
    let plan = |ipv4, dns: Vec<IPv4>| Some(NetworkPlan { interface: "em0".into(), ipv4, dns });
    assert_eq!(NetworkPlan::from("em0", Some("SYNCDHCP"), Some("NO"), None), plan(IPv4Config::Dhcp, vec![]));
    assert_eq!(
        NetworkPlan::from("em0", None, None, Some("1.1.1.1")),
        plan(IPv4Config::Dhcp, vec![ip("1.1.1.1")]),
        "an interface rc.conf does not name is on ifconfig_DEFAULT's DHCP"
    );
    assert_eq!(
        NetworkPlan::from("em0", Some("inet 10.0.0.5 netmask 255.255.255.0"), Some("10.0.0.1"), Some("")),
        plan(IPv4Config::Manual { address: ip("10.0.0.5"), prefix: 24, router: Some(ip("10.0.0.1")) }, vec![])
    );
    assert_eq!(NetworkPlan::from("em0", Some("inet6 fe80::1 prefixlen 64"), None, None), None, "a line this cannot show is not guessed at");
}

// MARK: sound (P14.6b)

#[test]
fn the_default_device_compiles_to_sysctl_conf_then_sysctl() {
    let steps = compile(&SettingsPlan::Sound(SoundPlan { default_unit: 1 })).unwrap();
    assert_eq!(
        steps,
        [
            SettingsStep::set_var(ConfFile::SysctlConf, "hw.snd.default_unit", Some("1")),
            SettingsStep::tool(&["sysctl", "hw.snd.default_unit=1"], false),
        ]
    );
    assert!(steps[0].command(&|f| f.etc_path()).is_empty(), "sysrc cannot edit sysctl.conf; no command pretends to");
    let r = render_etc(&steps);
    assert!(r.contains("set hw.snd.default_unit=\"1\" in sysctl.conf\n   (the helper edits the file itself)"), "{r}");
    assert!(r.contains("$ sysctl hw.snd.default_unit=1"), "{r}");
    assert_eq!(
        compile(&SettingsPlan::Sound(SoundPlan { default_unit: -1 })),
        Err(SettingsRefusal::new("pcm-1 is not a sound device's unit"))
    );
}

#[test]
fn sysctl_conf_is_edited_line_by_line() {
    let conf = "# kernel settings\nsecurity.bsd.see_other_uids=0\n hw.snd.default_unit = 0  # the card\nkern.foo=1\nhw.snd.default_unit=3\n";
    let key = "hw.snd.default_unit";
    let set = edit_sysctl_conf(conf, key, Some("1"));
    assert_eq!(
        set, "# kernel settings\nsecurity.bsd.see_other_uids=0\nhw.snd.default_unit=1\nkern.foo=1\n",
        "the first assignment replaced in place, the later one (which would win) dropped, the rest kept"
    );
    assert_eq!(sysctl_conf_value(conf, key).as_deref(), Some("3"), "the last one wins, as in sysctl(8)");
    assert_eq!(sysctl_conf_value(" hw.snd.default_unit = 0  # the card\n", key).as_deref(), Some("0"));
    assert_eq!(sysctl_conf_value(&set, key).as_deref(), Some("1"));
    assert_eq!(edit_sysctl_conf("#x\n", key, Some("2")), "#x\nhw.snd.default_unit=2\n");
    assert_eq!(edit_sysctl_conf("", "a.b", Some("2")), "a.b=2\n");
    assert_eq!(edit_sysctl_conf(&set, key, None), "# kernel settings\nsecurity.bsd.see_other_uids=0\nkern.foo=1\n");
    assert_eq!(
        edit_sysctl_conf("#hw.snd.default_unit=5\n", key, Some("1")),
        "#hw.snd.default_unit=5\nhw.snd.default_unit=1\n",
        "a comment is not an assignment"
    );
    assert_eq!(sysctl_conf_value("#hw.snd.default_unit=5\n", key), None);
    assert_eq!(edit_file(ConfFile::SysctlConf, "", "a.b", Some("2")), "a.b=2\n");
}

#[test]
fn the_default_device_is_read_back() {
    let k: Vec<String> = keys("sound", "").unwrap().into_iter().map(|(_, k)| k).collect();
    assert_eq!(k, ["hw.snd.default_unit"]);
    assert_eq!(current("sound", "", &values(&[("hw.snd.default_unit", "2")])), Some(SettingsPlan::Sound(SoundPlan { default_unit: 2 })));
    assert_eq!(current("sound", "", &values(&[])), None);
    assert_eq!(keys("network", "lo0"), None, "not a wired interface: nothing to read");
}

// MARK: Wi-Fi keys (P14.5)

#[test]
fn sha1_and_hmac_are_the_standard_ones() {
    assert_eq!(key::hex(&key::sha1(b"abc")), "a9993e364706816aba3e25717850c26c9cd0d89d");
    assert_eq!(key::hex(&key::sha1(b"")), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    assert_eq!(key::hex(&key::sha1(&[b'a'; 1000])), "291e9a6c66994949b57ba5e650361e98fc36b1ba", "more than one block");
    // RFC 2202, test cases 2 and 6 (a key longer than a block).
    assert_eq!(key::hex(&key::hmac_sha1(b"Jefe", b"what do ya want for nothing?")), "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79");
    assert_eq!(
        key::hex(&key::hmac_sha1(&[0xaa; 80], b"Test Using Larger Than Block-Size Key - Hash Key First")),
        "aa4ae5e15272d00e95705637ce8a3b55ed402112"
    );
}

/// IEEE 802.11i-2004, Annex H.4: the PSK wpa_passphrase(8) would print.
#[test]
fn a_passphrase_becomes_the_key_wpa_uses() {
    assert_eq!(key::psk("password", "IEEE").as_deref(), Some("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"));
    assert_eq!(
        key::psk("ThisIsAPassword", "ThisIsASSID").as_deref(),
        Some("0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af")
    );
    assert_eq!(key::psk("short", "x"), None, "WPA wants 8 to 63 characters");
    assert_eq!(key::psk(&"x".repeat(64), "x"), None);
    assert_eq!(key::psk("password", ""), None);
    assert!(key::is_psk("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"));
    assert!(!key::is_psk("password"));
    assert!(!key::is_psk(&"F".repeat(64)), "lower-case, as wpa_passphrase prints");
}

// MARK: Wi-Fi (P14.5b)

const KEY: &str = "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e";

fn join(ssid: &str, psk: Option<&str>) -> WifiAction {
    WifiAction::Join { ssid: ssid.into(), psk: psk.map(str::to_owned) }
}

#[test]
fn joining_compiles_to_the_network_the_radio_and_a_restart() {
    let steps = compile(&SettingsPlan::Wifi(WifiPlan::new("iwn0", join("Café Wi-Fi", Some(KEY))))).unwrap();
    assert_eq!(steps.len(), 4);
    assert_eq!(steps[1], rc("wlans_iwn0", Some("wlan0")));
    assert_eq!(steps[2], rc("ifconfig_wlan0", Some("WPA DHCP")));
    assert_eq!(steps[3], SettingsStep::service("netif", &["restart", "wlan0"], false));
    assert_eq!(steps[0].to_string(), "add network \"Café Wi-Fi\" to wpa_supplicant.conf");
    let r = render_etc(&steps);
    assert!(!r.contains(KEY), "the key is never in what a person or the journal reads: {r}");
    let forget = compile(&SettingsPlan::Wifi(WifiPlan::new("iwn0", WifiAction::Forget { ssid: "Café Wi-Fi".into() }))).unwrap();
    let said: Vec<String> = forget.iter().map(ToString::to_string).collect();
    assert_eq!(said, ["forget network \"Café Wi-Fi\" in wpa_supplicant.conf", "run wpa_cli -i wlan0 reconfigure"]);
}

#[test]
fn a_wifi_plan_is_refused_in_words() {
    let w = |p: WifiPlan| why(SettingsPlan::Wifi(p));
    assert_eq!(w(WifiPlan::new("iwn0", join("x", Some("password")))), ["the network key is not a WPA key (64 hex digits)"], "a passphrase is not a key");
    assert_eq!(w(WifiPlan::new("lo", join("x", None))), ["lo is not a wireless device's name"]);
    assert_eq!(w(WifiPlan::new("", join("x", None))), ["no radio is not a wireless device's name"]);
    let on_em0 = WifiPlan { interface: "em0".into(), ..WifiPlan::new("iwn0", WifiAction::Forget { ssid: "x".into() }) };
    assert_eq!(w(on_em0), ["em0 is not a wlan interface (wlan0, wlan1 …)"]);
    assert_eq!(w(WifiPlan::new("iwn0", join(&"x".repeat(33), None))), ["a network's name is 1 to 32 bytes, not 33"]);
    assert_eq!(w(WifiPlan::new("iwn0", join("", None))), ["a network's name is 1 to 32 bytes, not 0"]);
    assert!(w(WifiPlan::new("iwn0", join("Open Net", None))).is_empty());
}

#[test]
fn wpa_supplicant_conf_is_edited_by_network() {
    let hand = "# by hand\nctrl_interface=/var/run/wpa_supplicant\nnetwork={\n\tssid=\"Home\"\n\tpsk=\"hunter22\"\n}\nnetwork={\n\tssid=\"Work\"\n\tkey_mgmt=NONE\n}\n";
    assert_eq!(wpa::networks(hand), ["Home", "Work"]);
    // Joining Home again replaces the hand-written block where it was, in hex.
    let joined = wpa::edit(hand, "Home", Some(&format!("ssid={}\npsk={KEY}", wpa::hex("Home"))));
    assert_eq!(wpa::networks(&joined), ["Home", "Work"]);
    assert!(!joined.contains("hunter22"), "the old passphrase went with the old block");
    assert!(joined.contains(&format!("\tssid=486f6d65\n\tpsk={KEY}")), "{joined}");
    assert!(joined.starts_with("# by hand\n"), "the rest of the file is kept");
    // A name that would break out of quotes is only ever hex.
    let evil = "a\"\n}\nnetwork={ssid=\"x";
    let e = wpa::edit("", evil, Some(&format!("ssid={}\nkey_mgmt=NONE", wpa::hex(evil))));
    assert_eq!(wpa::networks(&e), [evil]);
    assert_eq!(e.split('\n').filter(|l| l.starts_with("network={")).count(), 1, "{e}");
    assert!(e.starts_with("ctrl_interface=/var/run/wpa_supplicant\n"), "wpa_cli needs the socket");
    // Forgetting removes only that network.
    assert_eq!(wpa::networks(&wpa::edit(&joined, "Home", None)), ["Work"]);
    assert_eq!(wpa::unhex("486f6d65").as_deref(), Some("Home"));
    assert_eq!(wpa::unhex("48z"), None);
    assert_eq!(wpa::unhex("+f"), None, "hex digits only");
    assert_eq!(edit_file(ConfFile::WpaSupplicant, "", &wpa::key("Home"), Some("ssid=486f6d65")), "ctrl_interface=/var/run/wpa_supplicant\nnetwork={\n\tssid=486f6d65\n}\n");
}

#[test]
fn a_scan_is_read_by_its_bssids_and_each_network_once() {
    let scan = "\
SSID/MESH ID                      BSSID              CHAN RATE    S:N     INT CAPS
abyss-lab                         00:98:9a:98:96:97    1   11M   10:10    100 EP   RSN
Café Wi-Fi 5G                     aa:bb:cc:dd:ee:01   36   54M  -61:-95   100 EP   RSN HTCAP WME
Café Wi-Fi 5G                     aa:bb:cc:dd:ee:02   40   54M  -48:-95   100 EP   RSN HTCAP WME
Library                           aa:bb:cc:dd:ee:03    6   54M  -70:-95   100 E    WME";
    let n = parse_scan(scan);
    let ssids: Vec<&str> = n.iter().map(|w| w.ssid.as_str()).collect();
    assert_eq!(ssids, ["abyss-lab", "Café Wi-Fi 5G", "Library"], "strongest first; one row per network");
    assert_eq!(n[1].bssid, "aa:bb:cc:dd:ee:02", "the strongest access point of the two");
    assert_eq!(n[1].channel, 40);
    assert!(n[0].secured);
    assert!(!n[2].secured, "no privacy, no RSN: open");
    assert_eq!(parse_scan("SSID/MESH ID  BSSID  CHAN\n"), []);
    assert!(!is_bssid("aa::bb:cc:dd:ee:ff"), "an empty field is not a pair");
}

// MARK: quitting a process (P15.7)

/// What may be asked: never init, never an unnamed pid; Quit is TERM and
/// Force Quit is KILL.
#[test]
fn a_signal_plan_refuses_init_and_compiles_to_kill() {
    let sig = |pid, name: &str| SettingsPlan::Signal(SignalPlan { pid, force: false, started: 5, name: name.into() });
    assert_eq!(why(sig(1, "init")), ["pid 1 is init: quitting it would stop the machine"]);
    assert_eq!(why(sig(0, "kernel")), ["0 is not a process"]);
    assert_eq!(why(sig(500, "")), ["a quit must name the process it means"]);
    let quit = SignalPlan { pid: 4242, force: false, started: 1_700_000_000, name: "sleep".into() };
    assert!(why(SettingsPlan::Signal(quit.clone())).is_empty());
    assert_eq!(compile(&SettingsPlan::Signal(quit.clone())).unwrap(), [SettingsStep::tool(&["kill", "-s", "TERM", "4242"], false)]);
    let force = SignalPlan { force: true, ..quit };
    assert_eq!(compile(&SettingsPlan::Signal(force)).unwrap(), [SettingsStep::tool(&["kill", "-s", "KILL", "4242"], false)]);
}

// MARK: volumes (P15.8)

/// Names are checked strictly before anything runs; the system's own mounts
/// are never unmounted; each action is one zfs (or umount) call.
#[test]
fn a_volume_plan_checks_names_and_compiles_to_zfs() {
    let v = |a: VolumeAction| why(SettingsPlan::Volume(a)).into_iter().next();
    let snap = |ds: &str, name: &str| VolumeAction::Snapshot { dataset: ds.into(), name: name.into() };
    let unmount = |p: &str| VolumeAction::Unmount { path: p.into() };
    assert_eq!(v(snap("zroot/home", "abyss-2026-10-01-090507")), None);
    assert!(v(snap("zroot/../etc", "x")).is_some());
    assert!(v(snap("zroot/home", "-rf")).is_some(), "a name that is an option");
    assert!(v(snap("zroot/home", "a b")).is_some());
    assert!(v(snap("zroot//home", "a")).is_some(), "an empty component");
    assert!(v(VolumeAction::Rollback { snapshot: "zroot/home".into() }).is_some(), "a rollback names a snapshot");
    assert_eq!(v(VolumeAction::Rollback { snapshot: "zroot/home@a".into() }), None);
    assert!(v(VolumeAction::Rollback { snapshot: "zroot/home@a@b".into() }).is_some());
    assert!(v(unmount("/")).is_some());
    assert!(v(unmount("/usr")).is_some());
    assert!(v(unmount("/media/../usr")).is_some());
    assert!(v(unmount("/dev/da0")).is_some());
    assert_eq!(v(unmount("media/stick")).as_deref(), Some("media/stick is not a mount point"));
    assert_eq!(v(unmount("/media/stick")), None);
    assert_eq!(compile(&SettingsPlan::Volume(snap("zroot/home", "s1"))).unwrap(), [SettingsStep::tool(&["zfs", "snapshot", "zroot/home@s1"], false)]);
    assert_eq!(
        compile(&SettingsPlan::Volume(VolumeAction::Rollback { snapshot: "zroot/home@s1".into() })).unwrap(),
        [SettingsStep::tool(&["zfs", "rollback", "zroot/home@s1"], false)],
        "never -r"
    );
}

// MARK: accounts (AccountsPlanTests)

const HASH: &str = "$6$salt$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ./abcdefgh";

fn add(name: &str, full: &str, hash: &str, admin: bool) -> SettingsPlan {
    SettingsPlan::Accounts(AccountAction::Add { name: name.into(), full_name: full.into(), password_hash: hash.into(), admin })
}

#[test]
fn names_the_system_owns_and_names_pw_refuses_are_refused() {
    let refused = |n: &str| !why(add(n, "", HASH, false)).is_empty();
    assert!(!refused("ada"));
    assert!(!refused("grace-h_2"));
    for bad in ["", "Ada", "1ada", "ada smith", "ada:x", "_loginwindow", "root", "toor", "abyss", "averyveryverylongname"] {
        assert!(refused(bad), "{bad} should be refused");
    }
    assert_eq!(why(add("ada", "", "hunter2", false)), ["the password did not arrive hashed"]);
    assert_eq!(why(add("ada", "Ada:L", HASH, false)), ["a full name cannot contain a colon, a comma or a new line"]);
    assert_eq!(
        why(add("", "", HASH, false)),
        ["an empty name is not an account name (lower-case letters, digits, _ and -, starting with a letter, at most 16)"]
    );
}

#[test]
fn the_hash_goes_on_stdin_and_is_never_said() {
    let steps = compile(&add("ada", "Ada Lovelace", HASH, true)).unwrap();
    assert_eq!(steps.len(), 1);
    let SettingsStep::Pw { args, input, .. } = &steps[0] else { panic!("not a pw step") };
    assert_eq!(input.as_deref(), Some(HASH));
    assert!(!args.iter().any(|a| a == HASH), "the hash is not in argv");
    let command = steps[0].command(&|_| String::new());
    assert!(!command.join(" ").contains(HASH));
    assert!(!steps[0].to_string().contains(HASH), "nor in what the journal and the pane say");
    assert_eq!(steps[0].to_string(), "create the account ada, an administrator");
    assert!(args.iter().any(|a| a == "wheel,operator,audio,video"));
    assert_eq!(command[..3], ["pw", "-R", "/"]);
    assert_eq!(steps[0].command_in(&|_| String::new(), "/scratch")[..3], ["pw", "-R", "/scratch"]);
    let user = compile(&add("bob", "", HASH, false)).unwrap();
    let SettingsStep::Pw { args: a2, .. } = &user[0] else { panic!() };
    assert!(a2.iter().any(|a| a == "audio,video") && !a2.concat().contains("wheel"), "a standard user is not an administrator");
    assert!(!a2.iter().any(|a| a == "-c"), "no full name, no -c");
}

#[test]
fn deleting_keeps_the_home_unless_asked() {
    let del = |remove_home| compile(&SettingsPlan::Accounts(AccountAction::Delete { name: "ada".into(), remove_home })).unwrap();
    let keep = del(false);
    let SettingsStep::Pw { args, input: None, what } = &keep[0] else { panic!() };
    assert_eq!(args, &["userdel", "-n", "ada"]);
    assert_eq!(what, "delete the account ada, keeping its home folder");
    let gone = del(true);
    let SettingsStep::Pw { args, input: None, .. } = &gone[0] else { panic!() };
    assert_eq!(args, &["userdel", "-n", "ada", "-r"]);
    assert!(!why(SettingsPlan::Accounts(AccountAction::Delete { name: "root".into(), remove_home: false })).is_empty());
}

#[test]
fn automatic_login_replaces_the_login_window_and_back() {
    assert_eq!(
        compile(&SettingsPlan::Accounts(AccountAction::AutoLogin(Some("ada".into())))).unwrap(),
        [rc("abyss_desktop_enable", Some("YES")), rc("abyss_desktop_user", Some("ada")), rc("abyss_loginwindow_greeter", Some("NO"))]
    );
    assert_eq!(
        compile(&SettingsPlan::Accounts(AccountAction::AutoLogin(None))).unwrap(),
        [rc("abyss_desktop_enable", Some("NO")), rc("abyss_desktop_user", None), rc("abyss_loginwindow_greeter", Some("YES"))]
    );
    assert_eq!(why(SettingsPlan::Accounts(AccountAction::AutoLogin(Some("Ada".into())))), ["Ada is not an account name"]);
}
