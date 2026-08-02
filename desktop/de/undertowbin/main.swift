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
                                    [--assert-windows N] [--verbose]
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { usage() }
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
    case "-h", "--help": usage()
    default: die("unknown option '\(args[i])'")
    }
    i += 1
}
guard hz > 0, frames > 0, surfaces >= 0 else { die("--hz/--frames must be positive") }
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
    let warmup = min(max(frames / 8, 16), 240)
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
        session = try WlrootsSession(headlessOutputs: 1, width: width, height: height,
                                     refreshMilliHz: Int32(hz &* 1000), verbose: verbose)
        compositor = try Compositor(session: session, outputWidth: width,
                                    outputHeight: height)
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
    emit(2, "undertow: \(output.name) \(output.width)x\(output.height) @ \(hz)Hz"
         + " on \(compositor.socketName)")

    let recorder = FlightRecorder(capacity: max(frames, 1))
    var metronome = Metronome<WlrootsOutput, SurfaceScene>(periodHintNs: output.periodHintNs)
    var o = output
    var s = scene
    // The early capture fires a few frames after the FIRST window maps, not at
    // a wall-clock guess. That makes it a synchronisation point the harness can
    // wait on — "the client has drawn" — instead of a sleep long enough to
    // usually work (HANDOFF §2.31's lesson about racing startup, one level up).
    var settleFrames = -1
    var earlyCaptured = false
    for _ in 0..<frames {
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
    out("missed=\(recorder.missedCount) of \(recorder.retained)")
    if let want = assertWindows, windows != want {
        emit(2, "FAIL: expected \(want) mapped window(s), got \(windows)")
        exit(1)
    }
    out("verdict ok")

default:
    usage()
}
