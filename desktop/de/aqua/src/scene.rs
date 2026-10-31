//! Scenes (Scene.swift): what a window draws, and one frame of it rendered
//! offscreen, for headless checks and the goldens.

use aquadraw::canvas::Canvas;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::{Rect, Runner};
use aquadraw::text::Style;
use aquadraw::theme::Theme;
use abyss_sys::{self as ffi, Context, Pattern, Surface};

/// What AquaDemo shows (AQUA_SCENE).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SceneKind {
    Window,
    Widgets,
    Scroll,
    Tabs,
    Sheet,
}

impl SceneKind {
    /// The scene AQUA_SCENE names, its title and its size, as AquaDemo has
    /// them. None for one not ported yet.
    pub fn named(name: Option<&str>) -> Option<(SceneKind, &'static str, i32, i32)> {
        match name {
            Some("widgets") => Some((SceneKind::Widgets, "Aqua Controls", 460, 360)),
            Some("scroll") => Some((SceneKind::Scroll, "Scroll", 360, 420)),
            Some("tabs") => Some((SceneKind::Tabs, "Tab View", 480, 380)),
            Some("sheet") => Some((SceneKind::Sheet, "Sheets", 440, 320)),
            None | Some("window") => Some((SceneKind::Window, "AbyssBSD", 440, 300)),
            _ => None,
        }
    }
}

/// The demo window: chrome, a welcome, a click counter, a live text field
/// and a default button. Returns the button's rect, for hit-testing.
#[allow(clippy::too_many_arguments)]
pub fn paint_aqua_window(c: &mut Canvas, w: f64, h: f64, title: &str, clicks: u64, pressed: bool, typed: &str, focused: bool) -> Rect {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, title, false, true);
    let t = c.theme.tokens.clone();
    c.text_left("Welcome to AbyssBSD", 24.0, 70.0, t.body_text, 16.0, Style::Regular, Role::Interface);
    c.text_left("A Swift 6 desktop, dressed in Aqua.", 24.0, 94.0, t.body_text.with_a(0.7), t.font_size, Style::Regular, Role::Interface);
    c.text_left(&format!("Clicks: {clicks}"), 24.0, 132.0, t.body_text, t.font_size, Style::Regular, Role::Interface);
    // A live text field: real keyboard input lands here.
    c.text_field(Rect::new(24.0, 150.0, w - 48.0, 26.0), typed, focused, "");
    let (bw, bh) = (120.0, 30.0);
    let button = Rect::new(w - bw - 20.0, h - bh - 20.0, bw, bh);
    c.gel_button(button, "Click Me", true, pressed);
    button
}

/// One scene rendered to a PNG: the desktop-grey backdrop, and the scene's
/// window inset on it.
#[allow(clippy::too_many_arguments)]
pub fn render_scene_png(path: &str, kind: SceneKind, width: i32, height: i32, scale: i32, title: &str, clicks: u64, runner: &mut Runner, theme: &Theme) -> bool {
    let cs = Surface::image(ffi::FORMAT_ARGB32, width * scale, height * scale);
    {
        let cr = Context::new(&cs);
        cr.scale(scale as f64, scale as f64);
        let was = runner.text.render_scale;
        runner.text.render_scale = scale; // shape and hint on the device grid
        let g = Pattern::linear(0.0, 0.0, 0.0, height as f64);
        g.add_color_stop_rgba(0.0, 0.62, 0.66, 0.72, 1.0);
        g.add_color_stop_rgba(1.0, 0.50, 0.54, 0.60, 1.0);
        cr.set_source(&g);
        cr.paint();
        let inset = 16.0;
        cr.save();
        cr.translate(inset, inset);
        let (cw, ch) = (width as f64 - 2.0 * inset, height as f64 - 2.0 * inset);
        let mut c = Canvas::new(&cr, runner, theme);
        match kind {
            SceneKind::Window => {
                paint_aqua_window(&mut c, cw, ch, title, clicks, false, "", false);
            }
            SceneKind::Scroll => {
                crate::scroll::paint_scroll(&mut c, cw, ch, 0.0);
            }
            SceneKind::Tabs => {
                crate::tabs::paint_tabs(&mut c, cw, ch, crate::tabs::TabsState::default());
            }
            // The sheet fully out, for the still.
            SceneKind::Sheet => {
                crate::sheet::paint_sheet_scene(&mut c, cw, ch, 1.0, true, "—");
            }
            SceneKind::Widgets => {
                crate::widgets::paint_widgets(&mut c, cw, ch, &crate::widgets::WidgetState::default(), Some(crate::widgets::WidgetFocus::Ok));
            }
        }
        cr.restore();
        runner.text.render_scale = was;
    }
    cs.flush();
    cs.write_png(path)
}
