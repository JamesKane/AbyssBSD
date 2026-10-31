//! abyss-vt: a program on a pseudo-terminal, through Terminal's screen
//! model, with no display (P15.4a). How "vi and top draw correctly" is
//! asserted with no window: the real program on a real pty, its output
//! through `Screen`, keys typed on a script, the screen printed as text.
//!
//! ```text
//! abyss-vt [--rows N] [--cols N] [--step 'KEYS'@MS | --resize ROWSxCOLS@MS]...
//!          [--settle MS] -- PROGRAM ARGS…
//! ```
//!
//! Each `--step` waits until the program has been quiet for MS ms (at most
//! 5 s), then types KEYS, in which `\e`, `\r`, `\n`, `\t` and `\xHH` are
//! escapes; `--resize` gives the terminal a new size (the program gets
//! SIGWINCH). After the last, it waits for quiet once more (`--settle`,
//! default 300 ms) and prints
//!
//! ```text
//! title: …   cursor: ROW,COL   alternate: yes|no   exited: STATUS|no
//! |line 1…|
//! ```
//!
//! every line framed in `|`, so trailing spaces and empty lines show.

use pty::Pty;
use std::collections::BTreeMap;
use std::process::exit;
use std::time::{Duration, Instant};
use terminal::Screen;

fn die(s: &str) -> ! {
    eprintln!("abyss-vt: {s}");
    exit(2)
}

fn unescape(s: &str) -> Vec<u8> {
    let mut out = vec![];
    let mut it = s.bytes();
    while let Some(b) = it.next() {
        if b != b'\\' {
            out.push(b);
            continue;
        }
        match it.next() {
            None => out.push(b),
            Some(b'e') => out.push(0x1B),
            Some(b'r') => out.push(b'\r'),
            Some(b'n') => out.push(b'\n'),
            Some(b't') => out.push(b'\t'),
            Some(b'x') => {
                let h: Vec<u8> = it.by_ref().take(2).collect();
                out.push(std::str::from_utf8(&h).ok().and_then(|h| u8::from_str_radix(h, 16).ok()).unwrap_or(b'?'))
            }
            Some(n) => out.push(n),
        }
    }
    out
}

enum Step {
    Keys(Vec<u8>),
    Resize(usize, usize),
}

/// Read until the program has said nothing for `quiet_ms` (at most 5 s),
/// or has closed the terminal.
fn drain(screen: &mut Screen, pty: &mut Pty, quiet_ms: i32) {
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(5) {
        if !pty.wait(quiet_ms) {
            return; // quiet long enough
        }
        let Some(bytes) = pty.read() else { return }; // closed
        screen.feed(&bytes);
        if !screen.responses.is_empty() {
            let r = std::mem::take(&mut screen.responses);
            pty.write(&r);
        }
    }
}

fn main() {
    let (mut rows, mut cols, mut settle) = (24usize, 80usize, 300i32);
    let mut steps: Vec<(Step, i32)> = vec![];
    let mut args = std::env::args().skip(1);
    let mut program: Vec<String> = vec![];
    let at = |s: &str, what: &str| -> (String, i32) {
        let Some((v, ms)) = s.rsplit_once('@').and_then(|(v, ms)| Some((v.to_string(), ms.parse().ok()?))) else { die(what) };
        (v, ms)
    };
    while let Some(a) = args.next() {
        let mut value = || args.next().unwrap_or_else(|| die(&format!("{a} wants a value")));
        match a.as_str() {
            "--rows" => rows = value().parse().unwrap_or(rows),
            "--cols" => cols = value().parse().unwrap_or(cols),
            "--settle" => settle = value().parse().unwrap_or(settle),
            "--step" => {
                let (keys, ms) = at(&value(), "--step wants KEYS@MS");
                steps.push((Step::Keys(unescape(&keys)), ms))
            }
            "--resize" => {
                let (rc, ms) = at(&value(), "--resize wants ROWSxCOLS@MS");
                let Some((r, c)) = rc.split_once('x').and_then(|(r, c)| Some((r.parse().ok()?, c.parse().ok()?))) else { die("--resize wants ROWSxCOLS@MS") };
                steps.push((Step::Resize(r, c), ms))
            }
            "--" => {
                program = args.by_ref().collect();
                break;
            }
            _ => die(&format!("unknown option {a}")),
        }
    }
    if program.is_empty() {
        die("usage: abyss-vt [--rows N] [--cols N] [--step KEYS@MS]... -- PROGRAM ARGS…")
    }
    let argv: Vec<&str> = program.iter().map(String::as_str).collect();
    let Some(mut pty) = Pty::spawn(&argv, rows, cols, &BTreeMap::new(), None) else { die(&format!("cannot start {} on a pty", program[0])) };
    let mut screen = Screen::new(rows, cols);
    for (step, quiet) in steps {
        drain(&mut screen, &mut pty, quiet);
        match step {
            Step::Keys(k) => {
                pty.write(&k);
            }
            Step::Resize(r, c) => {
                screen.resize(r, c);
                pty.resize(r, c)
            }
        }
    }
    drain(&mut screen, &mut pty, settle);
    std::thread::sleep(Duration::from_millis(100));
    let status = pty.reap();
    let mut out = format!(
        "title: {}   cursor: {},{}   alternate: {}   exited: {}\n",
        screen.title(),
        screen.cursor_row() + 1,
        screen.cursor_col() + 1,
        if screen.using_alternate() { "yes" } else { "no" },
        status.map_or("no".into(), |s| s.to_string())
    );
    for r in 0..screen.rows() {
        out += &format!("|{}|\n", screen.text_row(r))
    }
    print!("{out}")
}
