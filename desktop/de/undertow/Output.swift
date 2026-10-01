// Undertow — the display and the scene, as the present thread sees them
// (PHASE6.md P6.1; DESKTOP.md §3.1).
//
// Two protocols, and the contract they carry is the whole of C2:
//
//   **Every method here MUST be non-blocking and allocation-free.** They run on
//   the present thread. A call that can block on a client, take a lock a client
//   holds, or allocate is a missed flip waiting to happen — and no amount of
//   scheduling cleverness upstream can recover it.
//
// They are protocols rather than concrete types so the metronome can be driven
// by a synthetic display in a bench and by wlroots in P6.2 — but the metronome
// is **generic** over them, not existential (`some`/`<O: Output>`, never
// `any Output`). That keeps the calls statically dispatched and inlinable:
// DESKTOP.md §11's "hot paths avoid dyn dispatch", in the Swift idiom.

/// A completed flip: the vblank a submitted frame actually landed on.
public struct Flip: Equatable, Sendable {
    /// The vblank this frame was aimed at (echoed back from `submit`).
    public var target: UInt64
    /// When it actually turned into light.
    public var vblank: UInt64
    /// When the backend finished executing the frame. `done - submit` is the
    /// commit latency the latch margin has to cover.
    public var done: UInt64
    /// It landed later than the vblank it was aimed at.
    public var missed: Bool
    /// **It never landed**: the backend refused the commit (on DRM, a flip was
    /// still pending). A lost frame, so it counts as missed — but it carries no
    /// real vblank, so the predictor must not learn from it (PHASE4 §5.13).
    public var refused: Bool

    public init(target: UInt64, vblank: UInt64, done: UInt64, missed: Bool,
                refused: Bool = false) {
        self.target = target
        self.vblank = vblank
        self.done = done
        self.missed = missed
        self.refused = refused
    }
}

/// The display, abstracted. P6.1: a synthetic one. P6.2: wlroots. Phase 4:
/// DRM/KMS atomic flips.
public protocol Output {
    /// Nominal refresh period in ns — only a seed for the predictor, which then
    /// measures the truth. A display that lies here costs one frame of
    /// convergence, not correctness.
    var periodHintNs: UInt64 { get }

    /// Fire-and-forget: queue a composited frame aiming at vblank `target`.
    ///
    /// **Must not wait for the display.** Completion comes back through
    /// `pollFlip`, which is the shape of a real DRM page-flip event and of the
    /// wlroots bridge. A `submit` that blocks until the flip lands would burn a
    /// whole period of latency and make C3 unreachable.
    mutating func submit(target: UInt64, at now: UInt64)

    /// Drain one completed flip, if any arrived since the last poll. Returns nil
    /// when there is nothing to report — never blocks waiting for one.
    mutating func pollFlip() -> Flip?

    /// Wait until an absolute monotonic deadline.
    ///
    /// Defaulted to a plain sleep, and overridden by backends that must service
    /// something while waiting — the wlroots bridge dispatches its event loop
    /// here, without which no `present` event could ever arrive and the
    /// predictor would never receive a sample.
    ///
    /// **Declared here in the protocol body on purpose.** A method that exists
    /// only in a protocol extension is statically dispatched, so an override
    /// would compile, look right, and never be called — HANDOFF §2.11, which
    /// cost an afternoon in Phase 1 and would cost more here, because the
    /// symptom is a compositor that merely appears to hang.
    mutating func waitUntil(deadlineNs: UInt64)
}

public extension Output {
    mutating func waitUntil(deadlineNs: UInt64) { Mono.sleep(untilNs: deadlineNs) }
}

/// What one frame's composite produced. Recorded, not acted on.
public struct FrameStats: Equatable, Sendable {
    public var surfaces: Int32
    public var damageArea: Int64
    /// The composite could not be done in full and was reduced — C4's "defined
    /// and logged, not a surprise stall". Nothing here degrades yet; the field
    /// exists so the recorder's shape is right before P6.3 needs it.
    public var degraded: Bool
    /// When an island switch this frame is the first to draw was asked for
    /// (PHASE13 P13.2), or 0. The metronome follows it to the flip: C6.
    public var inputAt: UInt64

    public init(surfaces: Int32 = 0, damageArea: Int64 = 0, degraded: Bool = false, inputAt: UInt64 = 0) {
        self.surfaces = surfaces
        self.damageArea = damageArea
        self.degraded = degraded
        self.inputAt = inputAt
    }
}

/// The scene, as the present thread sees it: one call, bounded work.
public protocol FrameSink {
    /// Latch the freshest published snapshot and composite it.
    ///
    /// "Latch" is the load-bearing word — the snapshot is whatever clients have
    /// *already committed*, read through a lock-free publish. This call never
    /// asks a client for anything, which is why a client cannot stall it (C2).
    mutating func latchAndComposite(now: UInt64, target: UInt64) -> FrameStats
}

/// The display's refresh rate in whole Hz, from wlroots' millihertz.
///
/// **The other half of §2.48, and it went unapplied for a phase.** P4.1 learned
/// that on a real backend the display's *size* is the truth and our flags are
/// not, and took `width`/`height` from the output. It left `--hz` alone — so the
/// compositor went on reporting the rate it was *asked* for while running at the
/// rate the panel actually has, and the first metal run printed `@ 240Hz` on a
/// 60 Hz monitor because 240 is this binary's default.
///
/// That is worse than a cosmetic bug in a project whose deliverable is
/// measurement: every number in that report was labelled with a refresh rate
/// nothing had measured. A frame budget quoted against the wrong period is not a
/// frame budget.
///
/// Zero means the output has no mode — nothing plugged in, or a virtual
/// connector — and the caller's own default stands, because inventing a rate
/// here would be the same mistake one layer down.
public func displayHz(refreshMilliHz: Int32, fallback: UInt64) -> UInt64 {
    guard refreshMilliHz > 0 else { return fallback }
    // Round to nearest rather than truncate: 59.94 Hz reports 59940 mHz and is
    // a 60 Hz display everywhere except in a truncation.
    return UInt64((Int64(refreshMilliHz) + 500) / 1000)
}

/// Whether a run has no frame limit.
///
/// **Zero is the honest spelling of "no limit".** A desktop runs until it is
/// stopped; a bench runs a fixed count and reports. Until P4.4 this binary only
/// ever did the second, so the distinction had no name and the default of 1200
/// frames silently applied to a live session — which on metal is the installer
/// disappearing after thirty seconds and being restarted (PHASE4 §5.6).
///
/// Pure and here rather than inline in the argument parser, so the rule is
/// somewhere a test can reach.
public func runIsUnbounded(frames: Int) -> Bool { frames == 0 }

/// How many frames of history an unbounded run should keep.
///
/// Sizing from the frame count gives 1 when there is no count, which answers
/// nothing; growing without bound leaks in a process meant to run for days. Ten
/// seconds at 240 Hz is enough to say what just happened and small enough to
/// forget.
public func recorderCapacity(frames: Int) -> Int {
    runIsUnbounded(frames: frames) ? 2400 : max(frames, 1)
}
