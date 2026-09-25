import XCTest
import CCairo
@testable import AquaDraw
@testable import SVGImport

/// PHASE11 P11.8: SVG artwork becomes a draw list at build time — strictly.
final class SVGImportTests: XCTestCase {
    private var here: String { String(#filePath[..<#filePath.lastIndex(of: "/")!]) }

    private func pixels(_ list: String, _ name: String, size: Int32 = 40) throws -> (Int, Int) -> (Int, Int, Int, Int) {
        let l = try XCTUnwrap(try DrawListFile(parsing: list)[name])
        let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, size, size)!, cr = cairo_create(s)!
        DrawListRunner.run(l, cr, DrawContext(rect: Rect(0, 0, Double(size), Double(size))))
        cairo_surface_flush(s)
        let stride = Int(cairo_image_surface_get_stride(s))
        let d = Array(UnsafeBufferPointer(start: cairo_image_surface_get_data(s)!, count: stride * Int(size)))
        cairo_destroy(cr); cairo_surface_destroy(s)
        return { x, y in let p = y * stride + x * 4; return (Int(d[p + 2]), Int(d[p + 1]), Int(d[p]), Int(d[p + 3])) }
    }

    /// The committed sample is what the importer makes of the committed SVG —
    /// so a change to the importer shows as a change to its output, and the
    /// golden `svg-beacon@2x` pictures that output.
    func testTheSampleImportsToTheCommittedList() throws {
        let svg = try XCTUnwrap(ThemeLoader.readFile(here + "/../../abyss/tests/svg/beacon.svg"))
        let dl = try XCTUnwrap(ThemeLoader.readFile(here + "/../../abyss/tests/svg/beacon.dl"))
        XCTAssertEqual(try SVGImport.drawList(named: "icon.beacon", svg: svg), dl,
                       "re-run: svg2dl icon.beacon abyss/tests/svg/beacon.svg > abyss/tests/svg/beacon.dl")
        XCTAssertNoThrow(try DrawListFile(parsing: dl))
    }

    func testAShapeLandsWhereTheViewBoxPutsIt() throws {
        let dl = try SVGImport.drawList(named: "t", svg: """
        <svg viewBox="0 0 100 100"><rect x="50" y="0" width="50" height="50" fill="#ff0000"/></svg>
        """)
        let px = try pixels(dl, "t")
        XCTAssertEqual(px(30, 10).0, 255, "top-right quarter is red"); XCTAssertEqual(px(30, 10).3, 255)
        XCTAssertEqual(px(10, 10).3, 0); XCTAssertEqual(px(30, 30).3, 0)
    }

    /// Two arcs make a circle: filled at the centre, empty at the corner, and
    /// round (the midpoint of an edge is inside, the box's corner is not).
    func testArcsBecomeCurvesThatAreRound() throws {
        let dl = try SVGImport.drawList(named: "t", svg: """
        <svg viewBox="0 0 40 40"><path d="M 4 20 A 16 16 0 1 1 36 20 A 16 16 0 1 1 4 20 Z" fill="#0000ff"/></svg>
        """)
        let px = try pixels(dl, "t")
        XCTAssertEqual(px(20, 20).2, 255)
        XCTAssertEqual(px(20, 5).3, 255, "the top of the circle")
        XCTAssertEqual(px(6, 6).3, 0, "the box's corner is outside a circle")
    }

    func testTransformsGroupsAndInheritance() throws {
        let dl = try SVGImport.drawList(named: "t", svg: """
        <svg viewBox="0 0 40 40"><g fill="#00ff00" transform="translate(20 0)"><rect width="10" height="10"/></g></svg>
        """)
        let px = try pixels(dl, "t")
        XCTAssertEqual(px(25, 5).1, 255, "moved right by 20, green from the group")
        XCTAssertEqual(px(5, 5).3, 0)
    }

    func testWhatIsOutsideTheSubsetIsRefusedByName() {
        func err(_ svg: String) -> String? {
            do { _ = try SVGImport.drawList(named: "t", svg: svg); return nil }
            catch { return "\(error)" }
        }
        XCTAssertEqual(err("<svg viewBox=\"0 0 1 1\"><text>hi</text></svg>"),
                       "<text> is not in the subset svg2dl imports (svg g path rect circle ellipse line polyline polygon linearGradient)")
        XCTAssertEqual(err("<svg viewBox=\"0 0 1 1\"><path d=\"M0 0 L1 1\" fill-rule=\"evenodd\"/></svg>"),
                       "<path> fill-rule=evenodd: the draw-list format fills nonzero only")
        XCTAssertEqual(err("<svg viewBox=\"0 0 1 1\"><g transform=\"rotate(45)\"/></svg>"),
                       "transform rotate() is not in the subset (translate, scale)")
        XCTAssertEqual(err("<svg viewBox=\"0 0 1 1\"><rect width=\"1\" height=\"1\" fill=\"hsl(1,2,3)\"/></svg>"),
                       "hsl(1,2,3) is not a colour svg2dl reads (#rgb #rrggbb rgb() none url(#id))")
        XCTAssertEqual(err("<svg><rect/></svg>"), "<svg> has neither a viewBox nor a width and height")
        XCTAssertEqual(err("<html/>"), "the document is <html>, not <svg>")
    }
}
