// Undertow — the metronome (PHASE6.md P6.1; DESKTOP.md §3.1).
//
// The loop invariant that turns "present at refresh rate" from a hope into code:
//
//     loop:
//         T_v      = predict_next_vblank()      # EWMA over flip feedback
//         deadline = T_v - margin               # margin adapts to measured cost
//         sleep_until(deadline)                 # absolute, not an interval
//         poll flip completions                 # async -> feeds the predictor
//         latch + composite                     # bounded, allocation-free
//         submit                                # fire-and-forget
//         record                                # flight recorder
//
// Two things make this different from "render when a client commits, then wait
// for vblank", which spends a whole period of latency waiting:
//
//   **Late-latching.** We sleep until just before the deadline and *then* read
//   the freshest committed state. That is C3: the scene a frame shows is as
//   young as it can be, rather than as old as the client's commit.
//
//   **Predict, don't react.** The vblank time comes from an EWMA over flip
//   feedback, so a frame is aimed at a vblank that hasn't happened yet. On a bad
//   prediction we fall to the next period and log it (C4) — never tear, never
//   stall.
//
// The loop body has no call that can block on a client, no lock a client can
// hold, and no allocation a client can starve. That is C2 by construction, and
// `undertow bench-alloc` is what stops it from silently becoming untrue.

/// Predicts the next vblank from flip feedback.
///
/// The period is an EWMA over observed vblank intervals rather than the
/// display's advertised rate, because the advertised rate is a rounded lie on
/// most hardware (59.94 reported as 60) and a systematic phase error is exactly
/// what a metronome must not have.
public struct VblankPredictor: Equatable, Sendable {
    /// Current period estimate (ns).
    public private(set) var periodNs: UInt64
    /// The most recent vblank we know actually happened.
    public private(set) var lastVblankNs: UInt64 = 0
    public private(set) var samples: UInt64 = 0

    /// EWMA weight for a new sample, as a reciprocal: period += (obs - period)/8.
    /// Fast enough to track a mode switch in a few frames, slow enough that one
    /// stalled sample cannot move it far.
    private let shift: UInt64 = 3
    private let seedNs: UInt64

    public init(periodHintNs: UInt64) {
        let seed = max(periodHintNs, 1)
        self.periodNs = seed
        self.seedNs = seed
    }

    /// Feed a completed flip back in.
    public mutating func observe(_ flip: Flip) {
        defer { lastVblankNs = max(lastVblankNs, flip.vblank) }
        guard lastVblankNs != 0, flip.vblank > lastVblankNs else { return }

        let interval = flip.vblank &- lastVblankNs
        // A gap is usually several whole periods (we skipped frames), not a
        // changed refresh rate — so divide it down before treating it as a
        // sample. Without this, one missed frame teaches the predictor that the
        // display runs at half rate, and it never recovers.
        let periods = max(1, (interval &+ periodNs / 2) / periodNs)
        let perPeriod = interval / periods

        // Reject the implausible outright. Once the interval has been divided
        // by its whole number of periods, what remains should be *close* to the
        // current estimate — a fixed-rate display drifts by fractions of a
        // percent, not by tens. A ±12.5% band is wide enough for 59.94-reported-
        // as-60 (0.1% out) and for slow thermal drift, and narrow enough to
        // reject a 1.4x interval, which is a stall or a clock jump wearing a
        // plausible-looking number. A genuine mode change is not this method's
        // job: the compositor knows when it set one and calls `reseed()`.
        let low = periodNs &- (periodNs >> 3)
        let high = periodNs &+ (periodNs >> 3)
        guard perPeriod >= low, perPeriod <= high else { return }

        periodNs = periodNs &- (periodNs >> shift) &+ (perPeriod >> shift)
        samples &+= 1
    }

    /// The first vblank strictly after `now`.
    public func predictNext(after now: UInt64) -> UInt64 {
        guard lastVblankNs != 0 else { return now &+ periodNs }
        guard now >= lastVblankNs else { return lastVblankNs }
        // How many whole periods have elapsed since the last known vblank.
        let elapsed = now &- lastVblankNs
        let k = elapsed / periodNs &+ 1
        return lastVblankNs &+ k &* periodNs
    }

    /// Forget the phase but keep the period — for a mode change or a long idle,
    /// where the next flip's timestamp is the only trustworthy phase reference.
    public mutating func resetPhase() { lastVblankNs = 0 }

    /// Abandon a period estimate that has drifted somewhere useless.
    public mutating func reseed() { periodNs = seedNs; lastVblankNs = 0; samples = 0 }
}

/// How early to wake before the target vblank.
///
/// A frame is late if **any** of three things ran long, so the margin is the sum
/// of three separately *measured* quantities plus a small feedback term:
///
///   margin = wakeHigh + costHigh + commitHigh + safety
///
///   - `wakeHigh`   — how late the OS actually woke us past the deadline. On a
///                    non-RT thread this dominates, and it is the term Phase 4's
///                    `rtprio` is meant to collapse.
///   - `costHigh`   — how long the composite took.
///   - `commitHigh` — how long the display took to execute a submitted frame.
///   - `safety`     — the unmeasured remainder, grown on a miss.
///
/// The first version had only `costHigh` and a blind `safety` absorbing the other
/// two. It converged, but to a number that could not explain itself: a miss
/// could not be attributed, so the loop over-corrected and then decayed straight
/// back into missing again. Measuring each term is what makes the margin both
/// smaller *and* steadier — DESKTOP.md §3.1's "measured and adapted, not
/// guessed", taken literally.
public struct LatchMargin: Equatable, Sendable {
    public private(set) var wakeHighNs: UInt64 = 0
    public private(set) var costHighNs: UInt64 = 0
    public private(set) var commitHighNs: UInt64 = 0
    public private(set) var safetyNs: UInt64
    public let floorNs: UInt64
    public let ceilNs: UInt64

    public init(floorNs: UInt64 = 50_000, ceilNs: UInt64) {
        self.floorNs = floorNs
        self.ceilNs = max(ceilNs, floorNs)
        self.safetyNs = floorNs
    }

    /// What the loop should subtract from the target vblank.
    public var marginNs: UInt64 {
        let want = wakeHighNs &+ costHighNs &+ commitHighNs &+ safetyNs
        return min(max(want, floorNs), ceilNs)
    }

    /// Decaying maximum: jump straight to a new high, ease down from an old one.
    /// Reacting instantly upward and slowly downward is what keeps one spike
    /// from costing a second miss. The decay is deliberately slow (~0.4% per
    /// frame) — at 240Hz a faster one forgets an outlier before the next arrives
    /// and simply re-learns it by missing again.
    @inline(__always)
    private static func decayMax(_ high: UInt64, _ sample: UInt64) -> UInt64 {
        sample > high ? sample : high &- (high >> 8)
    }

    /// Fold in one frame's outcome.
    public mutating func observe(costNs: UInt64, wakeLateNs: UInt64, missed: Bool) {
        costHighNs = LatchMargin.decayMax(costHighNs, costNs)
        wakeHighNs = LatchMargin.decayMax(wakeHighNs, wakeLateNs)
        if missed {
            // The cost of over-correcting is latency; the cost of
            // under-correcting is another dropped frame.
            safetyNs = min(max(safetyNs &* 2, floorNs), ceilNs)
        } else {
            safetyNs = max(safetyNs &- (safetyNs >> 8), floorNs)
        }
    }

    /// Fold in a measured commit latency, from flip feedback.
    public mutating func observeCommit(latencyNs: UInt64) {
        commitHighNs = LatchMargin.decayMax(commitHighNs, latencyNs)
    }
}

/// The frame scheduler.
///
/// Generic over its display and scene rather than existential: the loop body's
/// calls to `output` and `sink` are statically dispatched and inlinable, so
/// there is no witness-table indirection on the present path.
public struct Metronome<O: Output, S: FrameSink> {
    public struct Config: Sendable {
        /// Skip the sleep and free-run. For benches that measure *work* rather
        /// than cadence (the allocation bench runs 10⁴ frames; at 60Hz that
        /// would be three minutes of sleeping to measure zero allocations).
        public var freeRun: Bool = false
        /// Cap on the latch margin.
        public var marginCeilNs: UInt64 = 8_000_000
        public init() {}
    }

    public private(set) var predictor: VblankPredictor
    public private(set) var margin: LatchMargin
    public private(set) var seq: UInt64 = 0
    /// The vblank the last frame was fired for. A plan never aims at it again:
    /// one frame per vblank per output. On one output the margin already
    /// guaranteed that; with several sharing a loop it is what stops the first
    /// output winning every tie while the others starve (P14.7a).
    public private(set) var lastTarget: UInt64 = 0
    public let config: Config

    public init(periodHintNs: UInt64, config: Config = Config()) {
        self.predictor = VblankPredictor(periodHintNs: periodHintNs)
        // Cap the margin below a whole period. A margin equal to the period
        // means every vblank is unreachable by the rule above, so the loop would
        // present at half rate for ever. Three quarters leaves room to latch and
        // still makes a genuinely expensive composite degrade to half rate
        // rather than thrash.
        self.margin = LatchMargin(ceilNs: min(config.marginCeilNs, periodHintNs * 3 / 4))
        self.config = config
    }

    /// Run `frames` iterations of the loop. Allocation-free after the first.
    public mutating func run(frames: Int, output: inout O, sink: inout S,
                             recorder: FlightRecorder) {
        for _ in 0..<frames {
            step(output: &output, sink: &sink, recorder: recorder)
        }
    }

    /// One frame. This is the loop body the contract is about; read it as the
    /// executable form of DESKTOP.md §3.1.
    /// The next frame this output should make: the vblank it aims at and the
    /// moment it must wake to make it. Pure bookkeeping — no waiting — so a
    /// loop driving several outputs can ask each and serve the earliest
    /// (P14.7a); `step` is plan, wait, fire for one.
    public struct Plan: Sendable {
        public let entry: UInt64
        public let target: UInt64
        public let deadline: UInt64
        public let marginNs: UInt64
    }

    /// The output's refresh rate changed (a new mode, P14.7b): start the
    /// prediction again from the new period. The margin is kept — the cost of
    /// a composite did not change with the mode.
    public mutating func retune(periodHintNs: UInt64) {
        predictor = VblankPredictor(periodHintNs: periodHintNs)
        lastTarget = 0
    }

    public func plan(now entry: UInt64) -> Plan {
        let m = margin.marginNs
        var target = predictor.predictNext(after: entry)
        // Aim at a vblank we can still MAKE. If the next one is closer than our
        // own margin, compositing for it is guaranteed to be late — and the
        // first version of this loop did exactly that, which is a runaway: the
        // miss grows the margin, the bigger margin makes the next vblank
        // unreachable too, and the loop degenerates into a spin that never
        // sleeps and misses everything. Skipping to the following vblank is C4's
        // "fall to the next period" — defined and logged, never a stall.
        if !config.freeRun {
            let period = predictor.periodNs
            while target < entry &+ m || target <= lastTarget { target &+= period }
        }
        let deadline = target > m ? target &- m : entry
        return Plan(entry: entry, target: target, deadline: config.freeRun ? entry : deadline, marginNs: m)
    }

    @inline(__always)
    public mutating func step(output: inout O, sink: inout S, recorder: FlightRecorder) {
        // 1. Where is the next vblank, and how early must we wake for it?
        let p = plan(now: Mono.now())
        // 2. Wait until the deadline. Absolute, so the wait cannot drift — and
        //    through the output, because a real backend has an event loop to
        //    service while it waits (Backend.swift).
        if !config.freeRun {
            output.waitUntil(deadlineNs: p.deadline)
        }
        fire(p, output: &output, sink: &sink, recorder: recorder)
    }

    /// Steps 3–5 of a frame planned by `plan`, once its deadline has come.
    @inline(__always)
    public mutating func fire(_ p: Plan, output: inout O, sink: inout S, recorder: FlightRecorder) {
        var r = FrameRecord()
        r.seq = seq
        seq &+= 1
        let m = p.marginNs, target = p.target, deadline = p.deadline
        lastTarget = target
        r.predictedVblank = target
        r.marginNs = m

        // 3. Drain flip feedback BEFORE latching, so the prediction that
        //    produced this frame is the freshest one available.
        while let flip = output.pollFlip() {
            predictor.observe(flip)
            margin.observeCommit(latencyNs: Mono.since(flip.target &- m, flip.done))
            r.actualVblank = flip.vblank
            if flip.missed { r.missed = true }
        }

        // 4. Latch and composite. Bounded work; the only part that scales with
        //    the scene, and the only part C1's 2 ms budget is about.
        let latch = Mono.now()
        // How far past the deadline the OS actually woke us. On a non-RT thread
        // this is usually the largest of the three margin terms.
        let wakeLate = config.freeRun ? 0 : Mono.since(deadline, latch)
        let stats = sink.latchAndComposite(now: latch, target: target)
        let compositeEnd = Mono.now()

        // 5. Fire and forget. We never wait for the display.
        output.submit(target: target, at: compositeEnd)

        r.latch = latch
        r.compositeEnd = compositeEnd
        r.submit = compositeEnd
        r.costNs = Mono.since(latch, compositeEnd)
        r.wakeLateNs = wakeLate
        r.surfaces = stats.surfaces
        r.damageArea = stats.damageArea
        r.degraded = stats.degraded
        // We woke too late to make this vblank: the composite ran past the
        // target. Counted as a miss even before the display confirms it,
        // because it is our own fault rather than the display's.
        if compositeEnd > target { r.missed = true }

        margin.observe(costNs: r.costNs, wakeLateNs: wakeLate, missed: r.missed)
        recorder.record(r)
    }
}

/// Several outputs on one loop, each with its own metronome (PHASE14 P14.7a).
///
/// **Earliest deadline first.** Each output holds one *pending* frame — its
/// plan — until that frame is fired; the loop waits for the earliest pending
/// deadline and fires every output whose deadline has come, each from its own
/// plan, in deadline order. Only an output that has just fired plans again. So
/// each keeps its own vblank, margin and misses, and a 144 Hz panel beside a
/// 60 Hz one is served at 144 and 60, not both at one of them. On one output
/// this is exactly `Metronome.step`.
///
/// Two versions got this wrong, and both starved an output for ever:
/// - **Re-planning every output on every pass.** The third of three equal
///   outputs, planned again after the first two fired, found its target a few
///   microseconds inside its margin and aimed at the next vblank — every time.
/// - The same, one level down: an output whose predictor has seen no flip yet
///   aims "one period from now", and re-planned before it ever fired, that
///   target receded as fast as time passed. A 60 Hz output beside a 144 Hz one
///   made no frames at all. A plan that is kept until it fires cannot recede.
public struct Conductor<O: Output, S: FrameSink> {
    public var outputs: [O]
    public var sinks: [S]
    public private(set) var metronomes: [Metronome<O, S>]
    private var pending: [Metronome<O, S>.Plan?]

    public init(outputs: [O], sinks: [S], config: Metronome<O, S>.Config = .init()) {
        precondition(!outputs.isEmpty && outputs.count == sinks.count)
        self.outputs = outputs
        self.sinks = sinks
        self.metronomes = outputs.map { Metronome(periodHintNs: $0.periodHintNs, config: config) }
        self.pending = Array(repeating: nil, count: outputs.count)
    }

    /// Output `i` has a new refresh rate: its pending frame is dropped and its
    /// metronome starts again from the new period.
    public mutating func retune(_ i: Int, periodHintNs: UInt64) {
        metronomes[i].retune(periodHintNs: periodHintNs)
        pending[i] = nil
    }

    /// Wait for the earliest deadline and serve every output due. Returns
    /// whether output 0 — the main display — was among them.
    @discardableResult
    public mutating func serveNext(recorders: [FlightRecorder]) -> Bool {
        let now = Mono.now()
        for i in pending.indices where pending[i] == nil { pending[i] = metronomes[i].plan(now: now) }
        let order = pending.indices.sorted { pending[$0]!.deadline < pending[$1]!.deadline }
        outputs[order[0]].waitUntil(deadlineNs: pending[order[0]]!.deadline)
        var servedMain = false
        for (k, i) in order.enumerated() {
            guard let p = pending[i] else { continue }
            if k > 0 && p.deadline > Mono.now() { break }
            metronomes[i].fire(p, output: &outputs[i], sink: &sinks[i], recorder: recorders[i])
            pending[i] = nil
            if i == 0 { servedMain = true }
        }
        return servedMain
    }
}
