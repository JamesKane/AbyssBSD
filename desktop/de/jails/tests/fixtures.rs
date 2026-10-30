//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/jails,
//! written by Swift (Tests/JailsTests/JailsFixtureTests.swift, the
//! specification). Every `.in` is a jails.ini, and here it makes the classes,
//! the plans and the violations Swift recorded.
//!
//! Where Swift's answer is one of its quirks (RUST.md §1), the case is in
//! DIVERGENT and Rust's own reading is pinned beside it as
//! `<case>.rust.txt`, which this test writes when ABYSS_WIRE_UPDATE is set.

use jails::{JailClass, JailLayout, JailPlan, JailUser};
use pool_config::Config;
use std::fs;
use std::path::PathBuf;

/// Cases where Swift's answer is a Swift-language quirk, and why.
const DIVERGENT: &[(&str, &str)] = &[
    // Swift's `hasPrefix` is by Character: a component beginning with a
    // combining mark joins the `/` before it, and the mount of a directory
    // in the person's own home is not refused.
    ("combining-home", "the real home is refused, by bytes"),
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/jails")
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

fn list(l: &[String]) -> String {
    format!("[{}]", l.iter().map(|s| q(s)).collect::<Vec<_>>().join(","))
}

fn class_text(c: &JailClass) -> String {
    format!(
        "class {} system={} devices={} network={} wayland={} agent={} budget={} model={} vocabulary={} fetch={}\n",
        q(&c.name),
        list(&c.system),
        list(&c.devices),
        c.network.as_str(),
        b(c.wayland),
        b(c.agent),
        c.budget,
        q(&c.model),
        b(c.vocabulary),
        b(c.fetch)
    )
}

fn plan_text(p: &JailPlan) -> String {
    let mut out = format!("plan {} root={}\n", q(&p.name), q(&p.root));
    for m in &p.mounts {
        out += &format!("mount {} {} {} {}\n", m.kind.as_str(), q(&m.source), q(&m.target), if m.read_only { "ro" } else { "rw" });
    }
    out += &format!("unhide {}\n", list(&p.unhide));
    for d in &p.dirs {
        out += &format!("dir {} {} {:o}\n", q(&d.path), d.uid, d.mode);
    }
    out += &format!("accounts {}\n", q(&p.accounts));
    for (path, contents) in &p.files {
        out += &format!("file {} {}\n", q(path), q(contents));
    }
    for (s, t) in &p.copies {
        out += &format!("copy {} {}\n", q(s), q(t));
    }
    for (k, v) in &p.params {
        out += &format!("param {}{}\n", q(k), v.as_deref().map_or(String::new(), |v| format!(" {}", q(v))));
    }
    for (k, v) in &p.env {
        out += &format!("env {} {}\n", q(k), q(v));
    }
    out + &format!("home {} dataset={}\n", q(&p.home_source), p.home_dataset.as_deref().map_or("none".into(), q))
}

fn run(op: &str, ini: &str) -> String {
    let w: Vec<&str> = op.split(' ').collect();
    let user = JailUser { name: w[1].into(), uid: w[2].parse().unwrap(), gid: w[3].parse().unwrap() };
    let pool = (w[5] != "none").then_some(w[5]);
    let mut out = format!("{op}\n");
    for c in JailClass::table(Some(&Config::parse(ini))) {
        let p = JailPlan::make(&c, &user, pool, &JailLayout::default());
        out += &(class_text(&c) + &plan_text(&p));
        for v in p.violations(&c, w[4]) {
            out += &format!("violation {}\n", q(&v));
        }
    }
    out
}

#[test]
fn the_fixtures_are_what_rust_makes() {
    let mut cases: Vec<String> = fs::read_dir(dir())
        .expect("abyss/tests/wire/jails: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(".in").map(str::to_owned))
        .collect();
    cases.sort();
    assert!(cases.len() >= 7, "only {} cases", cases.len());
    let update = std::env::var_os("ABYSS_WIRE_UPDATE").is_some();
    let mut wrong = vec![];
    for case in &cases {
        let ini = fs::read_to_string(dir().join(format!("{case}.in"))).unwrap();
        let swift = fs::read_to_string(dir().join(format!("{case}.txt"))).unwrap();
        let got = run(swift.lines().next().unwrap(), &ini);
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
