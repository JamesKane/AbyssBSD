import XCTest
import CCairo
@testable import AquaDraw

/// BACKLOG U.7: the pointer's shapes as theme data — a list per shape, its
/// hotspot in its header, and the fallbacks for names a theme does not draw.
final class CursorTests: XCTestCase {
    override func tearDown() { Theme.use(.jaguar) }

    func testAListHeaderMayNameAHotspotInItsOwnCoordinates() throws {
        let f = try DrawListFile(parsing: "list cursor.t hotspot w/4 h-2\n  rect 0 0 w h\n  fill #000000\nend\n")
        let h = try XCTUnwrap(f["cursor.t"]?.hotspot)
        let ctx = DrawContext(rect: Rect(0, 0, 24, 24))
        XCTAssertEqual(DrawListRunner.eval(h.x, ctx), 6)
        XCTAssertEqual(DrawListRunner.eval(h.y, ctx), 22)
        XCTAssertNil(try DrawListFile(parsing: "list plain\n  rect 0 0 w h\nend\n")["plain"]?.hotspot)
    }

    func testAMalformedHeaderIsRefusedWithTheShapeItWants() {
        for bad in ["list c hotspot 1\nend\n", "list c spot 1 2\nend\n", "list c hotspot 1 2 3\nend\n"] {
            XCTAssertThrowsError(try DrawListFile(parsing: bad)) { e in
                XCTAssertEqual((e as? DrawListError)?.message, "want: list <name> [hotspot <x> <y>]", bad)
            }
        }
    }

    /// Jaguar draws 18 shapes; every one of cursor-shape-v1's 34 names lands
    /// on one of them, and never on nothing.
    func testEveryShapeNameResolvesToAShapeJaguarDraws() {
        Theme.use(.jaguar)
        XCTAssertEqual(Cursor.shapeNames.count, 34)
        for n in Cursor.shapeNames {
            XCTAssertNotNil(Theme.lists["cursor." + Cursor.resolve(n)], n)
        }
        XCTAssertEqual(Cursor.resolve("text"), "text")
        XCTAssertEqual(Cursor.resolve("col-resize"), "ew-resize")
        XCTAssertEqual(Cursor.resolve("se-resize"), "nwse-resize")
        XCTAssertEqual(Cursor.resolve("vertical-text"), "text")
        XCTAssertEqual(Cursor.resolve("zoom-in"), "default")
        XCTAssertEqual(Cursor.resolve("no-such-shape"), "default")
    }

    func testTheArrowsHotspotIsItsTipAndItIsDrawnThere() throws {
        Theme.use(.jaguar)
        let (hx, hy) = Cursor.hotspot("default")
        XCTAssertEqual(hx, 5); XCTAssertEqual(hy, 3)
        XCTAssertEqual(Cursor.hotspot("text").x, 12)
        // Drawn: the body is black just below-right of the tip, and the cell's
        // far corner is empty.
        let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 24, 24)!
        let cr = cairo_create(s)!
        Cursor.draw("default", cr, x: 0, y: 0)
        cairo_surface_flush(s)
        let d = cairo_image_surface_get_data(s)!, stride = Int(cairo_image_surface_get_stride(s))
        let px = { (x: Int, y: Int) in (Int(d[y * stride + x * 4 + 2]), Int(d[y * stride + x * 4 + 3])) }
        XCTAssertEqual(px(7, 9).0, 0); XCTAssertEqual(px(7, 9).1, 255)
        XCTAssertEqual(px(22, 2).1, 0)
        cairo_destroy(cr); cairo_surface_destroy(s)
    }
}

/// BACKLOG U.7b: the XCursor file libXcursor and libwayland-cursor read.
final class XCursorFileTests: XCTestCase {
    override func tearDown() { Theme.use(.jaguar) }

    private func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    func testTheFileIsLibXcursorsFormatOneImagePerSize() throws {
        Theme.use(.jaguar)
        let images = XCursorTheme.sizes.compactMap { Cursor.rasterise("default", scale: Double($0) / 24) }
        XCTAssertEqual(images.map(\.size), [24, 32, 48, 64])
        let b = XCursorTheme.encode(images)
        XCTAssertEqual(Array(b[0..<4]), Array("Xcur".utf8))
        XCTAssertEqual(u32(b, 4), 16)
        XCTAssertEqual(u32(b, 8), 0x10000)
        XCTAssertEqual(u32(b, 12), 4)
        // The second table entry points at the 32-point image, whose chunk
        // header says so, with the arrow's hotspot scaled (5,3 × 4/3).
        XCTAssertEqual(u32(b, 16 + 12 + 4), 32)
        let at = Int(u32(b, 16 + 12 + 8))
        XCTAssertEqual(u32(b, at), 36)
        XCTAssertEqual(u32(b, at + 4), 0xfffd0002)
        XCTAssertEqual(u32(b, at + 16), 32)
        XCTAssertEqual(u32(b, at + 20), 32)
        XCTAssertEqual(u32(b, at + 24), 7)
        XCTAssertEqual(u32(b, at + 28), 4)
        XCTAssertEqual(b.count, 16 + 12 * 4 + (36 * 4) + 4 * (24 * 24 + 32 * 32 + 48 * 48 + 64 * 64))
    }

    func testEveryX11NameIsADrawnShapesName() {
        for (x, css) in XCursorTheme.x11Names {
            XCTAssertTrue(Cursor.shapeNames.contains(css), "\(x) → \(css) is not a cursor-shape name")
        }
    }
}
