//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/pool,
//! written by Swift (Tests/PoolConfigTests/PoolWireFixtureTests.swift, the
//! specification). Every `<case>.ini` loads here to what Swift recorded in
//! `<case>.txt`: the sections, keys, values and typed reads, in order, and
//! the same toINI() text. `#` lines are for people, and not compared.
//!
//! Except where Swift's answer is a quirk of Swift's strings (RUST.md §1):
//! Characters, where CRLF is one and a combining mark takes a delimiter
//! along, canonical equivalence, and `UInt64("-0")`. Rust reads bytes. The
//! cases in `DIVERGENT` are those: each must still differ from Swift (so a
//! change shows), and must match its `<case>.rust.txt`, what Rust does,
//! written by this test with ABYSS_WIRE_UPDATE=1. `diff <case>.txt
//! <case>.rust.txt` is the divergence.

use pool_config::{load, Config};
use std::fs;
use std::path::PathBuf;

const DIVERGENT: &[(&str, &str)] = &[
    ("unicode-equivalent-keys", "é and e+U+0301, K and U+212A KELVIN SIGN, are one name each to Swift, two to Rust"),
    ("unicode-nfd-order", "Swift sorts a+U+0301 as á, after f; Rust by bytes, before it"),
    ("crlf", "Swift never ends a line at CRLF (one Character); Rust does"),
    ("crlf-mixed", "Swift never ends a line at CRLF (one Character); Rust does"),
    ("crlf-split-line", "Swift never ends a line at CRLF (one Character); Rust does"),
    ("cr-before-crlf", "Swift never ends a line at CRLF (one Character); Rust does"),
    ("lone-cr", "Rust trims a CR beside a CRLF; Swift sees one Character"),
    ("graphemes", "a combining mark hides a delimiter from Swift, not from Rust"),
    ("greek-question-mark", "U+037E is canonically ; to Swift, a key's first letter to Rust"),
    ("numbers", "Swift's UInt64(\"-0\") is 0; Rust's is no number"),
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/pool")
}

fn hex(s: &str) -> String {
    if s.is_empty() {
        return "-".into();
    }
    s.bytes().map(|x| format!("{x:02x}")).collect()
}

fn opt<T: ToString>(v: Option<T>) -> String {
    v.map_or("-".into(), |v| v.to_string())
}

/// Swift's dump, without its comments.
fn dump(c: &Config) -> Vec<String> {
    let mut out = Vec::new();
    let names = c.section_names();
    out.push(std::iter::once("sections".to_string()).chain(names.iter().map(|s| hex(s))).collect::<Vec<_>>().join(" "));
    out.push(format!("schema_version {}", c.schema_version()));
    for s in &names {
        out.push(format!("section {}", hex(s)));
        for (k, v) in c.pairs(s) {
            out.push(format!(
                "key {} {} u64 {} i64 {} bool {}",
                hex(k),
                hex(v),
                opt(c.uint64(s, k)),
                opt(c.int64(s, k)),
                opt(c.bool(s, k))
            ));
        }
    }
    let ini = c.to_ini();
    out.push(format!("ini {}", hex(&ini)));
    let again = Config::parse(&ini).to_ini();
    out.push(format!("reparsed {}", if again == ini { "same".to_string() } else { hex(&again) }));
    out
}

fn facts(text: &str) -> Vec<String> {
    text.lines().filter(|l| !l.starts_with('#')).map(str::to_owned).collect()
}

#[test]
fn the_fixtures_are_what_rust_reads_and_writes() {
    let d = dir();
    let mut cases: Vec<String> = fs::read_dir(&d)
        .expect("abyss/tests/wire/pool: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(".ini").map(str::to_owned))
        .collect();
    cases.sort();
    assert!(cases.len() >= 29, "only {} cases", cases.len());
    let update = std::env::var_os("ABYSS_WIRE_UPDATE").is_some();
    let (mut same, mut divergent, mut wrong) = (0, 0, Vec::new());
    for case in &cases {
        let swift = facts(&fs::read_to_string(d.join(format!("{case}.txt"))).unwrap());
        let c = load(case, Some(d.to_str().unwrap())).unwrap_or_else(|e| panic!("{case}: {e}"));
        let rust = dump(&c);
        if let Some((_, why)) = DIVERGENT.iter().find(|(n, _)| n == case) {
            assert_ne!(rust, swift, "{case}: now agrees with Swift; take it out of DIVERGENT");
            let path = d.join(format!("{case}.rust.txt"));
            if update {
                fs::write(&path, format!("# {case}, as Rust reads it: {why}\n{}\n", rust.join("\n"))).unwrap();
            }
            let pinned = facts(&fs::read_to_string(&path).expect("run with ABYSS_WIRE_UPDATE=1"));
            assert_eq!(rust, pinned, "{case}: not what {case}.rust.txt says Rust does");
            divergent += 1;
        } else {
            if rust == swift { same += 1 } else { wrong.push(case.as_str()) }
        }
    }
    assert!(wrong.is_empty(), "not what Pool.load makes of the file: {wrong:?}");
    eprintln!("{same} cases as Swift reads them, {divergent} known divergent");
}
