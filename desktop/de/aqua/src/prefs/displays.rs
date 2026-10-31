//! The Displays pane (DisplaysPane.swift, P14.7c): Jaguar's two tabs on one
//! page. The **arrangement**, every display a rectangle to scale, the main
//! one wearing the menu bar, dragged to where it sits beside the others;
//! and the selected display's **resolution** and **scale**. Every change
//! is applied at once through wlr-output-management (the compositor
//! decides; undertow's displays.ini keeps it). Read, not remembered: redrawn
//! when anyone (the pane, wlr-randr, kanshi) changes them.

use super::{at, log, two_places, Pane, PrefsHost};
use aquadraw::canvas::Canvas;
use aquadraw::color::Color;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use std::cell::{Cell, RefCell};
use std::os::fd::RawFd;
use std::rc::{Rc, Weak};
use std::time::Duration;
use surface::display_config::{DisplayConfigurator, Head, Mode, Outcome, Setting};

/// A display being dragged: its name, and its box where the pointer has it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Dragging {
    pub name: String,
    pub x: i32,
    pub y: i32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DisplaysPaneState {
    pub heads: Vec<Head>,
    /// The display whose resolution and scale are shown.
    pub selected: Option<String>,
    pub dragging: Option<Dragging>,
    pub note: String,
}

impl DisplaysPaneState {
    pub fn selected_head(&self) -> Option<&Head> {
        self.heads.iter().find(|h| Some(&h.name) == self.selected.as_ref()).or(self.heads.first())
    }

    /// A fixed pair of displays, for the golden picture.
    pub fn sample() -> DisplaysPaneState {
        let m = |w, h, r, p| Mode { width: w, height: h, refresh_mhz: r, preferred: p };
        let (m1, m1b, m2) = (m(2560, 1440, 59951, true), m(1920, 1080, 60000, false), m(1920, 1200, 59950, true));
        let head = |name: &str, desc: &str, modes: Vec<Mode>, cur, x, scale| Head { name: name.into(), description: desc.into(), enabled: true, modes, current: Some(cur), x, y: 0, scale };
        DisplaysPaneState { heads: vec![head("DP-1", "Dell U2719D", vec![m1, m1b], m1, 0, 1.25), head("HDMI-A-1", "LG 24UD58", vec![m2], m2, 2048, 1.0)], selected: Some("DP-1".into()), ..DisplaysPaneState::default() }
    }
}

fn layout_w(h: &Head) -> i32 {
    h.layout_size().0
}
fn layout_h(h: &Head) -> i32 {
    h.layout_size().1
}

/// The page as one line, in `abyss-displays`' terms.
pub fn status_line(heads: &[Head]) -> String {
    heads.iter().map(|h| format!("{} {} at {},{} scale {}", h.name, h.current.map_or("none".into(), |m| format!("{}x{}", m.width, m.height)), h.x, h.y, scale_text(h.scale))).collect::<Vec<_>>().join("; ")
}

pub fn scale_text(s: f64) -> String {
    if s == s.round() { (s as i64).to_string() } else { s.to_string() }
}

pub fn mode_words(m: &Mode, all: &[Mode]) -> String {
    let same_size = all.iter().filter(|x| x.width == m.width && x.height == m.height).count() > 1;
    let hz = if same_size && m.refresh_mhz > 0 { format!(", {} Hz", (m.refresh_mhz as f64 / 1000.0).round() as i64) } else { String::new() };
    format!("{} × {}{hz}{}", m.width, m.height, if m.preferred { " (native)" } else { "" })
}

/// The usual scales, and the current one if it is not.
pub fn scales(current: f64) -> Vec<f64> {
    let mut s = vec![1.0, 1.25, 1.5, 2.0];
    if !s.contains(&current) {
        s.push(current);
        s.sort_by(f64::total_cmp)
    }
    s
}

fn mode_key(m: &Mode) -> String {
    format!("{}x{}@{}", m.width, m.height, m.refresh_mhz)
}

/// Layout units within which a dropped display's edge lines up with its
/// neighbour's.
pub const ALIGN_TOLERANCE: i32 = 24;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LayoutBox {
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

/// The boxes fitted into `area` to scale and centred, with the factor, so a
/// drag can be turned back into layout units.
pub fn fit(boxes: &[LayoutBox], area: Rect) -> (Vec<(String, Rect)>, f64) {
    let Some(first) = boxes.first() else { return (vec![], 1.0) };
    let (mut x0, mut y0, mut x1, mut y1) = (first.x, first.y, first.x + first.w, first.y + first.h);
    for b in boxes {
        (x0, y0, x1, y1) = (x0.min(b.x), y0.min(b.y), x1.max(b.x + b.w), y1.max(b.y + b.h))
    }
    let (bw, bh) = ((x1 - x0).max(1) as f64, (y1 - y0).max(1) as f64);
    let k = (area.w / bw).min(area.h / bh) * 0.8;
    let (ox, oy) = (area.x + (area.w - bw * k) / 2.0, area.y + (area.h - bh * k) / 2.0);
    (boxes.iter().map(|b| (b.name.clone(), Rect::new(ox + (b.x - x0) as f64 * k, oy + (b.y - y0) as f64 * k, b.w as f64 * k, b.h as f64 * k))).collect(), k)
}

/// Where a dropped display goes: **touching** another along an edge,
/// overlapping none (a Mac will not leave one floating apart), the nearest
/// such place to the drop. Edges nearly lined up are lined up: a drop a few
/// pixels off is a person who meant them flush.
pub fn snap(x: i32, y: i32, w: i32, h: i32, others: &[(i32, i32, i32, i32)]) -> (i32, i32) {
    let overlaps = |ax: i32, ay: i32| others.iter().any(|&(ox, oy, ow, oh)| (ax + w).min(ox + ow) > ax.max(ox) && (ay + h).min(oy + oh) > ay.max(oy));
    let align = |v: i32, start: i32, len: i32, size: i32| {
        let c = v.max(start - size + 1).min(start + len - 1);
        [start, start + len - size].into_iter().find(|e| (c - e).abs() <= ALIGN_TOLERANCE).unwrap_or(c)
    };
    let mut best: Option<(i32, i32)> = None;
    let mut best_d = i64::MAX;
    for &(ox, oy, ow, oh) in others {
        let (cy, cx) = (align(y, oy, oh, h), align(x, ox, ow, w));
        for c in [(ox - w, cy), (ox + ow, cy), (cx, oy - h), (cx, oy + oh)] {
            if overlaps(c.0, c.1) {
                continue;
            }
            let d = (c.0 - x) as i64 * (c.0 - x) as i64 + (c.1 - y) as i64 * (c.1 - y) as i64;
            if d < best_d {
                (best_d, best) = (d, Some(c))
            }
        }
    }
    best.unwrap_or((x, y))
}

#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub value: String,
    pub hit: Rect,
    pub control: Rect,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DisplaysLayout {
    pub arrangement: Rect,
    /// In drawing order: the dragged one last, on top.
    pub displays: Vec<(String, Rect)>,
    pub factor: f64,
    pub modes: Vec<Row>,
    pub scales: Vec<Row>,
    pub label_right: f64,
    pub detail_baseline: f64,
    pub modes_baseline: f64,
    pub scales_baseline: f64,
    pub note_baseline: f64,
}

pub fn displays_layout(body: Rect, s: &DisplaysPaneState) -> DisplaysLayout {
    let mut l = DisplaysLayout { label_right: body.x + 170.0, arrangement: Rect::new(body.x + 40.0, body.y + 20.0, body.w - 80.0, 200.0), ..DisplaysLayout::default() };
    // Fitted to the displays as they ARE, so the pane does not rescale
    // under the pointer; the dragged one is placed in the same frame.
    let as_is: Vec<LayoutBox> = s.heads.iter().map(|h| LayoutBox { name: h.name.clone(), x: h.x, y: h.y, w: layout_w(h), h: layout_h(h) }).collect();
    let a = l.arrangement;
    let (rects, k) = fit(&as_is, Rect::new(a.x + 10.0, a.y + 10.0, a.w - 20.0, a.h - 20.0));
    l.factor = k;
    let dragged = s.dragging.as_ref().map(|d| d.name.clone());
    let order = s.heads.iter().filter(|h| Some(&h.name) != dragged.as_ref()).chain(s.heads.iter().filter(|h| Some(&h.name) == dragged.as_ref()));
    for h in order {
        let Some((_, base)) = rects.iter().find(|(n, _)| *n == h.name) else { continue };
        let (bx, by) = s.dragging.as_ref().filter(|d| d.name == h.name).map_or((h.x, h.y), |d| (d.x, d.y));
        l.displays.push((h.name.clone(), Rect::new(base.x + (bx - h.x) as f64 * k, base.y + (by - h.y) as f64 * k, base.w, base.h)))
    }
    let mut y = a.y + a.h + 48.0;
    l.detail_baseline = y;
    y += 26.0;
    l.modes_baseline = y + 15.0;
    let x = l.label_right + 12.0;
    if let Some(h) = s.selected_head() {
        for m in &h.modes {
            l.modes.push(Row { value: mode_key(m), hit: Rect::new(x, y, 300.0, 22.0), control: Rect::new(x, y + 3.0, 16.0, 16.0) });
            y += 22.0
        }
        y += 14.0;
        l.scales_baseline = y + 15.0;
        for (i, sc) in scales(h.scale).into_iter().enumerate() {
            let sx = x + i as f64 * 74.0;
            l.scales.push(Row { value: scale_text(sc), hit: Rect::new(sx, y, 70.0, 22.0), control: Rect::new(sx, y + 3.0, 16.0, 16.0) })
        }
        y += 22.0
    }
    l.note_baseline = y + 34.0;
    l
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DisplaysHit {
    Display(String),
    /// `WxH@mHz`.
    Mode(String),
    Scale(String),
}

pub fn displays_hit(l: &DisplaysLayout, x: f64, y: f64) -> Option<DisplaysHit> {
    // The topmost first: the dragged one is drawn last.
    if let Some((n, _)) = l.displays.iter().rev().find(|(_, r)| r.contains(x, y)) {
        return Some(DisplaysHit::Display(n.clone()));
    }
    if let Some(r) = l.modes.iter().find(|r| r.hit.contains(x, y)) {
        return Some(DisplaysHit::Mode(r.value.clone()));
    }
    l.scales.iter().find(|r| r.hit.contains(x, y)).map(|r| DisplaysHit::Scale(r.value.clone()))
}

pub fn paint_displays(c: &mut Canvas, l: &DisplaysLayout, s: &DisplaysPaneState) {
    let t = c.theme.tokens.clone();
    let a = l.arrangement;
    if s.heads.is_empty() {
        return c.text(if s.note.is_empty() { "No displays to arrange." } else { &s.note }, a.x + a.w / 2.0, a.y + 60.0, t.secondary_text, 13.0, Style::Regular, Role::Interface);
    }
    c.group_box(a, "Arrangement");
    let main = s.heads.first().map(|h| h.name.clone());
    let chosen_name = s.selected_head().map(|h| h.name.clone());
    for (name, r) in &l.displays {
        let chosen = Some(name) == chosen_name.as_ref();
        c.set_color(if chosen { Color::new(0.36, 0.56, 0.86, 1.0) } else { Color::new(0.55, 0.66, 0.82, 1.0) });
        c.rounded_rect(*r, 2.0);
        c.cr.fill();
        c.set_color(if chosen { Color::new(0.12, 0.30, 0.66, 1.0) } else { Color::new(0.35, 0.40, 0.50, 1.0) });
        c.cr.set_line_width(if chosen { 2.0 } else { 1.0 });
        c.rounded_rect(*r, 2.0);
        c.cr.stroke();
        if Some(name) == main.as_ref() {
            // The menu bar: dragging it here is how a Mac moved it too.
            c.set_color(Color::new(1.0, 1.0, 1.0, 0.92));
            c.cr.rectangle(r.x + 1.0, r.y + 1.0, r.w - 2.0, (r.h * 0.07).max(3.0));
            c.cr.fill()
        }
        c.text(name, r.x + r.w / 2.0, r.y + r.h / 2.0, Color::new(1.0, 1.0, 1.0, 1.0), 11.0, Style::Regular, Role::Interface)
    }
    let Some(h) = s.selected_head() else { return };
    c.text("Drag displays to arrange them. The white bar is the menu bar: that display is the main one.", a.x + a.w / 2.0, a.y + a.h + 12.0, t.secondary_text, 11.0, Style::Regular, Role::Interface);
    let title = if h.description.is_empty() { h.name.clone() } else { format!("{} ({})", h.description, h.name) };
    c.text_left(&title, a.x, l.detail_baseline, t.body_text, 13.0, Style::Bold, Role::Interface);
    let heading = |c: &mut Canvas, text: &str, baseline: f64| {
        let w = c.text_width(text, 13.0, Style::Regular, Role::Interface);
        c.text_left(text, l.label_right - w, baseline, t.body_text, 13.0, Style::Regular, Role::Interface)
    };
    heading(c, "Resolution:", l.modes_baseline);
    for r in &l.modes {
        let Some(m) = h.modes.iter().find(|m| mode_key(m) == r.value) else { continue };
        c.radio_button(r.control.x + 8.0, r.control.y + 8.0, 7.0, Some(*m) == h.current);
        c.text_left(&mode_words(m, &h.modes), r.control.x + 24.0, r.control.y + 12.0, t.body_text, 13.0, Style::Regular, Role::Interface)
    }
    heading(c, "Scale:", l.scales_baseline);
    for r in &l.scales {
        c.radio_button(r.control.x + 8.0, r.control.y + 8.0, 7.0, r.value == scale_text(h.scale));
        c.text_left(&format!("{}×", r.value), r.control.x + 24.0, r.control.y + 12.0, t.body_text, 13.0, Style::Regular, Role::Interface)
    }
    if !s.note.is_empty() {
        c.text_left(&s.note, a.x, l.note_baseline, t.body_text, 12.0, Style::Regular, Role::Interface)
    }
}

/// A new mode or scale changes a display's size in the layout: those to its
/// right and below move by as much, so none overlaps it.
pub fn resized(heads: &[Head], name: &str, old: &Head) -> Vec<Head> {
    let Some(new) = heads.iter().find(|h| h.name == name) else { return heads.to_vec() };
    let (dw, dh) = (layout_w(new) - layout_w(old), layout_h(new) - layout_h(old));
    heads
        .iter()
        .map(|h| {
            let mut m = h.clone();
            if h.name != name {
                if h.x >= old.x + layout_w(old) {
                    m.x += dw
                }
                if h.y >= old.y + layout_h(old) {
                    m.y += dh
                }
            }
            m
        })
        .collect()
}

fn dlog(s: &str) {
    log(&format!("displays: {s}"))
}

pub struct DisplaysPane {
    me: Weak<DisplaysPane>,
    state: RefCell<DisplaysPaneState>,
    layout: RefCell<Option<DisplaysLayout>>,
    /// Its own connection: its requests pump their own loop, which on ours
    /// would dispatch this window's events from inside a handler.
    configurator: RefCell<Option<Rc<DisplayConfigurator>>>,
    configurator_fd: Cell<Option<RawFd>>,
    /// Where a drag began: the pointer, and the display's box.
    drag_from: Cell<Option<(f64, f64, i32, i32)>>,
    pointer: Cell<(f64, f64)>,
    dumped: RefCell<Option<DisplaysLayout>>,
}

impl DisplaysPane {
    pub fn new(state: DisplaysPaneState) -> Rc<DisplaysPane> {
        Rc::new_cyclic(|me| DisplaysPane { me: me.clone(), state: RefCell::new(state), layout: RefCell::new(None), configurator: RefCell::new(None), configurator_fd: Cell::new(None), drag_from: Cell::new(None), pointer: Cell::new((0.0, 0.0)), dumped: RefCell::new(None) })
    }

    fn changed(&self, h: &Rc<PrefsHost>) {
        let Some(c) = self.configurator.borrow().clone() else { return };
        let heads: Vec<Head> = c.displays().into_iter().filter(|h| h.enabled).collect();
        if heads == self.state.borrow().heads {
            return;
        }
        {
            let mut s = self.state.borrow_mut();
            let keep = s.selected.clone().filter(|k| heads.iter().any(|h| &h.name == k));
            s.selected = keep.or(heads.first().map(|h| h.name.clone()));
            s.heads = heads.clone();
        }
        dlog(&format!("status {}", status_line(&heads)));
        h.redraw()
    }

    /// Ask for `heads` as given, and say what came of it.
    fn apply(&self, h: &Rc<PrefsHost>, heads: &[Head], what: &str) {
        let Some(c) = self.configurator.borrow().clone() else { return };
        let settings: Vec<Setting> = heads.iter().map(|h| { let m = h.current.unwrap_or_default(); Setting { name: h.name.clone(), width: m.width, height: m.height, refresh_mhz: m.refresh_mhz, x: h.x, y: h.y, scale: h.scale } }).collect();
        dlog(&format!("apply {what} — {}", status_line(heads)));
        let note = match c.request(&settings, false, Duration::from_secs(3)) {
            Outcome::Succeeded => {
                c.await_update(Duration::from_secs(2));
                dlog("applied");
                ""
            }
            Outcome::Failed => {
                dlog("refused");
                "The compositor refused that arrangement."
            }
            Outcome::Cancelled => {
                dlog("cancelled");
                "The displays changed meanwhile; nothing was applied."
            }
            Outcome::TimedOut => {
                dlog("timed out");
                "The compositor did not answer."
            }
        };
        self.state.borrow_mut().note = note.into();
        self.changed(h);
        h.redraw()
    }

    fn drop_display(&self, h: &Rc<PrefsHost>) {
        let (d, from) = (self.state.borrow_mut().dragging.take(), self.drag_from.take());
        let (Some(d), Some(from)) = (d, from) else { return h.redraw() };
        let heads = self.state.borrow().heads.clone();
        let Some(moving) = heads.iter().find(|x| x.name == d.name).cloned() else { return h.redraw() };
        if d.x == from.2 && d.y == from.3 {
            return h.redraw();
        }
        let others: Vec<(i32, i32, i32, i32)> = heads.iter().filter(|x| x.name != d.name).map(|x| (x.x, x.y, layout_w(x), layout_h(x))).collect();
        let (sx, sy) = snap(d.x, d.y, layout_w(&moving), layout_h(&moving), &others);
        let mut heads = heads;
        if let Some(m) = heads.iter_mut().find(|x| x.name == d.name) {
            (m.x, m.y) = (sx, sy)
        }
        // The main display stays at the origin: everything else moves.
        if let Some((ox, oy)) = heads.first().map(|m| (m.x, m.y)).filter(|o| *o != (0, 0)) {
            for x in heads.iter_mut() {
                x.x -= ox;
                x.y -= oy
            }
        }
        self.apply(h, &heads, &format!("{} moved", d.name))
    }
}

impl Pane for DisplaysPane {
    fn id(&self) -> &'static str {
        "displays"
    }
    fn shown(&self, h: &Rc<PrefsHost>) {
        if self.configurator.borrow().is_none() {
            let Some(c) = DisplayConfigurator::new(Duration::from_secs(2)) else {
                let note = "This compositor does not let displays be arranged (it offers no wlr-output-management).".to_string();
                dlog(&note);
                self.state.borrow_mut().note = note;
                return h.redraw();
            };
            let c = Rc::new(c);
            if let Some(d) = &h.display {
                let cw = Rc::downgrade(&c);
                d.add_fd(c.fd(), move || {
                    if let Some(c) = cw.upgrade() {
                        c.dispatch()
                    }
                });
                self.configurator_fd.set(Some(c.fd()));
            }
            // Anyone's change, ours or wlr-randr's, redraws the page.
            let (me, host) = (self.me.clone(), h.clone());
            c.on_change(move || {
                if let Some(p) = me.upgrade() {
                    p.changed(&host)
                }
            });
            *self.configurator.borrow_mut() = Some(c);
        }
        self.changed(h)
    }
    fn paint(&self, c: &mut Canvas, body: Rect) {
        let s = self.state.borrow().clone();
        let l = displays_layout(body, &s);
        paint_displays(c, &l, &s);
        *self.layout.borrow_mut() = Some(l)
    }
    /// `disp.<name>` at each rectangle's centre, `mode.<WxH@mHz>` and
    /// `scale.<s>` at their radios, and the factor.
    fn dump(&self) -> Vec<String> {
        let Some(l) = self.layout.borrow().clone() else { return vec![] };
        if self.dumped.borrow().as_ref() == Some(&l) {
            return vec![];
        }
        let mut line = "displays layout".to_string();
        let mut names: Vec<&(String, Rect)> = l.displays.iter().collect();
        names.sort_by(|a, b| a.0.cmp(&b.0));
        for (n, r) in names {
            line += &format!(" disp.{n}={}", at(r))
        }
        for r in &l.modes {
            line += &format!(" mode.{}={}", r.value, at(&r.hit))
        }
        for r in &l.scales {
            line += &format!(" scale.{}={}", r.value, at(&r.hit))
        }
        line += &format!(" factor={}", two_places(l.factor * 1000.0));
        *self.dumped.borrow_mut() = Some(l);
        vec![line]
    }
    fn pointer_moved(&self, h: &Rc<PrefsHost>, x: f64, y: f64) {
        self.pointer.set((x, y));
        let (Some(from), Some(name)) = (self.drag_from.get(), self.state.borrow().dragging.as_ref().map(|d| d.name.clone())) else { return };
        let k = self.layout.borrow().as_ref().map_or(1.0, |l| l.factor).max(1e-6);
        self.state.borrow_mut().dragging = Some(Dragging { name, x: from.2 + ((x - from.0) / k).round() as i32, y: from.3 + ((y - from.1) / k).round() as i32 });
        h.redraw()
    }
    fn press(&self, h: &Rc<PrefsHost>, x: f64, y: f64) -> bool {
        let Some(hit) = self.layout.borrow().as_ref().and_then(|l| displays_hit(l, x, y)) else { return false };
        let Some(sel) = self.state.borrow().selected_head().cloned() else { return true };
        match hit {
            DisplaysHit::Display(name) => {
                let mut s = self.state.borrow_mut();
                s.selected = Some(name.clone());
                if let Some(head) = s.heads.iter().find(|x| x.name == name).cloned() {
                    self.drag_from.set(Some((x, y, head.x, head.y)));
                    s.dragging = Some(Dragging { name: name.clone(), x: head.x, y: head.y })
                }
                drop(s);
                dlog(&format!("selected {name}"))
            }
            DisplaysHit::Mode(v) => {
                let Some(m) = sel.modes.iter().find(|m| mode_key(m) == v).copied().filter(|m| Some(*m) != sel.current) else { return true };
                let mut heads = self.state.borrow().heads.clone();
                if let Some(x) = heads.iter_mut().find(|x| x.name == sel.name) {
                    x.current = Some(m)
                }
                self.apply(h, &resized(&heads, &sel.name, &sel), &format!("{} at {}x{}", sel.name, m.width, m.height))
            }
            DisplaysHit::Scale(v) => {
                let Some(sc) = v.parse::<f64>().ok().filter(|sc| *sc != sel.scale) else { return true };
                let mut heads = self.state.borrow().heads.clone();
                if let Some(x) = heads.iter_mut().find(|x| x.name == sel.name) {
                    x.scale = sc
                }
                self.apply(h, &resized(&heads, &sel.name, &sel), &format!("{} at scale {v}", sel.name))
            }
        }
        h.redraw();
        true
    }
    fn release(&self, h: &Rc<PrefsHost>) -> bool {
        if self.state.borrow().dragging.is_none() {
            return false;
        }
        self.drop_display(h);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dropped_display_touches_another_and_lines_up_when_nearly_flush() {
        let others = [(0, 0, 1920, 1080)];
        assert_eq!(snap(1900, 10, 1280, 1024, &others), (1920, 0), "right of it, lined up with its top");
        assert_eq!(snap(3000, 500, 1280, 1024, &others), (1920, 500), "pulled back to touch");
        assert_eq!(snap(100, 1100, 1280, 1024, &others), (100, 1080), "below it");
    }

    #[test]
    fn the_page_reads_as_one_line_and_its_controls_are_hit_where_drawn() {
        let s = DisplaysPaneState::sample();
        assert_eq!(status_line(&s.heads), "DP-1 2560x1440 at 0,0 scale 1.25; HDMI-A-1 1920x1200 at 2048,0 scale 1");
        let l = displays_layout(Rect::new(0.0, 100.0, 760.0, 500.0), &s);
        assert_eq!(l.modes.len(), 2);
        assert_eq!(l.scales.iter().map(|r| r.value.as_str()).collect::<Vec<_>>(), ["1", "1.25", "1.5", "2"]);
        for (n, r) in &l.displays {
            assert_eq!(displays_hit(&l, r.x + r.w / 2.0, r.y + r.h / 2.0), Some(DisplaysHit::Display(n.clone())))
        }
        assert_eq!(mode_words(&s.heads[0].modes[0], &s.heads[0].modes), "2560 × 1440 (native)");
    }

    #[test]
    fn a_resize_moves_those_to_the_right() {
        let s = DisplaysPaneState::sample();
        let mut heads = s.heads.clone();
        heads[0].scale = 2.0;
        let r = resized(&heads, "DP-1", &s.heads[0]);
        assert_eq!(r[1].x, 2048 - (2048 - 1280));
    }
}
