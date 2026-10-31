//! One Ebb, open, opening or closing on one display (Ebb.swift's `Ebb`,
//! PHASE13 P13.5). The grid it lays windows out on is `geometry::ebb_arrange`.

use crate::geometry::{EbbScope, IslandSlide, Rect};

/// A window in Ebb: where it really is, and where Ebb draws it. By id:
/// the compositor owns the window.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EbbSlot {
    pub window: u32,
    pub home: Rect,
    pub slot: Rect,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Ebb {
    pub display: String,
    pub scope: EbbScope,
    pub slots: Vec<EbbSlot>,
    /// The window under the pointer, by id.
    pub hovered: Option<u32>,
    /// 0 is every window at home, 1 every window in its slot. Opening runs
    /// it up; closing runs it down from wherever it is, so Escape mid-way
    /// does not jump.
    from: f64,
    to: f64,
    start: u64,
    pub duration_ns: u64,
}

impl Ebb {
    pub fn new(display: &str, scope: EbbScope, slots: Vec<EbbSlot>, now: u64, duration_ns: u64) -> Ebb {
        Ebb { display: display.into(), scope, slots, hovered: None, from: 0.0, to: 1.0, start: now, duration_ns }
    }

    /// Eased, 0…1.
    pub fn progress(&self, now: u64) -> f64 {
        if self.duration_ns == 0 || now <= self.start {
            return if self.duration_ns == 0 { self.to } else { self.from };
        }
        let t = ((now - self.start) as f64 / self.duration_ns as f64).min(1.0);
        self.from + (self.to - self.from) * IslandSlide::ease(t)
    }

    pub fn closing(&self) -> bool {
        self.to == 0.0
    }

    pub fn finished(&self, now: u64) -> bool {
        self.closing() && self.progress(now) <= 0.0001
    }

    pub fn close(&mut self, now: u64) {
        if self.closing() {
            return;
        }
        self.from = self.progress(now);
        self.to = 0.0;
        self.start = now;
    }

    /// Where `s` is drawn at `now`.
    pub fn rect(&self, s: &EbbSlot, now: u64) -> Rect {
        let p = self.progress(now);
        let lerp = |a: i32, b: i32| (a as f64 + (b as f64 - a as f64) * p).round() as i32;
        Rect::new(lerp(s.home.x, s.slot.x), lerp(s.home.y, s.slot.y), lerp(s.home.width, s.slot.width), lerp(s.home.height, s.slot.height))
    }

    /// The topmost slot at a point, once open: hit-testing a moving picture
    /// would pick whatever happened to fly past.
    pub fn slot_at(&self, x: f64, y: f64) -> Option<&EbbSlot> {
        if self.closing() {
            return None;
        }
        self.slots.iter().rev().find(|s| x >= s.slot.x as f64 && x < (s.slot.x + s.slot.width) as f64 && y >= s.slot.y as f64 && y < (s.slot.y + s.slot.height) as f64)
    }

    pub fn forget(&mut self, window: u32) {
        self.slots.retain(|s| s.window != window);
    }
}
