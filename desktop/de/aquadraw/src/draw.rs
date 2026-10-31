//! Draw's entry points (Drawing.swift) and the window chrome's painter
//! (Chrome.swift's `paintWindowChrome`): a list by name from the theme,
//! drawn by the runner.

use crate::chrome::{window_chrome, Gadget};
use crate::color::Color;
use crate::drawlist::{DrawState, Role};
use crate::runner::{DrawContext, Rect, Runner};
use crate::text::Style;
use crate::theme::Theme;
use abyss_sys::Context;
use std::collections::HashMap;

/// Draw the theme's list `name` into `r`, if the theme has it.
#[allow(clippy::too_many_arguments)]
pub fn paint(runner: &mut Runner, theme: &Theme, name: &str, cr: &Context, r: Rect, state: DrawState, label: &str, parameters: &[(&str, f64)]) {
    let Some(list) = theme.lists.get(name) else { return };
    let mut ctx = DrawContext::new(r, state, label);
    ctx.parameters = parameters.iter().map(|(k, v)| ((*k).to_owned(), *v)).collect::<HashMap<_, _>>();
    runner.run(list, cr, &ctx);
}

/// Clip to the theme's list `name` laid on `r`, leaving the clip set.
pub fn clip(runner: &mut Runner, theme: &Theme, name: &str, cr: &Context, r: Rect) {
    if let Some(list) = theme.lists.get(name) {
        runner.clip(list, cr, &DrawContext::new(r, DrawState::NORMAL, ""));
    }
}

/// A run of text from its left edge, on a baseline.
#[allow(clippy::too_many_arguments)]
pub fn text_left(runner: &mut Runner, cr: &Context, s: &str, x: f64, baseline_y: f64, color: Color, size: f64, style: Style, role: Role) {
    runner.text.draw_left(cr, s, x, baseline_y, color, size, style, role);
}

/// A run's width, in points.
pub fn text_width(runner: &mut Runner, s: &str, size: f64, style: Style, role: Role) -> f64 {
    runner.text.text_width(s, size, style, role)
}

/// Draw a window's frame: the body, the title bar, its gadgets and title,
/// and the border, from `window_chrome`, through the theme's lists
/// (`window`, `gadget.<name>`, `window.frame`). Returns the body below the
/// title bar.
#[allow(clippy::too_many_arguments)]
pub fn paint_window_chrome(runner: &mut Runner, theme: &Theme, cr: &Context, w: f64, h: f64, title: &str, foreign: bool, active: bool) -> Rect {
    let t = &theme.tokens;
    let l = window_chrome(t, w, h, foreign);
    let whole = Rect::new(0.0, 0.0, w, h);
    let state = if active { DrawState::ACTIVE } else { DrawState::NORMAL };
    // The gadgets and the title are drawn inside the frame's rounded clip,
    // as they always were: text composited under a clip is not the same
    // bytes as text composited without one.
    cr.save();
    clip(runner, theme, "window.shape", cr, whole);
    paint(runner, theme, "window", cr, whole, state, "", &[]);
    // The lights are always drawn lit: an inactive frame is washed over
    // afterwards (undertow's `window.inactive`). Left side, title, right
    // side: the order Jaguar's frame was painted in.
    let gadget = |runner: &mut Runner, g: Gadget, r: Rect| paint(runner, theme, &format!("gadget.{}", g.name()), cr, r, DrawState::ACTIVE, "", &[("r", r.w / 2.0)]);
    let split = t.chrome_left.iter().filter(|g| !(foreign && **g == Gadget::Pill)).count().min(l.gadgets.len());
    for p in &l.gadgets[..split] {
        gadget(runner, p.gadget, p.rect);
    }
    // The title: `window.title` (or `.bold`), centred on $x: the layout's
    // anchor, or, for a left title, its measured centre.
    let style = if l.title_bold { Style::Bold } else { Style::Regular };
    let cx = match l.title_align {
        crate::chrome::TitleAlign::Center => l.title_x,
        crate::chrome::TitleAlign::Left => l.title_x + text_width(runner, title, t.chrome_title_size, style, Role::Chrome) / 2.0,
    };
    paint(runner, theme, if l.title_bold { "window.title.bold" } else { "window.title" }, cr, l.title_bar, state, title, &[("x", cx)]);
    for p in &l.gadgets[split..] {
        gadget(runner, p.gadget, p.rect);
    }
    cr.restore();
    paint(runner, theme, "window.frame", cr, whole, state, "", &[]);
    l.body
}
