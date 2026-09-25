import XCTest
import CCairo
@testable import AquaDraw

/// PHASE11 P11.9: a second theme is data — and every theme the tree ships
/// loads, strictly, in every scheme it has.
final class ThemeSetTests: XCTestCase {
    private var themes: String { String(#filePath[..<#filePath.lastIndex(of: "/")!]) + "/../../themes" }
    override func tearDown() { Theme.use(.jaguar) }

    private func dirs() -> [String] {
        var out: [String] = []
        if let d = opendir(themes) {
            while let e = readdir(d) {
                let n = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if !n.hasPrefix("."), access(themes + "/" + n + "/theme.ini", F_OK) == 0 { out.append(n) }
            }
            closedir(d)
        }
        return out.sorted()
    }

    func testEveryShippedThemeLoadsInEverySchemeWithNothingToSay() throws {
        let names = dirs()
        XCTAssertGreaterThanOrEqual(names.count, 2, "Aqua and a second theme: \(names)")
        for n in names {
            let text = try XCTUnwrap(ThemeLoader.readFile("\(themes)/\(n)/theme.ini"))
            let base = try ThemeLoader.parse(text)
            XCTAssertTrue(base.warnings.isEmpty, "\(n): \(base.warnings)")
            for s in base.schemes {
                let t = try ThemeLoader.parse(text, scheme: s)
                XCTAssertTrue(t.warnings.isEmpty, "\(n) \(s): \(t.warnings)")
            }
            let (lists, w) = try ThemeLoader.loadLists("\(themes)/\(n)")
            XCTAssertTrue(w.isEmpty, "\(n) ships a list the toolkit never draws: \(w)")
            if n != "aqua" { XCTAssertGreaterThan(lists?.lists.count ?? 0, 60, "\(n) is a look, not a few overrides") }
        }
    }

    func testAThemeParameterReachesAList() throws {
        let t = try ThemeLoader.parse("[parameters]\nk = 0.5 0 1")
        Theme.use(t.tokens, parameters: ["k": 0.5])
        let l = try XCTUnwrap(try DrawListFile(parsing: "list t\n  rect 0 0 w h\n  fill fade(#ffffff, $k)\nend")["t"])
        let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 4, 4)!, cr = cairo_create(s)!
        DrawListRunner.run(l, cr, DrawContext(rect: Rect(0, 0, 4, 4)))
        cairo_surface_flush(s)
        XCTAssertEqual(Double(cairo_image_surface_get_data(s)![3]), 128, accuracy: 1)
        XCTAssertEqual(DrawListRunner.eval(.parameter("k"), DrawContext(rect: Rect(0, 0, 1, 1), parameters: ["k": 0.9])), 0.9,
                       "a widget's own value wins")
        cairo_destroy(cr); cairo_surface_destroy(s)
    }

    /// A role's case and tracking apply where it is shaped, so a measurement
    /// and the drawing agree without either knowing (§2.9).
    func testARolesCaseAndTrackingAreInTheMeasurement() throws {
        guard Text.available else { throw XCTSkip("no fonts") }
        let plain = Text.width(Text.shape("abc", px: 20, role: .chrome))
        var t = ThemeTokens.jaguar
        t.roleUpper = ["chrome"]; t.roleTracking = ["chrome": 0.1]
        Theme.use(t)
        let styled = Text.shape("abc", px: 20, role: .chrome)
        let upperOnly = Text.shape("ABC", px: 20, role: .interface)
        XCTAssertEqual(styled.map(\.index), upperOnly.map(\.index), "upper-cased")
        XCTAssertEqual(Text.width(styled), Text.width(upperOnly) + 3 * 2, accuracy: 0.01, "0.1 em × 20 px per glyph")
        XCTAssertNotEqual(Text.width(styled), plain)
        XCTAssertEqual(Text.width(Text.shape("abc", px: 20, role: .interface)), Text.width(Text.shape("abc", px: 20)),
                       "other roles untouched")
    }

    func testGhostEightsDotsAndHalo() throws {
        guard Text.available else { throw XCTSkip("no fonts") }
        func render(_ src: String, w: Int32 = 80, h: Int32 = 30, label: String = "") throws -> [UInt8] {
            let l = try XCTUnwrap(try DrawListFile(parsing: src)["t"])
            let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h)!, cr = cairo_create(s)!
            DrawListRunner.run(l, cr, DrawContext(rect: Rect(0, 0, Double(w), Double(h)), label: label))
            cairo_surface_flush(s)
            let n = Int(cairo_image_surface_get_stride(s)) * Int(h)
            let out = Array(UnsafeBufferPointer(start: cairo_image_surface_get_data(s)!, count: n))
            cairo_destroy(cr); cairo_surface_destroy(s)
            return out
        }
        let lit = try render("list t\n  text $label 4 h/2 color=#ffffff\nend", label: "1:1")
        let ghosted = try render("list t\n  text $label 4 h/2 color=#ffffff ghost=eights ghostalpha=0.5\nend", label: "1:1")
        XCTAssertGreaterThan(ghosted.filter { $0 > 0 }.count, lit.filter { $0 > 0 }.count, "8:8 under 1:1 adds ink")
        let dots = try render("list t\n  rect 0 0 w h\n  fill dots 10 1.5 #ffffff\nend", w: 40, h: 40)
        let stride = dots.count / 40
        XCTAssertGreaterThan(dots[5 * stride + 5 * 4 + 3], 200, "a dot at the tile's centre")
        XCTAssertEqual(dots[0 * stride + 0 * 4 + 3], 0, "and nothing between")
        XCTAssertGreaterThan(dots[15 * stride + 25 * 4 + 3], 200, "repeating")
        let plain = try render("list t\n  text \"H\" 40 h/2 center color=#ffffff\nend")
        let halo = try render("list t\n  text \"H\" 40 h/2 center color=#ffffff halo=#00e5ff halor=4\nend")
        XCTAssertGreaterThan(halo.filter { $0 > 0 }.count, plain.filter { $0 > 0 }.count, "the halo reaches past the glyph")
    }
}
