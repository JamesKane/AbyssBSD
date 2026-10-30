//! The `drawlist` golden scene (Scene.swift renderDrawListPNG), drawn by the
//! Rust draw-list interpreter: RUST.md R0's proof, kept under the golden gate
//! by abyss/tests/golden-rust.sh.
//!
//!   cargo run --example drawlist -- <list.dl> <out.png> [scale]

use abyss_sys::{self as ffi, Context, Surface};
use aquadraw::drawlist::DrawListFile;
use aquadraw::scene;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 || args.len() > 4 {
        eprintln!("usage: drawlist <list.dl> <out.png> [scale]");
        return ExitCode::from(2);
    }
    let (list_file, out) = (&args[1], &args[2]);
    let scale: i32 = match args.get(3).map(|s| s.parse::<i32>()) {
        None => 1,
        Some(Ok(s)) => s.max(1),
        Some(Err(_)) => {
            eprintln!("drawlist: scale wants an integer");
            return ExitCode::from(2);
        }
    };
    let text = match std::fs::read_to_string(list_file) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("drawlist: {list_file}: {e}");
            return ExitCode::FAILURE;
        }
    };
    let file = match DrawListFile::parse(&text) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("drawlist: {list_file}: {e}");
            return ExitCode::FAILURE;
        }
    };
    let Some(mut runner) = scene::runner(scale) else {
        eprintln!("drawlist: no fonts (the toy-text fallback is not ported)");
        return ExitCode::FAILURE;
    };
    let cs = Surface::image(ffi::FORMAT_ARGB32, scene::WIDTH * scale, scene::HEIGHT * scale);
    let cr = Context::new(&cs);
    scene::drawlist(&cr, scale, &file, &mut runner);
    cs.flush();
    if cs.write_png(out) {
        ExitCode::SUCCESS
    } else {
        eprintln!("drawlist: could not write {out}");
        ExitCode::FAILURE
    }
}
