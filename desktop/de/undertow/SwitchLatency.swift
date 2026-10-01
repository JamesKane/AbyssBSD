// C6, measured (PHASE13 P13.2, PRODUCT §7.2).
//
// > C6 — an island switch is committed within 2 frames of the input that
// > asked for it, and any animation is decoration that can be skipped,
// > interrupted and re-targeted without delaying the commit.
//
// **Measured to the display, not to the latch.** Counting latches would always
// say 1: the switch is applied before the next latch by construction, so a
// number taken there proves nothing about what a person sees. A sample here is
// from the moment the switch was asked for (`Compositor.switchIsland`, during
// the key's dispatch) to the vblank of the first frame that drew it — the
// flip's own timestamp — in frame periods, rounded up. A frame the display
// refused does not count as shown: the stamp moves to the next one, so a lost
// frame costs C6 exactly what it costs the eye.

/// The samples, in a fixed ring: the present path never allocates (C2's
/// precondition), and a bench keeps far fewer than this.
public struct SwitchLatencies: Sendable {
    public static let capacity = 512
    private var frames = [UInt8](repeating: 0, count: SwitchLatencies.capacity)
    private var nanos = [UInt64](repeating: 0, count: SwitchLatencies.capacity)
    /// Samples ever recorded (the ring keeps the last `capacity`).
    public private(set) var count = 0

    public init() {}

    /// Frames from input to the vblank that showed it: at least 1 — a frame
    /// cannot show what was asked after it latched, and a headless output's
    /// grid can put its "vblank" a hair before the input (Backend.snapToGrid).
    public static func frames(inputAt: UInt64, shownAt: UInt64, periodNs: UInt64) -> Int {
        guard periodNs > 0, shownAt > inputAt else { return 1 }
        return max(1, Int((shownAt - inputAt + periodNs - 1) / periodNs))
    }

    public mutating func record(inputAt: UInt64, shownAt: UInt64, periodNs: UInt64) {
        let i = count % SwitchLatencies.capacity
        frames[i] = UInt8(min(SwitchLatencies.frames(inputAt: inputAt, shownAt: shownAt, periodNs: periodNs), 255))
        nanos[i] = shownAt > inputAt ? shownAt - inputAt : 0
        count &+= 1
    }

    public var retained: Int { min(count, SwitchLatencies.capacity) }
    /// The i-th retained sample, oldest first.
    public func sample(_ i: Int) -> (frames: Int, ns: UInt64) {
        let start = count > SwitchLatencies.capacity ? count % SwitchLatencies.capacity : 0
        let j = (start + i) % SwitchLatencies.capacity
        return (Int(frames[j]), nanos[j])
    }

    /// Nearest-rank percentile of the frame counts (0 with no samples).
    public func framesPercentile(_ p: Int) -> Int {
        let n = retained
        guard n > 0 else { return 0 }
        let sorted = (0..<n).map { sample($0).frames }.sorted()
        let rank = max(1, (p * n + 99) / 100)
        return sorted[min(rank, n) - 1]
    }
    public var maxFrames: Int { (0..<retained).map { sample($0).frames }.max() ?? 0 }
}
