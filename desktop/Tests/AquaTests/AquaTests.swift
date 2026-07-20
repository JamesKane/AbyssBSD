import XCTest
@testable import Aqua

final class AquaTests: XCTestCase {
    func testColorHex() {
        let c = Color(hex: 0xFF8040)
        XCTAssertEqual(c.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(c.g, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(c.b, 64.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(c.a, 1.0, accuracy: 0.001)
    }

    func testColorWithAlpha() {
        let c = Color(hex: 0x000000).with(a: 0.5)
        XCTAssertEqual(c.a, 0.5, accuracy: 0.001)
    }

    func testRectContains() {
        let r = Rect(10, 10, 100, 50)
        XCTAssertTrue(r.contains(20, 20))
        XCTAssertTrue(r.contains(10, 10))     // edge inclusive
        XCTAssertTrue(r.contains(110, 60))    // far edge inclusive
        XCTAssertFalse(r.contains(5, 5))
        XCTAssertFalse(r.contains(200, 200))
    }

    // Text shaping is only meaningful when a real font is loaded. On a box with
    // no font these assertions are skipped (the toolkit uses toy-text there).
    func testShapeEmptyIsEmpty() {
        XCTAssertTrue(Text.shape("", px: 13).isEmpty)
    }

    func testShapeProducesGlyphs() throws {
        try XCTSkipUnless(Text.available, "no font on this host")
        let g = Text.shape("Displays", px: 13)
        XCTAssertEqual(g.count, 8, "one glyph per Latin letter")
        XCTAssertTrue(g.allSatisfy { $0.face == 0 }, "Latin covered by the primary face")
        XCTAssertTrue(g.allSatisfy { $0.x_advance > 0 }, "every glyph advances the pen")
        // A glyph INDEX, not the codepoint 'D' (0x44).
        XCTAssertNotEqual(g.first?.index, UInt(UInt8(ascii: "D")))
    }

    func testWidgetsLayoutIsSaneAndInBounds() {
        let w = 460.0, h = 360.0
        let L = widgetsLayout(w: w, h: h)

        XCTAssertEqual(L.checks.count, widgetCheckLabels.count)
        XCTAssertEqual(L.checkBoxes.count, widgetCheckLabels.count)
        XCTAssertEqual(L.radios.count, widgetRadioLabels.count)
        XCTAssertEqual(L.radioCenters.count, widgetRadioLabels.count)

        // Every interactive rect stays inside the window.
        func inBounds(_ r: Rect) -> Bool {
            r.x >= 0 && r.y >= 0 && r.x + r.w <= w && r.y + r.h <= h
        }
        for r in L.checks + L.checkBoxes + L.radios {
            XCTAssertTrue(inBounds(r))
        }
        for r in [L.sliderTrack, L.progress, L.popup, L.okButton, L.cancelButton] {
            XCTAssertTrue(inBounds(r))
            XCTAssertGreaterThan(r.w, 0)
        }

        // Checkbox boxes are the standard 14px squares, stacked top to bottom.
        for b in L.checkBoxes {
            XCTAssertEqual(b.w, 14, accuracy: 0.01)
            XCTAssertEqual(b.h, 14, accuracy: 0.01)
        }
        XCTAssertLessThan(L.checkBoxes[0].y, L.checkBoxes[1].y)
        XCTAssertLessThan(L.checkBoxes[1].y, L.checkBoxes[2].y)

        // Cancel sits to the left of OK, both pinned to the bottom band.
        XCTAssertLessThan(L.cancelButton.x + L.cancelButton.w, L.okButton.x + L.okButton.w)
        XCTAssertEqual(L.cancelButton.y, L.okButton.y, accuracy: 0.01)
        XCTAssertGreaterThan(L.okButton.y, h / 2)
    }

    func testWidthScalesAndMetricsPositive() throws {
        try XCTSkipUnless(Text.available, "no font on this host")
        let narrow = Text.width(Text.shape("ii", px: 13))
        let wide = Text.width(Text.shape("WW", px: 13))
        XCTAssertGreaterThan(wide, narrow, "W is wider than i")
        let m = Text.metrics(px: 13)
        XCTAssertGreaterThan(m.ascent, 0)
        XCTAssertGreaterThan(m.descent, 0)
    }

    func testSegmentRectsAndTabsLayout() {
        // segmentRects: equal widths, adjacent, covering the whole rect.
        let r = Rect(10, 20, 240, 22)
        let segs = Draw.segmentRects(r, count: 3)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[0].x, r.x, accuracy: 0.01)
        XCTAssertEqual(segs[2].x + segs[2].w, r.x + r.w, accuracy: 0.01)
        for i in 1..<segs.count {
            XCTAssertEqual(segs[i].x, segs[i - 1].x + segs[i - 1].w, accuracy: 0.01)
            XCTAssertEqual(segs[i].w, segs[0].w, accuracy: 0.01)
        }
        XCTAssertEqual(Draw.segmentRects(r, count: 0).count, 0)

        // Scene layout: segments + pane stay in bounds.
        let w = 480.0, h = 380.0
        let L = tabsLayout(w: w, h: h)
        XCTAssertEqual(L.segments.count, tabsSegmentLabels.count)
        func inBounds(_ x: Rect) -> Bool {
            x.x >= 0 && x.y >= 0 && x.x + x.w <= w && x.y + x.h <= h
        }
        XCTAssertTrue(inBounds(L.pane))
        XCTAssertGreaterThan(L.pane.h, 0)
        for s in L.segments { XCTAssertTrue(inBounds(s)) }
    }

    func testScrollLayoutAndThumb() {
        let w = 360.0, h = 420.0
        let L = scrollLayout(w: w, h: h)
        let vp = L.list.h

        // The content overflows, so there's a real thumb with travel.
        XCTAssertGreaterThan(scrollMaxOffset(viewportH: vp), 0)
        // Paired arrows sit at the bottom, up above down, both in the bar.
        XCTAssertLessThan(L.upArrow.y, L.downArrow.y)
        XCTAssertEqual(L.upArrow.x, L.track.x, accuracy: 0.01)
        XCTAssertLessThanOrEqual(L.downArrow.y + L.downArrow.h, h)

        let maxOff = scrollMaxOffset(viewportH: vp)
        guard let top = scrollThumbRect(track: L.track, offset: 0, viewportH: vp),
              let bot = scrollThumbRect(track: L.track, offset: maxOff, viewportH: vp)
        else { return XCTFail("expected a thumb when content overflows") }

        // Thumb stays within the track and travels top→bottom with the offset.
        XCTAssertGreaterThanOrEqual(top.y, L.track.y - 0.01)
        XCTAssertLessThan(top.y, bot.y)
        XCTAssertLessThanOrEqual(bot.y + bot.h, L.track.y + L.track.h + 0.01)
        XCTAssertEqual(top.h, bot.h, accuracy: 0.01, "thumb length is offset-independent")

        // A viewport taller than the content yields no thumb.
        XCTAssertNil(scrollThumbRect(track: L.track,
                                     offset: 0, viewportH: scrollContentHeight() + 10))
    }
}
