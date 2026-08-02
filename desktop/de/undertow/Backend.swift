// Undertow — the wlroots bridge (PHASE6.md P6.2).
//
// wlroots owns the unglamorous, correctness-critical plumbing: backends,
// buffer allocation, the renderer, and (later) the protocol grind. **We own the
// scene, the scheduler and the present path** (DESKTOP.md §2). This file is the
// seam between the two, and it is deliberately thin — a `wlr_output` wearing the
// `Output` protocol the metronome already knows how to drive.
//
// The inversion worth noticing: a wlroots compositor is normally written to
// render *when the output asks*, in its `frame` handler. Undertow does not. The
// metronome decides when a frame happens, and the output's job is to execute
// and to report back through `present`. That is what makes the schedule ours
// rather than the backend's, and it is the whole reason P6.1 came first.
//
// **P6.2 is single-threaded, and that is a stated debt.** The event loop is
// serviced from inside the metronome's wait (see `waitUntil`), which is fine
// while there are no clients — but C2 requires that no client can delay the
// present thread, and a single thread dispatching client requests plainly
// cannot promise that. The reactor/present split lands with the clients it
// exists to isolate us from (P6.3/P6.5), where it can actually be tested.

import CWlroots

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum BackendError: Error, CustomStringConvertible {
    case noDisplay, noBackend, noRenderer, noAllocator
    case noOutput
    case renderInitFailed
    case modeRejected

    public var description: String {
        switch self {
        case .noDisplay: return "could not create a wl_display"
        case .noBackend: return "could not create a wlroots backend"
        case .noRenderer: return "could not create a wlroots renderer"
        case .noAllocator: return "could not create a wlroots allocator"
        case .noOutput: return "the backend produced no output"
        case .renderInitFailed: return "wlr_output_init_render failed"
        case .modeRejected: return "the output rejected its mode"
        }
    }
}

/// One completed presentation, as wlroots reported it. Collected by the
/// `present` listener and drained by the metronome.
private struct PresentEvent {
    var commitSeq: UInt32
    var whenNs: UInt64
    var presented: Bool
    /// The driver measured this timestamp against real display hardware
    /// (`WLR_OUTPUT_PRESENT_HW_CLOCK`). Without it the timestamp is just "when
    /// the backend got round to it", which on a headless output is our own
    /// commit time — see `snapToGrid`.
    var hardwareClock: Bool
}

/// Shared state the C callbacks write into.
///
/// A class because the trampoline needs a stable pointer to hand back, and
/// because the listener outlives any one call. Note what it does *not* do:
/// nothing here allocates once the ring is built, so a present event costs a
/// few stores.
private final class OutputEvents {
    var ring = [PresentEvent](repeating: PresentEvent(commitSeq: 0, whenNs: 0,
                                                      presented: false,
                                                      hardwareClock: false),
                              count: 16)
    var head = 0, tail = 0, used = 0
    var destroyed = false

    func push(_ e: PresentEvent) {
        guard used < ring.count else { return }   // bounded: drop, never grow
        ring[tail] = e
        tail = (tail + 1) % ring.count
        used += 1
    }

    func pop() -> PresentEvent? {
        guard used > 0 else { return nil }
        let e = ring[head]
        head = (head + 1) % ring.count
        used -= 1
        return e
    }
}

/// The compositor's wlroots session: display, backend, renderer, allocator.
///
/// Owns everything with a C lifetime, and tears it down in the documented order
/// — HANDOFF §2.2/§2.35, which this project has walked into twice, so the
/// listeners are freed before the objects they listen to.
public final class WlrootsSession {
    public let display: OpaquePointer
    let eventLoop: OpaquePointer
    let backend: UnsafeMutablePointer<wlr_backend>
    let renderer: UnsafeMutablePointer<wlr_renderer>
    let allocator: UnsafeMutablePointer<wlr_allocator>

    /// Outputs the backend has announced, in arrival order.
    public private(set) var outputs: [UnsafeMutablePointer<wlr_output>] = []
    private var newOutputListener: UnsafeMutablePointer<tw_listener>?

    /// Create a headless session with `outputCount` outputs of the given size.
    ///
    /// Headless because that is where C1–C3 are provable without a GPU, and the
    /// build VM has no `/dev/dri` (PHASE6.md §7.1). A DRM backend is Phase 4.
    public init(headlessOutputs outputCount: Int, width: Int32, height: Int32,
                refreshMilliHz: Int32, verbose: Bool = false) throws {
        if verbose { tw_log_verbose() } else { tw_log_silence() }

        guard let d = wl_display_create() else { throw BackendError.noDisplay }
        display = d
        eventLoop = wl_display_get_event_loop(d)

        guard let b = wlr_headless_backend_create(eventLoop) else {
            wl_display_destroy(d)
            throw BackendError.noBackend
        }
        backend = b
        guard let r = wlr_renderer_autocreate(b) else {
            wl_display_destroy(d)
            throw BackendError.noRenderer
        }
        renderer = r
        guard let a = wlr_allocator_autocreate(b, r) else {
            wl_display_destroy(d)
            throw BackendError.noAllocator
        }
        allocator = a

        // Collect outputs as the backend announces them. Registered *before*
        // the backend starts, or the announcements arrive with nobody listening.
        let me = Unmanaged.passUnretained(self).toOpaque()
        newOutputListener = tw_listen(&b.pointee.events.new_output, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<WlrootsSession>.fromOpaque(ctx).takeUnretainedValue()
            s.outputs.append(data.assumingMemoryBound(to: wlr_output.self))
        }, me)

        guard wlr_backend_start(b) else {
            wl_display_destroy(d)
            throw BackendError.noBackend
        }
        for _ in 0..<outputCount {
            _ = wlr_headless_add_output(b, UInt32(width), UInt32(height))
        }
        guard !outputs.isEmpty else {
            wl_display_destroy(d)
            throw BackendError.noOutput
        }

        // Give every output a renderer and a mode. Until this commit lands, an
        // output has no buffers and `begin_render_pass` has nothing to draw to.
        for out in outputs {
            guard wlr_output_init_render(out, allocator, renderer) else {
                throw BackendError.renderInitFailed
            }
            var state = wlr_output_state()
            wlr_output_state_init(&state)
            wlr_output_state_set_enabled(&state, true)
            wlr_output_state_set_custom_mode(&state, width, height, refreshMilliHz)
            let ok = wlr_output_commit_state(out, &state)
            wlr_output_state_finish(&state)
            guard ok else { throw BackendError.modeRejected }
        }
    }

    deinit {
        tw_listener_free(newOutputListener)
        wl_display_destroy(display)
    }

    /// Dispatch pending events without blocking.
    public func dispatchPending() {
        wl_event_loop_dispatch(eventLoop, 0)
    }

    /// Dispatch, blocking at most `timeoutMs` (-1 blocks indefinitely).
    public func dispatch(timeoutMs: Int32) {
        wl_event_loop_dispatch(eventLoop, timeoutMs)
    }
}

/// A `wlr_output`, driven by the metronome.
///
/// A final class rather than a struct: it owns a C listener whose pointer must
/// stay stable, which is the same lifetime rule as every other listener in this
/// codebase (HANDOFF §2.2).
public final class WlrootsOutput: Output {
    private let output: UnsafeMutablePointer<wlr_output>
    private let session: WlrootsSession
    private let events = OutputEvents()
    private var presentListener: UnsafeMutablePointer<tw_listener>?

    /// commit_seq → the vblank we aimed that commit at, so a present event can
    /// be matched to its target. Small and fixed: only a few frames are ever in
    /// flight, and a map that could grow has no place near the present path.
    private var targets = [(seq: UInt32, target: UInt64)](repeating: (0, 0), count: 16)
    private var targetSlot = 0

    public let periodHintNs: UInt64
    private var frameColour: Float = 0
    /// Anchor for the synthetic grid used when the backend has no hardware
    /// clock. Set from the first present event.
    private var gridEpoch: UInt64 = 0
    /// Whether any present event has carried a hardware timestamp — reported,
    /// so a bench never silently claims a cadence the backend cannot provide.
    public private(set) var sawHardwareClock = false

    public init(_ output: UnsafeMutablePointer<wlr_output>, session: WlrootsSession) {
        self.output = output
        self.session = session
        // wlroots reports refresh in mHz. A headless output with no mode set
        // reports 0, in which case 60Hz is the honest guess — and the predictor
        // measures the truth anyway (P6.1), so a wrong hint costs convergence,
        // not correctness.
        let mHz = output.pointee.refresh
        periodHintNs = mHz > 0 ? UInt64(1_000_000_000_000 / Int64(mHz)) : 16_666_666

        let me = Unmanaged.passUnretained(self).toOpaque()
        presentListener = tw_listen(&output.pointee.events.present, { ctx, data in
            guard let ctx, let data else { return }
            let o = Unmanaged<WlrootsOutput>.fromOpaque(ctx).takeUnretainedValue()
            let ev = data.assumingMemoryBound(to: wlr_output_event_present.self)
            let when = ev.pointee.when
            let hwClock = ev.pointee.flags
                & UInt32(WLR_OUTPUT_PRESENT_HW_CLOCK.rawValue) != 0
            o.events.push(PresentEvent(
                commitSeq: ev.pointee.commit_seq,
                whenNs: UInt64(when.tv_sec) &* 1_000_000_000 &+ UInt64(when.tv_nsec),
                presented: ev.pointee.presented,
                hardwareClock: hwClock))
        }, me)
    }

    deinit {
        // Free the listener before dropping the context it points at. The
        // opposite order is §2.35's segfault, one layer down.
        tw_listener_free(presentListener)
    }

    public var name: String { String(cString: output.pointee.name) }
    public var width: Int32 { output.pointee.width }
    public var height: Int32 { output.pointee.height }

    /// Render and commit a frame. Fire-and-forget: `wlr_output_commit_state`
    /// queues the flip, and `present` reports back later.
    public func submit(target: UInt64, at now: UInt64) {
        var state = wlr_output_state()
        wlr_output_state_init(&state)
        defer { wlr_output_state_finish(&state) }

        guard let pass = wlr_output_begin_render_pass(output, &state, nil) else { return }
        // P6.2 draws a single animated rect: enough to prove buffers are being
        // allocated, rendered into, committed and presented. Real surfaces
        // arrive in P6.3 — this is the pipeline under test, not the picture.
        frameColour += 0.013
        if frameColour > 1 { frameColour -= 1 }
        var opts = wlr_render_rect_options()
        opts.box = wlr_box(x: 0, y: 0, width: Int32(output.pointee.width),
                           height: Int32(output.pointee.height))
        opts.color = wlr_render_color(r: frameColour, g: 0.25, b: 1 - frameColour, a: 1)
        opts.blend_mode = WLR_RENDER_BLEND_MODE_NONE
        wlr_render_pass_add_rect(pass, &opts)
        _ = wlr_render_pass_submit(pass)

        guard wlr_output_commit_state(output, &state) else { return }
        // Remember what this commit was aiming at, so its present event can be
        // judged on time.
        targets[targetSlot] = (output.pointee.commit_seq, target)
        targetSlot = (targetSlot &+ 1) % targets.count
    }

    public func pollFlip() -> Flip? {
        // Let wlroots deliver whatever is ready, without blocking. A present
        // event cannot arrive unless the loop is dispatched.
        session.dispatchPending()
        guard let e = events.pop() else { return nil }
        if e.hardwareClock { sawHardwareClock = true }
        var target = e.whenNs
        for t in targets where t.seq == e.commitSeq { target = t.target }
        let vblank = snapToGrid(e)
        return Flip(target: target, vblank: vblank, done: e.whenNs,
                    missed: e.presented && vblank > target)
    }

    /// Give a backend with no hardware clock an honest vblank grid.
    ///
    /// A headless output presents the instant it is committed, so its "vblank"
    /// timestamp *is our own commit time*. Feeding that straight back into the
    /// predictor closes a loop with no external reference: the estimated period
    /// becomes whatever rate we happen to be running at, and because the loop
    /// commits slightly before each target, it ratchets faster every frame. It
    /// is self-consistent at any period and therefore stable at none — measured
    /// drifting from 16.7 ms to 11.9 ms over 120 frames.
    ///
    /// `WLR_OUTPUT_PRESENT_HW_CLOCK` is exactly the flag that distinguishes a
    /// measured timestamp from a bookkeeping one, so we use it: with real
    /// hardware the timestamp is the truth and is passed through untouched;
    /// without it, we snap to the output's nominal refresh grid and pace against
    /// that. A virtual output has no vblank to discover — pretending to measure
    /// one is worse than admitting it.
    private func snapToGrid(_ e: PresentEvent) -> UInt64 {
        guard !e.hardwareClock, periodHintNs > 0 else { return e.whenNs }
        if gridEpoch == 0 { gridEpoch = e.whenNs; return e.whenNs }
        guard e.whenNs > gridEpoch else { return gridEpoch }
        let k = (Mono.since(gridEpoch, e.whenNs) &+ periodHintNs / 2) / periodHintNs
        return gridEpoch &+ k &* periodHintNs
    }

    /// Wait for the deadline **while servicing wlroots**.
    ///
    /// This is the override that makes the bridge work at all. The metronome's
    /// default is a plain `clock_nanosleep`, which would leave the event loop
    /// unserviced for the whole period — so no `present` event would ever
    /// arrive, the predictor would never get a sample, and the compositor would
    /// look hung while dutifully committing frames.
    ///
    /// Declared in the `Output` protocol body and defaulted in its extension,
    /// not defaulted alone: a method that exists only in a protocol extension is
    /// **statically dispatched** and this override would silently never be
    /// called (HANDOFF §2.11 — the sheet-animation trap, four phases old).
    public func waitUntil(deadlineNs: UInt64) {
        while true {
            let now = Mono.now()
            guard now < deadlineNs else { return }
            let remainingNs = deadlineNs &- now
            // Dispatch in millisecond slices; below a millisecond, spin the
            // remainder out with a plain sleep so we wake on time rather than
            // rounding a sub-millisecond wait up to one.
            if remainingNs < 1_000_000 {
                Mono.sleep(untilNs: deadlineNs)
                return
            }
            session.dispatch(timeoutMs: Int32(min(remainingNs / 1_000_000, 1000)))
        }
    }
}
