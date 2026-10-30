//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/facts,
//! written by Swift (Tests/SystemFactsTests/SystemFactsFixtureTests.swift,
//! the specification). Every `.in` is what a command said, or numbers to
//! format, and here it reads as Swift recorded.
//!
//! Where Swift's answer is one of its quirks (RUST.md §1), the case is in
//! DIVERGENT and Rust's own reading is pinned beside it as
//! `<case>.rust.txt`, which this test writes when ABYSS_WIRE_UPDATE is set.

use std::fs;
use std::path::PathBuf;
use system_facts::{format, parse, SystemFacts};

/// Cases where Swift's answer is a Swift-language quirk, and why.
const DIVERGENT: &[(&str, &str)] = &[
    // A CRLF is one Character: Swift's pciconf output is one line.
    ("pci-crlf", "CRLF lines"),
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/facts")
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

fn run(op: &str, input: &str) -> String {
    let mut out = format!("{op}\n");
    let lines: Vec<&str> = input.split('\n').filter(|l| !l.is_empty()).collect();
    let nums = |l: &str| l.split(' ').filter(|w| !w.is_empty()).map(|w| w.parse::<u64>().unwrap()).collect::<Vec<_>>();
    match op {
        "pci" => {
            for d in parse::pci_displays(input) {
                out += &format!("display {}\n", q(&d));
            }
        }
        "drm" => out += &format!("driver {}\n", parse::drm_driver(input).map_or("none".into(), q)),
        "ofw" => out += &format!("model {}\n", parse::ofw_model(input).map_or("none".into(), q)),
        "swap" => out += &parse::swap(input).map_or("swap none\n".into(), |(u, t)| format!("swap {u} {t}\n")),
        "bytes" => {
            for l in lines {
                out += &format!("bytes {l} {}\n", q(&format::bytes(l.parse().unwrap())));
            }
        }
        "usage" => {
            for l in lines {
                let n = nums(l);
                out += &format!("usage {l} {}\n", q(&format::usage(n[0], n[1])));
            }
        }
        "uptime" => {
            for l in lines {
                out += &format!("uptime {l} {}\n", q(&format::uptime(l.parse().unwrap())));
            }
        }
        "frequency" => {
            for l in lines {
                out += &format!("frequency {l} {}\n", q(&format::frequency(l.parse().unwrap())));
            }
        }
        "memory" => {
            for l in lines {
                let n = nums(l);
                out += &format!("memory {l} {}\n", parse::memory_used(n[0], n[1], n[2], n[3], n[4]));
            }
        }
        "sample" => out += &SystemFacts::sample().text(),
        _ => out += "no operation\n",
    }
    out
}

#[test]
fn the_fixtures_are_what_rust_reads() {
    let mut cases: Vec<String> = fs::read_dir(dir())
        .expect("abyss/tests/wire/facts: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(".in").map(str::to_owned))
        .collect();
    cases.sort();
    assert!(cases.len() >= 25, "only {} cases", cases.len());
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
