//! Draw (Drawing.swift): what the toolkit draws with, as one value.
//!
//! Swift's widgets reach a global `Theme` and static `Draw` and `Text`.
//! Here they draw on a `Canvas`: the cairo context, the runner (and its
//! text), and the theme, borrowed together for the length of a paint.
//! The look is the theme's draw lists; what is left here is which list,
//! which state, and the geometry a value decides (where a slider's thumb
//! sits, how far a progress bar has run).

use crate::color::Color;
use crate::drawlist::{DrawState, Role};
use crate::runner::{DrawContext, Rect, Runner};
use crate::text::Style;
use crate::theme::Theme;
use abyss_sys::{Context, Pattern};
use std::collections::HashMap;
use std::f64::consts::PI;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Arrow {
    Up,
    Down,
    Left,
    Right,
}

/// The slider's thumb radius, in points.
pub const SLIDER_THUMB_RADIUS: f64 = 8.0;

pub struct Canvas<'a> {
    pub cr: &'a Context,
    pub runner: &'a mut Runner,
    pub theme: &'a Theme,
}

/// What a list is run with, beyond its rectangle.
#[derive(Clone, Default)]
pub struct Paint<'p> {
    pub state: DrawState,
    pub label: &'p str,
    pub placeholder: &'p str,
    pub parameters: &'p [(&'p str, f64)],
    pub colors: &'p [(&'p str, Color)],
}

impl<'a> Canvas<'a> {
    pub fn new(cr: &'a Context, runner: &'a mut Runner, theme: &'a Theme) -> Canvas<'a> {
        Canvas { cr, runner, theme }
    }

    pub fn set_color(&self, c: Color) {
        self.cr.set_source_rgba(c.r, c.g, c.b, c.a)
    }

    pub fn rounded_rect(&self, r: Rect, radius: f64) {
        let rad = radius.min(r.w.min(r.h) / 2.0);
        let deg = PI / 180.0;
        let cr = self.cr;
        cr.new_sub_path();
        cr.arc(r.x + r.w - rad, r.y + rad, rad, -90.0 * deg, 0.0);
        cr.arc(r.x + r.w - rad, r.y + r.h - rad, rad, 0.0, 90.0 * deg);
        cr.arc(r.x + rad, r.y + r.h - rad, rad, 90.0 * deg, 180.0 * deg);
        cr.arc(r.x + rad, r.y + rad, rad, 180.0 * deg, 270.0 * deg);
        cr.close_path();
    }

    pub fn rounded_rect_top(&self, r: Rect, radius: f64) {
        let rad = radius.min(r.w.min(r.h) / 2.0);
        let deg = PI / 180.0;
        let cr = self.cr;
        cr.new_sub_path();
        cr.move_to(r.x, r.y + r.h);
        cr.line_to(r.x, r.y + rad);
        cr.arc(r.x + rad, r.y + rad, rad, 180.0 * deg, 270.0 * deg);
        cr.arc(r.x + r.w - rad, r.y + rad, rad, -90.0 * deg, 0.0);
        cr.line_to(r.x + r.w, r.y + r.h);
        cr.close_path();
    }

    pub fn rounded_rect_bottom(&self, r: Rect, radius: f64) {
        let rad = radius.min(r.w.min(r.h) / 2.0);
        let deg = PI / 180.0;
        let cr = self.cr;
        cr.new_sub_path();
        cr.move_to(r.x, r.y);
        cr.line_to(r.x + r.w, r.y);
        cr.line_to(r.x + r.w, r.y + r.h - rad);
        cr.arc(r.x + r.w - rad, r.y + r.h - rad, rad, 0.0, 90.0 * deg);
        cr.arc(r.x + rad, r.y + r.h - rad, rad, 90.0 * deg, 180.0 * deg);
        cr.line_to(r.x, r.y);
        cr.close_path();
    }

    /// Run the theme's list `name` for one widget.
    pub fn paint(&mut self, name: &str, r: Rect, p: Paint) {
        let Some(list) = self.theme.lists.get(name) else { return };
        let mut ctx = DrawContext::new(r, p.state, p.label);
        ctx.placeholder = p.placeholder.to_owned();
        ctx.parameters = p.parameters.iter().map(|(k, v)| ((*k).to_owned(), *v)).collect::<HashMap<_, _>>();
        ctx.colors = p.colors.iter().map(|(k, v)| ((*k).to_owned(), *v)).collect::<HashMap<_, _>>();
        self.runner.run(list, self.cr, &ctx);
    }

    /// Run `name` with nothing but its rectangle (and a state).
    pub fn paint_simple(&mut self, name: &str, r: Rect, state: DrawState) {
        self.paint(name, r, Paint { state, ..Paint::default() })
    }

    /// The theme's icon `name` filling the square `r` (P11.8): its `.small`
    /// variant below `icon.smallBelow` points, when the set has one.
    pub fn icon(&mut self, name: &str, r: Rect) {
        let small = format!("{name}.small");
        let use_name = if r.w < self.theme.tokens.icon_small_below && self.theme.lists.get(&small).is_some() { small.as_str() } else { name };
        let Some(list) = self.theme.lists.get(use_name) else { return };
        // A leading arc must not join a stray point a caller's text left.
        self.cr.new_path();
        self.runner.run(list, self.cr, &DrawContext::new(r, DrawState::NORMAL, ""));
    }

    /// Clip to the theme's shape `name` and leave it set.
    pub fn clip(&mut self, name: &str, r: Rect) {
        if let Some(list) = self.theme.lists.get(name) {
            self.runner.clip(list, self.cr, &DrawContext::new(r, DrawState::NORMAL, ""));
        }
    }

    /// The keyboard-focus halo hugging `r`.
    pub fn focus_ring(&mut self, r: Rect, radius: f64) {
        self.paint("focusring", r, Paint { parameters: &[("radius", radius)], ..Paint::default() })
    }

    /// A vertical gradient fill of the current path, over [y, y+h].
    pub fn fill_vertical_gradient(&self, y: f64, h: f64, stops: &[(f64, Color)]) {
        let g = Pattern::linear(0.0, y, 0.0, y + h);
        for (off, c) in stops {
            g.add_color_stop_rgba(*off, c.r, c.g, c.b, c.a)
        }
        self.cr.set_source(&g);
        self.cr.fill_preserve();
    }

    /// The faint horizontal pinstripe across `r`.
    pub fn pinstripe(&mut self, r: Rect, c: Color) {
        self.paint("pinstripe", r, Paint { colors: &[("color", c)], ..Paint::default() })
    }

    /// A gel button: `blue` is the default button.
    pub fn gel_button(&mut self, r: Rect, label: &str, blue: bool, pressed: bool) {
        let state = if pressed { DrawState::PRESSED } else { DrawState::NORMAL };
        self.paint(if blue { "button.default" } else { "button" }, r, Paint { state, label, ..Paint::default() })
    }

    /// A text field: `caret` when it has the keyboard; `placeholder` greys
    /// in when `text` is empty.
    pub fn text_field(&mut self, r: Rect, text: &str, caret: bool, placeholder: &str) {
        let state = if caret { DrawState::FOCUSED } else { DrawState::NORMAL };
        self.paint("textfield", r, Paint { state, label: text, placeholder, ..Paint::default() })
    }

    pub fn checkbox(&mut self, r: Rect, checked: bool) {
        self.paint_simple("checkbox", r, if checked { DrawState::SELECTED } else { DrawState::NORMAL })
    }

    /// A radio button centred at (cx, cy).
    pub fn radio_button(&mut self, cx: f64, cy: f64, radius: f64, selected: bool) {
        let state = if selected { DrawState::SELECTED } else { DrawState::NORMAL };
        self.paint("radio", Rect::new(cx - radius, cy - radius, radius * 2.0, radius * 2.0), Paint { state, parameters: &[("r", radius)], ..Paint::default() })
    }

    /// A horizontal slider in `track`, its thumb at `value` (0…1).
    pub fn slider(&mut self, track: Rect, value: f64) {
        let (v, tr) = (value.clamp(0.0, 1.0), SLIDER_THUMB_RADIUS);
        self.paint("slider", track, Paint { parameters: &[("thumb", tr + v * (track.w - 2.0 * tr))], ..Paint::default() })
    }

    pub fn pop_up_button(&mut self, r: Rect, label: &str) {
        self.paint("popup", r, Paint { label, ..Paint::default() })
    }

    /// A determinate progress bar, `value` in 0…1.
    pub fn progress_bar(&mut self, r: Rect, value: f64) {
        let v = value.clamp(0.0, 1.0);
        let fill = if v > 0.0 { r.h.max(v * r.w) } else { 0.0 };
        self.paint("progress", r, Paint { parameters: &[("fill", fill)], ..Paint::default() })
    }

    pub fn scroll_track(&mut self, r: Rect) {
        self.paint_simple("scrolltrack", r, DrawState::NORMAL)
    }

    pub fn scroll_thumb(&mut self, r: Rect) {
        self.paint_simple("scrollthumb", r, DrawState::NORMAL)
    }

    /// A scrollbar arrow; dimmed when there is no travel left that way.
    pub fn scroll_arrow(&mut self, r: Rect, dir: Arrow, enabled: bool) {
        let name = match dir {
            Arrow::Up => "scrollarrow.up",
            Arrow::Down => "scrollarrow.down",
            Arrow::Left => "scrollarrow.left",
            Arrow::Right => "scrollarrow.right",
        };
        self.paint_simple(name, r, if enabled { DrawState::NORMAL } else { DrawState::DISABLED })
    }

    /// A segmented control: bodies, gloss, dividers, frame, labels, in
    /// passes (the lists say why).
    pub fn segmented_control(&mut self, r: Rect, labels: &[&str], selected: usize) {
        let rects = segment_rects(r, labels.len());
        let seg_w = r.w / labels.len().max(1) as f64;
        let seg = |c: &mut Canvas, name: &str, i: usize| {
            let state = if i == selected { DrawState::SELECTED } else { DrawState::NORMAL };
            c.paint(name, r, Paint { state, label: labels[i], parameters: &[("x", i as f64 * seg_w), ("w", rects[i].w)], ..Paint::default() });
        };
        for i in 0..rects.len() {
            seg(self, "segmented.segment", i)
        }
        self.paint_simple("segmented.gloss", r, DrawState::NORMAL);
        for i in 1..rects.len() {
            seg(self, "segmented.divider", i)
        }
        self.paint_simple("segmented.frame", r, DrawState::NORMAL);
        for i in 0..rects.len() {
            seg(self, "segmented.label", i)
        }
    }

    pub fn tab_pane(&mut self, r: Rect) {
        self.paint_simple("tabpane", r, DrawState::NORMAL)
    }

    pub fn tab(&mut self, r: Rect, label: &str, selected: bool) {
        let state = if selected { DrawState::SELECTED } else { DrawState::NORMAL };
        self.paint("tab", r, Paint { state, label, ..Paint::default() })
    }

    pub fn group_box(&mut self, r: Rect, title: &str) {
        self.paint("groupbox", r, Paint { label: title, ..Paint::default() })
    }

    /// Text centred on a point.
    #[allow(clippy::too_many_arguments)]
    pub fn text(&mut self, s: &str, cx: f64, cy: f64, color: Color, size: f64, style: Style, role: Role) {
        self.runner.text.draw_centered(self.cr, s, cx, cy, color, size, style, role)
    }

    /// Text from its left edge, on a baseline.
    #[allow(clippy::too_many_arguments)]
    pub fn text_left(&mut self, s: &str, x: f64, baseline_y: f64, color: Color, size: f64, style: Style, role: Role) {
        self.runner.text.draw_left(self.cr, s, x, baseline_y, color, size, style, role)
    }

    /// A run's width, in points.
    pub fn text_width(&mut self, s: &str, size: f64, style: Style, role: Role) -> f64 {
        self.runner.text.text_width(s, size, style, role)
    }

    /// The theme's tokens.
    pub fn t(&self) -> &crate::tokens::ThemeTokens {
        &self.theme.tokens
    }
}

/// Equal-width segment rects dividing `r`: the one segmented geometry, the
/// painter's and the hit-tester's.
pub fn segment_rects(r: Rect, count: usize) -> Vec<Rect> {
    if count == 0 {
        return vec![];
    }
    let w = r.w / count as f64;
    (0..count).map(|i| Rect::new(r.x + i as f64 * w, r.y, w, r.h)).collect()
}
