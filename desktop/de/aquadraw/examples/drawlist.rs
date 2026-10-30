//! The `drawlist` golden scene (Scene.swift renderDrawListPNG), drawn by the
//! Rust draw-list interpreter: RUST.md R0's proof, kept under the golden gate
//! by abyss/tests/golden-rust.sh.
//!
//!   cargo run --example drawlist -- <list.dl> <out.png> [scale]

use abyss_sys::{self as ffi, Context, Surface};
use aquadraw::drawlist::{DrawListFile, DrawState, Role};
use aquadraw::runner::{DrawContext, Rect, Runner};
use aquadraw::text::Text;
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
    let Some(mut fonts) = Text::new(scale) else {
        eprintln!("drawlist: no fonts (the toy-text fallback is not ported)");
        return ExitCode::FAILURE;
    };
    // What AquaDemo's Theme.use does with the aqua theme's [fonts]: none of
    // these is installed, so every role draws with CText's default chain.
    fonts.use_roles(&[
        (Role::Interface, "Lucida Grande"),
        (Role::Chrome, "Lucida Grande"),
        (Role::Readout, "Lucida Grande"),
        (Role::Mono, "Monaco"),
    ]);
    let mut runner = Runner::new(fonts);

    let (w, h) = (520, 200);
    let cs = Surface::image(ffi::FORMAT_ARGB32, w * scale, h * scale);
    let cr = Context::new(&cs);
    cr.scale(scale as f64, scale as f64);
    cr.set_source_rgb(0.04, 0.04, 0.094); // Plan Neo's void
    cr.paint();
    let mut draw = |name: &str, r: Rect, state: DrawState, label: &str| {
        if let Some(l) = file.get(name) {
            runner.run(l, &cr, &DrawContext::new(r, state, label));
        }
    };
    draw("mui-button", Rect::new(20.0, 20.0, 120.0, 28.0), DrawState::NORMAL, "Save");
    draw("mui-button", Rect::new(160.0, 20.0, 120.0, 28.0), DrawState::PRESSED, "Use");
    draw("mui-button", Rect::new(300.0, 20.0, 120.0, 28.0), DrawState::FOCUSED, "Cancel");
    draw("brushed", Rect::new(20.0, 70.0, 260.0, 26.0), DrawState::NORMAL, "");
    draw("anodized", Rect::new(300.0, 70.0, 200.0, 110.0), DrawState::NORMAL, "");
    draw("knob", Rect::new(30.0, 118.0, 54.0, 54.0), DrawState::NORMAL, "");
    draw("led", Rect::new(110.0, 138.0, 14.0, 14.0), DrawState::NORMAL, "");
    draw("lcd", Rect::new(150.0, 124.0, 120.0, 40.0), DrawState::NORMAL, "");
    cs.flush();
    if cs.write_png(out) {
        ExitCode::SUCCESS
    } else {
        eprintln!("drawlist: could not write {out}");
        ExitCode::FAILURE
    }
}
