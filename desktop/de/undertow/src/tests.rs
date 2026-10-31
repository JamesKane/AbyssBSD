//! The metronome's logic, without a clock to flake on (Tests/UndertowTests).
//!
//! **Cadence is not tested here.** "Did we hit 240 Hz for 600 frames"
//! depends on OS scheduling and would flake in a VM under load (PHASE6.md
//! §6), so it lives in `undertow bench-metronome`. What is here is the pure
//! logic, fed synthetic numbers, deterministic on any machine.

use crate::metronome::{since, Config, LatchMargin, Metronome, VblankPredictor};
use crate::output::*;
use crate::recorder::{FlightRecorder, FrameRecord};
use crate::switch_latency::SwitchLatencies;
use crate::synthetic::{SyntheticOutput, SyntheticScene};
use std::collections::{HashSet, VecDeque};

fn flip(t: u64, missed: bool) -> Flip {
    Flip { target: t, vblank: t, done: t, missed, refused: false }
}

// MARK: a desktop is not a bench with a large number in it

#[test]
fn a_frame_limit_is_optional_and_zero_means_until_stopped() {
    assert!(run_is_unbounded(0));
    assert!(!run_is_unbounded(1));
    assert!(!run_is_unbounded(1200));
}

#[test]
fn an_unbounded_run_keeps_a_rolling_window_rather_than_none_or_all_of_it() {
    assert_eq!(recorder_capacity(0), 2400);
    assert_eq!(recorder_capacity(300), 300);
    assert_eq!(recorder_capacity(1), 1);
}

// MARK: the display's rate is the truth, not the flag

#[test]
fn the_refresh_rate_comes_from_the_display() {
    assert_eq!(display_hz(60_000, 240), 60);
    assert_eq!(display_hz(144_000, 240), 144);
    assert_eq!(display_hz(240_000, 60), 240);
}

#[test]
fn a_panel_that_is_not_a_whole_number_of_hz_still_rounds_to_one() {
    assert_eq!(display_hz(59_940, 240), 60);
    assert_eq!(display_hz(143_980, 240), 144);
}

#[test]
fn an_output_with_no_mode_leaves_the_callers_default_alone() {
    assert_eq!(display_hz(0, 60), 60);
    assert_eq!(display_hz(-1, 75), 75);
}

// MARK: time

#[test]
fn saturating_subtraction_never_wraps() {
    assert_eq!(since(100, 250), 150);
    assert_eq!(since(250, 100), 0);
    assert_eq!(since(0, 0), 0);
}

// MARK: the vblank predictor

/// It must converge on the *measured* period, not the advertised one.
#[test]
fn predictor_converges_on_the_true_period_not_the_hint() {
    let true_period = 16_683_333; // 59.94 Hz
    let mut p = VblankPredictor::new(16_666_666); // the 60 Hz lie
    let mut t = 1_000_000_000;
    for _ in 0..200 {
        t += true_period;
        p.observe(&flip(t, false));
    }
    assert!(p.period_ns.abs_diff(true_period) < true_period / 1000, "converged to {}", p.period_ns);
}

/// A gap of several periods means skipped frames, NOT a halved rate.
#[test]
fn a_skipped_frame_does_not_halve_the_period_estimate() {
    let period = 16_666_666;
    let mut p = VblankPredictor::new(period);
    let mut t = 1_000_000_000;
    p.observe(&flip(t, false));
    for _ in 0..50 {
        t += period * 3;
        p.observe(&flip(t, true));
    }
    assert!(p.period_ns.abs_diff(period) < period / 100, "a 3-period gap moved the estimate to {}", p.period_ns);
}

/// A wild sample is a stall or a clock jump, not data.
#[test]
fn predictor_rejects_implausible_samples() {
    let period = 16_666_666;
    let mut p = VblankPredictor::new(period);
    let mut t = 1_000_000_000;
    for _ in 0..50 {
        t += period;
        p.observe(&flip(t, false));
    }
    let settled = p.period_ns;
    t += period * 7 / 5;
    p.observe(&flip(t, false));
    assert_eq!(p.period_ns, settled, "an implausible sample moved the estimate");
}

/// Whatever else it does, the next vblank is in the future.
#[test]
fn predicted_target_is_always_in_the_future() {
    let period = 16_666_666;
    let mut p = VblankPredictor::new(period);
    assert!(p.predict_next(5_000_000_000) > 5_000_000_000);
    let base = 1_000_000_000;
    p.observe(&flip(base, false));
    p.observe(&flip(base + period, false));
    for step in 0..70 {
        let now = base + step * (period / 7);
        assert!(p.predict_next(now) > now, "target not in the future at step {step}");
    }
}

/// Targets land on the display's grid, not off it.
#[test]
fn predicted_targets_land_on_the_vblank_grid() {
    let period = 10_000_000;
    let mut p = VblankPredictor::new(period);
    let base = 500_000_000;
    p.observe(&flip(base, false));
    for k in 1..=5 {
        let target = p.predict_next(base + period * k - 1_000);
        assert_eq!((target - base) % period, 0, "target {target} is off the grid");
    }
}

// MARK: the latch margin

/// Grow hard on a miss, give it back slowly.
#[test]
fn margin_grows_on_a_miss_and_decays_on_success() {
    let mut m = LatchMargin::new(50_000, 8_000_000);
    let start = m.margin_ns();
    for _ in 0..4 {
        m.observe(10_000, 0, true);
    }
    let after = m.margin_ns();
    assert!(after > start, "a miss must widen the margin");
    for _ in 0..2000 {
        m.observe(10_000, 0, false);
    }
    assert!(m.margin_ns() < after, "the margin must come back down");
}

/// One expensive frame widens the margin before the next frame.
#[test]
fn margin_tracks_a_spike_immediately() {
    let mut m = LatchMargin::new(1_000, 8_000_000);
    for _ in 0..100 {
        m.observe(20_000, 5_000, false);
    }
    let steady = m.margin_ns();
    m.observe(900_000, 5_000, false);
    assert!(m.margin_ns() > steady + 800_000, "a 900 µs composite did not immediately widen the margin");
}

/// Every measured term reaches the margin, or a miss caused by it could
/// never be corrected by observing it.
#[test]
fn every_measured_term_reaches_the_margin() {
    let mut wake = LatchMargin::new(1_000, 8_000_000);
    wake.observe(0, 300_000, false);
    assert!(wake.margin_ns() >= 300_000);
    let mut cost = LatchMargin::new(1_000, 8_000_000);
    cost.observe(300_000, 0, false);
    assert!(cost.margin_ns() >= 300_000);
    let mut commit = LatchMargin::new(1_000, 8_000_000);
    commit.observe_commit(300_000);
    assert!(commit.margin_ns() >= 300_000);
    let mut vblank = LatchMargin::new(1_000, 8_000_000);
    vblank.observe_vblank_error(300_000);
    assert!(vblank.margin_ns() >= 300_000);
}

#[test]
fn margin_respects_its_floor_and_ceiling() {
    let mut m = LatchMargin::new(40_000, 200_000);
    assert!(m.margin_ns() >= 40_000);
    for _ in 0..50 {
        m.observe(5_000_000, 5_000_000, true);
    }
    assert!(m.margin_ns() <= 200_000, "the ceiling did not hold");
}

// MARK: the flight recorder

#[test]
fn recorder_wraps_and_keeps_the_most_recent_frames() {
    let mut r = FlightRecorder::new(8);
    for i in 0..20 {
        r.record(FrameRecord { seq: i, ..FrameRecord::default() });
    }
    assert_eq!((r.count(), r.retained()), (20, 8));
    assert_eq!(r.retained_record(0).seq, 12);
    assert_eq!(r.retained_record(7).seq, 19);
}

#[test]
fn recorder_counts_missed_and_degraded() {
    let mut r = FlightRecorder::new(16);
    for i in 0..10 {
        r.record(FrameRecord { seq: i, missed: i % 5 == 0, degraded: i == 7, ..FrameRecord::default() });
    }
    assert_eq!((r.missed_count(), r.degraded_count()), (2, 1));
}

#[test]
fn cost_percentiles() {
    let mut r = FlightRecorder::new(128);
    for i in 1..=100 {
        r.record(FrameRecord { cost_ns: i * 1000, ..FrameRecord::default() });
    }
    assert_eq!(r.cost_percentile_ns(0.0), 1000);
    assert_eq!(r.cost_percentile_ns(100.0), 100_000);
    assert!(r.cost_percentile_ns(50.0).abs_diff(50_000) <= 1500);
    assert!(r.cost_percentile_ns(99.0).abs_diff(99_000) <= 1500);
}

#[test]
fn empty_recorder_answers_without_crashing() {
    let r = FlightRecorder::new(4);
    assert_eq!((r.retained(), r.missed_count(), r.cost_percentile_ns(99.0)), (0, 0, 0));
}

// MARK: the loop

/// Free-run, so deterministic and instant: every frame makes exactly one
/// record, with a monotonic sequence number.
#[test]
fn every_frame_is_recorded_exactly_once() {
    let mut output = SyntheticOutput::new(16_666_666, 200_000);
    let mut scene = SyntheticScene::new(32, (1920, 1080));
    let mut recorder = FlightRecorder::new(512);
    let mut m = Metronome::new(16_666_666, Config { free_run: true, ..Config::default() });
    m.run(300, &mut output, &mut scene, &mut recorder);
    assert_eq!(recorder.count(), 300);
    for i in 1..recorder.retained() {
        assert_eq!(recorder.retained_record(i).seq, recorder.retained_record(i - 1).seq + 1);
    }
}

// MARK: C6 (PHASE13 P13.2)

/// Frames from input to the vblank that showed it, rounded up, never 0.
#[test]
fn c6_counts_frame_periods_to_the_vblank_that_showed_it() {
    let p = 16_666_666;
    assert_eq!(SwitchLatencies::frames(1_000, 1_000 + p / 2, p), 1);
    assert_eq!(SwitchLatencies::frames(1_000, 1_000 + p, p), 1);
    assert_eq!(SwitchLatencies::frames(1_000, 1_000 + p + 1, p), 2);
    assert_eq!(SwitchLatencies::frames(1_000, 999, p), 1, "a grid vblank a hair before the input is still the next frame");
    let mut l = SwitchLatencies::default();
    for f in [1, 1, 2, 1, 3] {
        l.record(0, f * p, p);
    }
    assert_eq!(l.count, 5);
    assert_eq!((l.frames_percentile(50), l.frames_percentile(99), l.max_frames()), (1, 3, 3));
}

/// A display that flips each frame at its target, refusing the frames named.
struct Scripted {
    refuse: HashSet<usize>,
    frame: usize,
    pending: VecDeque<Flip>,
}

impl Output for Scripted {
    fn period_hint_ns(&self) -> u64 {
        16_666_666
    }
    fn submit(&mut self, target: u64, now: u64) {
        self.pending.push_back(Flip { target, vblank: target, done: now, missed: false, refused: self.refuse.contains(&self.frame) });
        self.frame += 1;
    }
    fn poll_flip(&mut self) -> Option<Flip> {
        self.pending.pop_front()
    }
    fn wait_until(&mut self, _: u64) {}
}

/// A scene that asks for an island switch half a period before frame
/// `stamp_on`'s vblank.
struct Stamping {
    stamp_on: usize,
    frame: usize,
}

impl FrameSink for Stamping {
    fn latch_and_composite(&mut self, _: u64, target: u64) -> FrameStats {
        let input_at = if self.frame == self.stamp_on { target - 8_333_333 } else { 0 };
        self.frame += 1;
        FrameStats { input_at, ..FrameStats::default() }
    }
}

/// The metronome follows a switch to the flip that showed it, and a
/// refused flip does not count as shown: the next frame carries it.
#[test]
fn c6_follows_a_switch_to_its_flip_and_past_a_refusal() {
    let mut rec = FlightRecorder::new(64);
    let run = |refuse: &[usize], rec: &mut FlightRecorder| {
        let mut out = Scripted { refuse: refuse.iter().copied().collect(), frame: 0, pending: VecDeque::new() };
        let mut sink = Stamping { stamp_on: 5, frame: 0 };
        let mut m = Metronome::new(16_666_666, Config::default());
        for _ in 0..10 {
            m.step(&mut out, &mut sink, rec);
        }
        m.c6
    };
    let shown = run(&[], &mut rec);
    assert_eq!((shown.count, shown.sample(0).0), (1, 1));
    let refused = run(&[5], &mut rec);
    assert_eq!(refused.count, 1);
    assert!(refused.sample(0).0 >= 2, "a refused frame showed nothing");
}

/// The display's vblanks are its own, not an echo of the compositor's
/// target: a model that agrees with you cannot test a predictor.
#[test]
fn the_synthetic_display_keeps_its_own_vblank_grid() {
    let period = 10_000_000;
    let mut o = SyntheticOutput::new(period, 1_000);
    let t0 = abyss_sys::mono::now();
    o.submit(t0 + period, t0); // establishes the epoch
    o.drain_regardless_of_time();
    o.submit(t0 + period * 100 + 12_345, t0 + period);
    let f = o.drain_regardless_of_time().expect("a flip came back");
    assert_eq!((f.vblank - t0) % period, 0, "the display landed a frame off its own grid: it is echoing the target");
}
