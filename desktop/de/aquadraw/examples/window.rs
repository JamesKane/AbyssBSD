//! The `drawlist` golden scene in a Wayland window: an xdg_toplevel with one
//! shm buffer, drawn by the Rust draw-list interpreter (RUST.md R0: the
//! scene in a compositor). abyss/tests/golden-rust.sh --window captures it
//! from a headless compositor and holds it to the PNG scene's golden.
//!
//!   cargo run --example window -- <list.dl> [scale] [seconds]

use abyss_sys::wl::ShmWindow;
use abyss_sys::Context;
use aquadraw::drawlist::DrawListFile;
use aquadraw::scene;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 || args.len() > 4 {
        eprintln!("usage: window <list.dl> [scale] [seconds]");
        return ExitCode::from(2);
    }
    let scale: i32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1).max(1);
    let secs: f64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(5.0);
    let file = match std::fs::read_to_string(&args[1]).map_err(|e| e.to_string()).and_then(|t| DrawListFile::parse(&t).map_err(|e| e.to_string())) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("window: {}: {e}", args[1]);
            return ExitCode::FAILURE;
        }
    };
    let Some(mut runner) = scene::runner(scale) else {
        eprintln!("window: no fonts (the toy-text fallback is not ported)");
        return ExitCode::FAILURE;
    };
    let mut win = match ShmWindow::open("Draw lists", "org.abyssbsd.drawlist", scene::WIDTH, scene::HEIGHT, scale) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("window: {e}");
            return ExitCode::FAILURE;
        }
    };
    win.draw(|cs| {
        let cr = Context::new(cs);
        scene::drawlist(&cr, scale, &file, &mut runner);
    });
    win.present();
    // Readiness for a harness: the frame is committed.
    println!("window: presented {}x{} at {scale}x", scene::WIDTH, scene::HEIGHT);
    if win.run_for(secs) { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
