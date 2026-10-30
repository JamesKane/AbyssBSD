//! The wire halves of SettingsTests.swift and AccountsPlanTests.swift,
//! ported, and what Swift could not survive: a count far past what a message
//! holds, and an index past `Int.max`.

use current_ipc::Msg;
use settings::{
    AccountAction, EnergyPlan, IPv4, IPv4Config, NetworkPlan, PowerProfile, PowerdMode, SettingsPlan, SignalPlan, SoundPlan,
    VolumeAction, WifiAction, WifiNetwork, WifiPlan,
};
use settings_wire::{decode_event, decode_known, decode_plan, decode_scan, encode_event, encode_known, encode_plan, encode_scan, SettingsEvent, WifiKnown};

fn round_trip(plan: &SettingsPlan) -> SettingsPlan {
    let mut m = Msg::new();
    m.set_string("method", "apply");
    encode_plan(plan, &mut m);
    let back = Msg::unpack(&m.pack(), vec![]).unwrap();
    decode_plan(&back).unwrap_or_else(|r| panic!("{plan:?}: {r}"))
}

fn refusal(fields: &[(&str, &str)], powerd: Option<bool>) -> Option<String> {
    let mut m = Msg::new();
    for (k, v) in fields {
        m.set_string(k, v);
    }
    if let Some(p) = powerd {
        m.set_bool("energy.powerd", p);
    }
    decode_plan(&m).err().map(|r| r.message)
}

fn ip(s: &str) -> IPv4 {
    IPv4::parse(s).unwrap()
}

#[test]
fn every_plan_crosses_the_wire_intact() {
    let hash = "$6$salt$abc".to_owned();
    let plans = [
        SettingsPlan::Energy(EnergyPlan { powerd: true, on_ac: PowerdMode::Minimum, on_battery: PowerdMode::Hiadaptive, modes_from_profile: false }),
        SettingsPlan::Energy(EnergyPlan { modes_from_profile: true, ..EnergyPlan::new(true) }),
        SettingsPlan::PowerProfile(PowerProfile::Performance),
        SettingsPlan::Network(NetworkPlan {
            interface: "vtnet0".into(),
            ipv4: IPv4Config::Manual { address: ip("192.168.7.9"), prefix: 23, router: Some(ip("192.168.6.1")) },
            dns: vec![ip("192.168.6.1")],
        }),
        SettingsPlan::Network(NetworkPlan { interface: "em0".into(), ipv4: IPv4Config::Dhcp, dns: vec![] }),
        SettingsPlan::Sound(SoundPlan { default_unit: 1 }),
        SettingsPlan::Wifi(WifiPlan::new("wtap1", WifiAction::Join { ssid: "abyss-lab".into(), psk: Some("f".repeat(64)) })),
        SettingsPlan::Wifi(WifiPlan::new("wtap1", WifiAction::Join { ssid: "open".into(), psk: None })),
        SettingsPlan::Wifi(WifiPlan { interface: "wlan1".into(), ..WifiPlan::new("iwn0", WifiAction::Forget { ssid: "x".into() }) }),
        SettingsPlan::Signal(SignalPlan { pid: 4242, force: true, started: 1_700_000_000, name: "sleep".into() }),
        SettingsPlan::Volume(VolumeAction::Snapshot { dataset: "p/d".into(), name: "n".into() }),
        SettingsPlan::Volume(VolumeAction::Rollback { snapshot: "p/d@n".into() }),
        SettingsPlan::Volume(VolumeAction::MountDataset("p/d".into())),
        SettingsPlan::Volume(VolumeAction::UnmountDataset("p/d".into())),
        SettingsPlan::Volume(VolumeAction::Unmount { path: "/media/x".into() }),
        SettingsPlan::Accounts(AccountAction::Add { name: "ada".into(), full_name: "Ada".into(), password_hash: hash, admin: true }),
        SettingsPlan::Accounts(AccountAction::Delete { name: "ada".into(), remove_home: true }),
        SettingsPlan::Accounts(AccountAction::AutoLogin(Some("ada".into()))),
        SettingsPlan::Accounts(AccountAction::AutoLogin(None)),
    ];
    for plan in plans {
        assert_eq!(round_trip(&plan), plan);
    }
}

#[test]
fn the_wire_refuses_in_words_rather_than_guessing() {
    assert_eq!(refusal(&[], Some(true)).as_deref(), Some("the request names no kind of plan"));
    assert_eq!(
        refusal(&[("kind", "displays")], Some(true)).as_deref(),
        Some("there is no displays plan (there is: energy, network, power-profile, sound, wifi)")
    );
    assert_eq!(
        refusal(&[("kind", "power-profile"), ("power-profile", "turbo")], None).as_deref(),
        Some("a power-profile plan must name power-saver, balanced or performance")
    );
    assert_eq!(refusal(&[("kind", "sound")], None).as_deref(), Some("a sound plan must say which device is the default"));
    assert_eq!(refusal(&[("kind", "energy")], None).as_deref(), Some("an energy plan must say whether powerd runs"));
    assert_eq!(
        refusal(&[("kind", "energy"), ("energy.ac", "turbo")], Some(true)).as_deref(),
        Some("powerd has no mode turbo (it has: adaptive, hiadaptive, min, max)")
    );
    assert_eq!(
        refusal(&[("kind", "network"), ("network.interface", "em0"), ("network.mode", "manual"), ("network.address", "10.0.0.5"), ("network.netmask", "255.0.255.0")], None).as_deref(),
        Some("255.0.255.0 is not a subnet mask")
    );
}

#[test]
fn a_sound_device_is_said_as_a_person_says_it() {
    let sound = |said: &str| {
        let mut m = Msg::new();
        m.set_string("kind", "sound");
        m.set_string("sound.default", said);
        decode_plan(&m)
    };
    assert_eq!(sound("pcm3"), Ok(SettingsPlan::Sound(SoundPlan { default_unit: 3 })), "pcm3 is how a person says it");
    assert_eq!(sound("speakers").unwrap_err().message, "speakers is not a sound device (pcm0, pcm1 …)");
}

#[test]
fn events_cross_the_wire_intact() {
    let events = [
        SettingsEvent::Starting { index: 1, total: 3, what: "set x".into() },
        SettingsEvent::Ok { index: 1 },
        SettingsEvent::Failed { index: 2, what: "stop".into(), why: "not running".into(), ignored: true },
        SettingsEvent::Skipped { index: 2, why: "write-only".into() },
        SettingsEvent::Finished { ok: false, error: "because".into() },
    ];
    for e in events {
        assert_eq!(decode_event(&encode_event(&e)), Some(e));
    }
    let mut big = Msg::new();
    big.set_string("event", "ok");
    big.set_u64("index", u64::MAX);
    assert_eq!(decode_event(&big), Some(SettingsEvent::Ok { index: u64::MAX }), "Swift traps here");
    assert_eq!(decode_event(&Msg::new()), None);
}

#[test]
fn wifi_crosses_the_wire() {
    let known = WifiKnown { device: "wtap1".into(), interface: Some("wlan0".into()), networks: vec!["a".into(), "b c".into()] };
    let mut k = Msg::new();
    encode_known(&known, &mut k);
    assert_eq!(decode_known(&k), known);
    let nets = vec![
        WifiNetwork { ssid: "x y".into(), bssid: "00:11:22:33:44:55".into(), channel: 6, signal: -48, secured: true },
        WifiNetwork { ssid: "z".into(), bssid: "".into(), channel: 0, signal: 0, secured: false },
    ];
    let mut sc = Msg::new();
    encode_scan(&nets, &mut sc);
    assert_eq!(decode_scan(&sc), nets);
}

/// A count far past what the message holds reads what it holds, at once;
/// an index the count does not reach, or spelt with a leading zero, is not
/// read.
#[test]
fn a_list_reads_only_what_the_message_holds() {
    let mut m = Msg::new();
    m.set_u64("wifi.known.count", u64::MAX);
    m.set_string("wifi.known.0", "a");
    m.set_string("wifi.known.07", "leading zero");
    m.set_string("wifi.known.9", "sparse");
    m.set_u64("wifi.known.1", 5);
    assert_eq!(decode_known(&m).networks, ["a", "sparse"]);
    let mut short = Msg::new();
    short.set_u64("wifi.known.count", 1);
    short.set_string("wifi.known.0", "a");
    short.set_string("wifi.known.1", "past the count");
    assert_eq!(decode_known(&short).networks, ["a"]);
    let mut s = Msg::new();
    s.set_u64("scan.count", u64::MAX);
    s.set_string("scan.3.ssid", "far");
    s.set_u64("scan.3.channel", u64::MAX);
    let n = decode_scan(&s);
    assert_eq!(n.len(), 1);
    assert_eq!(n[0].channel, i64::MAX, "Swift traps here");
}
