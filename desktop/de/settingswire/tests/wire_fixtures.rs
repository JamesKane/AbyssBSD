//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/settings,
//! written by Swift (Tests/SettingsTests/SettingsWireFixtureTests.swift, the
//! specification). Every message decodes here to the text Swift recorded
//! (for a plan: the plan, its refusals and the steps the helper would run)
//! and, unless marked decode-only, encodes back to Swift's bytes. Every
//! `.in` is parsed or edited to the text Swift recorded.
//!
//! Where Swift's answer is one of its quirks (RUST.md §1), the case is in
//! DIVERGENT and Rust's own reading is pinned beside it as
//! `<case>.rust.txt`, which this test writes when ABYSS_WIRE_UPDATE is set.

use current_ipc::Msg;
use settings::{
    edit_sysctl_conf, parse_scan, problems, render_etc, sysctl_conf_value, wpa, AccountAction, IPv4, IPv4Config, SettingsPlan,
    VolumeAction, WifiAction, WifiNetwork,
};
use settings_wire::{decode_event, decode_known, decode_plan, decode_scan, encode_event, encode_known, encode_plan, encode_scan, SettingsEvent};
use std::fs;
use std::path::PathBuf;

/// Cases where Swift's answer is a Swift-language quirk, and why.
const DIVERGENT: &[(&str, &str)] = &[
    // Swift's `UInt8(_:radix:)` takes a sign: `+a` is a hex pair to it.
    ("scan-odd-bssids", "a signed pair, and an empty field Swift's split drops"),
    ("wpa-odd-hex", "ssid=+f is a name to Swift"),
    // A CRLF is one Character: Swift's file is one long line.
    ("wpa-crlf", "CRLF lines"),
    ("sysctl-crlf", "CRLF lines (Swift's edit drops the rest of the file)"),
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/settings")
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

/// `q` undone, and what follows it.
fn unq(s: &str) -> (String, &str) {
    let mut out = String::new();
    let mut rest = s.strip_prefix('"').expect("a quoted string");
    let next = |rest: &mut &str| {
        let c = rest.chars().next().unwrap_or_else(|| panic!("unterminated: {s}"));
        *rest = &rest[c.len_utf8()..];
        c
    };
    loop {
        match next(&mut rest) {
            '"' => return (out, rest.trim_start_matches(' ')),
            '\\' => match next(&mut rest) {
                'n' => out.push('\n'),
                'u' => {
                    let end = rest.find('}').unwrap();
                    out.push(char::from_u32(u32::from_str_radix(&rest[1..end], 16).unwrap()).unwrap());
                    rest = &rest[end + 1..];
                }
                e => out.push(e),
            },
            c => out.push(c),
        }
    }
}

fn b(v: bool) -> &'static str {
    if v { "1" } else { "0" }
}

fn plan_text(p: &SettingsPlan) -> String {
    match p {
        SettingsPlan::Energy(e) => format!(
            "energy powerd={} ac={} battery={} from-profile={}",
            b(e.powerd),
            e.on_ac.as_str(),
            e.on_battery.as_str(),
            b(e.modes_from_profile)
        ),
        SettingsPlan::PowerProfile(pp) => format!("power-profile {}", pp.as_str()),
        SettingsPlan::Network(n) => {
            let dns = format!("dns={}", n.dns.iter().map(IPv4::to_string).collect::<Vec<_>>().join(","));
            match n.ipv4 {
                IPv4Config::Dhcp => format!("network {} dhcp {dns}", q(&n.interface)),
                IPv4Config::Manual { address, prefix, router } => format!(
                    "network {} manual {address}/{prefix} router={} {dns}",
                    q(&n.interface),
                    router.map_or("none".to_owned(), |r| r.to_string())
                ),
            }
        }
        SettingsPlan::Sound(s) => format!("sound {}", s.default_unit),
        SettingsPlan::Wifi(w) => match &w.action {
            WifiAction::Join { ssid, psk } => format!(
                "wifi {} {} join {} {}",
                q(&w.device),
                q(&w.interface),
                q(ssid),
                psk.as_ref().map_or("open".to_owned(), |p| format!("psk={}", q(p)))
            ),
            WifiAction::Forget { ssid } => format!("wifi {} {} forget {}", q(&w.device), q(&w.interface), q(ssid)),
        },
        SettingsPlan::Signal(s) => format!("signal {} force={} started={} {}", s.pid, b(s.force), s.started, q(&s.name)),
        SettingsPlan::Volume(v) => match v {
            VolumeAction::Snapshot { dataset, name } => format!("volume snapshot {} {}", q(dataset), q(name)),
            VolumeAction::Rollback { snapshot } => format!("volume rollback {}", q(snapshot)),
            VolumeAction::MountDataset(ds) => format!("volume mount {}", q(ds)),
            VolumeAction::UnmountDataset(ds) => format!("volume unmount-dataset {}", q(ds)),
            VolumeAction::Unmount { path } => format!("volume unmount {}", q(path)),
        },
        SettingsPlan::Accounts(a) => match a {
            AccountAction::Add { name, full_name, password_hash, admin } => {
                format!("accounts add {} {} {} admin={}", q(name), q(full_name), q(password_hash), b(*admin))
            }
            AccountAction::Delete { name, remove_home } => format!("accounts delete {} remove-home={}", q(name), b(*remove_home)),
            AccountAction::AutoLogin(n) => format!("accounts autologin {}", n.as_deref().map_or("none".to_owned(), q)),
        },
    }
}

fn event_text(e: Option<&SettingsEvent>) -> String {
    match e {
        None => "none".into(),
        Some(SettingsEvent::Starting { index, total, what }) => format!("starting {index} {total} {}", q(what)),
        Some(SettingsEvent::Ok { index }) => format!("ok {index}"),
        Some(SettingsEvent::Failed { index, what, why, ignored }) => format!("failed {index} {} {} ignored={}", q(what), q(why), b(*ignored)),
        Some(SettingsEvent::Skipped { index, why }) => format!("skipped {index} {}", q(why)),
        Some(SettingsEvent::Finished { ok, error }) => format!("finished {} {}", b(*ok), q(error)),
    }
}

fn network_text(n: &WifiNetwork) -> String {
    format!("network {} {} {} {} secured={}", q(&n.ssid), q(&n.bssid), n.channel, n.signal, b(n.secured))
}

/// What `decoder` reads from `bin`, and the bytes the encoder makes of that
/// (None when it read nothing to encode).
fn decode(decoder: &str, bin: &[u8]) -> (String, Option<Vec<u8>>) {
    let mut out = format!("{decoder}\n");
    let Ok(m) = Msg::unpack(bin, vec![]) else { return (out + "malformed\n", None) };
    let mut e = Msg::new();
    match decoder {
        "plan" => match decode_plan(&m) {
            Err(r) => return (out + &format!("refused {}\n", q(&r.message)), None),
            Ok(p) => {
                out += &(plan_text(&p) + "\n");
                let refusals = problems(&p);
                for r in &refusals {
                    out += &format!("problem {}\n", q(&r.message));
                }
                if refusals.is_empty() {
                    out += &format!("steps\n{}\n", render_etc(&settings::compile(&p).unwrap()));
                }
                encode_plan(&p, &mut e);
            }
        },
        "event" => {
            let ev = decode_event(&m);
            out += &(event_text(ev.as_ref()) + "\n");
            return (out, ev.map(|ev| encode_event(&ev).pack()));
        }
        "known" => {
            let k = decode_known(&m);
            out += &format!("device {}\ninterface {}\n", q(&k.device), k.interface.as_deref().map_or("none".to_owned(), q));
            for n in &k.networks {
                out += &format!("network {}\n", q(n));
            }
            encode_known(&k, &mut e);
        }
        "scan" => {
            let nets = decode_scan(&m);
            for n in &nets {
                out += &(network_text(n) + "\n");
            }
            encode_scan(&nets, &mut e);
        }
        _ => return (out + "no decoder\n", None),
    }
    (out, Some(e.pack()))
}

/// `op` applied to `input`.
fn run(op: &str, input: &str) -> String {
    let mut out = format!("{op}\n");
    if op == "scan" {
        for n in parse_scan(input) {
            out += &(network_text(&n) + "\n");
        }
        return out;
    }
    // `<op> "<key>" "<value>"|none`
    let (verb, rest) = op.split_once(' ').unwrap();
    let (key, after) = unq(rest);
    let value = if after == "none" { None } else { Some(unq(after).0) };
    let value = value.as_deref();
    let opt = |v: Option<String>| v.as_deref().map_or("none".to_owned(), q);
    match verb {
        "wpa-edit" => {
            for n in wpa::networks(input) {
                out += &format!("before {}\n", q(&n));
            }
            let edited = wpa::edit(input, &key, value);
            out += &format!("---\n{edited}---\n");
            for n in wpa::networks(&edited) {
                out += &format!("after {}\n", q(&n));
            }
        }
        "sysctl-edit" => {
            out += &format!("value {}\n", opt(sysctl_conf_value(input, &key)));
            let edited = edit_sysctl_conf(input, &key, value);
            out += &format!("---\n{edited}\n---\n");
            out += &format!("value {}\n", opt(sysctl_conf_value(&edited, &key)));
        }
        _ => out += "no operation\n",
    }
    out
}

fn update() -> bool {
    std::env::var_os("ABYSS_WIRE_UPDATE").is_some()
}

/// Compare `got` with Swift's `swift` (or, for a divergent case, with the
/// pinned Rust reading), noting a mismatch in `wrong`.
fn compare(case: &str, swift: &str, got: &str, wrong: &mut Vec<String>) {
    if DIVERGENT.iter().any(|(c, _)| *c == case) {
        let pinned = dir().join(format!("{case}.rust.txt"));
        if update() {
            fs::write(&pinned, got).unwrap();
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

fn cases(suffix: &str) -> Vec<String> {
    let mut c: Vec<String> = fs::read_dir(dir())
        .expect("abyss/tests/wire/settings: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(suffix).map(str::to_owned))
        .collect();
    c.sort();
    c
}

#[test]
fn the_fixtures_are_what_rust_reads_and_writes() {
    let (messages, texts) = (cases(".bin"), cases(".in"));
    assert!(messages.len() >= 80, "only {} messages", messages.len());
    assert!(texts.len() >= 15, "only {} texts", texts.len());
    let mut wrong = Vec::new();
    let mut encoded = 0;
    for case in &messages {
        let bin = fs::read(dir().join(format!("{case}.bin"))).unwrap();
        let txt = fs::read_to_string(dir().join(format!("{case}.txt"))).unwrap();
        let (decode_only, swift) = match txt.strip_prefix("decode-only\n") {
            Some(rest) => (true, rest),
            None => (false, &txt[..]),
        };
        let (got, bytes) = decode(swift.lines().next().unwrap_or(""), &bin);
        compare(case, swift, &got, &mut wrong);
        if !decode_only {
            match bytes {
                Some(b) if b == bin => encoded += 1,
                _ => wrong.push(format!("{case}: encoding what was decoded")),
            }
        }
    }
    for case in &texts {
        let input = fs::read_to_string(dir().join(format!("{case}.in"))).unwrap();
        let swift = fs::read_to_string(dir().join(format!("{case}.txt"))).unwrap();
        compare(case, &swift, &run(swift.lines().next().unwrap(), &input), &mut wrong);
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    eprintln!("{} messages ({encoded} re-encoded), {} texts, {} divergent", messages.len(), texts.len(), DIVERGENT.len());
}
