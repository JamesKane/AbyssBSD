import XCTest
import CCairo
import Dispatch
import Foundation
@testable import AquaDraw

/// PHASE11 P11.3: the draw-list interpreter, pure where it can be and checked
/// in pixels where it cannot.
final class DrawListTests: XCTestCase {
    override func tearDown() { Theme.use(.jaguar) }

    private func parse(_ s: String) throws -> DrawListFile { try DrawListFile(parsing: s) }

    private func error(_ s: String) -> DrawListError? {
        do { _ = try parse(s); return nil } catch let e as DrawListError { return e } catch { return nil }
    }

    /// Render one list into a w×h surface and hand back a pixel reader.
    private func render(_ src: String, _ name: String = "t", w: Int32 = 40, h: Int32 = 20,
                        state: DrawState = .normal, label: String = "",
                        params: [String: Double] = [:]) throws -> (Int, Int) -> (Int, Int, Int, Int) {
        let f = try parse(src)
        let list = try XCTUnwrap(f[name])
        let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h)!
        let cr = cairo_create(s)!
        DrawListRunner.run(list, cr, DrawContext(rect: Rect(0, 0, Double(w), Double(h)),
                                                 state: state, label: label, parameters: params))
        cairo_surface_flush(s)
        let d = cairo_image_surface_get_data(s)!, stride = Int(cairo_image_surface_get_stride(s))
        cairo_destroy(cr)
        let copy = Array(UnsafeBufferPointer(start: d, count: stride * Int(h)))
        cairo_surface_destroy(s)
        return { x, y in   // (r, g, b, a), premultiplied as cairo stores them
            let p = y * stride + x * 4
            return (Int(copy[p + 2]), Int(copy[p + 1]), Int(copy[p]), Int(copy[p + 3]))
        }
    }

    // MARK: parsing

    func testEveryMistakeNamesItsLine() {
        XCTAssertEqual(error("list a\n  frobnicate 1\nend")?.line, 2)
        XCTAssertTrue(error("list a\n  frobnicate 1\nend")!.message.contains("is not an op"))
        XCTAssertEqual(error("list a\n  rect 0 0 w\nend")?.line, 2)
        XCTAssertEqual(error("list a\n  rect 0 0 w h\n  fill notAToken\nend")?.message,
                       "notAToken is not a colour token")
        XCTAssertEqual(error("list a\n  when sleepy fill #ffffff\nend")?.line, 2)
        XCTAssertEqual(error("list a\n  rect 0 0 (w-2 h\nend")?.message, "(w-2 h: a ( is not closed")
        XCTAssertEqual(error("list a\n  rect 0 0 w*z h\nend")?.message,
                       "w*z: z is not an operand (a number, w, h, @metric, $parameter, textw, min or max)")
        XCTAssertEqual(error("list a\n  rect 0 0 @tall h\nend")?.line, 2, "an unknown metric is refused when parsed")
        XCTAssertEqual(error("list a\n  fill shift(menuText, 3)\nend")?.message, "shift(menuText, 3): want shift(colour, -1…1)")
        XCTAssertEqual(error("list a\n  rect 0 0 w h\n")?.message, "list a has no end")
        XCTAssertEqual(error("fill #ffffff")?.message, "fill outside a list")
        XCTAssertEqual(error("list a\nend\nlist a\nend")?.message, "a second list called a")
        XCTAssertNil(error("list a # a comment\n  rect 0 0 w h  # another\n  fill #102030 # and here\nend"),
                     "a # that is not a colour starts a comment")
    }

    // MARK: pixels

    func testASolidFillIsExact() throws {
        let px = try render("list t\n  rect 0 0 w h\n  fill #3f6fdf\nend")
        XCTAssertEqual(px(10, 10).0, 0x3f); XCTAssertEqual(px(10, 10).1, 0x6f)
        XCTAssertEqual(px(10, 10).2, 0xdf); XCTAssertEqual(px(10, 10).3, 255)
    }

    func testATokenIsReadFromTheCurrentThemeWhenTheListRuns() throws {
        var t = ThemeTokens.jaguar; t.menuHighlight = Color(hex: 0x102030)
        Theme.use(t)
        let px = try render("list t\n  rect 0 0 w h\n  fill menuHighlight\nend")
        XCTAssertEqual(px(5, 5).0, 0x10, "a theme change reaches a list parsed before it")
    }

    func testStatesPickTheirOps() throws {
        let src = "list t\n  rect 0 0 w h\n  fill #ff0000\n  when pressed fill #0000ff\n  unless disabled,pressed fill #00ff00\nend"
        XCTAssertEqual(try render(src)(5, 5).1, 255, "normal: the unless applies")
        XCTAssertEqual(try render(src, state: .pressed)(5, 5).2, 255, "pressed: blue")
        XCTAssertEqual(try render(src, state: .disabled)(5, 5).0, 255, "disabled: only the base")
        let normalOnly = "list t\n  rect 0 0 w h\n  when normal fill #ff0000\nend"
        XCTAssertEqual(try render(normalOnly)(5, 5).0, 255)
        XCTAssertEqual(try render(normalOnly, state: .hover)(5, 5).3, 0, "`when normal` is the empty set only")
    }

    func testABevelLightsTopLeftAndShadesBottomRight() throws {
        let px = try render("list t\n  rect 0 0 w h\n  fill #808080\n  bevel 1 #ffffff #000000\nend")
        XCTAssertEqual(px(10, 0).0, 255, "top edge light")
        XCTAssertEqual(px(0, 10).0, 255, "left edge light")
        XCTAssertEqual(px(10, 19).0, 0, "bottom edge shade")
        XCTAssertEqual(px(39, 10).0, 0, "right edge shade")
        XCTAssertEqual(px(10, 10).0, 0x80, "the face is untouched")
    }

    func testOperandsCanUseTheSizeMetricsAndParameters() throws {
        // A 1-px-wide bar at x = w/2 and one at x = 2*$gap.
        let px = try render("""
        list t
          rect w/2 0 1 h
          fill #ff0000
          rect 2*$gap 0 1 h
          fill #00ff00
          rect 0 @titleBarHeight 1 1
          fill #0000ff
        end
        """, w: 40, h: 30, params: ["gap": 3])
        XCTAssertEqual(px(20, 5).0, 255); XCTAssertEqual(px(19, 5).0, 0)
        XCTAssertEqual(px(6, 5).1, 255)
        XCTAssertEqual(px(0, 22).2, 255, "@titleBarHeight is Jaguar's 22")
    }

    func testArithmeticIsCalcNotALanguage() throws {
        let ctx = DrawContext(rect: Rect(0, 0, 40, 30), parameters: ["v": 0.5])
        func v(_ s: String) throws -> Double { DrawListRunner.eval(try DrawListParser.operand(s, line: 1), ctx) }
        XCTAssertEqual(try v("w-h/2-3"), 22, "* before -, left to right")
        XCTAssertEqual(try v("(w-h)/2"), 5)
        XCTAssertEqual(try v("min(w,h)*0.5"), 15)
        XCTAssertEqual(try v("max(h, $v*w)"), 30)
        XCTAssertEqual(try v("-h+1"), -29)
        XCTAssertEqual(try v("@fontSize*0.35"), 13 * 0.35)
        XCTAssertEqual(try v("@finder.rowHeight*2"), 36, "a layer-3 metric, by its dotted name")
        XCTAssertEqual(try v("w/0"), 0, "a division by zero is 0, not a trap")
    }

    func testALinearGradientRunsEndToEnd() throws {
        let px = try render("list t\n  rect 0 0 w h\n  fill linear 0 0 w 0 stops 0 #000000 1 #ffffff\nend", w: 100)
        XCTAssertLessThan(px(0, 5).0, 5)
        XCTAssertGreaterThan(px(99, 5).0, 250)
        XCTAssertEqual(Double(px(50, 5).0), 128, accuracy: 4)
    }

    func testAConicSweepIsRightAtItsQuarters() throws {
        let px = try render("""
        list t
          rect 0 0 w h
          fill conic 50 50 50 stops 0 #ff0000 0.5 #0000ff 1 #ff0000
        end
        """, w: 100, h: 100)
        XCTAssertGreaterThan(px(95, 51).0, 240, "0° red")
        XCTAssertGreaterThan(px(5, 50).2, 240, "180° blue")
        let q = px(51, 95)   // 90°: half way red→blue
        XCTAssertEqual(Double(q.0), 128, accuracy: 12); XCTAssertEqual(Double(q.2), 128, accuracy: 12)
    }

    func testStripesAlternate() throws {
        let px = try render("list t\n  rect 0 0 w h\n  fill stripes 0 2 #ffffff 2 #000000\nend")
        XCTAssertEqual(px(0, 5).0, 255); XCTAssertEqual(px(1, 5).0, 255)
        XCTAssertEqual(px(2, 5).0, 0); XCTAssertEqual(px(3, 5).0, 0)
        XCTAssertEqual(px(4, 5).0, 255, "and repeat")
        let across = try render("list t\n  rect 0 0 w h\n  fill stripes 90 1 #ffffff 2 #000000\nend")
        XCTAssertEqual(across(7, 0).0, 255); XCTAssertEqual(across(7, 1).0, 0)
        XCTAssertEqual(across(7, 3).0, 255, "90° runs the bands across, as brushed metal wants")
        XCTAssertEqual(across(30, 3).0, 255)
    }

    func testNoiseIsDeterministicAndSeeded() throws {
        func grab(_ seed: Int) throws -> [Int] {
            let px = try render("list t\n  rect 0 0 w h\n  fill noise \(seed) 0.5\nend")
            return (0..<20).map { px($0, 3).3 }
        }
        XCTAssertEqual(try grab(7), try grab(7), "the same seed is the same tile — goldens depend on it")
        XCTAssertNotEqual(try grab(7), try grab(8))
        XCTAssertTrue(try grab(7).allSatisfy { $0 <= 128 }, "alpha 0.5 bounds the noise")
    }

    func testAGlowReachesOutsideItsShapeAndFades() throws {
        DrawListRunner.glowCache.removeAll()
        let src = "list t\n  rect 20 20 20 20\n  glow #00e5ff 8\nend"
        let px = try render(src, w: 60, h: 60)
        let near = px(18, 30).3, far = px(8, 30).3
        XCTAssertGreaterThan(near, 0, "the halo reaches past the edge")
        XCTAssertGreaterThan(near, far, "and fades with distance")
        XCTAssertEqual(px(0, 0).3, 0, "and ends")
        let made = DrawListRunner.glowsComputed
        _ = try render(src, w: 60, h: 60)
        XCTAssertEqual(DrawListRunner.glowsComputed, made, "the second draw of the same glow is cached")
    }

    func testTrackingWidensTextAndUpperChangesCase() throws {
        guard Text.available else { throw XCTSkip("no fonts") }
        func inkRight(_ opts: String) throws -> Int {
            let px = try render("list t\n  rect 0 0 w h\n  text \"abc\" 0 h/2 \(opts) color=#ffffff\nend", w: 120, h: 20)
            return (0..<120).last { x in (0..<20).contains { px(x, $0).3 > 0 } } ?? 0
        }
        let plain = try inkRight(""), tracked = try inkRight("tracking=4")
        XCTAssertGreaterThanOrEqual(tracked - plain, 7, "two gaps of 4 px (the last glyph's is outside the ink)")
        XCTAssertGreaterThan(try inkRight("upper"), plain, "ABC is wider than abc")
    }

    /// P11.5's additions: curves in a path, arcs, faded colours, dashes.
    func testCurvesArcsFadesAndDashes() throws {
        // A curve bulging right of the line x=10 fills pixels the straight
        // path would not.
        let bulge = try render("list t\n  path 10 0 curve 30 5 30 15 10 20 close\n  fill #ffffff\nend")
        XCTAssertGreaterThan(bulge(18, 10).3, 200); XCTAssertEqual(bulge(5, 10).3, 0)
        // An arc from 0 to π/2 is the lower-right quarter only.
        let arc = try render("list t\n  arc 20 0 10 0 1.5707963\n  stroke #ffffff 2\nend", w: 40, h: 20)
        XCTAssertGreaterThan(arc(27, 7).3, 100, "on the quarter")
        XCTAssertEqual(arc(13, 7).3, 0, "not the lower-left quarter")
        // fade(c, $p) multiplies alpha by a parameter.
        let half = try render("list t\n  rect 0 0 w h\n  fill fade(#ffffff, $p)\nend", params: ["p": 0.5])
        XCTAssertEqual(Double(half(5, 5).3), 128, accuracy: 1)
        XCTAssertEqual(try render("list t\n  rect 0 0 w h\n  fill fade(#ffffff, $p)\nend")(5, 5).3, 0,
                       "an absent parameter fades to nothing")
        // dash=2,2 leaves gaps along the line.
        let dash = try render("list t\n  path 0 10.5 40 10.5\n  stroke #ffffff 1 dash=2,2\nend")
        XCTAssertEqual(dash(0, 10).3, 255); XCTAssertEqual(dash(2, 10).3, 0); XCTAssertEqual(dash(4, 10).3, 255)
        // and the dash does not leak into the next stroke.
        let after = try render("list t\n  path 0 5.5 40 5.5\n  stroke #ffffff 1 dash=2,2\n  path 0 10.5 40 10.5\n  stroke #ffffff 1\nend")
        XCTAssertEqual(after(2, 10).3, 255)
        XCTAssertEqual(error("list t\n  path 0 0 curve 1 2 3\nend")?.line, 2, "a curve wants six operands")
        XCTAssertEqual(error("list t\n  path 0 0 1 1\n  stroke #ffffff 1 dash=\nend")?.message, "dash=: want dash=on,off,… in pixels")
    }

    /// A cast shadow (P11.8): the shape's blurred mask, moved — so it lands
    /// beside the shape, on the side it was cast to, and not on the other.
    func testACastShadowFallsWhereItIsCast() throws {
        let px = try render("list t\n  rect 20 20 12 12\n  shadow #000000/0.8 6 6 3\nend", w: 60, h: 60)
        XCTAssertGreaterThan(px(35, 35).3, 100, "down and right: under the moved square, outside the shape")
        XCTAssertEqual(px(16, 16).3, 0, "nothing up and left")
    }

    func testTheSampleSheetParses() throws {
        let here = String(#filePath[..<#filePath.lastIndex(of: "/")!])
        let text = try XCTUnwrap(ThemeLoader.readFile(here + "/../../abyss/tests/drawlist-sample.dl"))
        let f = try parse(text)
        XCTAssertEqual(Set(f.lists.keys), ["mui-button", "brushed", "anodized", "knob", "led", "lcd"])
    }

    /// The bench (P11.3): what one run of each sample list costs, glows cached.
    /// It prints; the bound is only there to catch an interpreter gone quadratic.
    func testTheInterpreterIsCheapEnoughToDrawEveryFrame() throws {
        let here = String(#filePath[..<#filePath.lastIndex(of: "/")!])
        let f = try parse(try XCTUnwrap(ThemeLoader.readFile(here + "/../../abyss/tests/drawlist-sample.dl")))
        let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 260, 120)!
        let cr = cairo_create(s)!
        defer { cairo_destroy(cr); cairo_surface_destroy(s) }
        let sizes: [String: (Double, Double)] = ["mui-button": (90, 24), "brushed": (260, 26), "anodized": (200, 110),
                                                 "knob": (54, 54), "led": (14, 14), "lcd": (120, 40)]
        for name in sizes.keys.sorted() {
            let list = try XCTUnwrap(f[name]), (w, h) = sizes[name]!
            let ctx = DrawContext(rect: Rect(0, 0, w, h), state: .focused, label: "Save", parameters: [:])
            DrawListRunner.run(list, cr, ctx)   // warm the glow cache
            let n = 200
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<n { DrawListRunner.run(list, cr, ctx) }
            let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(n) / 1000
            print("drawlist bench: \(name) \(Int(w))x\(Int(h)) \(String(format: "%.1f", us)) µs/run")
            XCTAssertLessThan(us, 5000, name)
        }
    }
}
