//! The `drawlist` golden scene (Scene.swift renderDrawListPNG): every
//! draw-list primitive on Plan Neo's void, 520x200 points. Drawn to a PNG by
//! examples/drawlist.rs and into a Wayland window by examples/window.rs, so
//! both are held to the same golden.

use crate::drawlist::{DrawListFile, DrawState, Role};
use crate::runner::{DrawContext, Rect, Runner};
use crate::text::Text;
use abyss_sys::Context;

pub const WIDTH: i32 = 520;
pub const HEIGHT: i32 = 200;

/// The runner the scene draws with at `scale`: what AquaDemo's Theme.use
/// does with the aqua theme's [fonts]. None of those is installed on the
/// test machines, so every role draws with CText's default chain. None if no
/// font loads at all (the toy-text fallback is not ported).
pub fn runner(scale: i32) -> Option<Runner> {
    let mut fonts = Text::new(scale)?;
    fonts.use_roles(&[
        (Role::Interface, "Lucida Grande"),
        (Role::Chrome, "Lucida Grande"),
        (Role::Readout, "Lucida Grande"),
        (Role::Mono, "Monaco"),
    ]);
    Some(Runner::new(fonts))
}

/// Draw the scene into `cr`, whose surface is the scene's size times `scale`.
pub fn drawlist(cr: &Context, scale: i32, file: &DrawListFile, runner: &mut Runner) {
    cr.scale(scale as f64, scale as f64);
    cr.set_source_rgb(0.04, 0.04, 0.094); // Plan Neo's void
    cr.paint();
    let mut draw = |name: &str, r: Rect, state: DrawState, label: &str| {
        if let Some(l) = file.get(name) {
            runner.run(l, cr, &DrawContext::new(r, state, label));
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
}
