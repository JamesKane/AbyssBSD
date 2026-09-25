import XCTest
@testable import AquaDraw
@testable import Aqua

/// PHASE11 P11.6: the frame is laid out once, from the theme, and painted and
/// hit-tested from that one answer.
final class ChromeTests: XCTestCase {
    override func tearDown() { Theme.use(.jaguar) }

    private func use(_ ini: String) throws {
        Theme.use(try ThemeLoader.parse(ini).tokens)
    }

    /// Jaguar's frame is where P9's code put it: the three lights from the
    /// inset, `spacing` apart, and the pill 8 px from the right.
    func testJaguarsFrameIsWhereItAlwaysWas() {
        let l = windowChrome(w: 400, h: 300)
        XCTAssertEqual(l.gadgets.map(\.gadget), [.close, .minimize, .zoom, .pill])
        XCTAssertEqual(l.rect(.close), Rect(10, 4.5, 13, 13))
        XCTAssertEqual(l.rect(.minimize), Rect(30, 4.5, 13, 13))
        XCTAssertEqual(l.rect(.zoom), Rect(50, 4.5, 13, 13))
        XCTAssertEqual(l.rect(.pill), Rect(370, 4.5, 22, 13))
        XCTAssertEqual(l.titleAlign, .center); XCTAssertEqual(l.titleX, 200)
        XCTAssertEqual(l.body, Rect(0, 22, 400, 278))
    }

    /// A foreign window has no toolbar, so no pill — in the layout, and so in
    /// both the paint and the hit-test (P11.1 found it painted where undertow's
    /// hit-test said "title").
    func testAForeignFrameHasNoPill() {
        let l = windowChrome(w: 400, h: 300, foreign: true)
        XCTAssertNil(l.rect(.pill))
        XCTAssertEqual(chromeHit(l, x: 380, y: 11), .title)
        XCTAssertEqual(chromeHit(windowChrome(w: 400, h: 300), x: 380, y: 11), .gadget(.pill))
    }

    /// Every gadget laid out is hit at every point inside it, and nowhere is
    /// hit as a gadget that is not laid out: paint and hit-test read the same
    /// rects, so this is the §2.9 property itself.
    func testEveryGadgetIsHitWhereItIsLaidOut() throws {
        for ini in ["", "[chrome]\nleft = close minimize zoom\nright = depth pill\ntitle = left",
                    "[chrome]\nleft = depth\nright = zoom minimize close",
                    "[chrome]\nleft = pill close\nright = depth"] {
            try use(ini)
            for foreign in [false, true] {
                let l = windowChrome(w: 500, h: 300, foreign: foreign)
                for g in l.gadgets {
                    for dx in stride(from: 0.5, to: g.rect.w, by: 1) {
                        XCTAssertEqual(chromeHit(l, x: g.rect.x + dx, y: g.rect.y + g.rect.h / 2),
                                       .gadget(g.gadget), "\(ini) \(g.gadget) at +\(dx)")
                    }
                }
                // No two gadgets overlap, and all sit in the title bar.
                for (i, a) in l.gadgets.enumerated() {
                    XCTAssertLessThanOrEqual(a.rect.y + a.rect.h, l.titleBar.h)
                    for b in l.gadgets[(i + 1)...] {
                        XCTAssertTrue(a.rect.x + a.rect.w <= b.rect.x || b.rect.x + b.rect.w <= a.rect.x,
                                      "\(ini): \(a.gadget) overlaps \(b.gadget)")
                    }
                }
            }
        }
    }

    /// The right side is laid from the edge inwards, in the order written:
    /// `right = depth pill` puts the pill at the edge and depth to its left.
    func testTheRightSideReadsLeftToRight() throws {
        try use("[chrome]\nright = depth pill\ntitle = left\ntitleWeight = bold")
        let l = windowChrome(w: 400, h: 300)
        let depth = try XCTUnwrap(l.rect(.depth)), pill = try XCTUnwrap(l.rect(.pill))
        XCTAssertEqual(pill.x + pill.w, 392)
        XCTAssertEqual(depth.x + depth.w, pill.x - 7, "the lights' own gap")
        XCTAssertTrue(l.titleBold)
        XCTAssertEqual(l.titleX, 63 + 7 + 4, "a left title starts after the lights")
        XCTAssertEqual(windowChromeHit(x: depth.x + 6, y: 11, w: 400, h: 300), .depth)
    }

    func testTheResizeBandIsTheThemes() throws {
        try use("[metrics]\nchrome.resizeBand = 10\nchrome.resizeCorner = 20")
        let l = windowChrome(w: 400, h: 300)
        XCTAssertEqual(chromeHit(l, x: 200, y: 291), .resize(.bottom))
        XCTAssertEqual(chromeHit(l, x: 385, y: 285), .resize(.bottomRight))
        XCTAssertEqual(chromeHit(l, x: 200, y: 289), .content)
    }

    func testChromeMistakesAreRefusedByName() {
        func problems(_ s: String) -> [String] {
            do { _ = try ThemeLoader.parse(s); return [] }
            catch let e as ThemeError { return e.problems } catch { return ["\(error)"] }
        }
        XCTAssertEqual(problems("[chrome]\nleft = close sparkle"),
                       ["[chrome] left = close sparkle: sparkle is not a gadget (close minimize zoom depth pill)"])
        XCTAssertEqual(problems("[chrome]\nleft = close\nright = close"), ["[chrome] close is on the left already"])
        XCTAssertEqual(problems("[chrome]\ntitle = right"), ["[chrome] title = right: want left or center"])
        XCTAssertEqual(problems("[chrome]\ntitleWeight = heavy"), ["[chrome] titleWeight = heavy: want regular or bold"])
        XCTAssertEqual(problems("[chrome]\ngadgets = close"), ["[chrome] gadgets is not a token"])
    }
}
