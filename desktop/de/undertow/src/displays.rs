//! Where each output sits in the desktop, as a pure value (Displays.swift
//! and DisplaysFile.swift, PHASE14 P14.7).
//!
//! The desktop is one coordinate space, the **layout**, and each output
//! shows a rectangle of it. Windows, layer surfaces, popups and the pointer
//! live in layout coordinates; only the scene that draws an output, and the
//! cursor it draws, subtract that output's origin. The first display is the
//! **main display**, as a Mac has one: the menu bar and the Dock go there,
//! new windows open there, and it sits at the origin.

use crate::geometry::Rect;
use pool_config::Config;
use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq)]
pub struct DisplayBox {
    /// The output's name (`HEADLESS-1`, `DP-2`): the key everything uses.
    pub name: String,
    /// Where it sits in the layout, and its size in layout units (its mode
    /// divided by its scale).
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    /// Buffer pixels per layout unit.
    pub scale: f64,
}

impl DisplayBox {
    pub fn new(name: &str, x: i32, y: i32, width: i32, height: i32) -> DisplayBox {
        DisplayBox { name: name.into(), x, y, width, height, scale: 1.0 }
    }

    pub fn rect(&self) -> Rect {
        Rect::new(self.x, self.y, self.width, self.height)
    }

    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= f64::from(self.x) && py >= f64::from(self.y) && px < f64::from(self.x + self.width) && py < f64::from(self.y + self.height)
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DisplayLayout {
    /// In order; the first is the main display.
    pub displays: Vec<DisplayBox>,
}

impl DisplayLayout {
    /// Outputs side by side, left to right, tops aligned: where a newly
    /// found output goes when nothing has said otherwise.
    pub fn row(sizes: &[(&str, i32, i32)]) -> DisplayLayout {
        let mut x = 0;
        let displays = sizes
            .iter()
            .map(|&(name, w, h)| {
                let d = DisplayBox::new(name, x, 0, w, h);
                x += w;
                d
            })
            .collect();
        DisplayLayout { displays }
    }

    pub fn main(&self) -> Option<&DisplayBox> {
        self.displays.first()
    }

    pub fn named(&self, name: &str) -> Option<&DisplayBox> {
        self.displays.iter().find(|d| d.name == name)
    }

    /// The smallest rectangle holding every display.
    pub fn bounds(&self) -> Rect {
        let Some(f) = self.displays.first() else { return Rect::default() };
        let (mut x0, mut y0, mut x1, mut y1) = (f.x, f.y, f.x + f.width, f.y + f.height);
        for d in &self.displays[1..] {
            (x0, y0, x1, y1) = (x0.min(d.x), y0.min(d.y), x1.max(d.x + d.width), y1.max(d.y + d.height));
        }
        Rect::new(x0, y0, x1 - x0, y1 - y0)
    }

    /// The display a point is on, if any: there may be gaps between them.
    pub fn display_at(&self, px: f64, py: f64) -> Option<&DisplayBox> {
        self.displays.iter().find(|d| d.contains(px, py))
    }

    /// The display a rectangle is mostly on: the one holding its centre, else
    /// the one it overlaps most, else the main display.
    pub fn display_for(&self, r: Rect) -> Option<&DisplayBox> {
        let (cx, cy) = (f64::from(r.x) + f64::from(r.width) / 2.0, f64::from(r.y) + f64::from(r.height) / 2.0);
        if let Some(d) = self.display_at(cx, cy) {
            return Some(d);
        }
        let overlap = |d: &DisplayBox| {
            let w = (r.x + r.width).min(d.x + d.width) - r.x.max(d.x);
            let h = (r.y + r.height).min(d.y + d.height) - r.y.max(d.y);
            if w > 0 && h > 0 { i64::from(w) * i64::from(h) } else { 0 }
        };
        // The first of equals, as Swift's max(by:) gives the last; ties are
        // two displays a rectangle covers equally, either is right.
        let best = self.displays.iter().max_by_key(|d| overlap(d));
        best.filter(|d| overlap(d) > 0).or(self.main())
    }

    /// Keep a point on some display: a cursor in the gap between two
    /// screens addresses nothing anyone can see. The nearest point of the
    /// nearest display.
    pub fn clamp(&self, px: f64, py: f64) -> (f64, f64) {
        if self.display_at(px, py).is_some() {
            return (px, py);
        }
        let (mut best, mut best_d) = ((px, py), f64::INFINITY);
        for d in &self.displays {
            let cx = px.max(f64::from(d.x)).min(f64::from(d.x + d.width) - 1.0);
            let cy = py.max(f64::from(d.y)).min(f64::from(d.y + d.height) - 1.0);
            let dist = (cx - px).powi(2) + (cy - py).powi(2);
            if dist < best_d {
                (best_d, best) = (dist, (cx, cy));
            }
        }
        best
    }

    /// Replace one display's box (a mode, a move, a scale), keeping order.
    pub fn update(&mut self, b: DisplayBox) {
        if let Some(d) = self.displays.iter_mut().find(|d| d.name == b.name) {
            *d = b;
        }
    }

    pub fn remove(&mut self, name: &str) {
        self.displays.retain(|d| d.name != name);
    }

    /// The layout as one log line (`HEADLESS-1 1024x768@0,0 main;
    /// HEADLESS-2 800x600@1024,0`), which is how a test reads it back. A
    /// scale prints as Swift printed it (`2.0`), which the tests match.
    pub fn summary(&self) -> String {
        let parts: Vec<String> = self
            .displays
            .iter()
            .enumerate()
            .map(|(i, d)| {
                let scale = if d.scale == 1.0 { String::new() } else { format!(" scale {:?}", d.scale) };
                format!("{} {}x{}@{},{}{scale}{}", d.name, d.width, d.height, d.x, d.y, if i == 0 { " main" } else { "" })
            })
            .collect();
        parts.join("; ")
    }
}

// MARK: a configuration: what a client asks for, and what is kept (P14.7b)

/// One output as a configuration names it: its mode in buffer pixels, where
/// it sits, and its scale. The layout box follows: mode ÷ scale.
#[derive(Clone, Debug, PartialEq)]
pub struct DisplaySetting {
    pub name: String,
    pub enabled: bool,
    pub mode_width: i32,
    pub mode_height: i32,
    /// mHz; 0 for "whatever the output has".
    pub refresh_milli_hz: i32,
    pub x: i32,
    pub y: i32,
    pub scale: f64,
}

impl DisplaySetting {
    pub fn display_box(&self) -> DisplayBox {
        let size = |v: i32| (f64::from(v) / self.scale).round() as i32;
        DisplayBox { name: self.name.clone(), x: self.x, y: self.y, width: size(self.mode_width), height: size(self.mode_height), scale: self.scale }
    }
}

/// Why a requested arrangement is refused, in words; empty when it may be
/// applied. Checked before anything is committed: applied whole or not at
/// all, as the protocol says.
pub fn problems(settings: &[DisplaySetting]) -> Vec<String> {
    if settings.is_empty() {
        return vec!["a configuration must name at least one display".into()];
    }
    let mut out = vec![];
    for s in settings.iter().filter(|s| !s.enabled) {
        // Turning a display off means taking it out of the run loop and
        // moving everything on it; not yet.
        out.push(format!("{}: turning a display off is not supported yet", s.name));
    }
    for s in settings {
        if !(0.5..=4.0).contains(&s.scale) {
            out.push(format!("{}: a scale of {:?} is outside 0.5 to 4", s.name, s.scale));
        }
        if s.mode_width <= 0 || s.mode_height <= 0 {
            out.push(format!("{}: {}x{} is not a mode", s.name, s.mode_width, s.mode_height));
        }
    }
    let boxes: Vec<DisplayBox> = settings.iter().filter(|s| s.enabled).map(DisplaySetting::display_box).collect();
    for (i, a) in boxes.iter().enumerate() {
        for b in &boxes[i + 1..] {
            let w = (a.x + a.width).min(b.x + b.width) - a.x.max(b.x);
            let h = (a.y + a.height).min(b.y + b.height) - a.y.max(b.y);
            if w > 0 && h > 0 {
                out.push(format!("{} and {} overlap", a.name, b.name));
            }
        }
    }
    out
}

/// `x,y WxH@mHz scale`: one line per display in displays.ini.
pub fn format_setting(s: &DisplaySetting) -> String {
    let scale = if s.scale == s.scale.round() { format!("{}", s.scale as i64) } else { format!("{}", s.scale) };
    format!("{},{} {}x{}@{} {scale}", s.x, s.y, s.mode_width, s.mode_height, s.refresh_milli_hz)
}

pub fn parse_setting(name: &str, value: &str) -> Option<DisplaySetting> {
    let f: Vec<&str> = value.split(' ').filter(|w| !w.is_empty()).collect();
    let [xy, mode, scale] = f.as_slice() else { return None };
    let (x, y) = xy.split_once(',')?;
    let (wh, r) = mode.split_once('@')?;
    let (w, h) = wh.split_once('x')?;
    Some(DisplaySetting {
        name: name.into(),
        enabled: true,
        mode_width: w.parse().ok()?,
        mode_height: h.parse().ok()?,
        refresh_milli_hz: r.parse().ok()?,
        x: x.parse().ok()?,
        y: y.parse().ok()?,
        scale: scale.parse().ok()?,
    })
}

// displays.ini: the arrangement a person chose, kept per user and applied
// at start (P14.7b). Written by undertow when a configuration is applied,
// whoever sent it (the Displays pane, wlr-randr, kanshi), so the file is
// always what is on screen.

const DOMAIN: &str = "displays";
const SECTION: &str = "displays";

pub fn load_settings(config_dir: Option<&str>) -> BTreeMap<String, DisplaySetting> {
    let Ok(c) = pool_config::load(DOMAIN, config_dir) else { return BTreeMap::new() };
    c.pairs(SECTION).iter().filter_map(|(k, v)| parse_setting(k, v).map(|s| ((*k).to_owned(), s))).collect()
}

pub fn store_settings(settings: &[DisplaySetting], config_dir: Option<&str>) -> Result<(), pool_config::Error> {
    let mut c = pool_config::load(DOMAIN, config_dir).unwrap_or_else(|_| Config::new());
    for s in settings {
        c.set(SECTION, &s.name, &format_setting(s));
    }
    c.store(DOMAIN, config_dir)
}
