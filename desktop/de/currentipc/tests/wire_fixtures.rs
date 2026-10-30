//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/current,
//! written by Swift (Tests/CurrentIPCTests/WireFixtureTests.swift, the
//! specification). Every case decodes here to the fields Swift recorded and,
//! unless marked decode-only, encodes back to Swift's bytes; every malformed
//! frame is refused. `#` lines are for people, and not compared.

use current_ipc::{Error, Msg, Value};
use std::fs::{self, File};
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::path::PathBuf;

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/current")
}

fn hex(b: &[u8]) -> String {
    if b.is_empty() {
        return "-".into();
    }
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex(s: &str) -> Vec<u8> {
    if s == "-" {
        return Vec::new();
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

fn dev_null(n: usize) -> Vec<OwnedFd> {
    (0..n).map(|_| File::open("/dev/null").unwrap().into()).collect()
}

/// Swift's dump without its comments: the fields, with each descriptor as
/// its index among those the message arrived with.
fn dump(m: &Msg, fds: &[RawFd], decode_only: bool) -> Vec<String> {
    let mut out = Vec::new();
    if decode_only {
        out.push("decode-only".to_string());
    }
    out.push(format!("fds {}", fds.len()));
    for (name, value) in m.fields() {
        let n = hex(name.as_bytes());
        out.push(match value {
            Value::String(s) => format!("string {n} {}", hex(s.as_bytes())),
            Value::UInt64(v) => format!("uint64 {n} {v}"),
            Value::Bool(b) => format!("bool {n} {}", *b as u8),
            Value::Bytes(b) => format!("bytes {n} {}", hex(b)),
            Value::Fd(f) => format!("fd {n} {}", fds.iter().position(|x| x == f).map_or(-1, |i| i as i64)),
        });
    }
    out
}

/// The message a fixture's text describes, its fd fields on `fds`.
fn parse(lines: &[String], fds: &[RawFd]) -> Msg {
    let mut m = Msg::new();
    for l in lines {
        let w: Vec<&str> = l.split(' ').collect();
        if w.len() != 3 {
            continue;
        }
        let name = String::from_utf8(unhex(w[1])).unwrap();
        match w[0] {
            "string" => m.set_string(&name, &String::from_utf8(unhex(w[2])).unwrap()),
            "uint64" => m.set_u64(&name, w[2].parse().unwrap()),
            "bool" => m.set_bool(&name, w[2] == "1"),
            "bytes" => m.set_bytes(&name, &unhex(w[2])),
            "fd" => m.set_fd(&name, fds[w[2].parse::<usize>().unwrap()]),
            _ => {}
        }
    }
    m
}

fn fds_line(lines: &[String]) -> usize {
    lines.iter().find_map(|l| l.strip_prefix("fds ")).map_or(0, |n| n.parse().unwrap())
}

#[test]
fn the_fixtures_are_what_rust_reads_and_writes() {
    let mut cases: Vec<String> = fs::read_dir(dir())
        .expect("abyss/tests/wire/current: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(".bin").map(str::to_owned))
        .collect();
    cases.sort();
    assert!(cases.len() >= 21, "only {} cases", cases.len());
    let (mut valid, mut refused) = (0, 0);
    for case in &cases {
        let bin = fs::read(dir().join(format!("{case}.bin"))).unwrap();
        if let Ok(err) = fs::read_to_string(dir().join(format!("{case}.err"))) {
            let lines: Vec<String> = err.lines().map(str::to_owned).collect();
            let r = Msg::unpack(&bin, dev_null(fds_line(&lines)));
            assert!(matches!(r, Err(Error::Malformed(_))), "{case}: {r:?}, not malformed");
            refused += 1;
            continue;
        }
        let txt = fs::read_to_string(dir().join(format!("{case}.txt"))).unwrap();
        let lines: Vec<String> = txt.lines().filter(|l| !l.starts_with('#')).map(str::to_owned).collect();
        let decode_only = lines.iter().any(|l| l == "decode-only");
        let fds = dev_null(fds_line(&lines));
        let raw: Vec<RawFd> = fds.iter().map(|f| f.as_raw_fd()).collect();
        let m = Msg::unpack(&bin, fds).unwrap_or_else(|e| panic!("{case}: {e}"));
        assert_eq!(dump(&m, &raw, decode_only), lines, "{case}: decoding the bytes");
        if !decode_only {
            assert_eq!(parse(&lines, &raw).pack(), bin, "{case}: encoding the fields");
        }
        valid += 1;
    }
    assert_eq!(valid + refused, cases.len());
    eprintln!("{valid} decoded and re-encoded, {refused} refused");
}
