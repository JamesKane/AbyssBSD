//! A showcase of the classic Aqua controls (Widgets.swift): checkbox, radio,
//! slider, pop-up button, progress bar, push buttons, wired to live input.
//!
//! Geometry lives in one place: `widgets_layout` returns every control's
//! rect, and both the painter and the hit-tester read it, so what is seen
//! is exactly what can be clicked.

use aquadraw::canvas::Canvas;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;

#[derive(Clone, Debug, PartialEq)]
pub struct WidgetState {
    pub checks: [bool; 3],
    pub radio: usize,
    /// 0…1.
    pub slider: f64,
    pub popup: usize,
    pub ok_pressed: bool,
    pub cancel_pressed: bool,
}

impl Default for WidgetState {
    fn default() -> WidgetState {
        WidgetState { checks: [true, false, true], radio: 1, slider: 0.6, popup: 0, ok_pressed: false, cancel_pressed: false }
    }
}

/// A keyboard-focusable control; `FOCUS_ORDER` is the Tab sequence.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WidgetFocus {
    Check(usize),
    Radio,
    Slider,
    Popup,
    Cancel,
    Ok,
}

/// Each checkbox, then the radio cluster, slider, pop-up, Cancel, OK.
pub const FOCUS_ORDER: [WidgetFocus; 8] = [WidgetFocus::Check(0), WidgetFocus::Check(1), WidgetFocus::Check(2), WidgetFocus::Radio, WidgetFocus::Slider, WidgetFocus::Popup, WidgetFocus::Cancel, WidgetFocus::Ok];

pub const CHECK_LABELS: [&str; 3] = ["Play user interface sound effects", "Show all file extensions", "Use smooth scrolling"];
pub const RADIO_LABELS: [&str; 3] = ["Small", "Medium", "Large"];
pub const POPUP_OPTIONS: [&str; 2] = ["Aqua Blue", "Graphite"];

/// Every control's rect. Interactive ones are hit-tested; `check_boxes`
/// and `progress` are drawing only.
#[derive(Clone, Debug, Default)]
pub struct WidgetLayout {
    /// Clickable strips: box and label.
    pub checks: Vec<Rect>,
    /// The 14 px boxes.
    pub check_boxes: Vec<Rect>,
    pub radios: Vec<Rect>,
    pub radio_centers: Vec<(f64, f64)>,
    pub slider_track: Rect,
    pub progress: Rect,
    pub popup: Rect,
    pub ok_button: Rect,
    pub cancel_button: Rect,
}

/// The scene's geometry at (w, h), under a title bar `title_bar` high.
pub fn widgets_layout(w: f64, h: f64, title_bar: f64) -> WidgetLayout {
    let mut l = WidgetLayout::default();
    let (m, box_size, row_h) = (22.0, 14.0, 24.0);
    // The Options group box, with three checkboxes.
    let group = Rect::new(m, title_bar + 26.0, w - 2.0 * m, row_h * 3.0 + 18.0);
    let box_x = group.x + 14.0;
    for i in 0..CHECK_LABELS.len() {
        let b = Rect::new(box_x, group.y + 15.0 + i as f64 * row_h, box_size, box_size);
        l.check_boxes.push(b);
        l.checks.push(Rect::new(b.x, b.y - 3.0, group.w - 28.0, 20.0));
    }
    // The radio group ("Icon size:") on one row.
    let radio_cy = group.y + group.h + 26.0;
    let (radio_r, slot0, gap) = (7.0, m + 84.0, 92.0);
    for i in 0..RADIO_LABELS.len() {
        let cx = slot0 + i as f64 * gap;
        l.radio_centers.push((cx, radio_cy));
        l.radios.push(Rect::new(cx - radio_r - 2.0, radio_cy - 9.0, gap - 6.0, 18.0));
    }
    // The slider ("Volume:") and a progress bar mirroring it; the label
    // column fits the longest label ("Appearance:").
    let track_x = m + 96.0;
    let slider_y = radio_cy + 24.0;
    l.slider_track = Rect::new(track_x, slider_y, w - m - track_x, 18.0);
    let prog_y = slider_y + 30.0;
    l.progress = Rect::new(track_x, prog_y + 4.0, w - m - track_x, 10.0);
    // The pop-up button ("Appearance:").
    l.popup = Rect::new(track_x, prog_y + 30.0, 170.0, 22.0);
    // The push buttons, bottom right.
    let (bw, bh) = (92.0, 28.0);
    let by = h - bh - 18.0;
    l.ok_button = Rect::new(w - bw - 18.0, by, bw, bh);
    l.cancel_button = Rect::new(w - 2.0 * bw - 30.0, by, bw, bh);
    l
}

/// Ring the focused control, after the controls: the halo sits outside
/// each control's rect.
fn paint_focus_ring(c: &mut Canvas, focus: WidgetFocus, l: &WidgetLayout, state: &WidgetState) {
    match focus {
        WidgetFocus::Check(i) => c.focus_ring(l.check_boxes[i], 3.0),
        WidgetFocus::Radio => {
            let (cx, cy) = l.radio_centers[state.radio];
            c.focus_ring(Rect::new(cx - 7.0, cy - 7.0, 14.0, 14.0), 7.0)
        }
        WidgetFocus::Slider => c.focus_ring(l.slider_track, l.slider_track.h / 2.0),
        WidgetFocus::Popup => c.focus_ring(l.popup, 5.0),
        WidgetFocus::Cancel => c.focus_ring(l.cancel_button, l.cancel_button.h / 2.0),
        WidgetFocus::Ok => c.focus_ring(l.ok_button, l.ok_button.h / 2.0),
    }
}

/// Paint the scene, and return its layout for hit-testing.
pub fn paint_widgets(c: &mut Canvas, w: f64, h: f64, state: &WidgetState, focus: Option<WidgetFocus>) -> WidgetLayout {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, "Aqua Controls", false, true);
    let t = c.theme.tokens.clone();
    let l = widgets_layout(w, h, t.title_bar_height);
    let m = 22.0;
    let label = |c: &mut Canvas, s: &str, x: f64, y: f64| c.text_left(s, x, y, t.control_label, t.font_size, Style::Regular, Role::Interface);
    c.text_left("A tour of the Jaguar control set", m, t.title_bar_height + 20.0, t.body_text.with_a(0.75), t.font_size, Style::Regular, Role::Interface);
    // The Options group and its checkboxes.
    c.group_box(Rect::new(m, t.title_bar_height + 26.0, w - 2.0 * m, 24.0 * 3.0 + 18.0), "Options");
    for (i, text) in CHECK_LABELS.iter().enumerate() {
        let b = l.check_boxes[i];
        c.checkbox(b, state.checks[i]);
        label(c, text, b.x + b.w + 8.0, b.y + b.h - 2.5);
    }
    // The radio group.
    let radio_cy = l.radio_centers.first().map_or(0.0, |p| p.1);
    label(c, "Icon size:", m, radio_cy + 4.0);
    for (i, text) in RADIO_LABELS.iter().enumerate() {
        let (cx, cy) = l.radio_centers[i];
        c.radio_button(cx, cy, 7.0, state.radio == i);
        label(c, text, cx + 12.0, cy + 4.0);
    }
    // The slider, and the progress bar mirroring it.
    label(c, "Volume:", m, l.slider_track.y + l.slider_track.h / 2.0 + 4.0);
    c.slider(l.slider_track, state.slider);
    label(c, "Level:", m, l.progress.y + l.progress.h + 1.0);
    c.progress_bar(l.progress, state.slider);
    // The pop-up button.
    label(c, "Appearance:", m, l.popup.y + l.popup.h / 2.0 + 4.0);
    c.pop_up_button(l.popup, POPUP_OPTIONS[state.popup]);
    // The push buttons.
    c.gel_button(l.cancel_button, "Cancel", false, state.cancel_pressed);
    c.gel_button(l.ok_button, "OK", true, state.ok_pressed);
    if let Some(f) = focus {
        paint_focus_ring(c, f, &l, state)
    }
    l
}
