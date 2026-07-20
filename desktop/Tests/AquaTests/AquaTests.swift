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
}
