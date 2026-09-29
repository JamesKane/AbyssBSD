// Several outputs (PHASE14 P14.7a): the layout's arithmetic, the scene's
// projection onto one output, and the loop that serves them all.

import XCTest
@testable import Undertow

final class DisplaysTests: XCTestCase {

    private let three = DisplayLayout([
        DisplayBox(name: "A", x: 0, y: 0, width: 1024, height: 768),
        DisplayBox(name: "B", x: 1024, y: 0, width: 800, height: 600),
        DisplayBox(name: "C", x: -320, y: 100, width: 320, height: 240),
    ])

    func testARowPlacesOutputsLeftToRight() {
        let l = DisplayLayout.row([("A", 1024, 768), ("B", 800, 600)])
        XCTAssertEqual(l.displays.map(\.x), [0, 1024])
        XCTAssertEqual(l.main?.name, "A", "the first is the main display")
        XCTAssertEqual(l.summary, "A 1024x768@0,0 main; B 800x600@1024,0")
    }

    func testBoundsHoldEveryDisplay() {
        XCTAssertEqual(three.bounds, Rect(x: -320, y: 0, width: 2144, height: 768))
        XCTAssertEqual(DisplayLayout([]).bounds, Rect(x: 0, y: 0, width: 0, height: 0))
    }

    func testAPointIsOnADisplayOrInAGap() {
        XCTAssertEqual(three.display(at: 10, 10)?.name, "A")
        XCTAssertEqual(three.display(at: 1024, 0)?.name, "B", "the edge belongs to the display that starts there")
        XCTAssertEqual(three.display(at: -1, 150)?.name, "C")
        XCTAssertNil(three.display(at: 1500, 700), "below B's bottom, beside A: a gap")
        XCTAssertNil(three.display(at: -100, 50), "above C: a gap")
    }

    func testTheCursorIsKeptOffTheGaps() {
        let (x, y) = three.clamp(1500, 700)
        XCTAssertEqual(three.display(at: x, y)?.name, "B", "the nearest display")
        XCTAssertEqual(y, 599)
        let (x2, y2) = three.clamp(-100, 50)
        XCTAssertEqual(three.display(at: x2, y2)?.name, "C")
        XCTAssertEqual(three.clamp(10, 10).0, 10, "a point on a display stays where it is")
        let (x3, _) = three.clamp(5000, 10)
        XCTAssertEqual(x3, 1823, "past the last display's edge: its last column")
    }

    func testAWindowIsOnTheDisplayHoldingItsCentre() {
        XCTAssertEqual(three.display(for: Rect(x: 900, y: 10, width: 300, height: 200))?.name, "B")
        XCTAssertEqual(three.display(for: Rect(x: 900, y: 10, width: 200, height: 200))?.name, "A")
        XCTAssertEqual(three.display(for: Rect(x: 1300, y: 550, width: 400, height: 400))?.name, "B",
                       "centre in a gap: the display it overlaps most")
        XCTAssertEqual(three.display(for: Rect(x: 9000, y: 9000, width: 10, height: 10))?.name, "A",
                       "on no display at all: the main one")
    }

    func testAnOutputDrawsItsOwnRectangleOfTheLayout() {
        // A window straddling A and B, drawn by B (origin 1024,0).
        XCTAssertEqual(SurfaceScene.project(Rect(x: 1000, y: 20, width: 100, height: 50), originX: 1024, originY: 0, scale: 1),
                       Rect(x: -24, y: 20, width: 100, height: 50))
        // At scale 2, edges double; two touching rectangles still touch.
        let a = SurfaceScene.project(Rect(x: 1024, y: 0, width: 33, height: 10), originX: 1024, originY: 0, scale: 1.5)
        let b = SurfaceScene.project(Rect(x: 1057, y: 0, width: 33, height: 10), originX: 1024, originY: 0, scale: 1.5)
        XCTAssertEqual(a.x + a.width, b.x, "no seam at a fractional scale")
        XCTAssertEqual(SurfaceScene.project(Rect(x: 10, y: 10, width: 20, height: 20), originX: 0, originY: 0, scale: 2),
                       Rect(x: 20, y: 20, width: 40, height: 40))
    }

    /// Real time, on synthetic displays: a 144 Hz and a 60 Hz output on one
    /// loop are each served at their own rate, and neither misses.
    func testMixedRatesAreEachServedAtTheirOwn() {
        var c = Conductor(outputs: [SyntheticOutput(periodNs: 16_666_667), SyntheticOutput(periodNs: 6_944_444)],
                          sinks: [SyntheticScene(surfaces: 4, viewport: (640, 480)),
                                  SyntheticScene(surfaces: 4, viewport: (640, 480))])
        defer { for i in c.sinks.indices { c.sinks[i].release() } }
        let warm = [FlightRecorder(capacity: 256), FlightRecorder(capacity: 256)]
        for _ in 0..<30 { c.serveNext(recorders: warm) }
        let recs = [FlightRecorder(capacity: 4096), FlightRecorder(capacity: 4096)]
        let start = Mono.now()
        while Mono.since(start, Mono.now()) < 500_000_000 { c.serveNext(recorders: recs) }
        let f60 = Double(recs[0].retained), f144 = Double(recs[1].retained)
        XCTAssertEqual(f60, 30, accuracy: 3, "the 60 Hz output made \(f60) frames in half a second")
        XCTAssertEqual(f144, 72, accuracy: 5, "the 144 Hz output made \(f144) frames in half a second")
        XCTAssertLessThanOrEqual(recs[0].missedCount + recs[1].missedCount, 1,
                                 "misses: \(recs[0].missedCount) at 60, \(recs[1].missedCount) at 144")
    }

    /// Three outputs at one rate: the third is not starved by ties.
    ///
    /// Per unit of time, not per call. The first version asserted 60 frames
    /// each from 60 `serveNext` calls, which holds only while the three grids'
    /// deadlines coincide exactly: they start microseconds apart, so a call can
    /// serve one output and the next the others. It passed when quiet and failed
    /// in the phase gate's busier run (32 of 60) — a test of timing luck.
    /// The re-planning bug it was written for is caught by the mixed-rate test
    /// above (a 60 Hz output beside a 144 Hz one makes no frames).
    func testEqualOutputsAreAllServed() {
        var c = Conductor(outputs: (0..<3).map { _ in SyntheticOutput(periodNs: 16_666_667) },
                          sinks: (0..<3).map { _ in SyntheticScene(surfaces: 2, viewport: (320, 240)) })
        defer { for i in c.sinks.indices { c.sinks[i].release() } }
        let warm = (0..<3).map { _ in FlightRecorder(capacity: 256) }
        for _ in 0..<30 { c.serveNext(recorders: warm) }
        let recs = (0..<3).map { _ in FlightRecorder(capacity: 4096) }
        let start = Mono.now()
        while Mono.since(start, Mono.now()) < 500_000_000 { c.serveNext(recorders: recs) }
        let frames = recs.map(\.retained)
        XCTAssertLessThanOrEqual((frames.max() ?? 0) - (frames.min() ?? 0), 1, "frames per output: \(frames)")
        for f in frames { XCTAssertEqual(Double(f), 30, accuracy: 3, "frames per output in half a second: \(frames)") }
    }
}

/// What a client may ask for, and what is kept (P14.7b).
final class DisplaysConfigTests: XCTestCase {
    private func s(_ n: String, _ w: Int32, _ h: Int32, _ x: Int32, _ y: Int32, scale: Double = 1, on: Bool = true) -> DisplaySetting {
        DisplaySetting(name: n, enabled: on, modeWidth: w, modeHeight: h, refreshMilliHz: 60000, x: x, y: y, scale: scale)
    }

    func testALayoutBoxIsTheModeOverTheScale() {
        XCTAssertEqual(s("B", 1024, 768, -1024, 100, scale: 2).box, DisplayBox(name: "B", x: -1024, y: 100, width: 512, height: 384, scale: 2))
        XCTAssertEqual(s("B", 1920, 1080, 0, 0, scale: 1.5).box.width, 1280)
    }

    func testARequestIsRefusedInWords() {
        XCTAssertEqual(DisplaysConfig.problems([s("A", 640, 480, 0, 0), s("B", 800, 600, 640, 0)]), [], "side by side")
        XCTAssertEqual(DisplaysConfig.problems([s("A", 640, 480, 0, 0), s("B", 800, 600, 600, 0)]), ["A and B overlap"])
        XCTAssertEqual(DisplaysConfig.problems([s("A", 640, 480, 0, 0), s("B", 1600, 1200, 640, 0, scale: 2)]), [],
                       "a scaled display's box is its mode over its scale")
        XCTAssertEqual(DisplaysConfig.problems([s("A", 640, 480, 0, 0), s("B", 800, 600, 640, 0, on: false)]),
                       ["B: turning a display off is not supported yet"])
        XCTAssertEqual(DisplaysConfig.problems([s("A", 640, 480, 0, 0, scale: 8)]), ["A: a scale of 8.0 is outside 0.5 to 4"])
        XCTAssertEqual(DisplaysConfig.problems([s("A", 0, 480, 0, 0)]), ["A: 0x480 is not a mode"])
        XCTAssertEqual(DisplaysConfig.problems([]), ["a configuration must name at least one display"])
    }

    func testALineOfDisplaysIniRoundTrips() {
        for d in [s("HEADLESS-2", 1024, 768, -1024, 100, scale: 2), s("DP-1", 2560, 1440, 0, 0, scale: 1.25)] {
            XCTAssertEqual(DisplaysConfig.parse(name: d.name, DisplaysConfig.format(d)), d)
        }
        XCTAssertEqual(DisplaysConfig.format(s("A", 640, 480, 0, 0)), "0,0 640x480@60000 1")
        XCTAssertNil(DisplaysConfig.parse(name: "A", "0,0 640x480 1"), "a line without a refresh is not one")
        XCTAssertNil(DisplaysConfig.parse(name: "A", "garbage"))
    }

    func testDisplaysIniIsStoredAndLoaded() throws {
        var t = Array("/tmp/abyss-displays-XXXXXX".utf8CString)
        let dir = t.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
        let a = s("HEADLESS-1", 640, 480, 0, 0), b = s("HEADLESS-2", 1024, 768, -1024, 100, scale: 2)
        try DisplaysFile.store([a, b], configDir: dir)
        XCTAssertEqual(DisplaysFile.load(configDir: dir), ["HEADLESS-1": a, "HEADLESS-2": b])
        try DisplaysFile.store([s("HEADLESS-2", 800, 600, 640, 0)], configDir: dir)
        XCTAssertEqual(DisplaysFile.load(configDir: dir)["HEADLESS-2"]?.x, 640, "a later apply replaces the line")
        XCTAssertEqual(DisplaysFile.load(configDir: dir)["HEADLESS-1"], a, "and leaves the others")
        XCTAssertEqual(DisplaysFile.load(configDir: dir + "/none"), [:])
    }
}
