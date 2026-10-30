//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/install,
//! written by Swift (Tests/InstallRunTests/InstallWireFixtureTests.swift,
//! the specification). Every message decodes here to the text Swift
//! recorded (for `check`: the plan, the machine, the refusals and the step
//! list `abyss-install` would run) and, unless marked decode-only, encodes
//! back to Swift's bytes. Every `.in` is read to the text Swift recorded.
//!
//! Where Swift's answer is one of its quirks (RUST.md §1), the case is in
//! DIVERGENT and Rust's own reading is pinned beside it as
//! `<case>.rust.txt`, which this test writes when ABYSS_WIRE_UPDATE is set.

use current_ipc::Msg;
use install::{compile, keymaps, problems, render, DiskInventory, InstallPlan};
use install_wire::{decode_event, decode_inventory, decode_plan, encode_event, encode_inventory, encode_plan, RunEvent};
use std::fs;
use std::path::PathBuf;

/// Cases where Swift's answer is a Swift-language quirk, and why.
const DIVERGENT: &[(&str, &str)] = &[
    // Swift's `isLetter` is Unicode's; ZFS's letters are ASCII, so Swift
    // passes a name `zpool create` refuses after `gpart` has run.
    ("check-pool-unicode", "a pool name ZFS refuses"),
    // A Character is a grapheme: to Swift, e + U+0308 is one letter.
    ("check-decomposed-name", "a combining mark is quoted"),
    // A CRLF is one Character: Swift's rc.conf is one line.
    ("keymap-crlf", "CRLF lines"),
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/install")
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

fn plan_text(p: &InstallPlan) -> String {
    let mut out = format!(
        "plan {} pool={} esp={} swap={} dist={} mountpoint={} hostname={} timezone={} keymap={} rootpw={} erase={} autologin={}\n",
        q(&p.disk),
        q(&p.pool_name),
        p.esp_bytes,
        p.swap_bytes,
        q(&p.dist_directory),
        q(&p.mountpoint),
        q(&p.hostname),
        q(&p.timezone),
        q(&p.keymap),
        q(&p.root_password_hash),
        b(p.erase_existing_data),
        b(p.auto_login)
    );
    for s in &p.sets {
        out += &format!("set {}\n", q(s));
    }
    for a in &p.accounts {
        out += &format!("account {} {} {} groups={} shell={}\n", q(&a.name), q(&a.full_name), q(&a.password_hash), list(&a.groups), q(&a.shell));
    }
    out
}

fn inventory_text(inv: &DiskInventory) -> String {
    let mut out = String::new();
    for d in &inv.disks {
        out += &format!(
            "disk {} bytes={} descr={} mounted={} root={} pools={} kinds={} free={} table={}\n",
            q(&d.name),
            d.bytes,
            q(&d.description),
            list(&d.mounted_at),
            b(d.holds_running_root),
            list(&d.existing_pools),
            list(&d.partition_kinds),
            d.free_bytes,
            b(d.has_partition_table)
        );
    }
    for p in &inv.imported_pools {
        out += &format!("pool {}\n", q(p));
    }
    out + &inv.machine.as_ref().map_or("machine none\n".to_owned(), |m| format!("machine {} {}\n", q(&m.maker), q(&m.product)))
}

fn event_text(e: Option<&RunEvent>) -> String {
    match e {
        None => "none".into(),
        Some(RunEvent::Starting { index, total, what, destructive }) => format!("starting {index} {total} {} destructive={}", q(what), b(*destructive)),
        Some(RunEvent::Ok { index }) => format!("ok {index}"),
        Some(RunEvent::Failed { index, what, why, ignored }) => format!("failed {index} {} {} ignored={}", q(what), q(why), b(*ignored)),
        Some(RunEvent::Finished { ok, error }) => format!("finished {} {}", b(*ok), q(error)),
    }
}

/// What `decoder` reads from `bin`, and the bytes the encoder makes of that
/// (None when it read nothing to encode).
fn decode(decoder: &str, bin: &[u8]) -> (String, Option<Vec<u8>>) {
    let mut out = format!("{decoder}\n");
    let Ok(m) = Msg::unpack(bin, vec![]) else { return (out + "malformed\n", None) };
    let mut e = Msg::new();
    match decoder {
        "check" => {
            let (p, inv) = (decode_plan(&m), decode_inventory(&m));
            out += &(plan_text(&p) + &inventory_text(&inv));
            let refusals = problems(&p, &inv);
            for r in &refusals {
                out += &format!("problem {}\n", q(&r.message()));
            }
            if refusals.is_empty() {
                out += &format!("steps\n{}", render(&compile(&p, &inv).unwrap()));
            }
            encode_plan(&p, &mut e);
            encode_inventory(&inv, &mut e);
        }
        "inventory" => {
            let inv = decode_inventory(&m);
            out += &inventory_text(&inv);
            encode_inventory(&inv, &mut e);
        }
        "event" => {
            let ev = decode_event(&m);
            out += &(event_text(ev.as_ref()) + "\n");
            return (out, ev.map(|ev| encode_event(&ev).pack()));
        }
        _ => return (out + "no decoder\n", None),
    }
    (out, Some(e.pack()))
}

fn xkb_text(name: &str) -> String {
    match keymaps::xkb(name) {
        None => format!("xkb {} none\n", q(name)),
        Some((k, exact)) => format!(
            "xkb {} layout={} variant={} exact={} name={}\n",
            q(name),
            q(&k.layout),
            q(&k.variant),
            b(exact),
            q(&keymaps::display_name(name))
        ),
    }
}

/// `op` applied to `input`.
fn run(op: &str, input: &str) -> String {
    let mut out = format!("{op}\n");
    match op {
        "keymap" => match keymaps::last_assignment("keymap", input) {
            None => out += "assignment none\n",
            Some(v) => out += &format!("assignment {}\n{}", q(&v), xkb_text(&v)),
        },
        "xkb" => {
            for name in input.split('\n').filter(|n| !n.is_empty()) {
                out += &xkb_text(name);
            }
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
        .expect("abyss/tests/wire/install: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(suffix).map(str::to_owned))
        .collect();
    c.sort();
    c
}

#[test]
fn the_fixtures_are_what_rust_reads_and_writes() {
    let (messages, texts) = (cases(".bin"), cases(".in"));
    assert!(messages.len() >= 50, "only {} messages", messages.len());
    assert!(texts.len() >= 10, "only {} texts", texts.len());
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
