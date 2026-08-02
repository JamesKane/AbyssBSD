// Undertow — a synthetic display and a synthetic scene (PHASE6.md P6.1).
//
// The metronome has to be provable before there is anything to show, so P6.1
// gives it a display made of arithmetic. This is not a mock in the "stub that
// always agrees" sense: it models the two things about a real display that the
// scheduler must cope with — flips complete *asynchronously*, and a frame
// submitted after its target vblank lands on a later one.
//
// wlroots replaces `SyntheticOutput` in P6.2 and a real SoA scene replaces
// `SyntheticScene` in P6.3. Both stay, because a bench that needs no compositor
// is the one that can run in every `swift test` on both platforms.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A fixed-rate display, in software.
public struct SyntheticOutput: Output {
    public let periodNs: UInt64
    /// How long the backend takes to execute a submitted frame — the commit
    /// latency the latch margin has to cover.
    public let commitLatencyNs: UInt64

    /// Flips submitted and not yet collected.
    ///
    /// A FIXED INLINE RING, not an Array — and this is not premature
    /// micro-optimisation, it is the first thing `bench-alloc` caught. `Array`'s
    /// `append`/`removeFirst` allocate, so the original version made ~1.05
    /// allocations per frame on the present path while looking perfectly
    /// innocent. A real display also has a bounded number of frames in flight,
    /// so the fixed capacity is the honest model as well as the fast one.
    private var ring: (Flip, Flip, Flip, Flip)
    private var head: Int = 0      // next to read
    private var tail: Int = 0      // next to write
    private var used: Int = 0
    private static let ringCapacity = 4

    /// The display's own vblank grid: `epoch + k * period`, fixed at the first
    /// submit and independent of anything the compositor predicts.
    ///
    /// This independence is the whole point. The first version computed a
    /// frame's vblank *from the target the predictor asked for*, which made the
    /// predictor observe its own guesses — a feedback loop in which it can never
    /// learn the true period and a bench that would pass no matter how wrong the
    /// prediction was. A display model that agrees with you is not a test.
    private var epoch: UInt64 = 0

    public init(periodNs: UInt64, commitLatencyNs: UInt64 = 200_000) {
        self.periodNs = periodNs
        self.commitLatencyNs = commitLatencyNs
        let z = Flip(target: 0, vblank: 0, done: 0, missed: false)
        ring = (z, z, z, z)
    }

    @inline(__always)
    private func slot(_ i: Int) -> Flip {
        switch i { case 0: return ring.0; case 1: return ring.1
                   case 2: return ring.2; default: return ring.3 }
    }

    @inline(__always)
    private mutating func setSlot(_ i: Int, _ f: Flip) {
        switch i { case 0: ring.0 = f; case 1: ring.1 = f
                   case 2: ring.2 = f; default: ring.3 = f }
    }

    public var periodHintNs: UInt64 { periodNs }

    public mutating func submit(target: UInt64, at now: UInt64) {
        if epoch == 0 { epoch = now }
        let ready = now &+ commitLatencyNs
        // The frame lands on the first vblank OF THE DISPLAY'S OWN GRID at or
        // after it is ready — never on the one the compositor hoped for.
        let k = (Mono.since(epoch, ready) &+ periodNs &- 1) / periodNs
        let vblank = epoch &+ k &* periodNs
        // It missed if it landed later than the vblank it was aimed at.
        let missed = vblank > target
        // A full ring drops the frame rather than growing. A real display would
        // apply backpressure here too, and a queue that could grow would hide
        // precisely the pile-up the contract is about.
        guard used < SyntheticOutput.ringCapacity else { return }
        setSlot(tail, Flip(target: target, vblank: vblank, done: ready, missed: missed))
        tail = (tail &+ 1) % SyntheticOutput.ringCapacity
        used &+= 1
    }

    public mutating func pollFlip() -> Flip? {
        guard used > 0 else { return nil }
        let first = slot(head)
        // Asynchronous by construction: a flip is only visible once its vblank
        // has actually passed. A caller that polls too early gets nil, exactly
        // as it would from a DRM event fd.
        guard Mono.now() >= first.vblank else { return nil }
        head = (head &+ 1) % SyntheticOutput.ringCapacity
        used &-= 1
        return first
    }

    /// Free-running variant for benches that do not sleep: report a pending
    /// flip without waiting for its vblank to arrive in real time.
    public mutating func drainRegardlessOfTime() -> Flip? {
        guard used > 0 else { return nil }
        let first = slot(head)
        head = (head &+ 1) % SyntheticOutput.ringCapacity
        used &-= 1
        return first
    }
}

/// A structure-of-arrays scene, preallocated once (DESKTOP.md §4).
///
/// The shape matters more than the contents: parallel arrays of rects walked
/// linearly, no pointer chasing, no per-node allocation, nothing the composite
/// touches that a client could have made expensive. P6.3 replaces the contents
/// with real surfaces; the *walk* is meant to stay exactly this shape.
public struct SyntheticScene: FrameSink {
    public let capacity: Int
    public private(set) var count: Int

    private let x, y, w, h: UnsafeMutableBufferPointer<Int32>
    private let damage: UnsafeMutableBufferPointer<Int32>
    private let viewportW: Int32
    private let viewportH: Int32
    /// Advances each frame so the composite is never trivially cacheable.
    private var phase: Int32 = 0

    public init(surfaces: Int, viewport: (Int32, Int32) = (1920, 1080)) {
        capacity = max(surfaces, 1)
        count = surfaces
        viewportW = viewport.0
        viewportH = viewport.1
        func buf() -> UnsafeMutableBufferPointer<Int32> {
            let p = UnsafeMutablePointer<Int32>.allocate(capacity: max(surfaces, 1))
            p.initialize(repeating: 0, count: max(surfaces, 1))
            return UnsafeMutableBufferPointer(start: p, count: max(surfaces, 1))
        }
        x = buf(); y = buf(); w = buf(); h = buf(); damage = buf()
        for i in 0..<count {
            x[i] = Int32((i &* 37) % Int(viewportW))
            y[i] = Int32((i &* 53) % Int(viewportH))
            w[i] = 160
            h[i] = 120
        }
    }

    public func release() {
        for b in [x, y, w, h, damage] {
            b.baseAddress?.deinitialize(count: capacity)
            b.baseAddress?.deallocate()
        }
    }

    /// Cull to the viewport and accumulate damage. Bounded by `count`, branchy
    /// enough not to be optimised away, and — the point — allocation-free.
    public mutating func latchAndComposite(now: UInt64, target: UInt64) -> FrameStats {
        phase &+= 1
        var painted: Int32 = 0
        var area: Int64 = 0
        for i in 0..<count {
            let px = x[i] &+ (phase & 0x3F)
            let r = px &+ w[i]
            let b = y[i] &+ h[i]
            if r <= 0 || b <= 0 || px >= viewportW || y[i] >= viewportH { continue }
            let cw = min(r, viewportW) &- max(px, 0)
            let ch = min(b, viewportH) &- max(y[i], 0)
            if cw > 0 && ch > 0 {
                damage[i] = cw &* ch
                area &+= Int64(cw &* ch)
                painted &+= 1
            }
        }
        return FrameStats(surfaces: painted, damageArea: area, degraded: false)
    }
}
