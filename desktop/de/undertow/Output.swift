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

    public init(target: UInt64, vblank: UInt64, done: UInt64, missed: Bool) {
        self.target = target
        self.vblank = vblank
        self.done = done
        self.missed = missed
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
}

/// What one frame's composite produced. Recorded, not acted on.
public struct FrameStats: Equatable, Sendable {
    public var surfaces: Int32
    public var damageArea: Int64
    /// The composite could not be done in full and was reduced — C4's "defined
    /// and logged, not a surprise stall". Nothing here degrades yet; the field
    /// exists so the recorder's shape is right before P6.3 needs it.
    public var degraded: Bool

    public init(surfaces: Int32 = 0, damageArea: Int64 = 0, degraded: Bool = false) {
        self.surfaces = surfaces
        self.damageArea = damageArea
        self.degraded = degraded
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
