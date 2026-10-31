//! The two joined-button controls (Tabs.swift): a segmented control and a
//! tab view whose pane changes with the selection. The segments and pane
//! are pure geometry; the tabs depend on text width, so painting computes
//! them and returns them for hit-testing.

use aquadraw::canvas::{segment_rects, Canvas, Paint};
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TabsState {
    pub segment: usize,
    pub tab: usize,
}

#[derive(Clone, Debug, Default)]
pub struct TabsLayout {
    pub segments: Vec<Rect>,
    pub tabs: Vec<Rect>,
    pub pane: Rect,
}

pub const SEGMENT_LABELS: [&str; 3] = ["Icons", "List", "Columns"];
pub const TAB_LABELS: [&str; 3] = ["General", "Advanced", "Sharing"];

/// Each tab's pane: a heading and two lines.
const CONTENT: [(&str, [&str; 2]); 3] = [
    ("General", ["General settings live here.", "The basics, front and centre."]),
    ("Advanced", ["Advanced options for power users.", "Tuning knobs — handle with care."]),
    ("Sharing", ["Share this Mac on the network.", "Services, computer name, and access."]),
];

const MARGIN: f64 = 20.0;

fn seg_rect(title_bar: f64) -> Rect {
    Rect::new(MARGIN + 52.0, title_bar + 18.0, 240.0, 22.0)
}

/// The segments and the pane (the tabs are filled in by painting).
pub fn tabs_layout(w: f64, h: f64, title_bar: f64) -> TabsLayout {
    let pane_top = title_bar + 74.0;
    TabsLayout { segments: segment_rects(seg_rect(title_bar), SEGMENT_LABELS.len()), tabs: vec![], pane: Rect::new(MARGIN, pane_top, w - 2.0 * MARGIN, h - pane_top - MARGIN) }
}

pub fn paint_tabs(c: &mut Canvas, w: f64, h: f64, state: TabsState) -> TabsLayout {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, "Tab View", false, true);
    let t = c.theme.tokens.clone();
    let mut l = tabs_layout(w, h, t.title_bar_height);
    // The segmented control ("View:").
    let seg = seg_rect(t.title_bar_height);
    c.text_left("View:", MARGIN, seg.y + seg.h / 2.0 + 4.0, t.control_label, t.font_size, Style::Regular, Role::Interface);
    c.segmented_control(seg, &SEGMENT_LABELS, state.segment);
    // The tab view: the pane, then the tabs, the selected one on top.
    c.tab_pane(l.pane);
    let tab_h = 24.0;
    let widths: Vec<f64> = TAB_LABELS.iter().map(|s| (c.text_width(s, t.font_size, Style::Regular, Role::Interface) + 34.0).max(64.0)).collect();
    let mut x = (w - widths.iter().sum::<f64>()) / 2.0;
    for tw in &widths {
        l.tabs.push(Rect::new(x, l.pane.y - tab_h, *tw, tab_h));
        x += tw;
    }
    for (i, r) in l.tabs.iter().enumerate() {
        if i != state.tab {
            c.tab(*r, TAB_LABELS[i], false)
        }
    }
    let sel = l.tabs[state.tab.min(l.tabs.len() - 1)];
    c.tab(sel, TAB_LABELS[state.tab], true);
    // The selected tab merges into the pane: the border under it erased.
    c.paint("tab.merge", sel, Paint { parameters: &[("pane", l.pane.y - sel.y)], ..Paint::default() });
    // The selected tab's pane.
    let (heading, lines) = CONTENT[state.tab];
    let cx = l.pane.x + 20.0;
    let mut cy = l.pane.y + 34.0;
    c.text_left(heading, cx, cy, t.body_text, 15.0, Style::Regular, Role::Interface);
    cy += 28.0;
    for line in lines {
        c.text_left(line, cx, cy, t.body_text.with_a(0.75), t.font_size, Style::Regular, Role::Interface);
        cy += 20.0;
    }
    l
}
