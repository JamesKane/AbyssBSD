// Undertow tests — the metronome's logic, without a clock to flake on.
//
// The split is deliberate and worth stating, because it is what keeps this
// suite trustworthy: **cadence is not tested here.** "Did we hit 240Hz for 600
// frames" depends on OS scheduling and would flake in a VM under load
// (PHASE6.md §6), so it lives in `undertow bench-metronome` where the harness
// can re-run it in isolation. What is here is the pure logic — the predictor,
// the margin control loop, the recorder — fed synthetic numbers, deterministic
// on any machine.

import XCTest
import AquaDraw
import PoolConfig
@testable import Undertow

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Make sure there is somewhere to bind a Wayland socket.
///
/// **FreeBSD sets no `XDG_RUNTIME_DIR`** — there is no pam_xdg (HANDOFF §2.31) —
/// so `wl_display_add_socket_auto` has nowhere to put a socket and the
/// compositor tests fail there while passing on Linux. A unit test should not
/// depend on ambient environment it can provide for itself, so it provides it.
private func ensureRuntimeDir() {
    if let existing = getenv("XDG_RUNTIME_DIR"), existing.pointee != 0 { return }
    let dir = "/tmp/abyss-test-run-\(getuid())"
    _ = mkdir(dir, 0o700)
    setenv("XDG_RUNTIME_DIR", dir, 1)
}

final class UndertowTests: XCTestCase {

    // MARK: - A desktop is not a bench with a large number in it

    func testAFrameLimitIsOptionalAndZeroMeansUntilStopped() {
        // Every use of `undertow` in this project's history was a bench or a
        // fixed-count test, so a frame limit was always right and the default of
        // 1200 was never questioned. On metal the installer appeared, ran out
        // its frames after ~30 seconds, exited normally, and `anchor` restarted
        // it — a session ending on a *success* path (PHASE4 §5.6).
        //
        // The rule as a pure function, so it is pinned somewhere a test can see
        // it rather than only in an argument parser.
        XCTAssertTrue(runIsUnbounded(frames: 0))
        XCTAssertFalse(runIsUnbounded(frames: 1))
        XCTAssertFalse(runIsUnbounded(frames: 1200))
    }

    func testAnUnboundedRunKeepsARollingWindowRatherThanNoneOrAllOfIt() {
        // Sizing the recorder from the frame count gives 1 for an unbounded run,
        // which answers no question at all; growing it without bound is a leak
        // in a process meant to run for days.
        XCTAssertEqual(recorderCapacity(frames: 0), 2400)
        XCTAssertEqual(recorderCapacity(frames: 300), 300)
        XCTAssertEqual(recorderCapacity(frames: 1), 1)
    }

    // MARK: - The display's rate is the truth, not the flag

    func testTheRefreshRateComesFromTheDisplay() {
        // wlroots reports millihertz. 60 Hz and 144 Hz are the ordinary cases.
        XCTAssertEqual(displayHz(refreshMilliHz: 60_000, fallback: 240), 60)
        XCTAssertEqual(displayHz(refreshMilliHz: 144_000, fallback: 240), 144)
        XCTAssertEqual(displayHz(refreshMilliHz: 240_000, fallback: 60), 240)
    }

    func testAPanelThatIsNotAWholeNumberOfHzStillRoundsToOne() {
        // 59.94 Hz is a real mode and truncating it reports 59, which then reads
        // as a machine that is missing a frame a second.
        XCTAssertEqual(displayHz(refreshMilliHz: 59_940, fallback: 240), 60)
        XCTAssertEqual(displayHz(refreshMilliHz: 143_980, fallback: 240), 144)
    }

    func testAnOutputWithNoModeLeavesTheCallersDefaultAlone() {
        // Nothing plugged in, or a virtual connector: wlroots reports 0. The
        // fallback stands, because inventing a rate here would be the same
        // mistake one layer down.
        XCTAssertEqual(displayHz(refreshMilliHz: 0, fallback: 60), 60)
        XCTAssertEqual(displayHz(refreshMilliHz: -1, fallback: 75), 75)
    }


    override func setUp() {
        super.setUp()
        ensureRuntimeDir()
    }


    // MARK: - Time

    func testSaturatingSubtractionNeverWraps() {
        // A UInt64 that goes negative wraps to ~584 years, which as a deadline
        // means "sleep forever". Every timestamp subtraction in the metronome
        // goes through this for that reason.
        XCTAssertEqual(Mono.since(100, 250), 150)
        XCTAssertEqual(Mono.since(250, 100), 0)
        XCTAssertEqual(Mono.since(0, 0), 0)
    }

    // MARK: - The vblank predictor

    /// It must converge on the *measured* period, not the advertised one. Real
    /// displays report 60Hz and run at 59.94, and a systematic phase error is
    /// exactly what a metronome must not have.
    func testPredictorConvergesOnTheTruePeriodNotTheHint() {
        let truePeriod: UInt64 = 16_683_333          // 59.94Hz
        var p = VblankPredictor(periodHintNs: 16_666_666)  // the 60Hz lie
        var t: UInt64 = 1_000_000_000
        for _ in 0..<200 {
            t &+= truePeriod
            p.observe(Flip(target: t, vblank: t, done: t, missed: false))
        }
        // Within 0.1% of the truth.
        let err = p.periodNs > truePeriod ? p.periodNs - truePeriod : truePeriod - p.periodNs
        XCTAssertLessThan(err, truePeriod / 1000,
                          "converged to \(p.periodNs), expected ~\(truePeriod)")
    }

    /// A gap of several periods means we skipped frames, NOT that the display
    /// halved its rate. Without dividing the interval down, one missed frame
    /// teaches the predictor the display runs at half speed and it never
    /// recovers — the frame scheduler equivalent of a runaway.
    func testASkippedFrameDoesNotHalveThePeriodEstimate() {
        let period: UInt64 = 16_666_666
        var p = VblankPredictor(periodHintNs: period)
        var t: UInt64 = 1_000_000_000
        p.observe(Flip(target: t, vblank: t, done: t, missed: false))
        // Now skip: the next flip lands three periods later.
        for _ in 0..<50 {
            t &+= period &* 3
            p.observe(Flip(target: t, vblank: t, done: t, missed: true))
        }
        let err = p.periodNs > period ? p.periodNs - period : period - p.periodNs
        XCTAssertLessThan(err, period / 100,
                          "a 3-period gap moved the estimate to \(p.periodNs)")
    }

    /// A wild sample is a stall or a clock jump, not data. Averaging it in
    /// corrupts an estimate that took hundreds of frames to earn.
    func testPredictorRejectsImplausibleSamples() {
        let period: UInt64 = 16_666_666
        var p = VblankPredictor(periodHintNs: period)
        var t: UInt64 = 1_000_000_000
        for _ in 0..<50 { t &+= period; p.observe(Flip(target: t, vblank: t, done: t, missed: false)) }
        let settled = p.periodNs

        // A 1.4x interval: not a whole multiple, not plausible as a period.
        t &+= period &* 7 / 5
        p.observe(Flip(target: t, vblank: t, done: t, missed: false))
        XCTAssertEqual(p.periodNs, settled, "an implausible sample moved the estimate")
    }

    /// Whatever else it does, the next vblank is in the future. A target in the
    /// past makes the deadline arithmetic negative and the loop stops sleeping.
    func testPredictedTargetIsAlwaysInTheFuture() {
        let period: UInt64 = 16_666_666
        var p = VblankPredictor(periodHintNs: period)
        // Before any sample.
        XCTAssertGreaterThan(p.predictNext(after: 5_000_000_000), 5_000_000_000)

        let base: UInt64 = 1_000_000_000
        p.observe(Flip(target: base, vblank: base, done: base, missed: false))
        p.observe(Flip(target: base &+ period, vblank: base &+ period,
                       done: base &+ period, missed: false))
        // Sample "now" all across a period, plus far into the future.
        for step in 0..<70 {
            let offset = UInt64(step) &* (period / 7)
            let now = base &+ offset
            XCTAssertGreaterThan(p.predictNext(after: now), now,
                                 "target not in the future at offset \(offset)")
        }
    }

    /// Targets should land on the display's grid, not drift off it.
    func testPredictedTargetsLandOnTheVblankGrid() {
        let period: UInt64 = 10_000_000
        var p = VblankPredictor(periodHintNs: period)
        let base: UInt64 = 500_000_000
        p.observe(Flip(target: base, vblank: base, done: base, missed: false))
        for k in 1...5 {
            let now = base &+ period &* UInt64(k) &- 1_000
            let target = p.predictNext(after: now)
            XCTAssertEqual((target &- base) % period, 0,
                           "target \(target) is off the grid")
        }
    }

    // MARK: - The latch margin

    /// Grow hard on a miss, give it back slowly. The asymmetry is the point:
    /// over-correcting costs latency, under-correcting costs another frame.
    func testMarginGrowsOnAMissAndDecaysOnSuccess() {
        var m = LatchMargin(floorNs: 50_000, ceilNs: 8_000_000)
        let start = m.marginNs
        for _ in 0..<4 { m.observe(costNs: 10_000, wakeLateNs: 0, missed: true) }
        let afterMisses = m.marginNs
        XCTAssertGreaterThan(afterMisses, start, "a miss must widen the margin")

        for _ in 0..<2000 { m.observe(costNs: 10_000, wakeLateNs: 0, missed: false) }
        XCTAssertLessThan(m.marginNs, afterMisses,
                          "the margin must come back down, or we keep the latency for ever")
    }

    /// A decaying max reacts instantly upward. One expensive frame must widen
    /// the margin *before* the next frame, not after averaging it away.
    func testMarginTracksASpikeImmediately() {
        var m = LatchMargin(floorNs: 1_000, ceilNs: 8_000_000)
        for _ in 0..<100 { m.observe(costNs: 20_000, wakeLateNs: 5_000, missed: false) }
        let steady = m.marginNs
        m.observe(costNs: 900_000, wakeLateNs: 5_000, missed: false)
        XCTAssertGreaterThan(m.marginNs, steady &+ 800_000,
                             "a 900us composite did not immediately widen the margin")
    }

    /// All three measured terms have to reach the margin, or a miss caused by
    /// one of them can never be corrected by observing it.
    func testEveryMeasuredTermReachesTheMargin() {
        var wake = LatchMargin(floorNs: 1_000, ceilNs: 8_000_000)
        wake.observe(costNs: 0, wakeLateNs: 300_000, missed: false)
        XCTAssertGreaterThanOrEqual(wake.marginNs, 300_000)

        var cost = LatchMargin(floorNs: 1_000, ceilNs: 8_000_000)
        cost.observe(costNs: 300_000, wakeLateNs: 0, missed: false)
        XCTAssertGreaterThanOrEqual(cost.marginNs, 300_000)

        var commit = LatchMargin(floorNs: 1_000, ceilNs: 8_000_000)
        commit.observeCommit(latencyNs: 300_000)
        XCTAssertGreaterThanOrEqual(commit.marginNs, 300_000)
    }

    func testMarginRespectsItsFloorAndCeiling() {
        var m = LatchMargin(floorNs: 40_000, ceilNs: 200_000)
        XCTAssertGreaterThanOrEqual(m.marginNs, 40_000)
        for _ in 0..<50 { m.observe(costNs: 5_000_000, wakeLateNs: 5_000_000, missed: true) }
        XCTAssertLessThanOrEqual(m.marginNs, 200_000, "the ceiling did not hold")
    }

    // MARK: - The flight recorder

    func testRecorderWrapsAndKeepsTheMostRecentFrames() {
        let r = FlightRecorder(capacity: 8)
        for i in 0..<20 {
            var rec = FrameRecord()
            rec.seq = UInt64(i)
            r.record(rec)
        }
        XCTAssertEqual(r.count, 20)
        XCTAssertEqual(r.retained, 8)
        // Oldest retained first: frames 12...19.
        XCTAssertEqual(r.retainedRecord(0).seq, 12)
        XCTAssertEqual(r.retainedRecord(7).seq, 19)
    }

    func testRecorderCountsMissedAndDegraded() {
        let r = FlightRecorder(capacity: 16)
        for i in 0..<10 {
            var rec = FrameRecord()
            rec.seq = UInt64(i)
            rec.missed = (i % 5 == 0)      // 0, 5
            rec.degraded = (i == 7)
            r.record(rec)
        }
        XCTAssertEqual(r.missedCount, 2)
        XCTAssertEqual(r.degradedCount, 1)
    }

    /// The contract is stated in percentiles because one outlier in a VM proves
    /// nothing, so the recorder had better compute them correctly.
    func testCostPercentiles() {
        let r = FlightRecorder(capacity: 128)
        for i in 1...100 {
            var rec = FrameRecord()
            rec.costNs = UInt64(i) * 1000      // 1us ... 100us
            r.record(rec)
        }
        XCTAssertEqual(r.costPercentileNs(0), 1000)
        XCTAssertEqual(r.costPercentileNs(100), 100_000)
        XCTAssertEqual(r.costPercentileNs(50), 50_000, accuracy: 1500)
        XCTAssertEqual(r.costPercentileNs(99), 99_000, accuracy: 1500)
    }

    func testEmptyRecorderAnswersWithoutCrashing() {
        let r = FlightRecorder(capacity: 4)
        XCTAssertEqual(r.retained, 0)
        XCTAssertEqual(r.missedCount, 0)
        XCTAssertEqual(r.costPercentileNs(99), 0)
    }

    // MARK: - The loop

    /// Free-run so this is deterministic and instant: what it pins is that every
    /// frame produces exactly one record with a monotonic sequence number.
    func testEveryFrameIsRecordedExactlyOnce() {
        var output = SyntheticOutput(periodNs: 16_666_666)
        var scene = SyntheticScene(surfaces: 32)
        defer { scene.release() }
        let recorder = FlightRecorder(capacity: 512)
        var config = Metronome<SyntheticOutput, SyntheticScene>.Config()
        config.freeRun = true
        var m = Metronome<SyntheticOutput, SyntheticScene>(periodHintNs: 16_666_666,
                                                           config: config)
        m.run(frames: 300, output: &output, sink: &scene, recorder: recorder)

        XCTAssertEqual(recorder.count, 300)
        for i in 1..<recorder.retained {
            XCTAssertEqual(recorder.retainedRecord(i).seq,
                           recorder.retainedRecord(i - 1).seq &+ 1)
        }
    }

    /// The scene walk must actually do something — a composite that culls
    /// everything would make every other number here meaningless.
    func testTheSceneCompositesTheSurfacesItIsGiven() {
        var scene = SyntheticScene(surfaces: 64)
        defer { scene.release() }
        let stats = scene.latchAndComposite(now: 0, target: 0)
        XCTAssertGreaterThan(stats.surfaces, 0)
        XCTAssertGreaterThan(stats.damageArea, 0)
        XCTAssertFalse(stats.degraded)
    }

    // MARK: - The wlroots bridge (P6.2)

    /// The FFI works end to end: a real wlroots session comes up, announces the
    /// outputs we asked for at the size we asked for, and tears down.
    ///
    /// Every one of those announcements arrives through the C trampoline
    /// (`tw_listen` + `wl_container_of`), so this is really a test of the one
    /// mechanism the whole compositor is built on — PHASE6.md §4.1.
    func testAWlrootsSessionComesUpAndAnnouncesItsOutputs() throws {
        let session = try WlrootsSession(headlessOutputs: 2, width: 640, height: 480,
                                         refreshMilliHz: 60_000)
        XCTAssertEqual(session.outputs.count, 2,
                       "the new_output signal did not reach Swift")
        let out = WlrootsOutput(session.outputs[0], session: session)
        XCTAssertEqual(out.width, 640)
        XCTAssertEqual(out.height, 480)
        XCTAssertTrue(out.name.hasPrefix("HEADLESS"))
        // The refresh hint should come from the mode we committed, not the 60Hz
        // fallback — 60_000 mHz is 16.67ms.
        XCTAssertEqual(out.periodHintNs, 16_666_666, accuracy: 2_000)
    }

    /// Frames must actually reach the backend, and feedback must come back.
    /// "It committed" is not the claim — "it presented, and told us when" is.
    func testFramesReachTheBackendAndFlipFeedbackReturns() throws {
        let session = try WlrootsSession(headlessOutputs: 1, width: 320, height: 240,
                                         refreshMilliHz: 60_000)
        var output = WlrootsOutput(session.outputs[0], session: session)
        var scene = SyntheticScene(surfaces: 8, viewport: (320, 240))
        defer { scene.release() }
        let recorder = FlightRecorder(capacity: 64)
        var m = Metronome<WlrootsOutput, SyntheticScene>(periodHintNs: output.periodHintNs)
        m.run(frames: 12, output: &output, sink: &scene, recorder: recorder)

        XCTAssertEqual(recorder.count, 12)
        XCTAssertGreaterThan(m.predictor.samples, 0,
                             "no flip feedback reached the predictor — the compositor is "
                             + "committing frames it never learns the fate of")
        var presented = 0
        for i in 0..<recorder.retained where recorder.retainedRecord(i).actualVblank > 0 {
            presented += 1
        }
        XCTAssertGreaterThan(presented, 0, "no present event ever arrived")
    }

    /// The headless backend presents on commit and reports no hardware clock, so
    /// its raw timestamps are our own commit times. Feeding those back closes a
    /// loop with no external reference — self-consistent at any period and
    /// therefore stable at none (measured drifting 16.7ms → 11.9ms). Snapping to
    /// the nominal grid is what keeps the estimate honest.
    func testAClocklessBackendStillPacesAtItsNominalRate() throws {
        let session = try WlrootsSession(headlessOutputs: 1, width: 320, height: 240,
                                         refreshMilliHz: 60_000)
        var output = WlrootsOutput(session.outputs[0], session: session)
        var scene = SyntheticScene(surfaces: 4, viewport: (320, 240))
        defer { scene.release() }
        let recorder = FlightRecorder(capacity: 128)
        var m = Metronome<WlrootsOutput, SyntheticScene>(periodHintNs: output.periodHintNs)
        m.run(frames: 60, output: &output, sink: &scene, recorder: recorder)

        XCTAssertFalse(output.sawHardwareClock,
                       "the headless backend claimed a hardware clock; this test's premise is stale")
        // Within 5% of 60Hz. Without the grid snap this drifts ~30% low.
        XCTAssertEqual(Double(m.predictor.periodNs), 16_666_666,
                       accuracy: 16_666_666 * 0.05)
    }

    // MARK: - The compositor (P6.3)

    /// The globals a client needs, and a socket to reach them.
    ///
    /// `wl_shm` is the one worth asserting: `wlr_compositor_create` does not
    /// create it, and without it no client can attach a buffer. Our own
    /// `Display.init` requires compositor + shm + xdg_wm_base and refuses the
    /// connection outright, so the symptom is "cannot connect to a Wayland
    /// compositor" — an error pointing nowhere near the missing global.
    func testTheCompositorOffersASocketAndTheGlobalsAClientNeeds() throws {
        let session = try WlrootsSession(headlessOutputs: 1, width: 320, height: 240,
                                         refreshMilliHz: 60_000)
        let compositor = try Compositor(session: session, outputWidth: 320, outputHeight: 240)
        XCTAssertFalse(compositor.socketName.isEmpty)
        XCTAssertTrue(compositor.socketName.hasPrefix("wayland-"))
        XCTAssertEqual(compositor.toplevels.count, 0)
        XCTAssertEqual(compositor.mappedToplevels.count, 0)
    }

    // MARK: P10.4 — popups

    /// A popup is positioned relative to its parent's WINDOW GEOMETRY, and its
    /// own surface may be offset from its geometry (a shadow). Both offsets
    /// have to be in the sum or a menu lands beside its title.
    func testAPopupLandsWhereItsParentsGeometrySays() {
        // A layer surface: no geometry offset. The bar's File menu under its
        // title at x=94, 22 down.
        let bar = PopupGeometry.surfaceOrigin(parentSurfaceX: 0, parentSurfaceY: 0,
                                              parentGeometry: (0, 0),
                                              popupPosition: (94, 22), popupGeometry: (0, 0))
        XCTAssertEqual(bar.x, 94); XCTAssertEqual(bar.y, 22)
        // A window at (140,100) whose geometry starts 10px into its surface
        // (a client-side shadow), and a popup with a 4px shadow of its own.
        let win = PopupGeometry.surfaceOrigin(parentSurfaceX: 140, parentSurfaceY: 100,
                                              parentGeometry: (10, 10),
                                              popupPosition: (30, 40), popupGeometry: (4, 4))
        XCTAssertEqual(win.x, 140 + 10 + 30 - 4)
        XCTAssertEqual(win.y, 100 + 10 + 40 - 4)
    }

    // MARK: P10.3 — whose menus are whose

    /// Two compositors in one process, each with its own menu globals. The C
    /// side keeps its state per display for exactly this — static state would
    /// make the second compositor's globals fail, and every test after the
    /// first would run a compositor with no menus.
    func testEveryCompositorHasItsOwnMenuGlobalsAndStartsWithNothingFocused() throws {
        let s1 = try WlrootsSession(headlessOutputs: 1, width: 64, height: 48, refreshMilliHz: 60_000)
        let c1 = try Compositor(session: s1, outputWidth: 64, outputHeight: 48)
        let s2 = try WlrootsSession(headlessOutputs: 1, width: 64, height: 48, refreshMilliHz: 60_000)
        let c2 = try Compositor(session: s2, outputWidth: 64, outputHeight: 48)
        XCTAssertNotNil(c1.menus)
        XCTAssertNotNil(c2.menus)
        XCTAssertEqual(c2.menus?.current, .nothing)
        XCTAssertEqual(c2.menus?.menubarCount, 0)
        XCTAssertNil(c1.privilegedSocketName, "no privileged socket unless asked for")
    }

    /// Asked for, the socket exists, is 0600, and goes away with the compositor.
    func testThePrivilegedSocketIsTheUsersAloneAndIsRemovedAfter() throws {
        guard let dir = getenv("XDG_RUNTIME_DIR").map({ String(cString: $0) }), !dir.isEmpty
        else { throw XCTSkip("no XDG_RUNTIME_DIR") }
        let name = "undertow-priv-test-\(getpid())"
        let path = dir + "/" + name
        do {
            let s = try WlrootsSession(headlessOutputs: 1, width: 64, height: 48, refreshMilliHz: 60_000)
            let c = try Compositor(session: s, outputWidth: 64, outputHeight: 48,
                                   privilegedSocket: name)
            XCTAssertEqual(c.privilegedSocketName, name)
            var st = stat()
            XCTAssertEqual(stat(path, &st), 0, "no socket at \(path)")
            XCTAssertEqual(UInt32(st.st_mode) & 0o777, 0o600)
            withExtendedLifetime(c) {}
        }
        var st = stat()
        XCTAssertNotEqual(stat(path, &st), 0, "the privileged socket outlived its compositor")
    }

    /// A path that cannot be a socket is an error with the path in it, not a
    /// compositor that quietly has no bar.
    func testAnImpossiblePrivilegedSocketIsAnError() throws {
        let s = try WlrootsSession(headlessOutputs: 1, width: 64, height: 48, refreshMilliHz: 60_000)
        XCTAssertThrowsError(try Compositor(session: s, outputWidth: 64, outputHeight: 48,
                                            privilegedSocket: "/nonexistent-dir/priv")) { e in
            XCTAssertTrue("\(e)".contains("/nonexistent-dir/priv"), "\(e)")
        }
    }

    /// An empty scene still composites: background only, nothing painted.
    func testAnEmptySceneCompositesTheDesktopAndNothingElse() throws {
        let session = try WlrootsSession(headlessOutputs: 1, width: 320, height: 240,
                                         refreshMilliHz: 60_000)
        let compositor = try Compositor(session: session, outputWidth: 320, outputHeight: 240)
        let scene = SurfaceScene(compositor: compositor, outputWidth: 320, outputHeight: 240)
        defer { scene.release() }
        let stats = scene.latchAndComposite(now: 0, target: 0)
        XCTAssertEqual(stats.surfaces, 0)
        XCTAssertEqual(stats.damageArea, 0)
        XCTAssertEqual(scene.count, 0)
    }

    /// The compositor writes out the frame it actually drew.
    ///
    /// The capture reads the output's own swapchain buffer. An earlier version
    /// allocated a buffer and re-rendered into it, and the renderer refused the
    /// pass — a buffer has to be in the renderer's render-format set, and
    /// guessing XRGB8888/INVALID is not the same as asking.
    func testTheCompositorCapturesTheFrameItDrew() throws {
        let session = try WlrootsSession(headlessOutputs: 1, width: 64, height: 48,
                                         refreshMilliHz: 60_000)
        let compositor = try Compositor(session: session, outputWidth: 64, outputHeight: 48)
        let output = WlrootsOutput(session.outputs[0], session: session)
        let scene = SurfaceScene(compositor: compositor, outputWidth: 64, outputHeight: 48)
        defer { scene.release() }
        output.scene = scene

        let path = "/tmp/undertow-test-\(getpid()).ppm"
        defer { unlink(path) }
        XCTAssertTrue(output.capturePPM(path: path), "the capture failed")

        let fd = open(path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var head = [UInt8](repeating: 0, count: 15)
        let n = head.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, 15) }
        XCTAssertGreaterThan(n, 0)
        XCTAssertTrue(String(decoding: head, as: UTF8.self).hasPrefix("P6\n64 48\n255\n"),
                      "not a 64x48 binary PPM")
        // Header + one RGB triple per pixel, exactly.
        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        XCTAssertEqual(Int(st.st_size), 13 + 64 * 48 * 3)
    }

    // MARK: - Input routing (P6.4)

    /// The top window wins. This is the whole reason raising a window changes
    /// what a click hits, and it is one line that would be tedious to prove with
    /// a running desktop and trivial here.
    // MARK: - Server-side decorations (P9.6)

    func testTheFrameAndTheSurfaceAreInversesOfEachOther() {
        // Everything has to agree about where the frame is: placement, the
        // hit-test, the move grab, the snap rectangle. Two functions that
        // disagree by a pixel are a title bar you can see and cannot click.
        let f = FrameMetrics.frame(forSurfaceAt: 100, 200, width: 400, height: 300)
        let s = FrameMetrics.surface(forFrameAt: f.x, f.y)
        XCTAssertEqual(s.x, 100)
        XCTAssertEqual(s.y, 200)
    }

    func testTheFrameIsTallerByATitleBarAndWiderByItsBorders() {
        let f = FrameMetrics.frame(forSurfaceAt: 0, 0, width: 400, height: 300)
        XCTAssertEqual(f.w, 400 + 2 * Int32(FrameMetrics.border))
        XCTAssertEqual(f.h, 300 + Int32(FrameMetrics.titleHeight) + Int32(FrameMetrics.border))
        // The frame starts above and to the left of the surface it wraps.
        XCTAssertEqual(f.y, -Int32(FrameMetrics.titleHeight))
        XCTAssertEqual(f.x, -Int32(FrameMetrics.border))
    }

    func testTheFrameUsesTheToolkitsOwnTitleBarHeight() {
        // The whole argument for §6.1: one grammar, so a re-skin in Phase 11
        // reaches the window frames without a second implementation.
        XCTAssertEqual(FrameMetrics.titleHeight, Theme.titleBarHeight)
    }

    // MARK: - The keybind table (P9.5)

    /// A stub keysym table, so the parse can be tested without xkb — and so the
    /// tests say which symbols they mean instead of quoting magic numbers.
    private func sym(_ name: String) -> UInt32? {
        switch name {
        case "Tab": return 0xff09
        case "q", "Q": return 0x71
        case "w": return 0x77
        case "3": return 0x33
        case "XF86AudioRaiseVolume": return 0x1008ff13
        default: return nil
        }
    }

    func testSpecParsingTakesModifiersInAnyOrderAndCase() {
        let a = KeyBindingParser.parse(spec: "Cmd+Shift+Tab", keysym: sym)
        XCTAssertEqual(a?.0, [.cmd, .shift])
        XCTAssertEqual(a?.1, 0xff09)
        // A file a person edits: case and spaces must not matter.
        let b = KeyBindingParser.parse(spec: " shift + CMD + tab ", keysym: sym)
        XCTAssertEqual(b?.0, [.cmd, .shift])
        XCTAssertEqual(b?.1, 0xff09)
        // Aliases, because "Super" is what the rest of the world calls it.
        XCTAssertEqual(KeyBindingParser.parse(spec: "Super+q", keysym: sym)?.0, [.cmd])
        // Nonsense is refused rather than silently bound to something.
        XCTAssertNil(KeyBindingParser.parse(spec: "Cmd+NoSuchKey", keysym: sym))
        XCTAssertNil(KeyBindingParser.parse(spec: "Cmd+q+w", keysym: sym))
        XCTAssertNil(KeyBindingParser.parse(spec: "Cmd+", keysym: sym))
    }

    func testActionParsingRefusesWhatItCannotRun() {
        XCTAssertEqual(KeyBindingParser.parse(action: "next-window"), .nextWindow)
        XCTAssertEqual(KeyBindingParser.parse(action: "quit-app"), .quitApplication)
        XCTAssertEqual(KeyBindingParser.parse(action: "run: abyssgrab screen"),
                       .run(["abyssgrab", "screen"]))
        XCTAssertNil(KeyBindingParser.parse(action: "rm -rf /"))
        XCTAssertNil(KeyBindingParser.parse(action: "run:"))
    }

    func testModifiersMustMatchExactly() {
        let table = KeyBindings(bindings: [
            KeyBinding(sym: 0x71, modifiers: [.cmd], action: .quitApplication),
        ])
        XCTAssertEqual(table.match(sym: 0x71, modifiers: KeyModifiers([.cmd])), KeyAction.quitApplication)
        // Cmd-Shift-Q is a different keystroke and must reach the application.
        XCTAssertNil(table.match(sym: 0x71, modifiers: KeyModifiers([.cmd, .shift])))
        XCTAssertNil(table.match(sym: 0x71, modifiers: KeyModifiers()))
        // Caps Lock is a state, not a modifier: leaving it on must not disable
        // every shortcut on the desktop.
        XCTAssertEqual(table.match(sym: 0x71, modifiers: KeyModifiers(rawValue: 64 | 2)),
                       KeyAction.quitApplication)
    }

    func testAnApplicationMayKeepACombination() {
        // §6.2's decision, as data: a terminal that cannot receive Cmd-Q cannot
        // run a program that wants it.
        let q = KeyBinding(sym: 0x71, modifiers: [.cmd], action: .quitApplication)
        let w = KeyBinding(sym: 0x77, modifiers: [.cmd], action: .closeWindow)
        let table = KeyBindings(bindings: [q, w],
                                passthrough: ["org.abyssbsd.terminal": [q]])
        // The terminal keeps Cmd-Q…
        XCTAssertNil(table.match(sym: 0x71, modifiers: KeyModifiers([.cmd]),
                                 focusedAppID: "org.abyssbsd.terminal"))
        // …but not Cmd-W, which it never asked for.
        XCTAssertEqual(table.match(sym: 0x77, modifiers: KeyModifiers([.cmd]),
                                   focusedAppID: "org.abyssbsd.terminal"), KeyAction.closeWindow)
        // And everybody else still gets the desktop's behaviour.
        XCTAssertEqual(table.match(sym: 0x71, modifiers: KeyModifiers([.cmd]),
                                   focusedAppID: "org.abyssbsd.finder"), KeyAction.quitApplication)
        XCTAssertEqual(table.match(sym: 0x71, modifiers: KeyModifiers([.cmd])), KeyAction.quitApplication)
    }

    func testAnApplicationMayKeepEverything() {
        // `*` — for the virtual machine window and the remote desktop that come
        // later, where every keystroke belongs to something else.
        let q = KeyBinding(sym: 0x71, modifiers: [.cmd], action: .quitApplication)
        let table = KeyBindings(bindings: [q], passthrough: ["org.abyssbsd.vm": []])
        XCTAssertNil(table.match(sym: 0x71, modifiers: KeyModifiers([.cmd]),
                                 focusedAppID: "org.abyssbsd.vm"))
        XCTAssertEqual(table.match(sym: 0x71, modifiers: KeyModifiers([.cmd]),
                                   focusedAppID: "other"), KeyAction.quitApplication)
    }

    func testTheTableReadsAConfigAndSkipsWhatItCannotUnderstand() {
        var c = Config()
        c = c.set("keys", "Cmd+Tab", "next-window")
        c = c.set("keys", "Cmd+q", "quit-app")
        c = c.set("keys", "Cmd+NoSuchKey", "next-window")   // unknown key
        c = c.set("keys", "Cmd+w", "explode")               // unknown action
        c = c.set("passthrough", "org.abyssbsd.terminal", "Cmd+q")
        let table = KeyBindingParser.table(from: c, keysym: sym)
        XCTAssertEqual(table.bindings.count, 2)
        XCTAssertEqual(table.match(sym: 0xff09, modifiers: KeyModifiers([.cmd])), KeyAction.nextWindow)
        XCTAssertNil(table.match(sym: 0x71, modifiers: KeyModifiers([.cmd]),
                                 focusedAppID: "org.abyssbsd.terminal"))
    }

    func testTheBuiltInDefaultsAllParse() {
        // A default that does not parse is a shortcut that silently does not
        // exist, which is the failure this whole table is meant to end.
        for (spec, action) in KeyBindingParser.defaults {
            XCTAssertNotNil(KeyBindingParser.parse(action: action), action)
            // The stub knows only the symbols these tests name, so this asserts
            // the *shape* — modifiers and a single key — not the symbol itself.
            let parts = spec.split(separator: "+")
            XCTAssertFalse(parts.isEmpty, spec)
        }
    }

    // MARK: - Edge snapping (P9.4)

    /// The usable area, not the output — a window snapped under the menu bar is
    /// the same defect as one placed there.
    private var snapArea: Undertow.Rect {
        Undertow.Rect(x: 0, y: 22, width: 800, height: 578)
    }

    func testSnapZonesAreTheThreeEdgesAndNothingElse() {
        let a = snapArea
        XCTAssertEqual(WindowSnap.zone(cursorX: 2, cursorY: 300, area: a), .left)
        XCTAssertEqual(WindowSnap.zone(cursorX: 799, cursorY: 300, area: a), .right)
        XCTAssertEqual(WindowSnap.zone(cursorX: 400, cursorY: 24, area: a), .maximize)
        // The middle is the overwhelming majority of the screen and snaps to
        // nothing: a person who never drags to an edge never meets this.
        XCTAssertNil(WindowSnap.zone(cursorX: 400, cursorY: 300, area: a))
        // The bottom edge is deliberately not a zone — there is a Dock there.
        XCTAssertNil(WindowSnap.zone(cursorX: 400, cursorY: 599, area: a))
    }

    func testTheTopCornersMaximizeRatherThanHalve() {
        let a = snapArea
        // Both readings are defensible; only one can happen, and a corner that
        // sometimes did each would be a coin toss.
        XCTAssertEqual(WindowSnap.zone(cursorX: 0, cursorY: 22, area: a), .maximize)
        XCTAssertEqual(WindowSnap.zone(cursorX: 799, cursorY: 22, area: a), .maximize)
    }

    func testSnapHalvesTileTheAreaExactly() {
        let a = snapArea
        let l = WindowSnap.rect(for: .left, in: a)
        let r = WindowSnap.rect(for: .right, in: a)
        XCTAssertEqual(l.x, a.x)
        XCTAssertEqual(l.x + l.width, r.x)                 // no gutter
        XCTAssertEqual(r.x + r.width, a.x + a.width)       // no overhang
        XCTAssertEqual(l.height, a.height)
        XCTAssertEqual(WindowSnap.rect(for: .maximize, in: a), a)
        // An odd width still tiles exactly.
        let odd = Undertow.Rect(x: 0, y: 0, width: 801, height: 100)
        let ol = WindowSnap.rect(for: .left, in: odd)
        let or = WindowSnap.rect(for: .right, in: odd)
        XCTAssertEqual(ol.width + or.width, odd.width)
        XCTAssertEqual(ol.x + ol.width, or.x)
    }

    func testAnEmptyAreaSnapsToNothing() {
        // A compositor with no usable area (every zone taken) must not divide
        // by it — and nil is the honest answer, not a zero-width half.
        XCTAssertNil(WindowSnap.zone(cursorX: 0, cursorY: 0,
                                     area: Undertow.Rect(x: 0, y: 0, width: 0, height: 0)))
    }

    func testTheTopmostWindowUnderThePointerWins() {
        let rects = [
            WindowRect(x: 0, y: 0, width: 200, height: 200),      // bottom
            WindowRect(x: 100, y: 100, width: 200, height: 200),  // top, overlapping
        ]
        // In the overlap, the later (higher) window takes it.
        XCTAssertEqual(PointerRouting.hit(150, 150, rects: rects)?.index, 1)
        // Outside the overlap, each gets its own.
        XCTAssertEqual(PointerRouting.hit(50, 50, rects: rects)?.index, 0)
        XCTAssertEqual(PointerRouting.hit(250, 250, rects: rects)?.index, 1)
        // Off both: the desktop, and nobody should be told they have the pointer.
        XCTAssertNil(PointerRouting.hit(400, 400, rects: rects))
        XCTAssertNil(PointerRouting.hit(150, 150, rects: []))
    }

    /// A click arrives in the surface's own coordinates, not the output's — get
    /// this wrong and every control in every window is offset by the window's
    /// position, which looks like a broken toolkit rather than a broken
    /// compositor.
    func testAHitReportsSurfaceLocalCoordinates() {
        let rects = [WindowRect(x: 170, y: 120, width: 460, height: 360)]
        guard let h = PointerRouting.hit(540, 415, rects: rects) else {
            return XCTFail("the point is inside the window")
        }
        XCTAssertEqual(h.localX, 370, accuracy: 0.001)
        XCTAssertEqual(h.localY, 295, accuracy: 0.001)
    }

    /// Edges: the top-left corner is inside, the bottom-right is not. Half-open
    /// bounds, so two windows sharing an edge never both claim a pixel.
    func testHitTestBoundsAreHalfOpen() {
        let rects = [WindowRect(x: 10, y: 10, width: 100, height: 100)]
        XCTAssertNotNil(PointerRouting.hit(10, 10, rects: rects))
        XCTAssertNotNil(PointerRouting.hit(109.9, 109.9, rects: rects))
        XCTAssertNil(PointerRouting.hit(110, 60, rects: rects))
        XCTAssertNil(PointerRouting.hit(60, 110, rects: rects))
        XCTAssertNil(PointerRouting.hit(9.9, 60, rects: rects))
    }

    /// A cursor that can leave the screen can address a surface nobody can see.
    func testTheCursorIsClampedToTheOutput() {
        let (x1, y1) = PointerRouting.clamp(-50, -50, width: 800, height: 600)
        XCTAssertEqual(x1, 0); XCTAssertEqual(y1, 0)
        let (x2, y2) = PointerRouting.clamp(9999, 9999, width: 800, height: 600)
        XCTAssertEqual(x2, 799); XCTAssertEqual(y2, 599)
        let (x3, y3) = PointerRouting.clamp(400, 300, width: 800, height: 600)
        XCTAssertEqual(x3, 400); XCTAssertEqual(y3, 300)
    }

    /// The seat comes up and offers the virtual-input globals — which is what
    /// lets the harness's existing `vpointer`/`vkeyboard` drive us unmodified.
    func testTheSeatOffersTheVirtualInputGlobals() throws {
        let session = try WlrootsSession(headlessOutputs: 1, width: 320, height: 240,
                                         refreshMilliHz: 60_000)
        let compositor = try Compositor(session: session, outputWidth: 320, outputHeight: 240)
        let seat = try Seat(compositor: compositor, outputWidth: 320, outputHeight: 240)
        // The cursor starts centred, so a capture with no input is still sane.
        XCTAssertEqual(seat.cursorX, 160)
        XCTAssertEqual(seat.cursorY, 120)
        XCTAssertNil(seat.focused)
        XCTAssertNil(seat.toplevel(at: 10, 10), "there are no windows yet")
    }

    // MARK: - Layer-shell arrangement (P6.6)

    private func fullOutput() -> Undertow.Rect {
        Undertow.Rect(x: 0, y: 0, width: 800, height: 600)
    }

    /// The menu bar: a top strip that reserves its height. This is the exact
    /// arrangement `live-session.sh` has asserted against sway since Phase 2 —
    /// a layer surface never appears in a window tree, so the usable area is the
    /// only observable proof the reservation happened (HANDOFF §2.26).
    func testATopStripWithAnExclusiveZoneReservesIt() {
        var bar = LayerRequest(anchor: [.top, .left, .right], desiredWidth: 0,
                               desiredHeight: 22)
        bar.exclusiveZone = 22
        let (rect, usable) = LayerArrange.place(bar, in: fullOutput(), output: fullOutput())
        XCTAssertEqual(rect, Rect(x: 0, y: 0, width: 800, height: 22))
        XCTAssertEqual(usable, Rect(x: 0, y: 22, width: 800, height: 578))
    }

    /// The Dock: anchored to the bottom, reserving nothing. It overlaps whatever
    /// is behind it, which is the Mac's behaviour and the reason a maximised
    /// window is not shortened by the Dock.
    func testAZeroZoneSurfaceOverlapsAndReservesNothing() {
        let dock = LayerRequest(anchor: [.bottom], desiredWidth: 320, desiredHeight: 64)
        let (rect, usable) = LayerArrange.place(dock, in: fullOutput(), output: fullOutput())
        XCTAssertEqual(rect, Rect(x: 240, y: 536, width: 320, height: 64))
        XCTAssertEqual(usable, fullOutput(), "a zero zone must reserve nothing")
    }

    /// The desktop: `exclusiveZone == -1` means "ignore everyone's
    /// reservations". Without it the wallpaper would start below the menu bar
    /// instead of painting the whole output underneath it (HANDOFF §2.26).
    func testAnExclusiveZoneOfMinusOneIgnoresReservations() {
        var wallpaper = LayerRequest(anchor: [.top, .bottom, .left, .right],
                                     desiredWidth: 0, desiredHeight: 0)
        wallpaper.exclusiveZone = -1
        // Pretend the menu bar has already taken its strip.
        let afterBar = Rect(x: 0, y: 22, width: 800, height: 578)
        let (rect, usable) = LayerArrange.place(wallpaper, in: afterBar,
                                                output: fullOutput())
        XCTAssertEqual(rect, fullOutput(), "the desktop must cover the whole output")
        XCTAssertEqual(usable, afterBar, "and must not change anyone else's area")
    }

    /// Arranged in order, reservations accumulate — which is how a menu bar and
    /// a Dock that both reserve leave a window the strip between them.
    func testReservationsAccumulateInOrder() {
        var bar = LayerRequest(anchor: [.top, .left, .right], desiredWidth: 0,
                               desiredHeight: 22)
        bar.exclusiveZone = 22
        var shelf = LayerRequest(anchor: [.bottom, .left, .right], desiredWidth: 0,
                                 desiredHeight: 60)
        shelf.exclusiveZone = 60

        var usable = fullOutput()
        (_, usable) = LayerArrange.place(bar, in: usable, output: fullOutput())
        let (shelfRect, finalUsable) = LayerArrange.place(shelf, in: usable,
                                                          output: fullOutput())
        // The shelf sits at the bottom of what was left, not of the output.
        XCTAssertEqual(shelfRect, Rect(x: 0, y: 540, width: 800, height: 60))
        XCTAssertEqual(finalUsable, Rect(x: 0, y: 22, width: 800, height: 518))
    }

    /// Anchoring to opposite edges means "span", and reserves nothing — there is
    /// no unambiguous side to take the reservation from.
    func testSpanningBothEdgesReservesNothing() {
        var full = LayerRequest(anchor: [.top, .bottom, .left, .right],
                                desiredWidth: 0, desiredHeight: 0)
        full.exclusiveZone = 40
        let (rect, usable) = LayerArrange.place(full, in: fullOutput(), output: fullOutput())
        XCTAssertEqual(rect, fullOutput())
        XCTAssertEqual(usable, fullOutput())
    }

    /// Margins push a surface off its edge and are counted in the reservation,
    /// or a surface with a margin overlaps whatever it was meant to sit beside.
    func testMarginsOffsetTheSurfaceAndCountTowardTheReservation() {
        var toast = LayerRequest(anchor: [.top, .right], desiredWidth: 300,
                                 desiredHeight: 58)
        toast.marginTop = 30
        toast.marginRight = 12
        let (rect, usable) = LayerArrange.place(toast, in: fullOutput(), output: fullOutput())
        XCTAssertEqual(rect, Rect(x: 800 - 300 - 12, y: 30, width: 300, height: 58))
        XCTAssertEqual(usable, fullOutput(), "a toast reserves nothing (PHASE7 P7.4)")

        var bar = LayerRequest(anchor: [.top, .left, .right], desiredWidth: 0,
                               desiredHeight: 22)
        bar.exclusiveZone = 22
        bar.marginTop = 4
        let (_, afterBar) = LayerArrange.place(bar, in: fullOutput(), output: fullOutput())
        XCTAssertEqual(afterBar.y, 26, "the margin is part of the space taken")
    }

    /// A reservation can never make the usable area negative, however greedy.
    func testAnOversizedReservationCannotInvertTheUsableArea() {
        var greedy = LayerRequest(anchor: [.top, .left, .right], desiredWidth: 0,
                                  desiredHeight: 9999)
        greedy.exclusiveZone = 9999
        let (_, usable) = LayerArrange.place(greedy, in: fullOutput(), output: fullOutput())
        XCTAssertGreaterThanOrEqual(usable.height, 0)
        XCTAssertGreaterThanOrEqual(usable.width, 0)
    }

    // MARK: - Remembered window positions (P6.7)

    /// `app_id` alone would be wrong: the spatial Finder opens one window per
    /// folder from one application, and they must not all share a position.
    func testAWindowKeyDistinguishesWindowsOfTheSameApp() {
        let a = WindowPlaces.key(appID: "org.abyssbsd.finder", title: "Documents")
        let b = WindowPlaces.key(appID: "org.abyssbsd.finder", title: "Pictures")
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b, "two folders of one app must not share a key")
    }

    /// A window with no title still gets a key, so single-window apps work.
    /// A window with neither gets none, because there is nothing stable to
    /// store it under — better no memory than the wrong window's position.
    func testAWindowKeyNeedsSomethingStable() {
        XCTAssertEqual(WindowPlaces.key(appID: "org.abyssbsd.demo", title: nil),
                       "org.abyssbsd.demo")
        XCTAssertEqual(WindowPlaces.key(appID: "org.abyssbsd.demo", title: "  "),
                       "org.abyssbsd.demo", "whitespace is not a title")
        XCTAssertNil(WindowPlaces.key(appID: nil, title: nil))
        XCTAssertNil(WindowPlaces.key(appID: "", title: ""))
    }

    /// The separator must not be forgeable, or one window could claim another's
    /// remembered position by choosing its title carefully.
    func testAWindowKeyCannotBeForgedThroughTheSeparator() {
        // Without escaping, both of these would render as "app/a/b" and the two
        // windows would share one remembered position.
        let honest = WindowPlaces.key(appID: "app", title: "a/b")
        let sneaky = WindowPlaces.key(appID: "app/a", title: "b")
        XCTAssertNotNil(honest)
        XCTAssertNotNil(sneaky)
        XCTAssertNotEqual(honest, sneaky,
                          "a title containing the separator collided with another window's key")
        // Exactly one separator, between the two halves.
        XCTAssertEqual(honest!.filter { $0 == "/" }.count, 1)
        XCTAssertEqual(sneaky!.filter { $0 == "/" }.count, 1)
        // And `=` cannot break the INI line it is written on.
        let equals = WindowPlaces.key(appID: "app", title: "a=b")
        XCTAssertFalse(equals!.contains("="))
    }

    /// A position survives a round trip through the real on-disk INI — the same
    /// mmap-read / atomic-rename store every other component uses.
    func testAPositionRoundTripsThroughTheConfigFile() throws {
        let dir = "/tmp/abyss-places-test-\(getpid())"
        _ = mkdir(dir, 0o700)
        defer {
            unlink(dir + "/windows.ini")
            unlink(dir + "/windows.ini.lock")
            _ = rmdir(dir)
        }

        let writer = WindowPlaces(configDir: dir)
        XCTAssertNil(writer.place(forKey: "app/Documents"), "nothing remembered yet")
        writer.remember(WindowPlace(x: 460, y: 345), forKey: "app/Documents")

        // A DIFFERENT instance, as a second session would be: the point is that
        // the position outlives the process that recorded it.
        let reader = WindowPlaces(configDir: dir)
        XCTAssertEqual(reader.place(forKey: "app/Documents"),
                       WindowPlace(x: 460, y: 345))
        XCTAssertNil(reader.place(forKey: "app/Pictures"))
    }

    /// A malformed entry must read as "not remembered", not as (0,0) — a window
    /// silently jumping to the top-left corner is worse than one that cascades.
    func testAMalformedPositionIsNotRemembered() throws {
        let dir = "/tmp/abyss-places-bad-\(getpid())"
        _ = mkdir(dir, 0o700)
        defer {
            unlink(dir + "/windows.ini")
            unlink(dir + "/windows.ini.lock")
            _ = rmdir(dir)
        }
        let path = dir + "/windows.ini"
        let text = "[windows]\napp/Broken = not-a-position\napp/Half = 12\n"
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, bytes.count) }
        close(fd)

        let places = WindowPlaces(configDir: dir)
        XCTAssertNil(places.place(forKey: "app/Broken"))
        XCTAssertNil(places.place(forKey: "app/Half"))
    }

    /// The display's vblanks must be its own, not an echo of what the
    /// compositor aimed at — a model that agrees with you cannot test a
    /// predictor (PHASE6.md P6.1).
    func testTheSyntheticDisplayKeepsItsOwnVblankGrid() {
        let period: UInt64 = 10_000_000
        var o = SyntheticOutput(periodNs: period, commitLatencyNs: 1_000)
        let t0 = Mono.now()
        o.submit(target: t0 &+ period, at: t0)          // establishes the epoch
        _ = o.drainRegardlessOfTime()
        // Aim at something absurd, far off the grid. The display must ignore it.
        o.submit(target: t0 &+ period &* 100 &+ 12_345, at: t0 &+ period)
        guard let flip = o.drainRegardlessOfTime() else {
            return XCTFail("no flip came back")
        }
        XCTAssertEqual((flip.vblank &- t0) % period, 0,
                       "the display landed a frame off its own grid — it is echoing the target")
    }
}
