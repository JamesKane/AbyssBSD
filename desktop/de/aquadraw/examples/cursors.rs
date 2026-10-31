//! The `cursors` golden scene (Scene.swift renderCursorSheetPNG): every
//! cursor-shape name as the theme draws it, its hotspot marked in red.
//!
//!   cargo run --example cursors -- <out.png> [scale]

use abyss_sys::{self as ffi, Context, Surface};
use aquadraw::cursor;
use aquadraw::drawlist::Role;
use aquadraw::scene;
use aquadraw::text::Style;
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
    let (columns, cell_w, cell_h) = (6, 104.0, 58.0);
    let rows = cursor::SHAPE_NAMES.len().div_ceil(columns);
    let (w, h) = ((cell_w * columns as f64) as i32, (cell_h * rows as f64) as i32);
    let cs = Surface::image(ffi::FORMAT_ARGB32, w * scale, h * scale);
    let cr = Context::new(&cs);
    cr.scale(scale as f64, scale as f64);
    let bg = theme.tokens.content_background;
    cr.set_source_rgba(bg.r, bg.g, bg.b, bg.a);
    cr.paint();
    let s = cursor::size(&theme);
    for (i, n) in cursor::SHAPE_NAMES.iter().enumerate() {
        let (x0, y0) = (cell_w * (i % columns) as f64, cell_h * (i / columns) as f64);
        let (cx, cy) = (x0 + (cell_w - s) / 2.0, y0 + 4.0);
        cursor::draw(&mut runner, &theme, n, &cr, cx, cy);
        let (hx, hy) = cursor::hotspot(&mut runner, &theme, n);
        cr.set_source_rgba(1.0, 0.0, 0.0, 1.0);
        cr.rectangle(cx + hx - 1.0, cy + hy - 1.0, 2.0, 2.0);
        cr.fill();
        let fg = theme.tokens.secondary_text;
        runner.text.draw_centered(&cr, n, x0 + cell_w / 2.0, y0 + cell_h - 12.0, fg, 9.0, Style::Regular, Role::Interface);
    }
    drop(cr);
    cs.flush();
    if cs.write_png(out) { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
