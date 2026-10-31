//! The metronome (Metronome.swift, PHASE6.md P6.1; DESKTOP.md §3.1).
//!
//! The loop invariant that turns "present at refresh rate" from a hope into
//! code:
//!
//! ```text
//! loop:
//!     T_v      = predict_next_vblank()      # EWMA over flip feedback
//!     deadline = T_v - margin               # margin adapts to measured cost
//!     sleep_until(deadline)                 # absolute, not an interval
//!     poll flip completions                 # async -> feeds the predictor
//!     latch + composite                     # bounded, allocation-free
//!     submit                                # fire-and-forget
//!     record                                # flight recorder
//! ```
//!
//! **Late-latching**: we sleep until just before the deadline and *then*
//! read the freshest committed state (C3). **Predict, don't react**: a frame
//! is aimed at a vblank that hasn't happened yet; on a bad prediction we
//! fall to the next period and log it (C4), never tear, never stall. The
//! loop body has no call that can block on a client and no allocation a
//! client can starve: C2 by construction.

use crate::output::{Flip, FrameSink, Output};
use crate::recorder::{FlightRecorder, FrameRecord};
use crate::switch_latency::SwitchLatencies;
use abyss_sys::mono;

/// `a - b`, clamped at zero: a u64 that goes negative wraps to ~584 years.
#[inline(always)]
pub fn since(b: u64, a: u64) -> u64 {
    a.saturating_sub(b)
}

/// Predicts the next vblank from flip feedback. The period is an EWMA over
/// observed intervals rather than the advertised rate, a rounded lie on most
/// hardware (59.94 reported as 60).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VblankPredictor {
    pub period_ns: u64,
    /// The most recent vblank we know actually happened.
    pub last_vblank_ns: u64,
    pub samples: u64,
    seed_ns: u64,
}

/// EWMA weight as a shift: period += (obs - period)/8. Fast enough to track
/// a mode switch in a few frames, slow enough that one stalled sample
/// cannot move it far.
const SHIFT: u32 = 3;

impl VblankPredictor {
    pub fn new(period_hint_ns: u64) -> VblankPredictor {
        let seed = period_hint_ns.max(1);
        VblankPredictor { period_ns: seed, last_vblank_ns: 0, samples: 0, seed_ns: seed }
    }

    /// Feed a completed flip back in.
    pub fn observe(&mut self, flip: &Flip) {
        let last = self.last_vblank_ns;
        self.last_vblank_ns = last.max(flip.vblank);
        if last == 0 || flip.vblank <= last {
            return;
        }
        let interval = flip.vblank - last;
        // A gap is usually several whole periods (we skipped frames), not a
        // changed refresh rate: divide it down first, or one missed frame
        // teaches the predictor the display runs at half rate.
        let periods = ((interval + self.period_ns / 2) / self.period_ns).max(1);
        let per_period = interval / periods;
        // Reject the implausible outright: ±12.5% is wide enough for
        // 59.94-as-60 and thermal drift, narrow enough to reject a stall or
        // a clock jump. A real mode change calls `reseed`.
        let (low, high) = (self.period_ns - (self.period_ns >> 3), self.period_ns + (self.period_ns >> 3));
        if per_period < low || per_period > high {
            return;
        }
        self.period_ns = self.period_ns - (self.period_ns >> SHIFT) + (per_period >> SHIFT);
        self.samples += 1;
    }

    /// The first vblank strictly after `now`.
    pub fn predict_next(&self, now: u64) -> u64 {
        if self.last_vblank_ns == 0 {
            return now.wrapping_add(self.period_ns);
        }
        if now < self.last_vblank_ns {
            return self.last_vblank_ns;
        }
        let k = (now - self.last_vblank_ns) / self.period_ns + 1;
        self.last_vblank_ns.wrapping_add(k.wrapping_mul(self.period_ns))
    }

    /// Forget the phase but keep the period: after a mode change or a long
    /// idle, the next flip's timestamp is the only trustworthy phase.
    pub fn reset_phase(&mut self) {
        self.last_vblank_ns = 0;
    }

    /// Abandon a period estimate that has drifted somewhere useless.
    pub fn reseed(&mut self) {
        self.period_ns = self.seed_ns;
        self.last_vblank_ns = 0;
        self.samples = 0;
    }
}

/// How early to wake before the target vblank. A frame is late if any of
/// several things ran long, so the margin is the sum of separately
/// *measured* quantities plus a small feedback term:
///
/// ```text
/// margin = wake_high + cost_high + commit_high + vblank_high + safety
/// ```
///
/// how late the OS woke us, how long the composite took, how long the
/// display took to execute the frame, how far a vblank landed from its
/// prediction (PHASE4 §5.13), and the unmeasured remainder, grown on a miss.
/// Measuring each is what makes the margin both smaller and steadier.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LatchMargin {
    pub wake_high_ns: u64,
    pub cost_high_ns: u64,
    pub commit_high_ns: u64,
    pub vblank_high_ns: u64,
    pub safety_ns: u64,
    pub floor_ns: u64,
    pub ceil_ns: u64,
}

impl LatchMargin {
    pub fn new(floor_ns: u64, ceil_ns: u64) -> LatchMargin {
        LatchMargin { wake_high_ns: 0, cost_high_ns: 0, commit_high_ns: 0, vblank_high_ns: 0, safety_ns: floor_ns, floor_ns, ceil_ns: ceil_ns.max(floor_ns) }
    }

    /// What the loop subtracts from the target vblank.
    pub fn margin_ns(&self) -> u64 {
        let want = self.wake_high_ns + self.cost_high_ns + self.commit_high_ns + self.vblank_high_ns + self.safety_ns;
        want.clamp(self.floor_ns, self.ceil_ns)
    }

    /// Decaying maximum: straight up to a new high, ~0.4% a frame down from
    /// an old one, so at 240 Hz one outlier is not forgotten before the next.
    #[inline(always)]
    fn decay_max(high: u64, sample: u64) -> u64 {
        if sample > high { sample } else { high - (high >> 8) }
    }

    /// Fold in one frame's outcome. Over-correcting costs latency;
    /// under-correcting costs another dropped frame.
    pub fn observe(&mut self, cost_ns: u64, wake_late_ns: u64, missed: bool) {
        self.cost_high_ns = LatchMargin::decay_max(self.cost_high_ns, cost_ns);
        self.wake_high_ns = LatchMargin::decay_max(self.wake_high_ns, wake_late_ns);
        self.safety_ns = if missed {
            self.safety_ns.saturating_mul(2).clamp(self.floor_ns, self.ceil_ns)
        } else {
            (self.safety_ns - (self.safety_ns >> 8)).max(self.floor_ns)
        };
    }

    /// Fold in a measured commit latency, from flip feedback.
    pub fn observe_commit(&mut self, latency_ns: u64) {
        self.commit_high_ns = LatchMargin::decay_max(self.commit_high_ns, latency_ns);
    }

    /// Fold in how far a vblank landed from its prediction, either way.
    pub fn observe_vblank_error(&mut self, error_ns: u64) {
        self.vblank_high_ns = LatchMargin::decay_max(self.vblank_high_ns, error_ns);
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Config {
    /// Skip the sleep and free-run, for benches that measure work rather
    /// than cadence.
    pub free_run: bool,
    /// Cap on the latch margin.
    pub margin_ceil_ns: u64,
}

impl Default for Config {
    fn default() -> Config {
        Config { free_run: false, margin_ceil_ns: 8_000_000 }
    }
}

/// The next frame an output should make: the vblank it aims at and the
/// moment it must wake to make it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Plan {
    pub entry: u64,
    pub target: u64,
    pub deadline: u64,
    pub margin_ns: u64,
}

/// The frame scheduler.
#[derive(Clone, Debug)]
pub struct Metronome {
    pub predictor: VblankPredictor,
    pub margin: LatchMargin,
    pub seq: u64,
    /// The vblank the last frame was fired for. A plan never aims at it
    /// again: one frame per vblank per output (P14.7a).
    pub last_target: u64,
    pub config: Config,
    /// C6 (P13.2): island switches, input to the vblank that showed them.
    /// One in flight per output; a second switch before the first is shown
    /// is measured from the earlier input.
    pub c6: SwitchLatencies,
    c6_input_at: u64,
    c6_target: u64,
    /// The frame carrying the switch was refused: the next one carries it.
    c6_carry: bool,
}

impl Metronome {
    pub fn new(period_hint_ns: u64, config: Config) -> Metronome {
        Metronome {
            predictor: VblankPredictor::new(period_hint_ns),
            // Below a whole period: a margin of a period makes every vblank
            // unreachable, and the loop runs at half rate for ever. Three
            // quarters leaves room to latch, and makes a genuinely expensive
            // composite degrade to half rate rather than thrash.
            margin: LatchMargin::new(50_000, config.margin_ceil_ns.min(period_hint_ns * 3 / 4)),
            seq: 0,
            last_target: 0,
            config,
            c6: SwitchLatencies::default(),
            c6_input_at: 0,
            c6_target: 0,
            c6_carry: false,
        }
    }

    /// The output's refresh rate changed (a new mode, P14.7b): predict again
    /// from the new period. The margin is kept: a composite's cost did not
    /// change with the mode.
    pub fn retune(&mut self, period_hint_ns: u64) {
        self.predictor = VblankPredictor::new(period_hint_ns);
        self.last_target = 0;
    }

    /// The next frame, as pure bookkeeping: no waiting, so a loop driving
    /// several outputs can ask each and serve the earliest (P14.7a).
    pub fn plan(&self, entry: u64) -> Plan {
        let m = self.margin.margin_ns();
        let mut target = self.predictor.predict_next(entry);
        if !self.config.free_run {
            let period = self.predictor.period_ns;
            // Aim at a vblank we can still MAKE: compositing for one closer
            // than our margin is guaranteed late, and the first version did,
            // a runaway (the miss grows the margin, which makes the next
            // vblank unreachable too). **And never the same vblank twice**
            // (PHASE4 §5.13): the predictor re-estimates as flips arrive, so
            // the last target can come back a few hundred µs later, and on
            // metal that was a second commit refused as "a page-flip is
            // already pending". Within half a period of the last target *is*
            // the last target.
            let floor = if self.last_target == 0 { 0 } else { self.last_target + period / 2 };
            while target < entry.wrapping_add(m) || target < floor {
                target = target.wrapping_add(period);
            }
        }
        let deadline = if target > m { target - m } else { entry };
        Plan { entry, target, deadline: if self.config.free_run { entry } else { deadline }, margin_ns: m }
    }

    /// One frame: plan, wait, fire.
    #[inline(always)]
    pub fn step<O: Output, S: FrameSink>(&mut self, output: &mut O, sink: &mut S, recorder: &mut FlightRecorder) {
        let p = self.plan(mono::now());
        // Through the output: a real backend has an event loop to service
        // while it waits.
        if !self.config.free_run {
            output.wait_until(p.deadline);
        }
        self.fire(p, output, sink, recorder);
    }

    pub fn run<O: Output, S: FrameSink>(&mut self, frames: u64, output: &mut O, sink: &mut S, recorder: &mut FlightRecorder) {
        for _ in 0..frames {
            self.step(output, sink, recorder);
        }
    }

    /// Steps 3 to 5 of a frame planned by `plan`, once its deadline has come.
    #[inline(always)]
    pub fn fire<O: Output, S: FrameSink>(&mut self, p: Plan, output: &mut O, sink: &mut S, recorder: &mut FlightRecorder) {
        let mut r = FrameRecord { seq: self.seq, predicted_vblank: p.target, margin_ns: p.margin_ns, ..FrameRecord::default() };
        self.seq += 1;
        let (m, target, deadline) = (p.margin_ns, p.target, p.deadline);
        self.last_target = target;

        // 3. Drain flip feedback BEFORE latching, so the prediction behind
        //    this frame is the freshest available.
        while let Some(flip) = output.poll_flip() {
            // The frame that drew an island switch reached the screen, or was
            // refused and the next must (C6).
            if self.c6_input_at != 0 && flip.target == self.c6_target {
                if flip.refused {
                    self.c6_carry = true;
                } else {
                    self.c6.record(self.c6_input_at, flip.vblank, self.predictor.period_ns);
                    self.c6_input_at = 0;
                }
            }
            // A refused commit never reached the screen: a miss, for the
            // recorder and the margin's safety term, which is how the loop
            // learns a margin too small for the flip pipeline. It has no
            // vblank, so the predictor and the commit term skip it.
            if flip.refused {
                r.missed = true;
                continue;
            }
            self.predictor.observe(&flip);
            self.margin.observe_commit(since(flip.target.wrapping_sub(m), flip.done));
            // How wrong the prediction was, for a frame that landed on its
            // vblank. A late one is a miss, not an estimate error, and its
            // whole period would pin the margin for ever.
            if !flip.missed {
                self.margin.observe_vblank_error(flip.vblank.abs_diff(flip.target));
            }
            r.actual_vblank = flip.vblank;
            r.missed |= flip.missed;
        }

        // 4. Latch and composite: bounded work, the only part C1's 2 ms
        //    budget is about.
        let latch = mono::now();
        let wake_late = if self.config.free_run { 0 } else { since(deadline, latch) };
        let stats = sink.latch_and_composite(latch, target);
        let composite_end = mono::now();
        (r.latch, r.composite_end, r.cost_ns, r.surfaces) = (latch, composite_end, since(latch, composite_end), stats.surfaces);
        // **Nothing changed: nothing to draw, nothing to send** (M.1). Idle,
        // not missed, and not fed to the margin. A switch that changed
        // nothing visible is on screen already: C6 counts it at this vblank.
        if stats.unchanged {
            if stats.input_at != 0 {
                self.c6.record(stats.input_at, target, self.predictor.period_ns);
            }
            r.idle = true;
            r.missed = false;
            recorder.record(r);
            return;
        }
        if stats.input_at != 0 {
            if self.c6_input_at == 0 {
                self.c6_input_at = stats.input_at;
            }
            self.c6_target = target;
            self.c6_carry = false;
        } else if self.c6_carry {
            self.c6_target = target;
            self.c6_carry = false;
        }

        // 5. Fire and forget. We never wait for the display.
        output.submit(target, composite_end);
        r.submit = composite_end;
        r.wake_late_ns = wake_late;
        r.damage_area = stats.damage_area;
        r.degraded = stats.degraded;
        // We woke too late to make this vblank: our own fault, a miss before
        // the display confirms it.
        if composite_end > target {
            r.missed = true;
        }
        self.margin.observe(r.cost_ns, wake_late, r.missed);
        recorder.record(r);
    }
}

/// Several outputs on one loop, each with its own metronome (PHASE14
/// P14.7a). **Earliest deadline first.** Each output holds one *pending*
/// plan until that frame is fired; the loop waits for the earliest deadline
/// and fires every output whose deadline has come, in deadline order. Only
/// an output that has just fired plans again, so a 144 Hz panel beside a
/// 60 Hz one is served at 144 and 60. Two earlier versions re-planned every
/// output on every pass, and each starved an output for ever: a plan kept
/// until it fires cannot recede.
pub struct Conductor<O: Output, S: FrameSink> {
    pub outputs: Vec<O>,
    pub sinks: Vec<S>,
    pub metronomes: Vec<Metronome>,
    pending: Vec<Option<Plan>>,
}

impl<O: Output, S: FrameSink> Conductor<O, S> {
    pub fn new(outputs: Vec<O>, sinks: Vec<S>, config: Config) -> Conductor<O, S> {
        assert!(!outputs.is_empty() && outputs.len() == sinks.len(), "an output per sink, and at least one");
        let metronomes = outputs.iter().map(|o| Metronome::new(o.period_hint_ns(), config)).collect();
        let pending = vec![None; outputs.len()];
        Conductor { outputs, sinks, metronomes, pending }
    }

    /// Output `i` has a new refresh rate: its pending frame is dropped.
    pub fn retune(&mut self, i: usize, period_hint_ns: u64) {
        self.metronomes[i].retune(period_hint_ns);
        self.pending[i] = None;
    }

    /// Wait for the earliest deadline and serve every output due. Whether
    /// output 0, the main display, was among them.
    pub fn serve_next(&mut self, recorders: &mut [FlightRecorder]) -> bool {
        let now = mono::now();
        for (i, p) in self.pending.iter_mut().enumerate() {
            if p.is_none() {
                *p = Some(self.metronomes[i].plan(now));
            }
        }
        let deadline = |p: &Option<Plan>| p.map_or(u64::MAX, |p| p.deadline);
        let mut order: Vec<usize> = (0..self.pending.len()).collect();
        order.sort_by_key(|&i| deadline(&self.pending[i]));
        self.outputs[order[0]].wait_until(deadline(&self.pending[order[0]]));
        let mut served_main = false;
        for (k, &i) in order.iter().enumerate() {
            let Some(p) = self.pending[i] else { continue };
            if k > 0 && p.deadline > mono::now() {
                break;
            }
            self.metronomes[i].fire(p, &mut self.outputs[i], &mut self.sinks[i], &mut recorders[i]);
            self.pending[i] = None;
            served_main |= i == 0;
        }
        served_main
    }
}
