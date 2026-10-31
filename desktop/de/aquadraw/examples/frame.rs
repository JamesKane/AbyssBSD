//! The `frame` golden scene (Scene.swift renderFramePNG): the frame undertow
//! paints around a foreign window, from the loaded theme's chrome lists.
//!
//!   cargo run --example frame -- <out.png> [scale]
//!
//! The theme is chosen as every process chooses it: appearance.ini, or
//! `$ABYSS_THEME` / `$ABYSS_THEME_SCHEME`, found on the theme search path.

use abyss_sys::{self as ffi, Context, Surface};
use aquadraw::draw;
use aquadraw::scene;
use aquadraw::theme::{announcement, Theme};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let Some(out) = args.get(1) else {
        eprintln!("usage: frame <out.png> [scale]");
        return ExitCode::from(2);
    };
    let scale: i32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1).max(1);
    let Some(mut runner) = scene::runner(scale) else {
        eprintln!("frame: no fonts (the toy-text fallback is not ported)");
        return ExitCode::FAILURE;
    };
    let mut theme = Theme::default();
    let outcome = theme.load_current(None, Some(&mut runner));
    eprintln!("{}", announcement(&outcome));
    let (w, h) = (480, 300);
    let cs = Surface::image(ffi::FORMAT_ARGB32, w * scale, h * scale);
    let cr = Context::new(&cs);
    cr.scale(scale as f64, scale as f64);
    draw::paint_window_chrome(&mut runner, &theme, &cr, w as f64, h as f64, "Untitled — gedit", true, true);
    cs.flush();
    if cs.write_png(out) { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
