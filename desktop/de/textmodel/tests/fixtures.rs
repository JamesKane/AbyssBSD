//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/text,
//! written by Swift (Tests/TextModelTests/TextModelFixtureTests.swift, the
//! specification). Every `.in` is an editing script; running it here prints
//! what Swift printed, command by command.
//!
//! Where Swift's answer is one of its quirks (RUST.md §1), or a bug fixed
//! here, the case is in DIVERGENT and Rust's own transcript is pinned beside
//! it as `<case>.rust.txt`, which this test writes when ABYSS_WIRE_UPDATE is
//! set.

use std::fs;
use std::path::PathBuf;
use text_model::{EditKind, Motion, TextLayout, TextModel, TextPosition, TextRange};

/// Cases where Rust's answer is not Swift's, and why.
const DIVERGENT: &[(&str, &str)] = &[
    // Swift compares Characters by canonical equivalence, so a composed é
    // finds a decomposed one; Rust compares the text.
    ("find-unicode", "é and e + U+0301 are different text"),
    // Swift's backward search starts past the last place a match can begin
    // and runs out of tries: with the caret at the end it finds nothing.
    ("find-backward-end", "a Swift bug, fixed (BACKLOG §5)"),
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/text")
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

/// A command's words; a quoted one (which may hold spaces) is Err.
fn words(line: &str) -> Vec<Result<String, String>> {
    let mut out = vec![];
    let mut chars = line.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c == ' ' {
            chars.next();
            continue;
        }
        let mut w = String::new();
        if c == '"' {
            chars.next();
            while let Some(c) = chars.next() {
                match c {
                    '"' => break,
                    '\\' => match chars.next().unwrap() {
                        'n' => w.push('\n'),
                        't' => w.push('\t'),
                        'r' => w.push('\r'),
                        'u' => {
                            chars.next(); // {
                            let hex: String = chars.by_ref().take_while(|&c| c != '}').collect();
                            w.push(char::from_u32(u32::from_str_radix(&hex, 16).unwrap()).unwrap());
                        }
                        e => w.push(e),
                    },
                    c => w.push(c),
                }
            }
            out.push(Err(w));
        } else {
            while let Some(&c) = chars.peek().filter(|&&c| c != ' ') {
                w.push(c);
                chars.next();
            }
            out.push(Ok(w));
        }
    }
    out
}

fn pos(p: TextPosition) -> String {
    format!("{}:{}", p.line, p.column)
}

fn range(r: Option<TextRange>) -> String {
    r.map_or("none".into(), |r| format!("{}-{}", pos(r.start), pos(r.end)))
}

fn state(m: &TextModel) -> String {
    let name = |n: Option<String>| n.as_deref().map_or("none".to_owned(), q);
    format!(
        "= {} anchor={} caret={} dirty={} undo={} redo={}\n",
        q(&m.text()),
        pos(m.anchor()),
        pos(m.caret()),
        u8::from(m.is_dirty()),
        name(m.undo_name()),
        name(m.redo_name())
    )
}

fn motion(s: &str) -> Motion {
    match s {
        "left" => Motion::Left,
        "right" => Motion::Right,
        "word-left" => Motion::WordLeft,
        "word-right" => Motion::WordRight,
        "line-start" => Motion::LineStart,
        "line-end" => Motion::LineEnd,
        "doc-start" => Motion::DocumentStart,
        _ => Motion::DocumentEnd,
    }
}

fn advance(c: &str) -> f64 {
    if c == "\t" {
        4.0
    } else if c.chars().next().unwrap() as u32 >= 0x1100 {
        2.0
    } else {
        1.0
    }
}

fn layout(m: &TextModel, width: Option<f64>) -> TextLayout<'_, fn(&str) -> f64> {
    TextLayout::new(m.lines(), width.expect("a layout command first"), advance as fn(&str) -> f64)
}

/// The script run, as text.
fn run(script: &str) -> String {
    let mut out = String::new();
    let mut m = TextModel::new("");
    let mut width: Option<f64> = None;
    for line in script.split('\n').filter(|l| !l.is_empty()) {
        out += &format!("> {line}\n");
        let w = words(line);
        let word = |i: usize| w[i].as_ref().unwrap_or_else(|e| e).as_str();
        let n = |i: usize| word(i).parse::<i64>().unwrap();
        // A negative position is clamped to the start, as Swift's is.
        let p = |i: usize| TextPosition::new(n(i).max(0) as usize, n(i + 1).max(0) as usize);
        let text = |i: usize| w[i].clone().unwrap_err();
        let has = |flag: &str| w[1..].iter().any(|x| x.as_deref() == Ok(flag));
        match word(0) {
            "text" => {
                m = TextModel::new(&text(1));
                width = None;
                out += &state(&m);
            }
            "caret" => {
                m.set_caret(p(1), has("extend"), false);
                out += &state(&m);
            }
            "select" => {
                m.select(TextRange::new(p(1), p(3)));
                out += &state(&m);
            }
            "all" => {
                m.select_all();
                out += &state(&m);
            }
            "move" => {
                m.move_caret(motion(word(1)), has("extend"));
                out += &state(&m);
            }
            "insert" => {
                let kind = match w.get(2).map(|k| k.as_deref()) {
                    Some(Ok("paste")) => EditKind::Paste,
                    Some(Ok("cut")) => EditKind::Cut,
                    Some(Ok("deleting")) => EditKind::Deleting,
                    Some(Ok("other")) => EditKind::Other(text(3)),
                    _ => EditKind::Typing,
                };
                m.insert(&text(1), kind);
                out += &state(&m);
            }
            "replace" => {
                m.replace(TextRange::new(p(1), p(3)), &text(5), EditKind::Other("Change".into()));
                out += &state(&m);
            }
            "backspace" => {
                m.delete_backward(has("word"));
                out += &state(&m);
            }
            "delete" => {
                m.delete_forward(has("word"));
                out += &state(&m);
            }
            "undo" => {
                m.undo();
                out += &state(&m);
            }
            "redo" => {
                m.redo();
                out += &state(&m);
            }
            "save" => {
                m.mark_saved();
                out += &state(&m);
            }
            "clusters" => {
                for (i, l) in m.lines().iter().enumerate() {
                    out += &format!("line {i}:{}\n", l.clusters().map(|c| format!(" {}", q(c))).collect::<String>());
                }
            }
            "find" => out += &format!("found {}\n", range(m.find(&text(1), has("backward"), !has("case")))),
            "word" => out += &format!("word {}\n", range(Some(m.word_range(p(1))))),
            "line" => out += &format!("line {}\n", range(Some(m.line_range(p(1))))),
            "offset" => out += &format!("offset {}\n", m.offset_of(p(1))),
            "position" => out += &format!("position {}\n", pos(m.position_of_offset(n(1) as usize))),
            "target" => out += &format!("target {}\n", pos(m.target(motion(word(1)), p(2)))),
            "layout" => {
                width = Some(n(1) as f64);
                let rows: String = layout(&m, width).rows.iter().map(|r| format!(" {}:{}-{}", r.line, r.start, r.end)).collect();
                out += &format!("rows{rows}\n");
            }
            "row" => out += &format!("row {}\n", layout(&m, width).row_of(p(1))),
            "x" => out += &format!("x {}\n", layout(&m, width).x_of(p(1)) as i64),
            "at" => out += &format!("at {}\n", pos(layout(&m, width).position(n(1) as isize, n(2) as f64))),
            "vertical" => {
                let v = layout(&m, width).vertical(p(1), n(3) as isize, n(4) as f64);
                out += &format!("vertical {}\n", v.map_or("none".into(), pos));
            }
            _ => out += "no command\n",
        }
    }
    out
}

#[test]
fn the_fixtures_are_what_rust_does() {
    let mut cases: Vec<String> = fs::read_dir(dir())
        .expect("abyss/tests/wire/text: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(".in").map(str::to_owned))
        .collect();
    cases.sort();
    assert!(cases.len() >= 14, "only {} scripts", cases.len());
    let update = std::env::var_os("ABYSS_WIRE_UPDATE").is_some();
    let mut wrong = vec![];
    for case in &cases {
        let script = fs::read_to_string(dir().join(format!("{case}.in"))).unwrap();
        let swift = fs::read_to_string(dir().join(format!("{case}.txt"))).unwrap();
        let got = run(&script);
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
    eprintln!("{} scripts, {} divergent", cases.len(), DIVERGENT.len());
}
