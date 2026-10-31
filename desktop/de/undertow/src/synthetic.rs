//! A synthetic display and a synthetic scene (Synthetic.swift, PHASE6.md
//! P6.1).
//!
//! The metronome has to be provable before there is anything to show, so
//! this is a display made of arithmetic. Not a mock that always agrees: it
//! models the two things about a real display the scheduler must cope with:
//! flips complete *asynchronously*, and a frame submitted after its target
//! vblank lands on a later one. A bench that needs no compositor runs in
//! every `cargo test` on both platforms.

use crate::metronome::since;
use crate::output::{Flip, FrameSink, FrameStats, Output};
use abyss_sys::mono;

const RING: usize = 4;

/// A fixed-rate display, in software.
pub struct SyntheticOutput {
    pub period_ns: u64,
    /// How long the backend takes to execute a submitted frame: the commit
    /// latency the latch margin has to cover.
    pub commit_latency_ns: u64,
    /// Flips submitted and not yet collected: a fixed ring, not a growing
    /// queue, because a real display has a bounded number of frames in
    /// flight (and the first Swift version's Array allocated on the present
    /// path, which `bench-alloc` caught).
    ring: [Flip; RING],
    head: usize,
    tail: usize,
    used: usize,
    /// The display's own vblank grid, `epoch + k * period`, fixed at the
    /// first submit and independent of anything the compositor predicts:
    /// a display that computed its vblank from the predictor's target would
    /// let the predictor observe its own guesses.
    epoch: u64,
}

impl SyntheticOutput {
    pub fn new(period_ns: u64, commit_latency_ns: u64) -> SyntheticOutput {
        SyntheticOutput { period_ns, commit_latency_ns, ring: [Flip::default(); RING], head: 0, tail: 0, used: 0, epoch: 0 }
    }

    /// For benches that do not sleep: report a pending flip without waiting
    /// for its vblank to arrive in real time.
    pub fn drain_regardless_of_time(&mut self) -> Option<Flip> {
        if self.used == 0 {
            return None;
        }
        let f = self.ring[self.head];
        self.head = (self.head + 1) % RING;
        self.used -= 1;
        Some(f)
    }
}

impl Output for SyntheticOutput {
    fn period_hint_ns(&self) -> u64 {
        self.period_ns
    }

    fn submit(&mut self, target: u64, now: u64) {
        if self.epoch == 0 {
            self.epoch = now;
        }
        let ready = now + self.commit_latency_ns;
        // The first vblank OF THE DISPLAY'S OWN GRID at or after it is
        // ready, never the one the compositor hoped for.
        let k = since(self.epoch, ready).div_ceil(self.period_ns);
        let vblank = self.epoch + k * self.period_ns;
        // A full ring drops the frame rather than growing: a queue that
        // could grow would hide the very pile-up the contract is about.
        if self.used >= RING {
            return;
        }
        self.ring[self.tail] = Flip { target, vblank, done: ready, missed: vblank > target, refused: false };
        self.tail = (self.tail + 1) % RING;
        self.used += 1;
    }

    fn poll_flip(&mut self) -> Option<Flip> {
        // Asynchronous by construction: a flip is visible once its vblank has
        // passed, as from a DRM event descriptor.
        if self.used == 0 || mono::now() < self.ring[self.head].vblank {
            return None;
        }
        self.drain_regardless_of_time()
    }
}

/// A structure-of-arrays scene, preallocated once (DESKTOP.md §4): parallel
/// arrays of rects walked linearly, no per-node allocation.
pub struct SyntheticScene {
    x: Vec<i32>,
    y: Vec<i32>,
    w: Vec<i32>,
    h: Vec<i32>,
    damage: Vec<i32>,
    viewport: (i32, i32),
    /// Advances each frame so the composite is never trivially cacheable.
    phase: i32,
}

impl SyntheticScene {
    pub fn new(surfaces: usize, viewport: (i32, i32)) -> SyntheticScene {
        let n = surfaces;
        let x = (0..n).map(|i| ((i * 37) % viewport.0 as usize) as i32).collect();
        let y = (0..n).map(|i| ((i * 53) % viewport.1 as usize) as i32).collect();
        SyntheticScene { x, y, w: vec![160; n], h: vec![120; n], damage: vec![0; n], viewport, phase: 0 }
    }
}

impl FrameSink for SyntheticScene {
    /// Cull to the viewport and accumulate damage: bounded, branchy enough
    /// not to be optimised away, and allocation-free.
    fn latch_and_composite(&mut self, _now: u64, _target: u64) -> FrameStats {
        self.phase = self.phase.wrapping_add(1);
        let (vw, vh) = self.viewport;
        let (mut painted, mut area) = (0i32, 0i64);
        for i in 0..self.x.len() {
            let px = self.x[i] + (self.phase & 0x3F);
            let (r, b) = (px + self.w[i], self.y[i] + self.h[i]);
            if r <= 0 || b <= 0 || px >= vw || self.y[i] >= vh {
                continue;
            }
            let (cw, ch) = (r.min(vw) - px.max(0), b.min(vh) - self.y[i].max(0));
            if cw > 0 && ch > 0 {
                self.damage[i] = cw * ch;
                area += i64::from(cw * ch);
                painted += 1;
            }
        }
        FrameStats { surfaces: painted, damage_area: area, ..FrameStats::default() }
    }
}
