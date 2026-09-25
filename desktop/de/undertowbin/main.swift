// undertow — the compositor (PHASE6.md). P6.1 is the metronome and its meter;
// there are no pixels yet, on purpose (DESKTOP.md §13: "the contract exists
// before the pixels do").
//
//   undertow bench-metronome [--hz N] [--frames N] [--surfaces N]
//                            [--assert-missed N] [--assert-cost-p99-us N]
//   undertow bench-alloc     [--frames N] [--surfaces N]
//
// The binary IS the bench, as `tide` is — flags in, a contract verdict out, a
// non-zero exit when an assertion fails. That keeps the gate in one place: the
// shell harness runs it and does not have to know what a percentile is.

import CAllocProbe
import Undertow
import AquaDraw

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func out(_ s: String) { emit(1, s) }
func die(_ s: String) -> Never { emit(2, "undertow: \(s)"); exit(1) }
func usage() -> Never {
    emit(2, """
    usage: undertow bench-metronome [--hz N] [--frames N] [--surfaces N]
                                    [--assert-missed N] [--assert-missed-permille N]
                                    [--assert-cost-p99-us N]
           undertow bench-alloc     [--frames N] [--surfaces N]
           undertow headless        [--hz N] [--frames N] [--surfaces N]
                                    [--width N] [--height N] [--verbose]
                                    [--assert-missed-permille N]
                                    [--assert-cost-p99-us N]
           undertow run             [--hz N] [--frames N] [--width N] [--height N]
                                    [--capture FILE.ppm] [--capture-early FILE.ppm]
                                    [--assert-windows N] [--assert-surfaces N]
                                    [--assert-layers N] [--assert-usable X,Y,WxH]
                                    [--assert-missed N] [--config-dir DIR] [--verbose]
                                    [--socket NAME] [--privileged-socket NAME]
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { usage() }
// The compositor paints server-side frames from the same theme the toolkit
// draws with (PHASE11 §6.7), so it loads it too — and says which.
ThemeLoader.announce(ThemeLoader.loadCurrent())
args.removeFirst()

var hz: UInt64 = 240
var frames = 1200
var surfaces = 512
var assertMissed: Int? = nil
var assertMissedPermille: Int? = nil
var assertCostP99Us: UInt64? = nil
var width: Int32 = 1920
var height: Int32 = 1080
var verbose = false
var capturePath: String? = nil
var captureEarlyPath: String? = nil
var assertWindows: Int? = nil
var assertSurfaces: Int? = nil
var assertLayers: Int? = nil
var assertUsable: String? = nil
var configDir: String? = nil
var socketName: String?
var privilegedSocket: String?
/// nil means headless (the default everywhere but metal).
var backendKind: WlrootsSession.Kind? = nil

var i = 0
while i < args.count {
    func value(_ name: String) -> String {
        i += 1
        guard i < args.count else { die("\(name) needs a value") }
        return args[i]
    }
    switch args[i] {
    case "--hz":
        guard let v = UInt64(value("--hz")) else { die("--hz wants a number") }
        hz = v
    case "--frames":
        guard let v = Int(value("--frames")) else { die("--frames wants a number") }
        frames = v
    case "--surfaces":
        guard let v = Int(value("--surfaces")) else { die("--surfaces wants a number") }
        surfaces = v
    case "--assert-missed": assertMissed = Int(value("--assert-missed"))
    case "--assert-missed-permille": assertMissedPermille = Int(value("--assert-missed-permille"))
    case "--assert-cost-p99-us": assertCostP99Us = UInt64(value("--assert-cost-p99-us"))
    case "--width":
        guard let v = Int32(value("--width")) else { die("--width wants a number") }
        width = v
    case "--height":
        guard let v = Int32(value("--height")) else { die("--height wants a number") }
        height = v
    case "--verbose": verbose = true
    case "--capture": capturePath = value("--capture")
    case "--capture-early": captureEarlyPath = value("--capture-early")
    case "--assert-windows": assertWindows = Int(value("--assert-windows"))
    case "--assert-surfaces": assertSurfaces = Int(value("--assert-surfaces"))
    case "--assert-layers": assertLayers = Int(value("--assert-layers"))
    case "--assert-usable": assertUsable = value("--assert-usable")
    case "--config-dir": configDir = value("--config-dir")
    case "--socket": socketName = value("--socket")
    case "--privileged-socket": privilegedSocket = value("--privileged-socket")
    case "--backend":
        let b = value("--backend")
        switch b {
        case "headless": backendKind = nil
        case "auto":     backendKind = .auto
        default: die("--backend is headless or auto, not '\(b)'")
        }
    case "-h", "--help": usage()
    default: die("unknown option '\(args[i])'")
    }
    i += 1
}
// **`--frames 0` means run until stopped, and until now there was no such
// thing.** Every use of this binary in the project's history has been a bench or
// a fixed-count test, so a frame limit was always right and the default of 1200
// was never questioned. On a real machine in front of a person it is wrong: the
// compositor ran, the installer appeared, and thirty seconds later the loop ran
// out and `anchor` dutifully restarted it (PHASE4 §5.6).
//
// A desktop is not a bench with a large number in it. Zero is the honest
// spelling of "no limit", and it stays opt-in so every harness invocation keeps
// the bounded behaviour its assertions depend on.
guard hz > 0, frames >= 0, surfaces >= 0 else { die("--hz must be positive, --frames must not be negative") }
let unbounded = runIsUnbounded(frames: frames)
// **An assertion that never runs is worse than no assertion**, and every
// `--assert-*` here is checked after the loop. Combined with an unbounded run
// they would sit in a command line looking like a gate and gating nothing —
// §2.37's shape, in the arguments rather than in the code.
if unbounded {
    let asserts = args.filter { $0.hasPrefix("--assert-") }
    if !asserts.isEmpty {
        die("\(asserts[0]) needs a frame count: an assertion after an unbounded run never runs")
    }
    if capturePath != nil || captureEarlyPath != nil {
        die("--capture needs a frame count: an unbounded run never reaches the end")
    }
}
let periodNs = 1_000_000_000 / hz

/// ns → "1234.56 us". No Foundation here, as everywhere else under de/.
func us(_ ns: UInt64) -> String {
    let hundredths = (ns &* 100) / 1000
    let frac = hundredths % 100
    return "\(hundredths / 100).\(frac < 10 ? "0" : "")\(frac) us"
}

switch mode {

// ---------------------------------------------------------------- C1 cadence
case "bench-metronome":
    var output = SyntheticOutput(periodNs: periodNs)
    var scene = SyntheticScene(surfaces: surfaces)
    defer { scene.release() }
    let recorder = FlightRecorder(capacity: max(frames, 1))
    var metronome = Metronome<SyntheticOutput, SyntheticScene>(periodHintNs: periodNs)

    // Warm up into a throwaway recorder. The margin control loop starts
    // deliberately optimistic and *discovers* the display's commit latency by
    // missing once or twice; measuring that convergence would be measuring the
    // first two frames of the process's life, not the cadence C1 is about.
    let warmupFrames = min(max(frames / 8, 16), 240)
    metronome.run(frames: warmupFrames, output: &output, sink: &scene,
                  recorder: FlightRecorder(capacity: warmupFrames))

    let began = Mono.now()
    metronome.run(frames: frames, output: &output, sink: &scene, recorder: recorder)
    let elapsed = Mono.since(began, Mono.now())

    let missed = recorder.missedCount
    let p50 = recorder.costPercentileNs(50)
    let p99 = recorder.costPercentileNs(99)
    let p999 = recorder.costPercentileNs(99.9)

    out("undertow bench-metronome — \(hz)Hz, \(frames) frames, \(surfaces) surfaces"
        + " (after \(warmupFrames) warmup)")
    out("  wall clock        \(elapsed / 1_000_000) ms"
        + "  (nominal \(UInt64(frames) &* periodNs / 1_000_000) ms)")
    out("  period estimate   \(us(metronome.predictor.periodNs))"
        + "  (nominal \(us(periodNs)), \(metronome.predictor.samples) samples)")
    out("  latch margin      \(us(metronome.margin.marginNs))")
    out("  composite cost    p50 \(us(p50))   p99 \(us(p99))   p99.9 \(us(p999))")
    let permille = recorder.retained > 0 ? missed * 1000 / recorder.retained : 0
    out("  missed flips      \(missed) of \(recorder.retained)  (\(permille) per mille)")
    out("  degraded frames   \(recorder.degradedCount)")

    var failed = false
    if let limit = assertMissed, missed > limit {
        emit(2, "FAIL C1: \(missed) missed flips, limit \(limit)")
        failed = true
    }
    if let limit = assertMissedPermille {
        let allowed = frames * limit / 1000
        if missed > allowed {
            emit(2, "FAIL C1: \(missed) missed flips of \(frames)"
                 + " (\(permille) per mille), limit \(limit) per mille = \(allowed)")
            failed = true
        }
    }
    if let limit = assertCostP99Us, p99 / 1000 > limit {
        emit(2, "FAIL C1: composite cost p99 \(us(p99)), limit \(limit).00 us")
        failed = true
    }
    if failed { exit(1) }
    out("  verdict           ok")

// ------------------------------------------------- C2's precondition: no alloc
case "bench-alloc":
    // The positive control comes FIRST and is fatal. A blind probe reports a
    // comfortable zero, which is indistinguishable from success and is exactly
    // how this measurement was wrong the first time (HANDOFF §2.37).
    guard ap_alloc_probe_works() == 1 else {
        die("""
            the allocation probe is BLIND — it did not see a deliberate allocation.
            Nothing measured here would mean anything. Check that this is an
            executable (interposition does not work inside a .xctest bundle) and
            that every allocator entry point Swift uses is wrapped.
            """)
    }
    out("undertow bench-alloc — \(frames) frames, \(surfaces) surfaces")
    out("  probe             live (positive control saw its own allocations)")

    var output = SyntheticOutput(periodNs: periodNs)
    var scene = SyntheticScene(surfaces: surfaces)
    defer { scene.release() }
    let recorder = FlightRecorder(capacity: 1024)
    var config = Metronome<SyntheticOutput, SyntheticScene>.Config()
    // Free-run: we are measuring allocations, not cadence. At 60Hz, 10⁴ frames
    // would be three minutes of sleeping to observe zero.
    config.freeRun = true
    var metronome = Metronome<SyntheticOutput, SyntheticScene>(periodHintNs: periodNs,
                                                              config: config)

    // Warm every path once — first-touch lazily initialises things (the ring's
    // pages, the predictor's first sample) that are legitimately one-off.
    metronome.run(frames: 64, output: &output, sink: &scene, recorder: recorder)

    ap_alloc_arm()
    metronome.run(frames: frames, output: &output, sink: &scene, recorder: recorder)
    let allocations = ap_alloc_count()
    ap_alloc_disarm()

    out("  frames measured   \(frames)")
    out("  allocations       \(allocations)")
    if allocations != 0 {
        emit(2, """
            FAIL C2: the present loop allocated \(allocations) times in \(frames) frames.
            An allocation on the present path is a lock a client can contend and a
            latency spike the contract does not permit (PLAN.md risk 4).
            """)
        exit(1)
    }
    out("  verdict           ok — the present loop is allocation-free")

// -------------------------------------------- the compositor, on real wlroots
case "headless":
    let session: WlrootsSession
    do {
        session = try WlrootsSession(headlessOutputs: 1, width: width, height: height,
                                     refreshMilliHz: Int32(hz &* 1000), verbose: verbose)
    } catch {
        die("\(error)")
    }
    guard let wlrOutput = session.outputs.first else { die("no output") }
    let output = WlrootsOutput(wlrOutput, session: session)
    var scene = SyntheticScene(surfaces: surfaces, viewport: (width, height))
    defer { scene.release() }
    let recorder = FlightRecorder(capacity: max(frames, 1))
    var metronome = Metronome<WlrootsOutput, SyntheticScene>(
        periodHintNs: output.periodHintNs)

    out("undertow headless — \(output.name) \(output.width)x\(output.height)"
        + " @ \(hz)Hz, \(frames) frames, \(surfaces) surfaces")

    // Same warmup argument as the synthetic bench: the margin control loop
    // discovers the backend's real commit latency by missing once or twice.
    let warmup = unbounded ? 240 : min(max(frames / 8, 16), 240)
    var o = output
    metronome.run(frames: warmup, output: &o, sink: &scene,
                  recorder: FlightRecorder(capacity: warmup))

    let began = Mono.now()
    metronome.run(frames: frames, output: &o, sink: &scene, recorder: recorder)
    let elapsed = Mono.since(began, Mono.now())

    let missed = recorder.missedCount
    let p99 = recorder.costPercentileNs(99)
    let permille = recorder.retained > 0 ? missed * 1000 / recorder.retained : 0
    let presented = recorder.percentile(50) { $0.actualVblank }

    out("  wall clock        \(elapsed / 1_000_000) ms"
        + "  (nominal \(UInt64(frames) &* periodNs / 1_000_000) ms)")
    out("  period estimate   \(us(metronome.predictor.periodNs))"
        + "  (nominal \(us(periodNs)), \(metronome.predictor.samples) samples)")
    out("  latch margin      \(us(metronome.margin.marginNs))")
    out("  composite cost    p50 \(us(recorder.costPercentileNs(50)))   p99 \(us(p99))")
    out("  missed flips      \(missed) of \(recorder.retained)  (\(permille) per mille)")
    // The proof that frames really reached the display: wlroots only reports a
    // present event for a commit it actually presented, so a non-zero vblank
    // timestamp means the backend turned our buffer into a "flip".
    out("  presented frames  \(presented > 0 ? "yes" : "NO — no present events arrived")")
    // Say which kind of clock the cadence above rests on. A headless output
    // presents on commit and reports no hardware timestamp, so we pace it
    // against its nominal grid (Backend.snapToGrid) — that is a real limitation
    // of the backend, not a result, and a bench that hid it would be claiming a
    // measured vblank it never had.
    out("  vblank source     "
        + (o.sawHardwareClock
           ? "hardware clock (driver-measured timestamps)"
           : "nominal grid — this backend reports no hardware clock"))

    var failed = false
    if presented == 0 {
        emit(2, "FAIL: no present events — the compositor committed frames that never landed")
        failed = true
    }
    if metronome.predictor.samples == 0 {
        emit(2, "FAIL: the predictor never received a sample — flip feedback is not reaching it")
        failed = true
    }
    if let limit = assertMissedPermille, permille > limit {
        emit(2, "FAIL C1: \(missed) missed of \(frames) (\(permille) per mille), limit \(limit)")
        failed = true
    }
    if let limit = assertCostP99Us, p99 / 1000 > limit {
        emit(2, "FAIL C1: composite cost p99 \(us(p99)), limit \(limit).00 us")
        failed = true
    }
    if failed { exit(1) }
    out("  verdict           ok")

// ----------------------------------------- the compositor, hosting real clients
case "run":
    let session: WlrootsSession
    let compositor: Compositor
    do {
        // `--backend auto` is Phase 4: DRM on metal, a nested window inside
        // another compositor, whatever this machine actually is. Headless stays
        // the default because it is the only thing the build VM can do and the
        // only thing that makes C1–C5 reproducible.
        session = try WlrootsSession(backendKind
                                     ?? .headless(count: 1, width: width, height: height,
                                                  refreshMilliHz: Int32(hz &* 1000)),
                                     verbose: verbose)
        // **On a real backend the display's size is the truth, not ours.**
        // Headless invents an output at whatever size it was asked for; a
        // monitor arrives with a mode already, and a compositor that keeps
        // using the numbers on its own command line lays the desktop out for a
        // screen that is not there. Found the first time undertow ran nested:
        // it was given 900x700, the output was 1280x720, and the menu bar's
        // exclusive zone was computed for the wrong width.
        if backendKind != nil, let first = session.outputs.first {
            width = first.pointee.width
            height = first.pointee.height
            // **And its refresh rate, which this took a phase to learn twice.**
            // Taking the size and leaving `--hz` meant every line we printed on
            // metal was labelled with the rate we asked for rather than the one
            // the panel has: the first run on a 60 Hz monitor announced 240 Hz,
            // which is simply this binary's default read back. The metronome was
            // already seeded from `output.periodHintNs` and so was right; the
            // *report* was wrong, which in a project whose deliverable is
            // measurement is the worse of the two.
            hz = displayHz(refreshMilliHz: first.pointee.refresh, fallback: hz)
        }
        compositor = try Compositor(session: session, outputWidth: width,
                                    outputHeight: height, configDir: configDir,
                                    socketName: socketName,
                                    privilegedSocket: privilegedSocket)
    } catch {
        die("\(error)")
    }
    guard let wlrOutput = session.outputs.first else { die("no output") }
    let output = WlrootsOutput(wlrOutput, session: session)
    let scene = SurfaceScene(compositor: compositor, outputWidth: width,
                             outputHeight: height)
    defer { scene.release() }
    output.scene = scene
    let seat: Seat
    do {
        seat = try Seat(compositor: compositor, outputWidth: width, outputHeight: height)
    } catch {
        die("\(error)")
    }
    output.seat = seat

    // Announce the socket on stdout BEFORE the loop starts, so a harness can
    // read one line and know where to point a client. Anything else means
    // racing a sleep against a compositor's startup.
    out("WAYLAND_DISPLAY=\(compositor.socketName)")
    // The menu bar's door (PHASE10 P10.3): same announcement, same reason.
    if let p = compositor.privilegedSocketName { out("WAYLAND_PRIVILEGED=\(p)") }
    // The rate comes from the output, not from the flag — see above. Said in the
    // one line a person reads off a screen they cannot copy and paste from.
    emit(2, "undertow: \(output.name) \(output.width)x\(output.height) @ \(hz)Hz"
         + " (period \(us(output.periodHintNs)))"
         + " on \(compositor.socketName)")

    // An unbounded session cannot size its recorder from a frame count, and must
    // not grow one without bound either — so it keeps a rolling window. Ten
    // seconds at 240Hz is enough to answer "what just happened" and small enough
    // to forget.
    let recorder = FlightRecorder(capacity: recorderCapacity(frames: frames))
    var metronome = Metronome<WlrootsOutput, SurfaceScene>(periodHintNs: output.periodHintNs)
    var o = output
    var s = scene

    // Warm up into a throwaway recorder, as bench-metronome does: the margin
    // control loop discovers the backend's commit latency by missing once or
    // twice, and counting that convergence as a C2 failure would be measuring
    // the first frames of the process's life rather than its behaviour under
    // load. With this, a healthy baseline is exactly zero missed frames, which
    // is what lets the C2 gate be a flat zero rather than a tolerance.
    let warmup = unbounded ? 240 : min(max(frames / 8, 16), 240)
    let warmupRecorder = FlightRecorder(capacity: warmup)
    for _ in 0..<warmup {
        metronome.step(output: &o, sink: &s, recorder: warmupRecorder)
        compositor.endFrame()
    }
    // The early capture fires a few frames after the FIRST window maps, not at
    // a wall-clock guess. That makes it a synchronisation point the harness can
    // wait on — "the client has drawn" — instead of a sleep long enough to
    // usually work (HANDOFF §2.31's lesson about racing startup, one level up).
    var settleFrames = -1
    var earlyCaptured = false
    var drawn = 0
    // **Report the clipboard as it happens, not only in the summary.** An
    // unbounded run never reaches the summary — which is the whole point of it —
    // so a counter that only appears at the end is invisible to exactly the
    // sessions a person is using. Comparing one Int per frame costs nothing.
    var reportedSelections = 0
    var reportedDrags = 0
    var reportedKeybinds = 0
    var reportedFrameClicks = 0
    var reportedRasterisations = 0
    // **Where the windows are, as it changes.** A Wayland client is never told
    // its own position and only learns its size a frame later, so the compositor
    // is the only witness to a move, a snap or a maximize — and without one, a
    // test for P9.4 can assert that a request was *made* but never that anything
    // happened. One line per change, which on an idle desktop is none.
    var reportedGeometry: [String: String] = [:]
    // The same argument for the window-request counters (P9.4): an unbounded run
    // is stopped with a signal and never reaches the summary below, so a counter
    // printed only there cannot be asserted on by the tests that need it most.
    var reportedWindowOps = ""
    // **The stacking order, as it changes** (P11.6): the depth gadget's only
    // effect is where a window sits in it, and nothing else says.
    var reportedStack = ""
    while unbounded || drawn < frames {
        let ops = "resizes-started=\(compositor.resizesStarted) " +
                  "maximizes=\(compositor.maximizeCount) " +
                  "minimizes=\(compositor.minimizeCount) " +
                  "snaps=\(compositor.snapCount) " +
                  "lowers=\(compositor.lowerCount)"
        if ops != reportedWindowOps {
            reportedWindowOps = ops
            out(ops)
        }
        for t in compositor.toplevels where t.mapped {
            let key = t.placeKey ?? "?"
            var flags = ""
            if t.minimized { flags = " min" } else if t.maximized { flags = " max" }
            let line = "\(t.x),\(t.y) \(t.width)x\(t.height)\(flags)"
            if reportedGeometry[key] != line {
                reportedGeometry[key] = line
                out("window \(key) \(line)")
            }
        }
        let stack = compositor.toplevels.filter { $0.mapped }.map { $0.placeKey ?? "?" }
            .joined(separator: " ")
        if stack != reportedStack {
            reportedStack = stack
            out("stack=\(stack)")        // bottom to top
        }
        if seat.selectionsAccepted != reportedSelections {
            reportedSelections = seat.selectionsAccepted
            out("selections-accepted=\(reportedSelections)")
        }
        // §6.1 asked for the frame cache to be *measured*, and a number that
        // only appears in the summary is invisible to exactly the runs that
        // need it — an unbounded one never reaches the summary at all.
        if compositor.decorations?.rasterisations ?? 0 != reportedRasterisations {
            reportedRasterisations = compositor.decorations?.rasterisations ?? 0
            out("frame-rasterisations=\(reportedRasterisations)")
        }
        if seat.frameClicks != reportedFrameClicks {
            reportedFrameClicks = seat.frameClicks
            out("frame-clicks=\(reportedFrameClicks)")
        }
        if seat.keybindsFired != reportedKeybinds {
            reportedKeybinds = seat.keybindsFired
            out("keybinds-fired=\(reportedKeybinds)")
        }
        if seat.dragsStarted != reportedDrags {
            reportedDrags = seat.dragsStarted
            out("drags-started=\(reportedDrags)")
        }
        drawn += 1
        metronome.step(output: &o, sink: &s, recorder: recorder)
        // Release clients to draw the next frame, and push the events out.
        // Without this a client renders once and waits for ever.
        compositor.endFrame()

        // A separate `earlyCaptured` flag, not a sentinel in `settleFrames`.
        // The first version used `settleFrames < 0` to mean "not started" and
        // set it to -2 for "done" — which also satisfies `< 0`, so it re-armed
        // itself and captured on every subsequent frame. The "before" file then
        // held the LAST write, taken after the click, so it was identical to
        // the "after" one and the input test failed for a reason that had
        // nothing to do with input.
        if let early = captureEarlyPath, !earlyCaptured {
            if settleFrames < 0 {
                if !compositor.mappedToplevels.isEmpty { settleFrames = 20 }
            } else if settleFrames > 0 {
                settleFrames -= 1
            } else {
                earlyCaptured = true
                guard output.capturePPM(path: early) else { die("could not write \(early)") }
                emit(2, "undertow: wrote \(early) (first window has drawn)")
            }
        }
    }

    if let path = capturePath {
        guard output.capturePPM(path: path) else { die("could not write \(path)") }
        emit(2, "undertow: wrote \(path)")
    }

    let windows = compositor.mappedToplevels.count
    out("windows=\(windows)")
    out("surfaces-composited=\(scene.count)")
    out("cursor=\(Int(seat.cursorX)),\(Int(seat.cursorY))")
    out("focused=\(seat.focused != nil ? "yes" : "no")")
    out("restored=\(compositor.restoredCount)")
    for t in compositor.mappedToplevels {
        out("window \(t.placeKey ?? "?") at \(t.x),\(t.y)")
    }
    // ... and everyone who was ever here, including the clients that have since
    // quit. `window` is the survivors; `mapped` is the guest list.
    for key in compositor.everMapped {
        out("mapped \(key)")
    }
    // The positive control for adversarial load: every surface any client ever
    // created. `missed=0` with `surfaces-created=0` means the adversaries never
    // arrived, which is a passing bench that proves nothing (PHASE6.md P6.5).
    out("surfaces-created=\(compositor.surfacesCreated)")
    // The positive control for a clipboard test: a paste that matched a stale
    // selection looks identical to one that worked, unless the compositor says
    // how many offers it accepted (P9.1).
    out("selections-accepted=\(seat.selectionsAccepted)")
    // The same positive control for a drag: a drop that did nothing and a drag
    // the compositor refused to start look identical from the outside (P9.3).
    out("drags-started=\(seat.dragsStarted)")
    out("keybinds-fired=\(seat.keybindsFired)")
    out("frame-clicks=\(seat.frameClicks)")
    // §6.1 asked for the frame cache to be *measured*: one rasterisation per
    // decorated window on a desktop nobody is resizing, and this is the number
    // that says so.
    out("frame-rasterisations=\(compositor.decorations?.rasterisations ?? 0)")
    // The window requests P9.4 answered. Counters rather than a log, for the
    // same reason as the two above: "nothing happened" and "it happened and did
    // nothing" are indistinguishable without one.
    out("resizes-started=\(compositor.resizesStarted)")
    out("maximizes=\(compositor.maximizeCount)")
    out("minimizes=\(compositor.minimizeCount)")
    out("snaps=\(compositor.snapCount)")
    out("layers=\(compositor.mappedLayers.count) of \(compositor.layers.count)")
    // The usable area is the ONLY observable proof that an exclusive zone was
    // honoured — a layer surface never appears in a window tree, so §2.26's
    // workspace-rect check is the assertion that the shell composed.
    let u = compositor.usableArea
    out("usable=\(u.x),\(u.y),\(u.width)x\(u.height)")
    out("wake-late-p99-us=\(recorder.percentile(99) { $0.wakeLateNs } / 1000)")
    out("composite-p99-us=\(recorder.costPercentileNs(99) / 1000)")
    out("margin-us=\(metronome.margin.marginNs / 1000)")
    out("missed=\(recorder.missedCount) of \(recorder.retained)")
    // **Say what the numbers were measured against, in the output that gets
    // read.** `bench-metronome` has printed the vblank source since P6.1; `run`
    // never did — and `run` is the mode a person invokes on a strange machine
    // and photographs off a screen. Every line above is a duration, and a
    // duration measured against a synthetic grid is not the same quantity as one
    // measured against a real vblank (§2.48). Unlabelled they are
    // indistinguishable, which is how a nominal-clock miss count gets quoted as
    // a hardware result.
    // **The margin's parts, not just its total.** `margin = wakeHigh + costHigh +
    // commitHigh + safety`, and P6.1 measured them separately precisely so a
    // miss could be attributed. Run mode then reported only the sum — which on
    // the first hardware measurement left "58 of 300 missed while compositing in
    // 12us" with no way to say which term ate the frame (PHASE4 §5.7).
    //
    // `margin-pinned` is the one that matters most: the margin is clamped to
    // three quarters of a period, so a loop that wants more than that is a loop
    // that has given up and will miss for ever. A number at its ceiling and a
    // number that happens to be large look identical without this.
    out("margin-wake-us=\(metronome.margin.wakeHighNs / 1000)")
    out("margin-cost-us=\(metronome.margin.costHighNs / 1000)")
    out("margin-commit-us=\(metronome.margin.commitHighNs / 1000)")
    out("margin-safety-us=\(metronome.margin.safetyNs / 1000)")
    out("margin-pinned=\(metronome.margin.marginNs >= metronome.margin.ceilNs ? "yes" : "no")")
    out("period-us=\(output.periodHintNs / 1000)")
    out("vblank-source=\(output.sawHardwareClock ? "hardware" : "nominal")")
    // And **whose** clock, which `vblank-source` alone cannot say: a nested
    // backend reports real timestamps from the host's vblank (§2.48).
    out("backend=\(output.backendName)")
    var runFailed = false
    if let want = assertLayers, compositor.mappedLayers.count != want {
        emit(2, "FAIL: expected \(want) mapped layer surface(s),"
             + " got \(compositor.mappedLayers.count)")
        runFailed = true
    }
    if let want = assertUsable, "\(u.x),\(u.y),\(u.width)x\(u.height)" != want {
        emit(2, "FAIL: usable area is \(u.x),\(u.y),\(u.width)x\(u.height), expected \(want)"
             + " — an exclusive zone was not honoured")
        runFailed = true
    }
    if let want = assertWindows, windows != want {
        emit(2, "FAIL: expected \(want) mapped window(s), got \(windows)")
        runFailed = true
    }
    if let want = assertSurfaces, compositor.surfacesCreated < want {
        emit(2, "FAIL: only \(compositor.surfacesCreated) client surfaces were created,"
             + " expected at least \(want) — the load never arrived, so a passing"
             + " frame count would prove nothing")
        runFailed = true
    }
    if let limit = assertMissed, recorder.missedCount > limit {
        emit(2, "FAIL C2: \(recorder.missedCount) missed flips of \(recorder.retained),"
             + " limit \(limit) — a client made the compositor drop a frame")
        runFailed = true
    }
    if runFailed { exit(1) }
    out("verdict ok")

default:
    usage()
}
