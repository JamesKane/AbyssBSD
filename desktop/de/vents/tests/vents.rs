//! VentsTests.swift and ProcessesTests.swift, ported: the parsing and
//! encoding, pure, on lines captured from the build VM; and the real
//! system, where the platform has the facility, which must otherwise say so.

use vents::network::{self, Address};
use vents::processes::{self, Column, Filter, Info, ProcessTable, Sample};
use vents::{sound, sysctl, wifi, Battery, Devd, Event, EventKind, Mixer, VolumeLevel};

// MARK: devd

#[test]
fn attach_and_detach_carry_the_device_name() {
    let attach = Event::new("+ugen0.2 at port=2 ... on uhub0");
    assert_eq!((attach.kind, attach.device(), attach.summary().as_str()), (EventKind::Attach, Some("ugen0.2"), "attach ugen0.2"));
    let detach = Event::new("-ugen0.2 at port=2 on uhub0");
    assert_eq!((detach.kind, detach.device()), (EventKind::Detach, Some("ugen0.2")));
}

#[test]
fn notify_fields_from_real_devfs_events() {
    let e = Event::new("!system=DEVFS subsystem=CDEV type=CREATE cdev=md0");
    assert_eq!(e.kind, EventKind::Notify);
    assert_eq!([e.value("system"), e.value("subsystem"), e.value("type"), e.value("cdev")], [Some("DEVFS"), Some("CDEV"), Some("CREATE"), Some("md0")]);
    assert_eq!(e.value("nope"), None);
    assert_eq!(e.device(), None, "an attach question asked of a notify gets an honest None");
}

#[test]
fn quoted_values_with_spaces_survive() {
    let e = Event::new(r#"!system=CAM subsystem=periph type=error device=cd0 serial="QM00005" cam_status="0x4cc" scsi_status=2 scsi_sense="70 02 3a 00" CDB="00 00 00 00 00 00 ""#);
    assert_eq!(e.kind, EventKind::Notify);
    assert_eq!(e.value("device"), Some("cd0"));
    assert_eq!(e.value("serial"), Some("QM00005"));
    assert_eq!(e.value("scsi_sense"), Some("70 02 3a 00"));
    assert_eq!(e.value("CDB"), Some("00 00 00 00 00 00 "));
    assert_eq!(e.value("scsi_status"), Some("2"));
}

#[test]
fn nomatch_and_unknown_lines() {
    assert_eq!(Event::new("? at bus=0 on pci0").kind, EventKind::Nomatch);
    let odd = Event::new("something devd never sends");
    assert_eq!((odd.kind, odd.raw.as_str()), (EventKind::Unknown, "something devd never sends"), "an unknown line keeps its first character");
}

#[test]
fn line_endings_and_empty_input() {
    let e = Event::new("+md0 at\r\n");
    assert_eq!((e.device(), e.raw.as_str()), (Some("md0"), "md0 at"), "the CR goes too");
    assert_eq!((Event::new("").kind, Event::new("").raw.as_str()), (EventKind::Unknown, ""));
    assert!(Event::new("!").fields.is_empty(), "a notify with no fields is fine");
}

// MARK: volume, battery

#[test]
fn volume_encoding_round_trips_and_clamps() {
    let v = VolumeLevel::new(42, 73);
    assert_eq!(VolumeLevel::from_encoded(v.encoded()), v);
    assert_eq!(VolumeLevel::new(10, 20).encoded(), 10 | (20 << 8));
    assert_eq!(VolumeLevel::new(200, 150), VolumeLevel::new(100, 100), "clamped, not wrapped into the other channel");
    assert_eq!(VolumeLevel::both(66).mono(), 66);
}

#[test]
fn volume_decode_ignores_higher_bits() {
    let d = VolumeLevel::from_encoded(0x00FF_3264);
    assert_eq!((d.left, d.right), (100, 50));
}

#[test]
fn battery_label_is_honest_about_not_knowing() {
    assert_eq!(Battery { percent: Some(84), minutes_remaining: Some(120), is_charging: false }.label(), "84%");
    assert_eq!(Battery { percent: None, minutes_remaining: None, is_charging: true }.label(), "—");
}

// MARK: sysctl

#[test]
fn sysctl_reads_real_kernel_values() {
    if !sysctl::is_supported() {
        assert_eq!(sysctl::string("kern.ostype"), None, "a stub says so rather than pretending");
        assert_eq!(sysctl::int("hw.ncpu"), None);
        return;
    }
    assert_eq!(sysctl::string("kern.ostype").as_deref(), Some("FreeBSD"));
    assert!(sysctl::int("hw.ncpu").unwrap() > 0);
    assert!(sysctl::int("hw.physmem").unwrap() > 0);
    assert_eq!(sysctl::string("abyss.no.such.sysctl"), None);
}

/// `kern.ostype` is "FreeBSD\0", exactly eight bytes: text first.
#[test]
fn display_prefers_text_over_a_plausible_integer() {
    assert_eq!(sysctl::display_of(b"FreeBSD\0"), "FreeBSD");
    assert_eq!(sysctl::display_of(&8i32.to_ne_bytes()), "8");
    assert_eq!(sysctl::display_of(&[1, 2, 3]), "<3 bytes>");
    assert_eq!(sysctl::display_of(b"a value \n\0"), "a value");
    if sysctl::is_supported() {
        assert_eq!(sysctl::display("kern.ostype").as_deref(), Some("FreeBSD"));
        assert!(sysctl::display("hw.ncpu").unwrap().parse::<i64>().is_ok());
        assert_eq!(sysctl::display("abyss.no.such.sysctl"), None);
    } else {
        assert_eq!(sysctl::display("kern.ostype"), None);
    }
}

#[test]
fn absent_facilities_return_none_rather_than_fake_readings() {
    assert!(Mixer::open(Some("/nonexistent/mixer")).is_err());
    assert!(Devd::connect("/nonexistent/devd.pipe").is_none());
}

// MARK: the network

#[test]
fn the_default_route_is_read_from_route_get() {
    let out = "   route to: default\ndestination: default\n       mask: default\n    gateway: 10.0.2.2\n        fib: 0\n  interface: vtnet0\n      flags: <UP,GATEWAY,DONE,STATIC>\n";
    let r = network::parse_route_get(out).unwrap();
    assert_eq!((r.address.as_str(), r.interface.as_str()), ("10.0.2.2", "vtnet0"));
    assert_eq!(network::parse_route_get("route: route has not been found\n"), None, "no default route is none");
}

#[test]
fn the_default_route_is_read_from_proc_net_route() {
    let table = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\nenp77s0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\nenp77s0\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\n";
    let r = network::parse_proc_route(table).unwrap();
    assert_eq!((r.address.as_str(), r.interface.as_str()), ("192.168.0.1", "enp77s0"));
    assert_eq!(network::parse_proc_route("Iface\tDestination\tGateway\n"), None);
}

#[test]
fn name_servers_are_read_in_order_and_nothing_else() {
    let conf = "# generated\nsearch example.org\nnameserver 10.0.2.3\nnameserver\t9.9.9.9\noptions edns0\n";
    assert_eq!(network::parse_resolv_conf(conf), ["10.0.2.3", "9.9.9.9"]);
    assert!(network::parse_resolv_conf("").is_empty());
}

/// Real, on both platforms: every machine has a loopback with 127.0.0.1/8.
#[test]
fn the_loopback_is_found_with_its_address() {
    let all = network::interfaces();
    let lo = all.iter().find(|i| i.loopback).unwrap_or_else(|| panic!("no loopback among {:?}", all.iter().map(|i| &i.name).collect::<Vec<_>>()));
    assert!(lo.up);
    assert!(lo.ipv4.contains(&Address { address: "127.0.0.1".into(), prefix: 8 }), "{:?}", lo.ipv4);
    assert!(network::Watch::open().is_some(), "no routing socket to watch");
}

// MARK: sound

#[test]
fn sndstat_gives_devices_and_who_is_playing() {
    let text = "dev\t0\tpcm0\tDummy Audio Device\tdsp0\t1\t1\t0
chan\t0\tdsp0.play.0\t-1\t<UNUSED>\t45\t45
chan\t0\tdsp0.virtual_play.0\t31118\tplayer\t30\t30
chan\t0\tdsp0.virtual_play.1\t31119\tmpv\t80\t75
chan\t0\tdsp0.record.0\t-1\t<UNUSED>\t45\t45
chan\t0\tdsp0.virtual_record.0\t4242\tobs\t50\t50
dev\t1\tpcm1\tUSB Headset\tdsp1\t1\t0\t0
dev\t-1\tvdsp\tVirtual OSS\tvdsp\t1\t1\t1";
    let d = sound::parse_sndstat(text);
    assert_eq!(d.iter().map(|d| d.name.as_str()).collect::<Vec<_>>(), ["pcm0", "pcm1"], "a user-space device is not a pcm");
    assert_eq!(d[0].description, "Dummy Audio Device");
    assert!(d[0].playback && d[0].recording && !d[1].recording);
    assert_eq!(d[0].channels.len(), 5);
    let playing = d[0].playing();
    assert_eq!(playing.iter().map(|c| c.command.as_str()).collect::<Vec<_>>(), ["player", "mpv"], "unused channels and a recorder are not playing");
    assert_eq!((playing[1].pid, playing[1].left, playing[1].right), (Some(31119), 80, 75));
    assert_eq!(d[0].channels[0].pid, None);
    assert!(d[1].channels.is_empty());
    assert!(sound::parse_sndstat("").is_empty());
}

#[test]
fn mixer_controls_with_levels_and_mute() {
    let c = sound::parse_controls("ctl\tvol\t75\t70\t0\t0\nctl\tpcm\t40\t40\t1\t0\nctl\trec\t75\t75\t0\t1\ngarbage\n");
    assert_eq!(c.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["vol", "pcm", "rec"]);
    assert_eq!(c[0].level(), 75, "a slider shows the louder side");
    assert!(c[1].muted && c[2].recordable && !c[0].recordable);
}

/// Real, on Linux: no OSS, and the bridge says none rather than guessing.
#[test]
fn no_oss_means_no_devices() {
    if cfg!(target_os = "linux") {
        assert!(sound::devices().is_empty());
        assert!(sound::controls(0).is_empty());
        assert!(sound::set(0, "vol", 50, 50).is_some(), "a set must fail, not pretend");
    }
}

// MARK: Wi-Fi

#[test]
fn ifconfig_says_what_a_wlan_is_associated_with() {
    let out = "wlan0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
\tssid \"Café Wi-Fi\" channel 6 (2437 MHz 11g) bssid 00:11:22:33:44:55
\tstatus: associated
";
    let s = wifi::parse_ifconfig(out, "wlan0");
    assert!(s.exists && s.associated);
    assert_eq!((s.ssid.as_deref(), s.channel, s.bssid.as_deref()), (Some("Café Wi-Fi"), Some(6), Some("00:11:22:33:44:55")));
    let bare = wifi::parse_ifconfig("\tssid lab channel 1 (2412 MHz 11g)\n\tstatus: no carrier\n", "wlan1");
    assert!(!bare.associated);
    assert_eq!((bare.ssid.as_deref(), bare.bssid), (Some("lab"), None));
}

// MARK: processes

fn p(pid: i32, name: &str, uid: u32, cpu: u64, started: i64, rss: u64, threads: i32) -> Info {
    Info { pid, ppid: 0, uid, threads, resident_bytes: rss, virtual_bytes: 0, cpu_microseconds: cpu, started, state: 'S', system: false, name: name.into() }
}

/// %CPU is CPU time over wall time between samples; a pid reused in
/// between is a new process at 0, not an old one at 1,000%.
#[test]
fn cpu_is_measured_between_samples_of_the_same_process() {
    let before = Sample { processes: vec![p(10, "busy", 1000, 1_000_000, 100, 0, 1), p(11, "idle", 1000, 50_000, 100, 0, 1), p(12, "old", 1000, 5_000_000, 100, 0, 1)], at: 10_000_000, memory_total: 0, memory_available: 0 };
    let now = Sample {
        processes: vec![p(10, "busy", 1000, 1_500_000, 100, 0, 1), p(11, "idle", 1000, 50_000, 100, 0, 1), p(12, "new", 1000, 20_000_000, 900, 0, 1), p(13, "born", 1000, 7, 100, 0, 1)],
        at: 11_000_000,
        memory_total: 0,
        memory_available: 0,
    };
    let t = ProcessTable::new(&now, Some(&before));
    let cpu = |pid| t.rows.iter().find(|r| r.info.pid == pid).unwrap().cpu_percent;
    assert!((cpu(10) - 50.0).abs() < 0.001, "0.5 s of CPU in 1 s");
    assert_eq!([cpu(11), cpu(12), cpu(13)], [0.0; 3], "idle, reused, newborn");
    assert!(ProcessTable::new(&now, None).rows.iter().all(|r| r.cpu_percent == 0.0));
}

#[test]
fn sorting_and_filtering() {
    let s = Sample { processes: vec![p(3, "beta", 0, 0, 100, 30, 1), p(1, "Alpha", 1000, 0, 100, 10, 1), p(2, "gamma", 1000, 0, 100, 30, 4)], at: 0, memory_total: 0, memory_available: 0 };
    let t = ProcessTable::new(&s, None);
    let pids = |rows: Vec<vents::Row>| rows.iter().map(|r| r.info.pid).collect::<Vec<_>>();
    let names = |uid: u32| uid.to_string();
    assert_eq!(pids(t.view(Filter::All, Column::Name, true, &names)), [1, 3, 2], "names sort without regard to case");
    assert_eq!(pids(t.view(Filter::All, Column::Memory, false, &names)), [2, 3, 1], "ties broken by pid");
    assert_eq!(pids(t.view(Filter::Mine(1000), Column::Pid, true, &names)), [1, 2]);
    assert_eq!(t.view(Filter::All, Column::Threads, false, &names)[0].info.pid, 2);
}

#[test]
#[allow(clippy::approx_constant)] // Swift's test's own number
fn memory_and_percent_are_written_as_activity_monitor_writes_them() {
    assert_eq!(ProcessTable::format_bytes(512 * 1024), "512 KB");
    assert_eq!(ProcessTable::format_bytes(12 * 1024 * 1024 + 512 * 1024), "12.5 MB");
    assert_eq!(ProcessTable::format_bytes(1_288_490_189), "1.20 GB");
    assert_eq!(ProcessTable::format_percent(3.14159), "3.1");
}

/// The real thing: this process is in the sample, as itself.
#[test]
fn the_sample_contains_this_process() {
    let s = processes::sample().expect("a sample");
    let me = s.processes.iter().find(|p| p.pid == std::process::id() as i32).expect("this process");
    assert_eq!(me.uid, abyss_sys::platform::euid());
    assert!(me.resident_bytes > 0);
    assert!(me.started > 1_600_000_000, "a start time since the epoch");
    assert!(!me.system);
    assert!(s.memory_total > 0 && s.processes.len() > 5);
}
