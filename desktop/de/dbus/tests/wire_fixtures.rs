//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/dbus,
//! written by Swift (Tests/DBusTests/DBusWireFixtureTests.swift, the
//! specification). Every message decodes here to the text Swift recorded
//! and, unless marked decode-only, encodes back to Swift's bytes and
//! descriptors. Every address names what Swift read from it.
//!
//! Where Swift's answer is one of its quirks (RUST.md §1), the case is in
//! DIVERGENT and Rust's own reading is pinned beside it as
//! `<case>.rust.txt`, which this test writes when ABYSS_WIRE_UPDATE is set.

use dbus::{parse_address, Message, MessageType, Value};
use std::fs;
use std::path::PathBuf;

/// Cases where Swift reads what is not a value, and why.
const DIVERGENT: &[(&str, &str)] = &[
    // Swift reads a variant's first type and ignores the rest.
    ("variant-of-two", "a variant holds one complete type"),
    // Swift splits any signature: `(` and `()` are an empty struct to it,
    // and an array of `{sss}` is fine while it is empty.
    ("struct-unbalanced", "an unbalanced signature"),
    ("struct-empty", "a struct with no fields"),
    ("close-paren", "an unbalanced signature, said so"),
    ("empty-array-of-nothing", "a dict entry of three types"),
    // Swift has no depth limit; the specification's is 64.
    ("variants-70", "nested deeper than 64"),
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/dbus")
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

fn value_text(v: &Value) -> String {
    let join = |items: &[Value], sep: &str| items.iter().map(value_text).collect::<Vec<_>>().join(sep);
    match v {
        Value::Byte(n) => format!("y {n}"),
        Value::Bool(b) => format!("b {}", u8::from(*b)),
        Value::UInt16(n) => format!("q {n}"),
        Value::Int32(n) => format!("i {n}"),
        Value::UInt32(n) => format!("u {n}"),
        Value::UInt64(n) => format!("t {n}"),
        Value::Double(d) => format!("d {:#x}", d.to_bits()),
        Value::String(s) => format!("s {}", q(s)),
        Value::ObjectPath(s) => format!("o {}", q(s)),
        Value::Signature(s) => format!("g {}", q(s)),
        Value::UnixFd(fd) => format!("h {fd}"),
        Value::Array(elem, items) => format!("a{elem} [{}]", join(items, ", ")),
        Value::Struct(items) => format!("({})", join(items, " ")),
        Value::Variant(inner) => format!("v {}", value_text(inner)),
        Value::DictEntry(k, v) => format!("{{{} {}}}", value_text(k), value_text(v)),
    }
}

fn message_text(m: &Message) -> String {
    let kind = match m.kind {
        MessageType::MethodCall => "method_call",
        MessageType::MethodReturn => "method_return",
        MessageType::Error => "error",
        MessageType::Signal => "signal",
    };
    let mut out = format!("type {kind} flags={} serial={}\n", m.flags.0, m.serial);
    for (name, v) in [("path", &m.path), ("interface", &m.interface), ("member", &m.member), ("error-name", &m.error_name)] {
        if let Some(s) = v {
            out += &format!("{name} {}\n", q(s));
        }
    }
    if let Some(n) = m.reply_serial {
        out += &format!("reply-serial {n}\n");
    }
    for (name, v) in [("destination", &m.destination), ("sender", &m.sender)] {
        if let Some(s) = v {
            out += &format!("{name} {}\n", q(s));
        }
    }
    out += &format!("declared-fds {}\nbody\n", m.declared_fds);
    for v in &m.body {
        out += &(value_text(v) + "\n");
    }
    out
}

/// What `decoder` reads from `bin`, and the bytes the encoder makes of that.
fn decode(decoder: &str, bin: &[u8]) -> (String, Option<Vec<u8>>) {
    let mut out = format!("{decoder}\n");
    if decoder == "frame" {
        return (out + &Message::framed_length(bin).map_or("needs more\n".to_owned(), |n| format!("needs {n}\n")), None);
    }
    let n: i32 = decoder.strip_prefix("message fds=").unwrap().parse().unwrap();
    let fds: Vec<i32> = (0..n).map(|i| 100 + i).collect();
    match Message::decode(bin, &fds) {
        Err(e) => (out + &format!("malformed {}\n", q(&e.0)), None),
        Ok(m) => {
            out += &message_text(&m);
            let (bytes, sent) = m.encode().unwrap();
            out += &format!("sends {}\n", sent.iter().map(i32::to_string).collect::<Vec<_>>().join(" "));
            (out, Some(bytes))
        }
    }
}

fn address(a: &str) -> String {
    match parse_address(a) {
        None => "address\nnone\n".into(),
        Some((p, abstract_)) => format!("address\npath {} abstract={}\n", q(&p), u8::from(abstract_)),
    }
}

fn update() -> bool {
    std::env::var_os("ABYSS_WIRE_UPDATE").is_some()
}

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
        .expect("abyss/tests/wire/dbus: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(suffix).map(str::to_owned))
        .collect();
    c.sort();
    c
}

#[test]
fn the_fixtures_are_what_rust_reads_and_writes() {
    let (messages, texts) = (cases(".bin"), cases(".in"));
    assert!(messages.len() >= 40, "only {} messages", messages.len());
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
        let a = fs::read_to_string(dir().join(format!("{case}.in"))).unwrap();
        let swift = fs::read_to_string(dir().join(format!("{case}.txt"))).unwrap();
        compare(case, &swift, &address(&a), &mut wrong);
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    eprintln!("{} messages ({encoded} re-encoded), {} addresses, {} divergent", messages.len(), texts.len(), DIVERGENT.len());
}
