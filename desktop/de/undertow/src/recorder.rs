//! The flight recorder (FlightRecorder.swift, PHASE6.md P6.1; DESKTOP.md
//! §10). "A claim of 60/120/144 fps, no jank is worthless without a meter."
//! Cheap enough to leave on always, and what the C1–C5 benches assert
//! against.
//!
//! Records are plain data in a preallocated ring: recording a frame is a
//! copy into a slot, no allocation and no lock. Swift shared the ring
//! between threads with an atomic count for a HUD reader yet to exist; here
//! it is the present thread's, by `&mut`, until such a reader does.

use std::cell::RefCell;

/// One frame, as it happened.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FrameRecord {
    pub seq: u64,
    /// The vblank this frame aimed at, and when it actually landed.
    pub predicted_vblank: u64,
    pub actual_vblank: u64,
    /// When the loop woke and latched, and when the composite finished.
    pub latch: u64,
    pub composite_end: u64,
    pub submit: u64,
    /// The margin the loop woke by, and what the composite cost.
    pub margin_ns: u64,
    pub cost_ns: u64,
    /// How late the OS woke us past the deadline: under adversarial load,
    /// where a flooder's traffic shows up.
    pub wake_late_ns: u64,
    pub damage_area: i64,
    pub surfaces: i32,
    pub missed: bool,
    pub degraded: bool,
    /// Nothing changed, so nothing was drawn or sent to the display (M.1).
    pub idle: bool,
}

pub struct FlightRecorder {
    slots: Vec<FrameRecord>,
    count: u64,
    /// For percentile queries, preallocated so even reading allocates
    /// nothing.
    scratch: RefCell<Vec<u64>>,
}

impl FlightRecorder {
    pub fn new(capacity: usize) -> FlightRecorder {
        let capacity = capacity.max(1);
        FlightRecorder { slots: vec![FrameRecord::default(); capacity], count: 0, scratch: RefCell::new(vec![0; capacity]) }
    }

    pub fn capacity(&self) -> usize {
        self.slots.len()
    }

    /// Record one frame. When the ring wraps it overwrites the oldest: a
    /// flight recorder keeps the recent past and never grows or blocks.
    #[inline(always)]
    pub fn record(&mut self, r: FrameRecord) {
        let n = self.slots.len() as u64;
        self.slots[(self.count % n) as usize] = r;
        self.count = self.count.wrapping_add(1);
    }

    /// Frames recorded in total (may exceed the capacity).
    pub fn count(&self) -> u64 {
        self.count
    }

    /// How many are still retained in the ring.
    pub fn retained(&self) -> usize {
        self.count.min(self.slots.len() as u64) as usize
    }

    /// The i-th retained record, oldest first.
    pub fn retained_record(&self, i: usize) -> FrameRecord {
        let n = self.slots.len() as u64;
        let first = self.count.saturating_sub(n);
        self.slots[((first + i as u64) % n) as usize]
    }

    pub fn missed_count(&self) -> usize {
        (0..self.retained()).filter(|&i| self.retained_record(i).missed).count()
    }

    pub fn degraded_count(&self) -> usize {
        (0..self.retained()).filter(|&i| self.retained_record(i).degraded).count()
    }

    /// The p-th percentile of composite cost, in ns. **p99, never max**:
    /// one outlier in a VM proves nothing (PHASE6.md §6).
    pub fn cost_percentile_ns(&self, p: f64) -> u64 {
        self.percentile(p, |r| r.cost_ns)
    }

    /// The p-th percentile of any field, nearest rank. Off the present
    /// path: nothing calls it from the loop.
    pub fn percentile(&self, p: f64, field: impl Fn(&FrameRecord) -> u64) -> u64 {
        let n = self.retained();
        if n == 0 {
            return 0;
        }
        let mut scratch = self.scratch.borrow_mut();
        for i in 0..n {
            scratch[i] = field(&self.retained_record(i));
        }
        let view = &mut scratch[..n];
        view.sort_unstable();
        let rank = p.clamp(0.0, 100.0) / 100.0 * (n - 1) as f64;
        view[rank.round() as usize]
    }
}
