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
// **Single-threaded, and P6.5 measured why that is enough.** The event loop is
// serviced from inside the metronome's wait (see `waitUntil`). P6.2 recorded
// this as a debt against C2 — one thread dispatching client requests cannot
// obviously promise that no client delays the present thread — and P6.5 put
// eleven hostile processes against it to find out. The answer: what mattered
// was not *which thread* dispatches but **where in the frame** it happens.
// Dispatching after the deadline (the original `pollFlip`) collapsed under 32
// flooders; dispatching only in the slack before it, with a reserve, survives
// 64 at every rate we target. That is DESKTOP.md §4's "bounded work per wakeup
// gives backpressure" rather than its threading model. The debt is re-scoped,
// not dropped: a GPU present path (Phase 4) puts far more work on this thread,
// and the measurement should be repeated then.

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
    case noGlobals(String)
    /// Could not bind a Wayland socket. Its own case, with its own message,
    /// because it was originally folded into `.noDisplay` and reported
    /// "could not create a wl_display" — which is a lie that sends you to
    /// look at the compositor when the problem is the environment.
    case noSocket

    public var description: String {
        switch self {
        case .noDisplay: return "could not create a wl_display"
        case .noBackend: return "could not create a wlroots backend"
        case .noRenderer: return "could not create a wlroots renderer"
        case .noAllocator: return "could not create a wlroots allocator"
        case .noOutput: return "the backend produced no output"
        case .renderInitFailed: return "wlr_output_init_render failed"
        case .modeRejected: return "the output rejected its mode"
        case .noGlobals(let what): return "could not create the \(what) global"
        case .noSocket:
            return "could not bind a Wayland socket — is XDG_RUNTIME_DIR set?"
                + " (FreeBSD has no pam_xdg, so nothing sets it: HANDOFF §2.31)"
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

        // Software rendering, unless the caller says otherwise.
        //
        // Phase 6 is software-rendered by scope (PHASE6.md §7.1) — the build VM
        // has no `/dev/dri` and real GPU work is Phase 4 — but on a dev box with
        // a GPU `wlr_renderer_autocreate` picks GLES2 and allocates GPU-backed
        // buffers, which are **not CPU-readable**. That makes `capturePPM`
        // impossible and the difference between the two machines invisible until
        // it fails. Pinning pixman here keeps both platforms on the same path.
        // `overwrite: 0` so WLR_RENDERER from the environment still wins.
        setenv("WLR_RENDERER", "pixman", 0)

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

            // **Advertise the output to clients.** Without this global there is
            // no `wl_output` on the bus at all: a client asking "what displays
            // are there?" is told none. It is easy to miss because the things
            // that break are the things that *ask* — screencopy ("the
            // compositor advertised no outputs"), and per-output HiDPI scale,
            // which Phase 1 built and which would silently stay at 1x. Ordinary
            // windows and layer surfaces never notice.
            wlr_output_create_global(out, display)
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
    /// The scene to draw. A concrete type rather than an existential: the
    /// present path calls this every frame and a witness-table hop plus the ARC
    /// traffic of a `weak var` is exactly the kind of cost DESKTOP.md §11 bans
    /// from here. Set once at startup; nil means "draw the test pattern", which
    /// is what P6.2 had and what the bridge bench still exercises.
    public var scene: SurfaceScene?
    /// The seat, for the compositor-drawn cursor. Drawn last, so the pointer is
    /// over everything — DESKTOP.md §5 makes this a hardware cursor plane on
    /// real hardware (Phase 4); here it is a rectangle in the same frame.
    public var seat: Seat?
    /// The desktop behind the windows. Jaguar blue, so a capture is obviously
    /// ours and an empty output is obviously empty.
    public var background = wlr_render_color(r: 0.24, g: 0.40, b: 0.63, a: 1.0)
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
        if let scene {
            scene.render(into: pass, background: background)
            seat?.renderCursor(into: pass)
        } else {
            // No scene: the P6.2 test pattern, an animated rect. Enough to prove
            // buffers are allocated, rendered into, committed and presented —
            // which is what the bridge bench still measures.
            frameColour += 0.013
            if frameColour > 1 { frameColour -= 1 }
            var opts = wlr_render_rect_options()
            opts.box = wlr_box(x: 0, y: 0, width: Int32(output.pointee.width),
                               height: Int32(output.pointee.height))
            opts.color = wlr_render_color(r: frameColour, g: 0.25, b: 1 - frameColour, a: 1)
            opts.blend_mode = WLR_RENDER_BLEND_MODE_NONE
            wlr_render_pass_add_rect(pass, &opts)
        }
        _ = wlr_render_pass_submit(pass)

        guard wlr_output_commit_state(output, &state) else { return }
        // Remember what this commit was aiming at, so its present event can be
        // judged on time.
        targets[targetSlot] = (output.pointee.commit_seq, target)
        targetSlot = (targetSlot &+ 1) % targets.count
    }

    public func pollFlip() -> Flip? {
        // **No dispatch here, deliberately.** This runs AFTER the deadline, in
        // the critical path between waking and compositing — the single worst
        // place to service client traffic, because every microsecond spent here
        // is taken directly from the frame. Present events are collected during
        // `waitUntil`, which is where the compositor has slack by construction;
        // this only drains what already arrived. (Measured: moving the dispatch
        // out of here is what took 240Hz from collapsing at 24 hostile clients
        // to surviving them — PHASE6.md P6.5.)
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

    /// Render one frame and write it out as a binary PPM.
    ///
    /// **A PPM, not a PNG**, and deliberately: the compositor would otherwise
    /// have to link an image encoder to prove it drew something, and the harness
    /// has probed PPM with `od` since Phase 2 (HANDOFF §2.26 — "a pixel probe
    /// needs no image library"). The same reasoning that keeps cairo out of
    /// `abyss-portal` keeps it out of here.
    ///
    /// It captures **the output's own swapchain buffer**, the one it is about to
    /// present. The first attempt allocated a buffer of its own and rendered
    /// into that — and the renderer refused the pass, because a buffer has to be
    /// in the renderer's render-format set and guessing XRGB8888/INVALID is not
    /// the same as asking. `wlr_output_begin_render_pass` already negotiates all
    /// of that and leaves the chosen buffer in `state.buffer`, so the honest
    /// capture is the frame we actually drew rather than a re-render into a
    /// buffer we hoped was compatible.
    public func capturePPM(path: String) -> Bool {
        var state = wlr_output_state()
        wlr_output_state_init(&state)
        defer { wlr_output_state_finish(&state) }

        guard let pass = wlr_output_begin_render_pass(output, &state, nil) else {
            fail("the output refused a render pass")
            return false
        }
        if let scene {
            scene.render(into: pass, background: background)
            seat?.renderCursor(into: pass)
        }
        guard wlr_render_pass_submit(pass) else {
            fail("the render pass failed")
            return false
        }
        guard let buffer = state.buffer else {
            fail("the render pass left no buffer to read")
            return false
        }

        var data: UnsafeMutableRawPointer?
        var fmt: UInt32 = 0
        var stride = 0
        guard wlr_buffer_begin_data_ptr_access(
            buffer, UInt32(WLR_BUFFER_DATA_PTR_ACCESS_READ.rawValue),
            &data, &fmt, &stride), let src = data
        else {
            fail("the output's buffer is not CPU-readable (not shm-backed?)")
            return false
        }
        defer { wlr_buffer_end_data_ptr_access(buffer) }

        let w = Int(output.pointee.width), h = Int(output.pointee.height)
        let ok = WlrootsOutput.writePPM(path: path, pixels: src, width: w, height: h,
                                        stride: stride)
        if !ok { fail("could not write \(path)") }
        return ok
    }

    /// A capture that fails silently is worse than no capture: the harness gets
    /// a missing file and no idea which of four steps went wrong.
    private func fail(_ why: String) {
        let m = Array("undertow: capture failed — \(why)\n".utf8)
        _ = m.withUnsafeBufferPointer { write(2, $0.baseAddress, m.count) }
    }

    /// Binary PPM (P6). Source is XRGB8888 little-endian, i.e. B,G,R,X in
    /// memory; PPM wants R,G,B.
    private static func writePPM(path: String, pixels: UnsafeMutableRawPointer,
                                 width: Int, height: Int, stride: Int) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var out = Array("P6\n\(width) \(height)\n255\n".utf8)
        out.reserveCapacity(out.count + width * height * 3)
        let base = pixels.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let line = base + row * stride
            for col in 0..<width {
                let p = line + col * 4
                out.append(p[2])   // R
                out.append(p[1])   // G
                out.append(p[0])   // B
            }
        }
        var written = 0
        while written < out.count {
            let n = out.withUnsafeBufferPointer {
                write(fd, $0.baseAddress! + written, out.count - written)
            }
            if n <= 0 { return false }
            written += n
        }
        return true
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
        // Stop servicing clients this much before the deadline and just sleep.
        //
        // A dispatch pass is bounded by what is in the clients' socket buffers,
        // NOT by the time we have left — so the last pass before a deadline can
        // overrun it, and that overrun lands on the frame. The reserve means the
        // last thing we do before compositing is always a plain sleep, so a
        // pass that runs long eats slack rather than the frame.
        let reserveNs: UInt64 = 500_000
        while true {
            let now = Mono.now()
            guard now < deadlineNs else { return }
            let remainingNs = deadlineNs &- now
            if remainingNs <= reserveNs {
                Mono.sleep(untilNs: deadlineNs)
                return
            }
            // Bounded, non-blocking passes with a clock check between each, so
            // a flood cannot hold us inside one long blocking dispatch.
            session.dispatchPending()
            if Mono.now() >= deadlineNs &- reserveNs { continue }
            // Nothing pending: block for the remainder rather than spinning.
            session.dispatch(timeoutMs: Int32(min((remainingNs &- reserveNs) / 1_000_000 + 1,
                                                  1000)))
        }
    }
}
