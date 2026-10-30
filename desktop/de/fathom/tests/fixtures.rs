//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/fathom,
//! written by Swift (Tests/FathomTests/FathomFixtureTests.swift, the
//! specification). Every `.in` is captured text a probe reads, and the
//! probe here finds what Swift recorded.
//!
//! Where Swift's answer is one of its quirks (RUST.md §1), the case is in
//! DIVERGENT and Rust's own reading is pinned beside it as
//! `<case>.rust.txt`, which this test writes when ABYSS_WIRE_UPDATE is set.

use fathom::*;
use std::fs;
use std::path::PathBuf;

/// Cases where Swift's answer is a Swift-language quirk, and why.
const DIVERGENT: &[(&str, &str)] = &[
    // A CRLF is one Character: Swift's kldstat is one line, ending in no `.ko`.
    ("modules-crlf", "CRLF lines"),
    // ASCII folding by Character drops a whole grapheme; by char, the accent.
    ("render-decomposed", "e + U+0301 folds to e"),
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/fathom")
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

fn text(r: &ProbeResult) -> String {
    format!("{} {}\n", r.status.as_str(), q(&r.detail))
}

/// The two lines of a maker-and-product input.
fn pair(input: &str) -> (&str, &str) {
    input.split_once('\n').unwrap_or((input, ""))
}

fn status(s: &str) -> ProbeStatus {
    *ProbeStatus::ALL.iter().find(|st| st.as_str() == s).unwrap()
}

/// `op` applied to `input`.
fn run(op: &str, input: &str) -> String {
    let out = format!("{op}\n");
    let (word, arg) = op.split_once(' ').map_or((op, None), |(w, a)| (w, Some(a)));
    let lines: Vec<&str> = input.split('\n').filter(|l| !l.is_empty()).collect();
    out + &match word {
        "boot" => text(&probe_boot_method(Some(input), arg.map(|a| &a[1..a.len() - 1]))),
        "gpu" => text(&probe_gpu(Some(&lines))),
        "modules" => text(&probe_modules(Some(input))),
        "network" => text(&probe_network(Some(input))),
        "wifi" => text(&probe_wifi(Some(input), None)),
        "audio" => text(&probe_audio(Some(input))),
        "frame" => text(&probe_frame_contract(Some(input))),
        "machine" => {
            let (mk, pr) = pair(input);
            text(&probe_machine(Some(mk), Some(pr)))
        }
        "filename" => {
            let (mk, pr) = pair(input);
            format!("file {}\n", q(&report_filename(Some(mk), Some(pr))))
        }
        "cpu" => text(&probe_cpu(Some(input), arg.and_then(|a| a.parse().ok()))),
        "memory" => text(&probe_memory(input.parse().ok())),
        "disks" => {
            let facts: Vec<DiskFact> = lines
                .iter()
                .map(|l| {
                    let f: Vec<&str> = l.split('\t').collect();
                    DiskFact { name: f[0].into(), bytes: f[1].parse().unwrap(), model: f.get(2).copied().unwrap_or("").into() }
                })
                .collect();
            text(&probe_disks(&facts))
        }
        "render" => {
            let results = lines
                .iter()
                .map(|l| {
                    let f: Vec<&str> = l.splitn(3, '\t').collect();
                    ProbeResult::new(f[0], status(f[1]), f[2])
                })
                .collect();
            render_text(&FathomReport::new(results), "Fathom")
        }
        _ => "no operation\n".into(),
    }
}

#[test]
fn the_fixtures_are_what_rust_reads() {
    let mut cases: Vec<String> = fs::read_dir(dir())
        .expect("abyss/tests/wire/fathom: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(".in").map(str::to_owned))
        .collect();
    cases.sort();
    assert!(cases.len() >= 60, "only {} cases", cases.len());
    let update = std::env::var_os("ABYSS_WIRE_UPDATE").is_some();
    let mut wrong = Vec::new();
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
    eprintln!("{} texts, {} divergent", cases.len(), DIVERGENT.len());
}
