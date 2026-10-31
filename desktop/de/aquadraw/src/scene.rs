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

/// The `frame` scene (Scene.swift renderFramePNG): the frame undertow
/// paints around a foreign window, from `theme`'s chrome lists, 480×300.
pub fn render_frame_png(out: &str, scale: i32, runner: &mut Runner, theme: &crate::theme::Theme) -> bool {
    let (w, h) = (480, 300);
    let cs = abyss_sys::Surface::image(abyss_sys::FORMAT_ARGB32, w * scale, h * scale);
    {
        let cr = Context::new(&cs);
        cr.scale(scale as f64, scale as f64);
        crate::draw::paint_window_chrome(runner, theme, &cr, w as f64, h as f64, "Untitled — gedit", true, true);
    }
    cs.flush();
    cs.write_png(out)
}

/// The `cursors` sheet: every cursor shape the theme draws, its hotspot
/// marked in red, and its name under it.
pub fn render_cursor_sheet_png(out: &str, scale: i32, runner: &mut Runner, theme: &crate::theme::Theme) -> bool {
    use crate::cursor;
    let (columns, cell_w, cell_h) = (6, 104.0, 58.0);
    let rows = cursor::SHAPE_NAMES.len().div_ceil(columns);
    let (w, h) = ((cell_w * columns as f64) as i32, (cell_h * rows as f64) as i32);
    let cs = abyss_sys::Surface::image(abyss_sys::FORMAT_ARGB32, w * scale, h * scale);
    {
        let cr = Context::new(&cs);
        cr.scale(scale as f64, scale as f64);
        let bg = theme.tokens.content_background;
        cr.set_source_rgba(bg.r, bg.g, bg.b, bg.a);
        cr.paint();
        let s = cursor::size(theme);
        for (i, n) in cursor::SHAPE_NAMES.iter().enumerate() {
            let (x0, y0) = (cell_w * (i % columns) as f64, cell_h * (i / columns) as f64);
            let (cx, cy) = (x0 + (cell_w - s) / 2.0, y0 + 4.0);
            cursor::draw(runner, theme, n, &cr, cx, cy);
            let (hx, hy) = cursor::hotspot(runner, theme, n);
            cr.set_source_rgba(1.0, 0.0, 0.0, 1.0);
            cr.rectangle(cx + hx - 1.0, cy + hy - 1.0, 2.0, 2.0);
            cr.fill();
            let fg = theme.tokens.secondary_text;
            runner.text.draw_centered(&cr, n, x0 + cell_w / 2.0, y0 + cell_h - 12.0, fg, 9.0, crate::text::Style::Regular, Role::Interface);
        }
    }
    cs.flush();
    cs.write_png(out)
}
