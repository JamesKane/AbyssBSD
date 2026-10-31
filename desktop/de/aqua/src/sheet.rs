//! An Aqua modal sheet (Sheet.swift): a panel sliding down from the title
//! bar while the content behind dims. Not a separate surface: the window
//! draws its content, a dim, then the panel, clipped below the title bar
//! and raised by (1 − progress) of its height so it emerges from under it.

use aquadraw::canvas::{Canvas, Paint};
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;

#[derive(Clone, Copy, Debug, Default)]
pub struct SheetScene {
    /// Opens the sheet (the base layer).
    pub base_button: Rect,
    /// The sheet's buttons: hit only when it is open.
    pub cancel: Rect,
    pub ok: Rect,
}

const PANEL_HEIGHT: f64 = 132.0;

/// The panel and its buttons at (w, h).
pub fn sheet_layout(w: f64, title_bar: f64) -> (Rect, Rect, Rect) {
    let pw = (w - 48.0).min(380.0);
    let panel = Rect::new((w - pw) / 2.0, title_bar, pw, PANEL_HEIGHT);
    let (bw, bh) = (96.0, 28.0);
    let by = panel.y + panel.h - bh - 16.0;
    let ok = Rect::new(panel.x + panel.w - bw - 16.0, by, bw, bh);
    (panel, Rect::new(ok.x - bw - 10.0, by, bw, bh), ok)
}

/// The base layer's "Delete…" button.
pub fn sheet_base_button(w: f64) -> Rect {
    Rect::new((w - 130.0) / 2.0, 150.0, 130.0, 30.0)
}

/// The scene: content, then (visible) the dim and the sliding panel;
/// `progress` 0 is hidden, 1 fully out.
pub fn paint_sheet_scene(c: &mut Canvas, w: f64, h: f64, progress: f64, visible: bool, last_action: &str) -> SheetScene {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, "Sheets", false, true);
    let t = c.theme.tokens.clone();
    let mut s = SheetScene::default();
    c.text_left("Delete a file", 24.0, 70.0, t.body_text, 16.0, Style::Regular, Role::Interface);
    c.text_left("Removing it opens a confirmation sheet.", 24.0, 94.0, t.body_text.with_a(0.7), t.font_size, Style::Regular, Role::Interface);
    c.text_left(&format!("Last action: {last_action}"), 24.0, 128.0, t.body_text, t.font_size, Style::Regular, Role::Interface);
    s.base_button = sheet_base_button(w);
    c.gel_button(s.base_button, "Delete…", false, false);
    if !visible {
        return s;
    }
    let tb = t.title_bar_height;
    // The body dims as the sheet comes out.
    c.paint("sheet.dim", Rect::new(0.0, tb, w, h - tb), Paint { parameters: &[("progress", progress)], ..Paint::default() });
    let (panel, cancel, ok) = sheet_layout(w, tb);
    (s.cancel, s.ok) = (cancel, ok);
    c.cr.save();
    c.cr.rectangle(0.0, tb, w, h - tb);
    c.cr.clip();
    c.cr.translate(0.0, -(1.0 - progress) * panel.h);
    c.paint_simple("sheet", panel, aquadraw::drawlist::DrawState::NORMAL);
    // The question bold, as Aqua sets it; the rest regular.
    c.text_left("Delete this item?", panel.x + 24.0, panel.y + 40.0, t.body_text, 15.0, Style::Bold, Role::Interface);
    c.text_left("This action can’t be undone.", panel.x + 24.0, panel.y + 64.0, t.body_text.with_a(0.7), t.font_size, Style::Regular, Role::Interface);
    c.gel_button(cancel, "Cancel", false, false);
    c.gel_button(ok, "Delete", true, false);
    c.cr.restore();
    s
}
