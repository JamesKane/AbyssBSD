//! The `cursors` golden scene (Scene.swift renderCursorSheetPNG): every
//! cursor-shape name as the theme draws it, its hotspot marked in red.
//!
//!   cargo run --example cursors -- <out.png> [scale]

use aquadraw::scene;
use aquadraw::theme::{announcement, Theme};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let Some(out) = args.get(1) else {
        eprintln!("usage: cursors <out.png> [scale]");
        return ExitCode::from(2);
    };
    let scale: i32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1).max(1);
    let Some(mut runner) = scene::runner(scale) else {
        eprintln!("cursors: no fonts (the toy-text fallback is not ported)");
        return ExitCode::FAILURE;
    };
    let mut theme = Theme::default();
    eprintln!("{}", announcement(&theme.load_current(None, Some(&mut runner))));
    if scene::render_cursor_sheet_png(out, scale, &mut runner, &theme) { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
