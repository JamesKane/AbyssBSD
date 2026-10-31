//! `svg2dl`: turn an SVG icon into a draw list, at build time (PHASE11
//! P11.8), ported from main.swift beside it.
//!
//!     svg2dl NAME FILE.svg >> themes/<theme>/icons/<set>.dl
//!
//! The subset and the reasons are in de/svgimport. It refuses what it
//! cannot convert, by name, and exits 1.

use std::fs::File;
use std::io::{ErrorKind, Read, Write};
use std::process::exit;

fn die(m: &str) -> ! {
    eprintln!("svg2dl: {m}");
    exit(1)
}

fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 3 {
        die("usage: svg2dl NAME FILE.svg");
    }
    let name = args[1].to_string_lossy();
    let shown = args[2].to_string_lossy();
    let Ok(mut f) = File::open(&args[2]) else { die(&format!("cannot read {shown}")) };
    // As the Swift reads with fread: a read error is the end of the data
    // (so a directory opens and reads as empty).
    let mut bytes = Vec::new();
    let mut buf = [0u8; 65536];
    loop {
        match f.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => bytes.extend_from_slice(&buf[..n]),
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    drop(f);
    match svgimport::draw_list(&name, &String::from_utf8_lossy(&bytes)) {
        Ok(list) => {
            let mut out = std::io::stdout().lock();
            if out.write_all(list.as_bytes()).and_then(|_| out.flush()).is_err() {
                exit(1);
            }
        }
        Err(e) => die(&format!("{shown}: {e}")),
    }
}
