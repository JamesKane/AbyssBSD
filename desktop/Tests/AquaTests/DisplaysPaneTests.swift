// Displays pane tests (PHASE14 P14.7c): the arrangement's arithmetic — fit,
// snap — the page in words, and one layout for paint and hit.

import XCTest
@testable import Aqua
@testable import AquaDraw
import Surface

final class DisplaysPaneTests: XCTestCase {

    func testTheLayoutIsFittedToScaleAndCentred() {
        let (r, k) = DisplaysArrange.fit([("A", 0, 0, 640, 480), ("B", 640, 0, 800, 600)], in: Rect(0, 0, 720, 300))
        XCTAssertEqual(k, 0.4, accuracy: 1e-9, "the height binds: 300/600 x 0.8")
        XCTAssertEqual(r["A"]!.w, 256, accuracy: 1e-9)
        XCTAssertEqual(r["B"]!.x, r["A"]!.x + r["A"]!.w, accuracy: 1e-9, "neighbours touch in the pane as they do in the layout")
        XCTAssertEqual(r["A"]!.x + (r["B"]!.x + r["B"]!.w - r["A"]!.x) / 2, 360, accuracy: 1e-9, "centred")
    }

    func testADroppedDisplaySnapsToTouchTheNearestEdge() {
        let main = (x: Int32(0), y: Int32(0), w: Int32(640), h: Int32(480))
        // Dropped a little below and left of main's bottom edge: it sits on it.
        var p = DisplaysArrange.snap(name: "B", x: 100, y: 520, w: 800, h: 600, others: [main])
        XCTAssertEqual(p.x, 100); XCTAssertEqual(p.y, 480)
        // A few units off lining up: lined up (left edges, then right edges).
        p = DisplaysArrange.snap(name: "B", x: 3, y: 500, w: 800, h: 600, others: [main])
        XCTAssertEqual(p.x, 0); XCTAssertEqual(p.y, 480)
        p = DisplaysArrange.snap(name: "B", x: -150, y: 500, w: 800, h: 600, others: [main])
        XCTAssertEqual(p.x, -160, "right edges flush: 640 - 800")
        // Dropped overlapping main's right half: to its right, touching.
        p = DisplaysArrange.snap(name: "B", x: 500, y: 30, w: 800, h: 600, others: [main])
        XCTAssertEqual(p.x, 640); XCTAssertEqual(p.y, 30)
        // Dropped far away: brought back to touch, keeping at least one unit of edge.
        p = DisplaysArrange.snap(name: "B", x: 3000, y: 2000, w: 800, h: 600, others: [main])
        XCTAssertTrue((p.x == 640 && p.y == 479) || (p.x == 639 && p.y == 480) || (p.x == 640 && p.y == 0) || (p.x == 0 && p.y == 480)
                      || (p.x == -160 && p.y == 480) || (p.x == 640 && p.y == -120), "\(p)")
        // Two neighbours: never onto either.
        let right = (x: Int32(640), y: Int32(0), w: Int32(800), h: Int32(600))
        p = DisplaysArrange.snap(name: "C", x: 600, y: 470, w: 320, h: 240, others: [main, right])
        let overlapsMain = min(p.x + 320, 640) > max(p.x, 0) && min(p.y + 240, 480) > max(p.y, 0)
        let overlapsRight = min(p.x + 320, 1440) > max(p.x, 640) && min(p.y + 240, 600) > max(p.y, 0)
        XCTAssertFalse(overlapsMain || overlapsRight, "\(p)")
    }

    func testThePageInWords() {
        XCTAssertEqual(DisplaysWords.statusLine(DisplaysPaneState.sample.heads),
                       "DP-1 2560x1440 at 0,0 scale 1.25; HDMI-A-1 1920x1200 at 2048,0 scale 1")
        let modes = DisplaysPaneState.sample.heads[0].modes
        XCTAssertEqual(DisplaysWords.mode(modes[0], among: modes), "2560 × 1440 (native)")
        XCTAssertEqual(DisplaysWords.scales(current: 1.75), [1, 1.25, 1.5, 1.75, 2], "an unusual current scale is offered too")
        XCTAssertEqual(DisplaysPaneState.sample.heads[0].layoutWidth, 2048, "2560 at 1.25")
    }

    func testOneLayoutForPaintAndHit() {
        let l = displaysLayout(body: Rect(0, 80, 760, 540), .sample)
        func at(_ r: Rect) -> DisplaysHit? { displaysHit(l, x: r.x + r.w / 2, y: r.y + r.h / 2) }
        XCTAssertEqual(at(l.displays["HDMI-A-1"]!), .display("HDMI-A-1"))
        XCTAssertEqual(l.modes.map(\.value), ["2560x1440@59951", "1920x1080@60000"])
        XCTAssertEqual(at(l.modes[1].hit), .mode("1920x1080@60000"))
        XCTAssertEqual(at(l.scales[3].hit), .scale("2"))
        XCTAssertLessThan(l.noteBaseline, 620)
        var dragged = DisplaysPaneState.sample
        dragged.dragging = ("HDMI-A-1", 0, 1440)
        let d = displaysLayout(body: Rect(0, 80, 760, 540), dragged)
        XCTAssertEqual(d.factor, l.factor, "the pane does not rescale under the pointer mid-drag")
        XCTAssertEqual(d.displays["HDMI-A-1"]!.y, l.displays["DP-1"]!.y + 1440 * l.factor, accuracy: 1e-9)
    }
}
