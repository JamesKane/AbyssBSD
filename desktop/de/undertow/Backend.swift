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
    /// A socket name was asked for and is already in use — someone else's
    /// session, or ours, still holding it.
    case socketTaken(String)
    /// The privileged socket (PHASE10 P10.3) could not be made: path, errno.
    case privilegedSocket(String, Int32)

    public var description: String {
        switch self {
        case .privilegedSocket(let path, let e):
            return "could not listen on the privileged socket \(path): \(String(cString: strerror(e)))"
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
        case .socketTaken(let name):
            return "could not bind the Wayland socket '\(name)' — something is"
                + " already using it (is a session already running?)"
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

    /// Outputs the backend has announced, in arrival order — and only the ones
    /// that still exist.
    public private(set) var outputs: [UnsafeMutablePointer<wlr_output>] = []
    private var newOutputListener: UnsafeMutablePointer<tw_listener>?
    /// One destroy listener per output, freed when it fires.
    private var outputDestroyListeners: [UInt: UnsafeMutablePointer<tw_listener>] = [:]
    /// Set once the outputs found at start are configured. After that, an
    /// output that arrives is configured as it arrives.
    private var started = false

    /// **Outputs come and go while we run** (P16, found on metal). wlroots 0.20
    /// destroys every DRM output when the session is paused — a VT switch,
    /// Ctrl-Alt-F2, or fast user switching — and announces new ones when it
    /// comes back (`backend/drm/backend.c`, `handle_session_active`). A monitor
    /// unplugged and plugged in again is the same pair of events. undertow
    /// assumed its outputs lived for ever, and the first VT switch on the
    /// 12700KF aborted it in `wlr_output_finish` with its present listener
    /// still attached.
    ///
    /// `onOutputRemoved` runs inside the output's destroy, **before** wlroots
    /// finishes it: every holder lets go there. `onOutputAdded` runs once a
    /// late output is configured and has its global.
    public var onOutputRemoved: ((UnsafeMutablePointer<wlr_output>) -> Void)?
    public var onOutputAdded: ((UnsafeMutablePointer<wlr_output>) -> Void)?
    public private(set) var outputsLost = 0
    public private(set) var outputsReturned = 0
    /// Input devices the backend announced while it started, before anything
    /// that handles input existed. `Seat` adopts them (`takeStartupInputs`).
    private var startupInputs: [UnsafeMutablePointer<wlr_input_device>] = []
    private var startupInputListener: UnsafeMutablePointer<tw_listener>?

    /// Which backend to run on.
    ///
    /// Phases 1–8 ran headless by scope: C1–C3 are provable without a GPU and
    /// the build VM has no `/dev/dri`. Phase 4 is where that stops being enough
    /// — a machine somebody installs onto has a screen, and nothing above this
    /// line has ever driven one.
    public struct HeadlessSize: Equatable, Sendable {
        public var width, height: Int32
        public init(_ width: Int32, _ height: Int32) { self.width = width; self.height = height }
    }

    public enum Kind: Equatable, Sendable {
        /// Outputs we invent, at a size we choose. Deterministic, CPU-readable,
        /// and the only thing the build VM can do.
        /// One per size, in order (P14.7a: several, for Displays).
        case headless(sizes: [HeadlessSize], refreshMilliHz: Int32)
        /// Whatever this machine actually is: **DRM/KMS on metal**, a nested
        /// Wayland window inside another compositor, X11 under one. wlroots
        /// decides, from the environment and from what it can open — which is
        /// the same decision every wlroots compositor makes and not one worth
        /// making differently.
        case auto
    }

    /// The session, when the backend needed one. DRM does; nested does not.
    /// Held because it owns the VT and the device fds — dropping it takes the
    /// display down with it.
    private var session: UnsafeMutablePointer<wlr_session>?

    /// What we ended up on, for the log and for the tests.
    public let kind: Kind

    public convenience init(headlessOutputs outputCount: Int, width: Int32, height: Int32,
                            refreshMilliHz: Int32, verbose: Bool = false) throws {
        try self.init(.headless(sizes: Array(repeating: HeadlessSize(width, height), count: outputCount),
                                refreshMilliHz: refreshMilliHz), verbose: verbose)
    }

    public init(_ kind: Kind, verbose: Bool = false) throws {
        self.kind = kind
        if verbose { tw_log_verbose() } else { tw_log_silence() }

        // Software rendering **for headless only**.
        //
        // On a dev box with a GPU `wlr_renderer_autocreate` picks GLES2 and
        // allocates GPU-backed buffers, which are *not CPU-readable*: that makes
        // `capturePPM` impossible and the difference between the two machines
        // invisible until it fails. Pinning pixman keeps every headless run on
        // one path. On a real backend it would be the wrong choice — a GPU we
        // refuse to render with is a GPU we are not using — so the pin does not
        // apply there. `overwrite: 0` so WLR_RENDERER from the environment wins
        // either way.
        if case .headless = kind { setenv("WLR_RENDERER", "pixman", 0) }

        guard let d = wl_display_create() else { throw BackendError.noDisplay }
        display = d
        eventLoop = wl_display_get_event_loop(d)

        let b: UnsafeMutablePointer<wlr_backend>
        switch kind {
        case .headless:
            guard let hb = wlr_headless_backend_create(eventLoop) else {
                wl_display_destroy(d)
                throw BackendError.noBackend
            }
            b = hb
        case .auto:
            // wlroots returns a multi-backend and, for DRM, a session that owns
            // the VT and the device descriptors. Both have to be kept.
            var sess: UnsafeMutablePointer<wlr_session>?
            guard let ab = wlr_backend_autocreate(eventLoop, &sess) else {
                wl_display_destroy(d)
                throw BackendError.noBackend
            }
            b = ab
            session = sess
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
            s.adopt(data.assumingMemoryBound(to: wlr_output.self))
        }, me)
        // **And inputs, for the same reason** (PHASE4 §5.11). libinput announces
        // every device present at start from inside `wlr_backend_start`, and
        // `Seat` — which registers its own `new_input` listener — is built
        // later. Without this, the first metal boot on DRM had a dead keyboard:
        // libinput added it, and nobody heard. The mouse only worked because
        // its driver loaded after the session was up, as a hot-plug. The VM
        // never shows this: the harness's devices are virtual, created later.
        startupInputListener = tw_listen(&b.pointee.events.new_input, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<WlrootsSession>.fromOpaque(ctx).takeUnretainedValue()
            s.startupInputs.append(data.assumingMemoryBound(to: wlr_input_device.self))
        }, me)

        guard wlr_backend_start(b) else {
            wl_display_destroy(d)
            throw BackendError.noBackend
        }
        if case .headless(let sizes, _) = kind {
            for sz in sizes { _ = wlr_headless_add_output(b, UInt32(sz.width), UInt32(sz.height)) }
        } else {
            // A real backend announces its own outputs, and may take a moment
            // about it: DRM enumerates connectors and the Wayland backend has to
            // round-trip to its host. Give the loop a chance to deliver them
            // before deciding there is no display.
            for _ in 0..<50 where outputs.isEmpty {
                wl_display_flush_clients(display)
                _ = wl_event_loop_dispatch(eventLoop, 20)
            }
        }
        guard !outputs.isEmpty else {
            wl_display_destroy(d)
            throw BackendError.noOutput
        }

        // Give every output a renderer and a mode. Until this commit lands, an
        // output has no buffers and `begin_render_pass` has nothing to draw to.
        for (index, out) in outputs.enumerated() {
            try configure(out, index: index)
        }
        started = true
    }

    /// A renderer, a mode, and a global — for an output found at start, and
    /// for one that arrives later (a VT come back, a monitor plugged in).
    private func configure(_ out: UnsafeMutablePointer<wlr_output>, index: Int,
                           size: HeadlessSize? = nil) throws {
        guard wlr_output_init_render(out, allocator, renderer) else {
            throw BackendError.renderInitFailed
        }
        var state = wlr_output_state()
        wlr_output_state_init(&state)
        wlr_output_state_set_enabled(&state, true)
        switch kind {
        case .headless(let sizes, let hz):
            let sz = size ?? sizes[min(index, sizes.count - 1)]
            wlr_output_state_set_custom_mode(&state, sz.width, sz.height, hz)
        case .auto:
            // **Take the display's own preferred mode.** A custom mode is
            // what a headless output needs and what a real one is entitled
            // to refuse: a monitor has a native resolution and a refresh
            // rate it was built for, and asking a panel for 1024x768 at
            // 60.000Hz is asking it to scale. Some connectors report no
            // modes at all (nothing plugged in, or a virtual connector), in
            // which case there is nothing to set and the commit still
            // enables it.
            if let mode = wlr_output_preferred_mode(out) {
                wlr_output_state_set_mode(&state, mode)
            }
        }
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

    /// Every output the backend announces, at start or later.
    private func adopt(_ out: UnsafeMutablePointer<wlr_output>) {
        outputs.append(out)
        let me = Unmanaged.passUnretained(self).toOpaque()
        outputDestroyListeners[UInt(bitPattern: out)] = tw_listen(&out.pointee.events.destroy, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<WlrootsSession>.fromOpaque(ctx).takeUnretainedValue()
                .lose(data.assumingMemoryBound(to: wlr_output.self))
        }, me)
        guard started else { return }
        // The stand-in VT's way back: the same name and size as before, as a
        // DRM connector has when its session resumes.
        var size: HeadlessSize? = nil
        if !standInReturning.isEmpty {
            let r = standInReturning.removeFirst()
            r.name.withCString { wlr_output_set_name(out, $0) }
            size = r.size
        }
        let name = String(cString: out.pointee.name)
        do {
            try configure(out, index: outputs.count - 1, size: size)
        } catch {
            Compositor.log("output \(name) arrived and could not be configured: \(error)")
            return
        }
        outputsReturned &+= 1
        onOutputAdded?(out)
    }

    /// An output going away. Runs inside wlroots' destroy signal, which allows
    /// a listener to remove itself.
    private func lose(_ out: UnsafeMutablePointer<wlr_output>) {
        outputsLost &+= 1
        onOutputRemoved?(out)
        outputs.removeAll { $0 == out }
        if let l = outputDestroyListeners.removeValue(forKey: UInt(bitPattern: out)) {
            tw_listener_free(l)
        }
    }

    // MARK: - The stand-in VT (for tests)

    /// What a headless output was, so `back` can bring it back as itself.
    private var standInAway: [(name: String, size: HeadlessSize)] = []
    private var standInReturning: [(name: String, size: HeadlessSize)] = []
    private var standInVTFd: Int32 = -1
    private var standInVTSource: OpaquePointer?
    private var standInVTBuffer: [UInt8] = []

    /// `--stand-in-vt FIFO`: a line `away` does to the headless outputs what
    /// wlroots does to DRM ones when the VT is switched away — destroys them
    /// all — and `back` announces them again, by the same names. Headless only:
    /// a real session has a real VT.
    public func addStandInVT(fifo: String) -> Bool {
        guard case .headless = kind, standInVTFd < 0 else { return false }
        let fd = open(fifo, O_RDWR | O_NONBLOCK)   // RDWR: never sees EOF between writers
        guard fd >= 0 else { return false }
        standInVTFd = fd
        standInVTSource = wl_event_loop_add_fd(eventLoop, fd, UInt32(WL_EVENT_READABLE), { _, _, data in
            guard let data else { return 0 }
            Unmanaged<WlrootsSession>.fromOpaque(data).takeUnretainedValue().readStandInVT()
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
        return true
    }

    private func readStandInVT() {
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(standInVTFd, &buf, buf.count)
        guard n > 0 else { return }
        standInVTBuffer += buf[0..<n]
        while let nl = standInVTBuffer.firstIndex(of: 10) {
            let line = String(decoding: standInVTBuffer[..<nl], as: UTF8.self)
            standInVTBuffer.removeSubrange(...nl)
            switch line {
            case "away":
                guard standInAway.isEmpty else { continue }
                for o in outputs {
                    standInAway.append((String(cString: o.pointee.name),
                                        HeadlessSize(o.pointee.width, o.pointee.height)))
                }
                Compositor.log("stand-in VT: away — every output destroyed, as DRM's are")
                for o in outputs { wlr_output_destroy(o) }
            case "back":
                Compositor.log("stand-in VT: back — the outputs announced again")
                standInReturning = standInAway
                standInAway = []
                for r in standInReturning {
                    _ = wlr_headless_add_output(backend, UInt32(r.size.width), UInt32(r.size.height))
                }
            default:
                continue
            }
        }
    }

    /// The devices announced before `Seat` existed, handed over once; from
    /// then on `Seat`'s own `new_input` listener sees every device.
    public func takeStartupInputs() -> [UnsafeMutablePointer<wlr_input_device>] {
        tw_listener_free(startupInputListener)
        startupInputListener = nil
        defer { startupInputs = [] }
        return startupInputs
    }

    deinit {
        tw_listener_free(startupInputListener)
        tw_listener_free(newOutputListener)
        // Before the display goes, which destroys the outputs: a destroy
        // listener firing into a session mid-deinit is §2.35 again.
        for l in outputDestroyListeners.values { tw_listener_free(l) }
        outputDestroyListeners = [:]
        if let src = standInVTSource { wl_event_source_remove(src) }
        if standInVTFd >= 0 { close(standInVTFd) }
        wl_display_destroy(display)
    }

    /// Switch to virtual terminal `vt` (Ctrl-Alt-F*n*). False with no session
    /// to ask — headless, or nested in another compositor — which is how the
    /// key is left to the client there instead of eaten.
    @discardableResult
    public func changeVT(_ vt: UInt32) -> Bool {
        guard let session else { return false }
        return wlr_session_change_vt(session, vt)
    }

    /// The output called `name`, if the backend has one.
    public func output(named name: String) -> UnsafeMutablePointer<wlr_output>? {
        outputs.first { String(cString: $0.pointee.name) == name }
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
    /// The wlroots output, while it exists. **Nil while the VT is away** (or
    /// the monitor unplugged): wlroots has destroyed it, and this object —
    /// which the scene, the metronome and the loop all hold — waits, drawing
    /// nothing, for one of the same name to come back (`attach`).
    private var output: UnsafeMutablePointer<wlr_output>?
    /// The connector's name, which outlives any one `wlr_output` for it.
    public let name: String
    private var lastWidth: Int32, lastHeight: Int32
    private let session: WlrootsSession
    private let events = OutputEvents()
    private var presentListener: UnsafeMutablePointer<tw_listener>?
    /// wlroots asking for a frame (`needs_frame`): screencopy waits on one, and
    /// with present-on-damage a static screen would otherwise never send it.
    private var needsFrameListener: UnsafeMutablePointer<tw_listener>?

    /// commit_seq → the vblank we aimed that commit at, so a present event can
    /// be matched to its target. Small and fixed: only a few frames are ever in
    /// flight, and a map that could grow has no place near the present path.
    private var targets = [(seq: UInt32, target: UInt64, committed: UInt64)](
        repeating: (0, 0, 0), count: 16)
    private var targetSlot = 0
    /// Commits that reached the backend, and commits it refused (PHASE4 §5.12).
    public private(set) var commitsMade = 0
    public private(set) var commitsRefused = 0
    /// Present events heard more than a millisecond / half a period after the
    /// flip they report, and the worst delay seen (hardware clock only).
    public private(set) var deliveriesLate1ms = 0
    public private(set) var deliveriesLateHalfPeriod = 0
    public private(set) var deliveryWorstNs: UInt64 = 0
    public private(set) var deliveries = 0
    func noteDelivery(_ ns: UInt64) {
        deliveries &+= 1
        if ns > 1_000_000 { deliveriesLate1ms &+= 1 }
        if ns > periodHintNs / 2 { deliveriesLateHalfPeriod &+= 1 }
        if ns > deliveryWorstNs { deliveryWorstNs = ns }
    }
    /// Refused commits not yet reported by `pollFlip`, as their targets. A
    /// fixed ring, like `targets`: nothing on the present path allocates.
    private var refused = [UInt64](repeating: 0, count: 16)
    private var refusedHead = 0
    private var refusedPending = 0

    public private(set) var periodHintNs: UInt64
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
        self.name = String(cString: output.pointee.name)
        self.lastWidth = output.pointee.width
        self.lastHeight = output.pointee.height
        self.session = session
        // wlroots reports refresh in mHz. A headless output with no mode set
        // reports 0, in which case 60Hz is the honest guess — and the predictor
        // measures the truth anyway (P6.1), so a wrong hint costs convergence,
        // not correctness.
        let mHz = output.pointee.refresh
        periodHintNs = mHz > 0 ? UInt64(1_000_000_000_000 / Int64(mHz)) : 16_666_666
        listen(to: output)
    }

    /// Whether this is the object for `o`.
    public func isBound(to o: UnsafeMutablePointer<wlr_output>) -> Bool { output == o }
    /// Whether there is an output to draw on.
    public var attached: Bool { output != nil }

    /// Its output is being destroyed (inside wlroots' destroy signal): let go
    /// of it, and of flips it will never report.
    public func detach() {
        tw_listener_free(presentListener)
        presentListener = nil
        tw_listener_free(needsFrameListener)
        needsFrameListener = nil
        output = nil
        refusedPending = 0
        while events.pop() != nil {}
    }

    /// One of the same name is back: draw on it. If the displays were asleep
    /// when it went, it goes back to sleep — the new output starts enabled.
    public func attach(_ o: UnsafeMutablePointer<wlr_output>) {
        output = o
        lastWidth = o.pointee.width
        lastHeight = o.pointee.height
        gridEpoch = 0
        listen(to: o)
        scene?.invalidate()          // a new output shows nothing until drawn
        _ = refreshPeriod()
        if asleep { asleep = false; setAsleep(true) }
    }

    private func listen(to output: UnsafeMutablePointer<wlr_output>) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        needsFrameListener = tw_listen(&output.pointee.events.needs_frame, { ctx, _ in
            guard let ctx else { return }
            Unmanaged<WlrootsOutput>.fromOpaque(ctx).takeUnretainedValue().scene?.invalidate()
        }, me)
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
            // How long after the flip we heard of it (PHASE4 §5.13): wlroots
            // keeps the output "flip pending" until this event is read, so a
            // late delivery refuses the next commit however early it comes.
            let whenNs = UInt64(when.tv_sec) &* 1_000_000_000 &+ UInt64(when.tv_nsec)
            if hwClock { o.noteDelivery(Mono.since(whenNs, Mono.now())) }
        }, me)
    }

    deinit {
        // Free the listener before dropping the context it points at. The
        // opposite order is §2.35's segfault, one layer down.
        tw_listener_free(presentListener)
        tw_listener_free(needsFrameListener)
    }

    /// Read the refresh rate again, after a mode change; returns whether the
    /// period changed.
    @discardableResult
    public func refreshPeriod() -> Bool {
        guard let output else { return false }
        let mHz = output.pointee.refresh
        let p = mHz > 0 ? UInt64(1_000_000_000_000 / Int64(mHz)) : periodHintNs
        defer { periodHintNs = p }
        return p != periodHintNs
    }

    public var width: Int32 { output?.pointee.width ?? lastWidth }
    public var height: Int32 { output?.pointee.height ?? lastHeight }

    /// Off while the displays sleep (U.9). On metal that is the CRTC, and the
    /// monitor goes to standby; nothing is drawn or committed until it wakes.
    public private(set) var asleep = false

    public func setAsleep(_ on: Bool) {
        guard on != asleep else { return }
        var state = wlr_output_state()
        wlr_output_state_init(&state)
        defer { wlr_output_state_finish(&state) }
        wlr_output_state_set_enabled(&state, !on)
        if let output, !wlr_output_commit_state(output, &state) {
            Compositor.log("\(name): could not turn \(on ? "off" : "on")")
        }
        asleep = on
        if !on { scene?.invalidate() }   // awake: the screen is blank until drawn
    }

    /// Render and commit a frame. Fire-and-forget: `wlr_output_commit_state`
    /// queues the flip, and `present` reports back later.
    public func submit(target: UInt64, at now: UInt64) {
        guard !asleep, let output else { return }
        var state = wlr_output_state()
        wlr_output_state_init(&state)
        defer { wlr_output_state_finish(&state) }

        guard let pass = wlr_output_begin_render_pass(output, &state, nil) else { return }
        if let scene {
            scene.render(into: pass, background: background)
            seat?.renderCursor(into: pass, scene: scene)
            scene.markPresented(on: output)
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

        guard wlr_output_commit_state(output, &state) else {
            // Refused: on DRM, most often "a page-flip is already pending" —
            // the previous frame has not reached the screen yet. A frame lost
            // here never produces a present event, so nothing else counts it.
            commitsRefused &+= 1
            // And it was never shown: the next frame draws, changed or not.
            scene?.invalidate()
            // Tell the loop, which otherwise never hears of it: no present
            // event will ever come for this frame.
            if refusedPending < refused.count {
                refused[(refusedHead &+ refusedPending) % refused.count] = target
                refusedPending &+= 1
            }
            return
        }
        commitsMade &+= 1
        // Remember what this commit was aiming at, so its present event can be
        // judged on time — and when the commit returned, which is what the
        // flip's `done` means (PHASE4 §5.11: see `pollFlip`).
        targets[targetSlot] = (output.pointee.commit_seq, target, Mono.now())
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
        if refusedPending > 0 {
            let target = refused[refusedHead]
            refusedHead = (refusedHead &+ 1) % refused.count
            refusedPending &-= 1
            return Flip(target: target, vblank: target, done: Mono.now(),
                        missed: true, refused: true)
        }
        guard let e = events.pop() else { return nil }
        if e.hardwareClock { sawHardwareClock = true }
        var target = e.whenNs
        // **`done` is when the commit returned, not when the frame lit up.**
        // `Flip.done` is "when the backend finished executing the frame", and the
        // metronome's commit term is `done` minus when the frame was started
        // (`target - margin`). This used to pass the present event's time, which
        // headless makes the commit time and a real display makes the *vblank*
        // — so on DRM every on-time frame reported a "commit latency" of the
        // whole margin, the margin grew to cover it, and the next sample grew
        // with it: a loop that ratchets to its ceiling and stays there. It is
        // what P4.5's first breakdown on metal reported as "margin dominated by
        // display commit (30 ms)" (PHASE4 §5.11). A present with no recorded
        // commit (none should happen) falls back to its own timestamp.
        var done = e.whenNs
        for t in targets where t.seq == e.commitSeq { target = t.target; done = t.committed }
        let vblank = snapToGrid(e)
        // **Late means a later vblank, not a later nanosecond** (PHASE4 §5.12).
        // `target` is the predictor's estimate of the vblank this frame aimed
        // at; a hardware clock's timestamp for that same vblank lands a few µs
        // either side of it. `vblank > target` called every frame that landed
        // 1 µs after its estimate "missed" — about half of them on metal, every
        // one of which reached the screen on time — and each false miss doubled
        // the margin's safety term until it sat at its ceiling. A frame is late
        // when it landed at least one whole period after the vblank it aimed at.
        // (Headless snaps to its own grid, where the two are exactly equal.)
        let late = periodHintNs > 0 ? vblank > target &+ periodHintNs / 2 : vblank > target
        return Flip(target: target, vblank: vblank, done: done,
                    missed: e.presented && late)
    }

    /// Which backend this output actually landed on.
    ///
    /// **Not the same question as `Backend.Kind`**, which is what we *asked*
    /// for: `--backend auto` resolves to DRM on metal, a nested Wayland window
    /// inside a session, or X11 under one. §2.48 is the reason this has to be
    /// reported rather than inferred — a nested output passes through real
    /// present timestamps taken from the **host's** vblank, so `sawHardwareClock`
    /// is true there and its numbers still mean nothing. Only the backend
    /// distinguishes "measured against our own clock" from "measured against
    /// somebody else's".
    public var backendName: String {
        guard let output else { return "gone" }
        if wlr_output_is_drm(output) { return "drm" }
        if wlr_output_is_wl(output) { return "nested-wayland" }
        if wlr_output_is_x11(output) { return "nested-x11" }
        if wlr_output_is_headless(output) { return "headless" }
        return "unknown"
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
        guard let output else {
            fail("the output is gone (VT away, or unplugged)")
            return false
        }
        var state = wlr_output_state()
        wlr_output_state_init(&state)
        defer { wlr_output_state_finish(&state) }

        guard let pass = wlr_output_begin_render_pass(output, &state, nil) else {
            fail("the output refused a render pass")
            return false
        }
        if let scene {
            // **Latch now, not the last frame's list.** Its textures belong to
            // buffers a client may have replaced since — with several outputs,
            // every other output's wait dispatches client commits in between —
            // and rendering a freed texture aborted undertow in pixman
            // ("wlr_texture_is_pixman"), on the second output's capture only.
            let now = Mono.now()
            _ = scene.latchAndComposite(now: now, target: now)
            scene.render(into: pass, background: background)
            seat?.renderCursor(into: pass, scene: scene)
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
            // Nothing pending: block for the remainder rather than spinning —
            // **and wake before the reserve, never after it** (PHASE4 §5.13).
            // The event loop's timeout is whole milliseconds and was rounded
            // *up* (+1), and FreeBSD may fire a timer up to
            // `kern.timecounter.alloweddeviation` (5%) late on top: together the
            // 1.4 ms of wake lateness that was the largest term left in the latch
            // margin on metal — which real-time priority could not touch, because
            // nothing was competing for the CPU. Round down, leave a sixteenth of
            // the wait for the slop, and when less than a millisecond would be
            // left, finish with the precise sleep instead.
            let slopNs = remainingNs / 16
            let ms = (remainingNs &- reserveNs &- min(slopNs, remainingNs &- reserveNs)) / 1_000_000
            if ms == 0 {
                Mono.sleep(untilNs: deadlineNs &- reserveNs)
                continue
            }
            session.dispatch(timeoutMs: Int32(min(ms, 1000)))
        }
    }
}
