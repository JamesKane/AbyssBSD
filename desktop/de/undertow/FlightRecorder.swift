// Undertow — the flight recorder (PHASE6.md P6.1; DESKTOP.md §10).
//
// "A claim of 60/120/144 fps, no jank is worthless without a meter." This is the
// meter, and it is a first-class subsystem rather than a --debug afterthought:
// cheap enough to leave on always, and the thing the C1–C5 benches assert
// against. Without it the performance contract is an assertion in a document.
//
// One writer (the present thread), any number of readers later. Records are POD
// in a preallocated ring, so recording a frame is a handful of stores and a
// release — no allocation, no lock, no branch a client can influence.

import Synchronization

/// One frame, as it happened. Plain data, fixed size, no references — so a
/// record costs a memcpy and the ring can be walked by anything.
public struct FrameRecord: Equatable, Sendable {
    public var seq: UInt64 = 0
    /// The vblank this frame aimed at, and when it actually landed. The gap
    /// between them is the predictor's error.
    public var predictedVblank: UInt64 = 0
    public var actualVblank: UInt64 = 0
    /// When the loop woke and latched, and when the composite finished.
    public var latch: UInt64 = 0
    public var compositeEnd: UInt64 = 0
    public var submit: UInt64 = 0
    /// The margin the loop chose to wake by, and what the composite actually
    /// cost. `cost > margin` is the shape of a frame about to be late.
    public var marginNs: UInt64 = 0
    public var costNs: UInt64 = 0
    public var damageArea: Int64 = 0
    public var surfaces: Int32 = 0
    public var missed: Bool = false
    public var degraded: Bool = false

    public init() {}
}

/// A fixed-capacity ring of frame records.
///
/// A class, not a struct, because the present thread and a future HUD reader
/// share one — but note what that does *not* cost: recording touches only
/// preallocated storage through an `UnsafeMutableBufferPointer`, so there is no
/// allocation and no ARC traffic on the record path itself.
public final class FlightRecorder {
    public let capacity: Int
    private let slots: UnsafeMutableBufferPointer<FrameRecord>
    /// Total frames ever recorded. Published with release ordering *after* the
    /// slot is written, so a reader that acquires this count can only observe
    /// slots that are fully written. P6.1 has a single thread; the ordering is
    /// here because getting it right later is harder than getting it right now.
    private let published = Atomic<UInt64>(0)
    /// Scratch for percentile queries, preallocated so even *reading* the
    /// recorder cannot allocate.
    private let scratch: UnsafeMutableBufferPointer<UInt64>

    public init(capacity: Int = 4096) {
        precondition(capacity > 0)
        self.capacity = capacity
        let p = UnsafeMutablePointer<FrameRecord>.allocate(capacity: capacity)
        p.initialize(repeating: FrameRecord(), count: capacity)
        slots = UnsafeMutableBufferPointer(start: p, count: capacity)
        let s = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
        s.initialize(repeating: 0, count: capacity)
        scratch = UnsafeMutableBufferPointer(start: s, count: capacity)
    }

    deinit {
        slots.baseAddress?.deinitialize(count: capacity)
        slots.baseAddress?.deallocate()
        scratch.baseAddress?.deinitialize(count: capacity)
        scratch.baseAddress?.deallocate()
    }

    /// Record one frame. Allocation-free, lock-free, wait-free.
    ///
    /// When the ring wraps it overwrites the oldest — a flight recorder keeps
    /// the *recent* past and must never grow, block, or drop a frame it was
    /// asked to record.
    @inline(__always)
    public func record(_ r: FrameRecord) {
        let n = published.load(ordering: .relaxed)
        slots[Int(n % UInt64(capacity))] = r
        published.store(n &+ 1, ordering: .releasing)
    }

    /// How many frames have been recorded in total (may exceed `capacity`).
    public var count: UInt64 { published.load(ordering: .acquiring) }

    /// How many are still retained in the ring.
    public var retained: Int { Int(min(count, UInt64(capacity))) }

    /// The i-th retained record, oldest first.
    public func retainedRecord(_ i: Int) -> FrameRecord {
        let n = count
        let first = n > UInt64(capacity) ? n &- UInt64(capacity) : 0
        return slots[Int((first &+ UInt64(i)) % UInt64(capacity))]
    }

    // MARK: - Queries (off the present path)

    public var missedCount: Int {
        var m = 0
        for i in 0..<retained where retainedRecord(i).missed { m += 1 }
        return m
    }

    public var degradedCount: Int {
        var d = 0
        for i in 0..<retained where retainedRecord(i).degraded { d += 1 }
        return d
    }

    /// The p-th percentile of composite cost, in ns. `p` in 0...100.
    ///
    /// **p99, never max** — one outlier in a VM proves nothing (PHASE6.md §6),
    /// which is why the contract is stated in percentiles and this is the only
    /// way the benches are allowed to ask.
    public func costPercentileNs(_ p: Double) -> UInt64 {
        percentile(p) { $0.costNs }
    }

    /// The p-th percentile of any UInt64 field.
    public func percentile(_ p: Double, _ field: (FrameRecord) -> UInt64) -> UInt64 {
        let n = retained
        guard n > 0 else { return 0 }
        for i in 0..<n { scratch[i] = field(retainedRecord(i)) }
        // Sorting the preallocated prefix in place. Off the present path by
        // construction: nothing calls this from the loop.
        var view = UnsafeMutableBufferPointer(rebasing: scratch[0..<n])
        view.sort()
        let rank = max(0.0, min(100.0, p)) / 100.0 * Double(n - 1)
        return view[Int(rank.rounded())]
    }
}
