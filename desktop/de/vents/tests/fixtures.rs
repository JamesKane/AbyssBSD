//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/vents,
//! written by Swift (Tests/VentsTests/VentsFixtureTests.swift, the
//! specification). Every `.in` is what the machine said, and every parser
//! here reads it as Swift's did.
//!
//! Where Swift's answer is one of its quirks (RUST.md §1), the case is in
//! DIVERGENT and Rust's own reading is pinned beside it as
//! `<case>.rust.txt`, which this test writes when ABYSS_WIRE_UPDATE is set.

use std::fs;
use std::path::PathBuf;
use vents::network;
use vents::{sound, sysctl, wifi, Event, EventKind, ProcessTable, VolumeLevel};

/// Cases where Swift's answer is a Swift-language quirk, and why.
const DIVERGENT: &[(&str, &str)] = &[
    // A CRLF is one Character: Swift neither splits nor strips it.
    ("devd-odd", "a CRLF line"),
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/vents")
}

fn q(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => out.push_str(&format!("\\u{{{:x}}}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn b(v: bool) -> &'static str {
    if v { "1" } else { "0" }
}

fn kind(k: EventKind) -> &'static str {
    match k {
        EventKind::Notify => "notify",
        EventKind::Attach => "attach",
        EventKind::Detach => "detach",
        EventKind::Nomatch => "nomatch",
        EventKind::Unknown => "unknown",
    }
}

/// The bytes a sysctl's hex spells (an odd last digit dropped, as Swift does).
fn bytes(hex: &str) -> Vec<u8> {
    hex.as_bytes().as_chunks::<2>().0.iter().map(|p| u8::from_str_radix(std::str::from_utf8(p).unwrap(), 16).unwrap()).collect()
}

fn run(op: &str, input: &str) -> String {
    let mut out = format!("{op}\n");
    let lines: Vec<&str> = input.split('\n').filter(|l| !l.is_empty()).collect();
    match op {
        "devd" => {
            for l in input.split('\n') {
                let e = Event::new(l);
                let fields: String = e.fields.iter().map(|(k, v)| format!(" {}={}", q(k), q(v))).collect();
                out += &format!("event {} {} device={} summary={}{fields}\n", kind(e.kind), q(&e.raw), e.device().map_or("none".into(), q), q(&e.summary()));
            }
        }
        "sndstat" => {
            for d in sound::parse_sndstat(input) {
                out += &format!("device {} {} {} {} play={} rec={} user={}\n", d.unit, q(&d.name), q(&d.description), q(&d.devnode), b(d.playback), b(d.recording), b(d.from_user));
                for c in &d.channels {
                    out += &format!("  channel {} pid={} {} {}:{} playback={}\n", q(&c.name), c.pid.map_or("none".into(), |p| p.to_string()), q(&c.command), c.left, c.right, b(c.is_playback()));
                }
                out += &format!("  playing{}\n", d.playing().iter().map(|c| format!(" {}", c.pid.unwrap())).collect::<String>());
            }
        }
        "controls" => {
            for c in sound::parse_controls(input) {
                out += &format!("control {} {}:{} level={} muted={} rec={}\n", q(&c.name), c.left, c.right, c.level(), b(c.muted), b(c.recordable));
            }
        }
        "route" | "procroute" => {
            let r = if op == "route" { network::parse_route_get(input) } else { network::parse_proc_route(input) };
            out += &r.map_or("router none\n".into(), |r| format!("router {} {}\n", q(&r.address), q(&r.interface)));
        }
        "resolv" => out += &format!("dns{}\n", network::parse_resolv_conf(input).iter().map(|n| format!(" {}", q(n))).collect::<String>()),
        "ifconfig" => {
            let s = wifi::parse_ifconfig(input, "wlan0");
            out += &format!(
                "wifi exists={} associated={} ssid={} bssid={} channel={}\n",
                b(s.exists),
                b(s.associated),
                s.ssid.as_deref().map_or("none".into(), q),
                s.bssid.as_deref().map_or("none".into(), q),
                s.channel.map_or("none".into(), |c| c.to_string())
            );
        }
        "display" => {
            for l in lines {
                out += &format!("display {l} {}\n", q(&sysctl::display_of(&bytes(l))));
            }
        }
        "volume" => {
            for l in lines {
                let v = VolumeLevel::from_encoded(l.parse().unwrap());
                out += &format!("volume {l} {}:{} encoded={}\n", v.left, v.right, v.encoded());
            }
        }
        #[allow(clippy::approx_constant)] // Swift's corpus's own number
        "formats" => {
            for l in lines {
                out += &format!("bytes {l} {}\n", q(&ProcessTable::format_bytes(l.parse().unwrap())));
            }
            for p in [0.0, 0.05, 0.15, 3.14159, 99.95, 100.0, 250.04] {
                // Swift writes a Double's description: 100.0, 0.05.
                let text = if p == f64::trunc(p) { format!("{p:.1}") } else { format!("{p}") };
                out += &format!("percent {text} {}\n", q(&ProcessTable::format_percent(p)));
            }
        }
        _ => out += "no operation\n",
    }
    out
}

#[test]
fn the_fixtures_are_what_rust_reads() {
    let mut cases: Vec<String> = fs::read_dir(dir())
        .expect("abyss/tests/wire/vents: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(".in").map(str::to_owned))
        .collect();
    cases.sort();
    assert!(cases.len() >= 15, "only {} cases", cases.len());
    let update = std::env::var_os("ABYSS_WIRE_UPDATE").is_some();
    let mut wrong = vec![];
    for case in &cases {
        let input = fs::read_to_string(dir().join(format!("{case}.in"))).unwrap();
        let swift = fs::read_to_string(dir().join(format!("{case}.txt"))).unwrap();
        let got = run(swift.lines().next().unwrap(), &input);
        if DIVERGENT.iter().any(|(c, _)| c == case) {
            let pinned = dir().join(format!("{case}.rust.txt"));
            if update {
                fs::write(&pinned, &got).unwrap();
            }
            let want = fs::read_to_string(&pinned).unwrap_or_else(|_| panic!("{case}.rust.txt: run with ABYSS_WIRE_UPDATE=1"));
            if got != want {
                wrong.push(format!("{case}: not the pinned Rust reading\n--- pinned\n{want}--- got\n{got}"));
            }
            if got == swift {
                wrong.push(format!("{case}: agrees with Swift now; take it out of DIVERGENT"));
            }
        } else if got != swift {
            wrong.push(format!("{case}\n--- swift\n{swift}--- rust\n{got}"));
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    eprintln!("{} cases, {} divergent", cases.len(), DIVERGENT.len());
}
