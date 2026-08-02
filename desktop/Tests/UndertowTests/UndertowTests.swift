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
@testable import Undertow

final class UndertowTests: XCTestCase {

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
