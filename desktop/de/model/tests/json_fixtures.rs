//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/json,
//! written by Swift (Tests/ModelTests/JSONFixtureTests.swift, the
//! specification). Every `.in` parses here to what Swift wrote back, or is
//! refused at the same byte for the same reason; every double is written as
//! Swift writes it.
//!
//! Where Swift's answer is one of its quirks (RUST.md §1), the case is in
//! DIVERGENT and Rust's own reading is pinned beside it as
//! `<case>.rust.txt`, which this test writes when ABYSS_WIRE_UPDATE is set.

use model::Json;
use std::fs;
use std::path::PathBuf;

/// What Swift's `Double(_:)` and `UInt32(_:radix:)` accept and JSON does not.
const DIVERGENT: &[(&str, &str)] = &[
    ("plus-one", "a sign JSON does not have"),
    ("leading-zero", "a leading zero"),
    ("leading-dot", "no integer part"),
    ("trailing-dot", "no fraction digits"),
    ("signed-escape", "a sign in a \\u escape"),
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/json")
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

fn run(bytes: &[u8]) -> String {
    match Json::parse(bytes) {
        Ok(j) => format!("json\nparsed {}\n", j.text()),
        Err(e) => format!("json\nmalformed {} {}\n", e.offset, q(&e.why)),
    }
}

#[test]
fn the_fixtures_are_what_rust_reads_and_writes() {
    let mut cases: Vec<String> = fs::read_dir(dir())
        .expect("abyss/tests/wire/json: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(".in").map(str::to_owned))
        .filter(|c| c != "numbers")
        .collect();
    cases.sort();
    assert!(cases.len() >= 30, "only {} cases", cases.len());
    let update = std::env::var_os("ABYSS_WIRE_UPDATE").is_some();
    let mut wrong = vec![];
    for case in &cases {
        let input = fs::read(dir().join(format!("{case}.in"))).unwrap();
        let swift = fs::read_to_string(dir().join(format!("{case}.txt"))).unwrap();
        let got = run(&input);
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
    // The doubles, by bit pattern.
    let numbers = fs::read_to_string(dir().join("numbers.in")).unwrap();
    let mut got = String::from("numbers\n");
    for l in numbers.lines() {
        let bits = u64::from_str_radix(l.strip_prefix("0x").unwrap(), 16).unwrap();
        got += &format!("number {l} {}\n", Json::Number(f64::from_bits(bits)).text());
    }
    let swift = fs::read_to_string(dir().join("numbers.txt")).unwrap();
    for (g, s) in got.lines().zip(swift.lines()) {
        if g != s {
            wrong.push(format!("numbers: swift {s}, rust {g}"));
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    eprintln!("{} texts and {} doubles, {} divergent", cases.len(), numbers.lines().count(), DIVERGENT.len());
}
