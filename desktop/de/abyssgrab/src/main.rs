//! abyssgrab: capture an output to a PNG (PHASE7.md P7.5), ported from
//! main.swift beside it.
//!
//!     abyssgrab <out.png|out.ppm> [--output N] [--cursor]
//!     abyssgrab --convert <in.png> <out.ppm>
//!     abyssgrab --diff <a.ppm> <b.ppm>
//!
//! `--convert` writes a PNG's pixels as an opaque RGB PPM, so a test can
//! compare a saved picture with the screen byte for byte. `--diff` says
//! where two PPMs of one size differ: "same", or "N pixels differ, within
//! X,Y WxH".
//!
//! The screenshot portal's capture step as its own process, so the portal
//! stays a headless IPC service that links no cairo. Exit codes are the
//! portal's contract (PHASE7.md §6.2): 0 wrote the file, 1 could not
//! capture, 2 bad usage.

use abyss_sys::Surface;
use std::process::exit;
use std::time::Duration;
use surface::Display;

const USAGE: &str = "usage: abyssgrab <out.png> [--output N] [--cursor]";

fn die(s: &str) -> ! {
    eprintln!("abyssgrab: {s}");
    exit(1)
}
fn usage(s: &str) -> ! {
    eprintln!("abyssgrab: {s}");
    exit(2)
}

/// Packed native-endian ARGB words (cairo's ARGB32 and RGB24) as RGB
/// triples behind a PPM header.
fn ppm(w: usize, h: usize, words: impl Iterator<Item = u32>) -> Vec<u8> {
    let mut out = format!("P6\n{w} {h}\n255\n").into_bytes();
    out.reserve(w * h * 3);
    for p in words {
        out.extend_from_slice(&[(p >> 16) as u8, (p >> 8) as u8, p as u8]);
    }
    out
}

fn write_file(path: &str, bytes: &[u8]) {
    if std::fs::write(path, bytes).is_err() {
        die(&format!("could not write {path}"))
    }
}

/// `--convert in.png out.ppm`: a PNG's pixels as a PPM, alpha dropped.
fn convert(input: &str, output: &str) -> ! {
    let Some(s) = Surface::from_png(input) else { die(&format!("cannot read {input} as a PNG")) };
    s.flush();
    let (w, h) = (s.width(), s.height());
    let px = s.argb_pixels(w, h);
    write_file(output, &ppm(w as usize, h as usize, px.into_iter()));
    eprintln!("abyssgrab: converted {input} ({w}x{h}) → {output}");
    exit(0)
}

/// A PPM's size and RGB bytes: "P6", width, height, maxval, then pixels.
fn load_ppm(path: &str) -> (usize, usize, Vec<u8>) {
    let Ok(bytes) = std::fs::read(path) else { die(&format!("cannot read {path}")) };
    let not = || -> ! { die(&format!("{path} is not a PPM")) };
    let mut fields = Vec::new();
    let mut i = 0;
    while fields.len() < 4 {
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        let start = i;
        while i < bytes.len() && !bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if start == i {
            not()
        }
        fields.push(String::from_utf8_lossy(&bytes[start..i]).into_owned());
    }
    i += 1; // the one whitespace byte before the raster
    let (Ok(w), Ok(h)) = (fields[1].parse::<usize>(), fields[2].parse::<usize>()) else { not() };
    if fields[0] != "P6" || i > bytes.len() {
        not()
    }
    (w, h, bytes[i..].to_vec())
}

/// `--diff a.ppm b.ppm`: how many pixels differ, and the box around them.
fn diff(a: &str, b: &str) -> ! {
    let (x, y) = (load_ppm(a), load_ppm(b));
    if x.0 != y.0 || x.1 != y.1 || x.2.len() != y.2.len() {
        die(&format!("{}x{} and {}x{}: not one size", x.0, x.1, y.0, y.1))
    }
    let w = x.0;
    let (mut n, mut x0, mut y0, mut x1, mut y1) = (0usize, usize::MAX, usize::MAX, 0usize, 0usize);
    for (p, (pa, pb)) in x.2.as_chunks::<3>().0.iter().zip(y.2.as_chunks::<3>().0).enumerate() {
        if pa != pb {
            n += 1;
            let (px, py) = (p % w, p / w);
            x0 = x0.min(px);
            y0 = y0.min(py);
            x1 = x1.max(px);
            y1 = y1.max(py);
        }
    }
    if n == 0 {
        println!("same")
    } else {
        println!("{n} pixels differ, within {x0},{y0} {}x{}", x1 - x0 + 1, y1 - y0 + 1)
    }
    exit(0)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() == 3 && args[0] == "--diff" {
        diff(&args[1], &args[2])
    }
    if args.len() == 3 && args[0] == "--convert" {
        convert(&args[1], &args[2])
    }

    let (mut out_path, mut index, mut cursor) = (None::<String>, 0usize, false);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--output" => match it.next().and_then(|n| n.parse::<usize>().ok()) {
                Some(n) => index = n,
                None => usage("--output needs a non-negative index"),
            },
            "--cursor" => cursor = true,
            "-h" | "--help" => {
                println!("{USAGE}");
                exit(0)
            }
            o if o.starts_with('-') => usage(&format!("unknown option '{o}'")),
            path => {
                if out_path.is_some() {
                    usage("only one output file")
                }
                out_path = Some(path.to_string())
            }
        }
    }
    let Some(out_path) = out_path else { usage(USAGE) };

    let Some(display) = Display::connect() else {
        die("cannot connect to a Wayland compositor (is WAYLAND_DISPLAY set?)")
    };
    if !display.can_capture_screen() {
        // The one failure a user can act on: nothing to retry without
        // wlr-screencopy.
        die("this compositor does not offer wlr-screencopy — cannot capture the screen")
    }
    if display.output_count() == 0 {
        die("the compositor advertised no outputs")
    }
    let shot = display.capture_output(index, cursor, Duration::from_secs(5)).unwrap_or_else(|e| die(&e.to_string()));
    let (w, h) = (shot.width, shot.height);

    // `.ppm` is for assertions on a live desktop (P10.4): a header and RGB
    // triples a script can probe with dd and od. PNG is for people.
    if out_path.ends_with(".ppm") {
        let words = shot.pixels.as_chunks::<4>().0.iter().map(|b| u32::from_ne_bytes(*b));
        write_file(&out_path, &ppm(w, h, words));
    } else {
        // RGB24: a screenshot is opaque, and an alpha channel would only
        // invite premultiplication questions.
        let ok = Surface::rgb24(w as i32, h as i32, &shot.pixels).is_some_and(|s| s.write_png(&out_path));
        if !ok {
            die(&format!("could not write {out_path}"))
        }
    }
    eprintln!("abyssgrab: captured output {index} — {w}x{h} → {out_path}");
}
