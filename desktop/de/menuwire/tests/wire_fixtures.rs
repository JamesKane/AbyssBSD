//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/menu,
//! written by Swift (Tests/MenuModelTests/MenuWireFixtureTests.swift, the
//! specification). Every case decodes here to the text Swift recorded (the
//! vocabulary, or the error and its reason) and, unless marked decode-only,
//! encodes back to Swift's bytes. service-names.txt is `service_name` over
//! Swift's list of application names.
//!
//! Where Swift's answer is one of its quirks (RUST.md §1), the case is in
//! DIVERGENT and Rust's own reading is pinned beside it as
//! `<case>.rust.txt`, which this test writes when ABYSS_WIRE_UPDATE is set.

use current_ipc::Msg;
use menu_model::{Command, CommandResult, Enablement, KeyEquivalent, Menu, MenuBarModel, MenuItem};
use menu_wire::fixtures::{describe_reply_with, key_name};
use menu_wire::Error;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

/// Cases where Swift's answer is a Swift-language quirk, and why.
const DIVERGENT: &[(&str, &str)] = &[
    // One Swift Character, but two chars: not a single key.
    ("describe-decomposed-key", "a letter and a combining accent"),
    // A character at a time, not a Character at a time; and Rust's
    // lowercasing knows a word-final sigma.
    ("service-names", "decomposed accents, İ, ς, emoji sequences"),
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/menu")
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

/// `q` undone, for the names in service-names.txt; and what follows it.
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
            '"' => return (out, rest.trim_start()),
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

fn enablement(e: &Enablement) -> String {
    match e {
        Enablement::Enabled => "enabled".into(),
        Enablement::Disabled(why) => format!("disabled {}", q(why)),
    }
}

fn key(k: &KeyEquivalent) -> String {
    format!("{} {} {}", k.modifiers().0, q(&key_name(k.key())), q(&k.display()))
}

fn menu(m: &Menu, states: &HashMap<String, Enablement>, indent: &str, out: &mut String) {
    for item in &m.items {
        match item {
            MenuItem::Command(c) => {
                let i = format!("{indent}  ");
                out.push_str(&format!("{indent}command {} {}\n", q(&c.verb), q(&c.title)));
                out.push_str(&format!("{i}summary {}\n", q(&c.summary)));
                if let Some(k) = &c.key {
                    out.push_str(&format!("{i}key {}\n", key(k)));
                }
                for k in &c.alternate_keys {
                    out.push_str(&format!("{i}alternate {}\n", key(k)));
                }
                for a in &c.arguments {
                    out.push_str(&format!("{i}argument {} {} {}\n", q(&a.name), a.ty.as_str(), q(&a.summary)));
                }
                if c.writes {
                    out.push_str(&format!("{i}writes\n"));
                }
                if let Some(e) = states.get(&c.verb) {
                    out.push_str(&format!("{i}{}\n", enablement(e)));
                }
            }
            MenuItem::Separator => out.push_str(&format!("{indent}separator\n")),
            MenuItem::Submenu(sub) => {
                out.push_str(&format!("{indent}submenu {}\n", q(&sub.title)));
                menu(sub, states, &format!("{indent}  "), out);
            }
        }
    }
}

/// What `decoder` reads from `bin`, and the bytes the encoder makes of that
/// (None for an error).
fn decode(decoder: &str, bin: &[u8]) -> (String, Option<Vec<u8>>) {
    let mut out = format!("{decoder}\n");
    match read(decoder, bin, &mut out) {
        Ok(bytes) => (out, Some(bytes)),
        Err(Error::Ipc(current_ipc::Error::Malformed(why))) => (out + &format!("malformed {}\n", q(&why)), None),
        Err(Error::Service(why)) => (out + &format!("service {}\n", q(&why)), None),
        Err(e) => (out + &format!("error {}\n", q(&e.to_string())), None),
    }
}

fn read(decoder: &str, bin: &[u8], out: &mut String) -> Result<Vec<u8>, Error> {
    let m = Msg::unpack(bin, vec![])?;
    match decoder {
        "describe" => {
            let (model, states) = menu_wire::decode_describe(&m)?;
            out.push_str(&format!("app {}\n", q(&model.app_name)));
            for mm in &model.menus {
                out.push_str(&format!("menu {}\n", q(&mm.title)));
                menu(mm, &states, "  ", out);
            }
            Ok(describe_reply_with(&model, &|c| states.get(&c.verb).cloned()).pack())
        }
        "validate" => {
            let mut v: Vec<(String, Enablement)> = menu_wire::decode_validate(&m)?.into_iter().collect();
            v.sort_by(|a, b| a.0.cmp(&b.0));
            for (verb, e) in &v {
                out.push_str(&format!("{} {}\n", q(verb), enablement(e)));
            }
            let items = v.iter().map(|(verb, _)| MenuItem::Command(Command::new(verb, "", ""))).collect();
            let model = MenuBarModel::new("", vec![Menu::new("", items)]);
            let states: HashMap<_, _> = v.into_iter().collect();
            Ok(menu_wire::validate_reply(&model, &|c| states[&c.verb].clone()).pack())
        }
        "activate" => {
            let verb = m.string("verb").ok_or_else(|| Error::Ipc(current_ipc::Error::Malformed("activate with no verb".into())))?;
            let args = menu_wire::arguments(&m)?;
            out.push_str(&format!("verb {}\n", q(verb)));
            for (k, v) in &args {
                out.push_str(&format!("arg {} {}\n", q(k), q(v)));
            }
            Ok(menu_wire::activate_request(verb, &args).pack())
        }
        "result" => {
            let r = menu_wire::decode_result(&m)?;
            match &r {
                CommandResult::Ok(None) => out.push_str("ok\n"),
                CommandResult::Ok(Some(v)) => out.push_str(&format!("ok {}\n", q(v))),
                CommandResult::Refused(why) => out.push_str(&format!("refused {}\n", q(why))),
            }
            Ok(menu_wire::result_reply(&r).pack())
        }
        _ => {
            out.push_str("no decoder\n");
            Err(Error::Service("no decoder".into()))
        }
    }
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
        wrong.push(format!("{case}: decoding the bytes\n--- swift\n{swift}--- rust\n{got}"));
    }
}

#[test]
fn the_fixtures_are_what_rust_reads_and_writes() {
    let mut cases: Vec<String> = fs::read_dir(dir())
        .expect("abyss/tests/wire/menu: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(".bin").map(str::to_owned))
        .collect();
    cases.sort();
    assert!(cases.len() >= 30, "only {} cases", cases.len());
    let mut wrong = Vec::new();
    let mut encoded = 0;
    for case in &cases {
        let bin = fs::read(dir().join(format!("{case}.bin"))).unwrap();
        let txt = fs::read_to_string(dir().join(format!("{case}.txt"))).unwrap();
        let (decode_only, swift) = match txt.strip_prefix("decode-only\n") {
            Some(rest) => (true, rest),
            None => (false, &txt[..]),
        };
        let decoder = swift.lines().next().unwrap_or("");
        let (got, bytes) = decode(decoder, &bin);
        compare(case, swift, &got, &mut wrong);
        if !decode_only {
            match bytes {
                Some(b) if b == bin => encoded += 1,
                Some(_) => wrong.push(format!("{case}: encoding what was decoded")),
                None => wrong.push(format!("{case}: an error case must be decode-only")),
            }
        }
    }

    let swift = fs::read_to_string(dir().join("service-names.txt")).unwrap();
    let got: String = swift
        .lines()
        .map(|l| {
            let (app, rest) = unq(l);
            let pid: i32 = rest.split(' ').next().unwrap().parse().unwrap();
            format!("{} {pid} {}\n", q(&app), q(&menu_wire::service_name(&app, pid)))
        })
        .collect();
    compare("service-names", &swift, &got, &mut wrong);

    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    eprintln!("{} cases decoded, {encoded} re-encoded, {} divergent", cases.len() + 1, DIVERGENT.len());
}
