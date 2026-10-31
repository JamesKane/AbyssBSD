//! The display and the scene, as the present thread sees them (Output.swift,
//! PHASE6.md P6.1; DESKTOP.md §3.1).
//!
//! Two traits, and the contract they carry is the whole of C2: **every
//! method here must be non-blocking and allocation-free.** They run on the
//! present thread. The metronome is generic over them, never `dyn`, so the
//! calls are statically dispatched (DESKTOP.md §11's "hot paths avoid dyn
//! dispatch").

/// A completed flip: the vblank a submitted frame actually landed on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Flip {
    /// The vblank this frame was aimed at (echoed back from `submit`).
    pub target: u64,
    /// When it actually turned into light.
    pub vblank: u64,
    /// When the backend finished executing the frame: `done - submit` is the
    /// commit latency the latch margin has to cover.
    pub done: u64,
    /// It landed later than the vblank it was aimed at.
    pub missed: bool,
    /// **It never landed**: the backend refused the commit (on DRM, a flip
    /// was still pending). A lost frame, so it counts as missed, but it
    /// carries no real vblank, so the predictor must not learn from it
    /// (PHASE4 §5.13).
    pub refused: bool,
}

/// The display, abstracted: a synthetic one for the benches, wlroots for a
/// session.
pub trait Output {
    /// Nominal refresh period in ns: only a seed for the predictor, which
    /// then measures the truth.
    fn period_hint_ns(&self) -> u64;

    /// Fire-and-forget: queue a composited frame aiming at vblank `target`.
    /// **Must not wait for the display**: completion comes back through
    /// `poll_flip`, the shape of a DRM page-flip event.
    fn submit(&mut self, target: u64, now: u64);

    /// Drain one completed flip, if any arrived since the last poll. Never
    /// blocks waiting for one.
    fn poll_flip(&mut self) -> Option<Flip>;

    /// Wait until an absolute monotonic deadline: a plain sleep, unless a
    /// backend must service something while it waits (the wlroots bridge
    /// dispatches its event loop here, without which no present event could
    /// arrive). A trait method with a default, which an implementation
    /// overrides: Swift's protocol-extension trap (HANDOFF §2.11) has no
    /// counterpart here.
    fn wait_until(&mut self, deadline_ns: u64) {
        abyss_sys::mono::sleep_until(deadline_ns);
    }
}

/// What one frame's composite produced. Recorded, not acted on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FrameStats {
    pub surfaces: i32,
    pub damage_area: i64,
    /// The composite could not be done in full and was reduced: C4's
    /// "defined and logged, not a surprise stall".
    pub degraded: bool,
    /// When an island switch this frame is the first to draw was asked for
    /// (PHASE13 P13.2), or 0. The metronome follows it to the flip: C6.
    pub input_at: u64,
    /// **Nothing visible changed since the last frame presented** (BACKLOG
    /// M.1): nothing is drawn or committed, and the display keeps what it has.
    pub unchanged: bool,
}

/// The scene, as the present thread sees it: one call, bounded work.
pub trait FrameSink {
    /// Latch the freshest committed state and composite it. This never asks
    /// a client for anything, which is why a client cannot stall it (C2).
    fn latch_and_composite(&mut self, now: u64, target: u64) -> FrameStats;
}

/// The display's refresh rate in whole Hz, from wlroots' millihertz.
///
/// **The other half of §2.48.** The first metal run printed `@ 240Hz` on a
/// 60 Hz monitor because 240 was the default and the panel was never asked.
/// Zero means the output has no mode, and the caller's own default stands.
/// Rounded, not truncated: 59.94 Hz is a 60 Hz display.
pub fn display_hz(refresh_milli_hz: i32, fallback: u64) -> u64 {
    if refresh_milli_hz <= 0 {
        return fallback;
    }
    ((i64::from(refresh_milli_hz) + 500) / 1000) as u64
}

/// Whether a run has no frame limit. **Zero is the honest spelling of "no
/// limit"**: a desktop runs until it is stopped (PHASE4 §5.6, where 1200
/// frames was the installer disappearing after thirty seconds).
pub fn run_is_unbounded(frames: u64) -> bool {
    frames == 0
}

/// How many frames of history a run should keep: ten seconds at 240 Hz for
/// an unbounded one, which says what just happened and forgets after.
pub fn recorder_capacity(frames: u64) -> usize {
    if run_is_unbounded(frames) { 2400 } else { frames.max(1) as usize }
}
