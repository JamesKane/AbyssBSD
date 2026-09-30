// Cursors — the pointer's shapes, as theme data (BACKLOG U.7).
//
// A cursor is a draw list called `cursor.<name>` in the theme's icons/ —
// Jaguar's in themes/aqua/icons/cursors.dl, compiled in behind every theme as
// the rest of the icon set is — drawn in a `cursor.size` square, with its
// hotspot in the list's header. The names are cursor-shape-v1's, which are
// CSS's: `default`, `text`, `pointer`, `ew-resize`… A theme need not draw all
// 34 of them; a name it does not draw falls back along a short chain to one
// it does (every sizing arrow to its axis, `vertical-text` to `text`), and
// finally to `default`.
//
// Painting is AquaDraw's; putting the picture on the screen is the
// compositor's, which rasterises each shape once per scale and theme.

import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Cursor {
    /// The shape cursor-shape-v1 calls `name`, as this theme draws it: the
    /// name of the list that will draw, after the fallbacks.
    public static func resolve(_ name: String) -> String {
        var n = name
        for _ in 0..<4 {
            if Theme.lists["cursor." + n] != nil { return n }
            guard let next = fallback[n] else { break }
            n = next
        }
        return "default"
    }

    /// The names every theme is asked for, in cursor-shape-v1's order.
    public static let shapeNames = [
        "default", "context-menu", "help", "pointer", "progress", "wait", "cell", "crosshair",
        "text", "vertical-text", "alias", "copy", "move", "no-drop", "not-allowed", "grab",
        "grabbing", "e-resize", "n-resize", "ne-resize", "nw-resize", "s-resize", "se-resize",
        "sw-resize", "w-resize", "ew-resize", "ns-resize", "nesw-resize", "nwse-resize",
        "col-resize", "row-resize", "all-scroll", "zoom-in", "zoom-out",
    ]

    /// Where a name goes when the theme does not draw it. Meaning, not look:
    /// one edge's arrow is its axis's, a crosshair serves for a cell.
    static let fallback: [String: String] = [
        "e-resize": "ew-resize", "w-resize": "ew-resize", "col-resize": "ew-resize",
        "n-resize": "ns-resize", "s-resize": "ns-resize", "row-resize": "ns-resize",
        "ne-resize": "nesw-resize", "sw-resize": "nesw-resize",
        "nw-resize": "nwse-resize", "se-resize": "nwse-resize",
        "all-scroll": "move", "vertical-text": "text", "cell": "crosshair",
        "no-drop": "not-allowed", "progress": "wait", "zoom-in": "default", "zoom-out": "default",
    ]

    /// The cell's size, in points.
    public static var size: Double { Theme.current.cursorSize }

    /// The hotspot of the shape `name` resolves to, in points from the cell's
    /// top-left. The cell's centre if the list names none.
    public static func hotspot(_ name: String) -> (x: Double, y: Double) {
        let s = size
        guard let l = Theme.lists["cursor." + resolve(name)], let h = l.hotspot else { return (s / 2, s / 2) }
        let ctx = DrawContext(rect: Rect(0, 0, s, s))
        return (DrawListRunner.eval(h.x, ctx), DrawListRunner.eval(h.y, ctx))
    }

    /// Draw the shape `name` resolves to, its cell's top-left at (x, y).
    public static func draw(_ name: String, _ cr: OpaquePointer, x: Double, y: Double) {
        guard let l = Theme.lists["cursor." + resolve(name)] else { return }
        cairo_new_path(cr)
        DrawListRunner.run(l, cr, DrawContext(rect: Rect(x, y, size, size)))
    }
}

// MARK: - Pixels, and the XCursor theme (U.7b)

/// One shape, rasterised: premultiplied ARGB, row-major, `size`×`size`.
public struct CursorImage: Sendable {
    public let size: Int
    public let pixels: [UInt32]
    /// The hotspot in these pixels.
    public let hotX: Int, hotY: Int
}

extension Cursor {
    /// The shape `name` resolves to, drawn at `scale` — the one rasteriser,
    /// so the compositor's cursor and the XCursor theme a toolkit loads are
    /// the same pixels (U.7b's test holds them to it).
    public static func rasterise(_ name: String, scale: Double) -> CursorImage? {
        let px = Int32((size * scale).rounded(.up))
        guard px > 0, let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, px, px),
              let cr = cairo_create(surface) else { return nil }
        defer { cairo_destroy(cr); cairo_surface_destroy(surface) }
        cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
        cairo_set_source_rgba(cr, 0, 0, 0, 0)
        cairo_paint(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        cairo_scale(cr, scale, scale)
        let was = Text.renderScale
        Text.renderScale = Int32(scale.rounded(.up))
        defer { Text.renderScale = was }
        draw(name, cr, x: 0, y: 0)
        cairo_surface_flush(surface)
        guard let data = cairo_image_surface_get_data(surface) else { return nil }
        let stride = Int(cairo_image_surface_get_stride(surface)), n = Int(px)
        var out = [UInt32](repeating: 0, count: n * n)
        data.withMemoryRebound(to: UInt32.self, capacity: stride / 4 * n) { p in
            for y in 0..<n { for x in 0..<n { out[y * n + x] = p[y * (stride / 4) + x] } }
        }
        let h = hotspot(name)
        return CursorImage(size: n, pixels: out, hotX: Int((h.x * scale).rounded()), hotY: Int((h.y * scale).rounded()))
    }
}

/// An XCursor theme on disk, from the theme's cursor lists (U.7b).
///
/// Toolkits that draw their own cursor — GTK 3, SDL, anything through
/// libwayland-cursor or libXcursor, and X clients under Xwayland — load an
/// XCursor theme by name (`XCURSOR_THEME`) from `XCURSOR_PATH`. Without one of
/// ours they draw Adwaita's arrow over our windows. This writes the current
/// theme's shapes as such a theme: every cursor-shape (CSS) name as a file, and
/// the X11 names older toolkits ask for as links to them.
public enum XCursorTheme {
    /// The nominal sizes written: the cell at 1x, 1.33x, 2x and 2.67x.
    public static let sizes = [24, 32, 48, 64]

    /// X11's names, and the CSS name each is. GTK 3, SDL and X clients ask
    /// for these; a missing one falls back to a toolkit's own choice.
    public static let x11Names: [String: String] = [
        "left_ptr": "default", "arrow": "default", "top_left_arrow": "default",
        "xterm": "text", "ibeam": "text",
        "hand1": "pointer", "hand2": "pointer", "pointing_hand": "pointer",
        "watch": "wait", "left_ptr_watch": "progress", "half-busy": "progress",
        "question_arrow": "help", "whats_this": "help",
        "cross": "crosshair", "tcross": "crosshair",
        "fleur": "move", "size_all": "move",
        "sb_h_double_arrow": "ew-resize", "h_double_arrow": "ew-resize", "size_hor": "ew-resize",
        "left_side": "w-resize", "right_side": "e-resize", "split_h": "col-resize",
        "sb_v_double_arrow": "ns-resize", "v_double_arrow": "ns-resize", "size_ver": "ns-resize",
        "top_side": "n-resize", "bottom_side": "s-resize", "split_v": "row-resize",
        "top_left_corner": "nw-resize", "bottom_right_corner": "se-resize",
        "top_right_corner": "ne-resize", "bottom_left_corner": "sw-resize",
        "size_fdiag": "nwse-resize", "size_bdiag": "nesw-resize",
        "openhand": "grab", "closedhand": "grabbing", "dnd-move": "grabbing",
        "dnd-copy": "copy", "dnd-link": "alias", "dnd-none": "no-drop",
        "crossed_circle": "not-allowed", "circle": "not-allowed", "forbidden": "not-allowed",
    ]

    /// One XCursor file: an image per size, each with its hotspot.
    /// The format is libXcursor's: a header, a table of contents, then image
    /// chunks of premultiplied ARGB, all little-endian.
    public static func encode(_ images: [CursorImage]) -> [UInt8] {
        var b: [UInt8] = []
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { b.append(contentsOf: $0) } }
        let imageType: UInt32 = 0xfffd_0002
        u32(0x7275_6358)                // "Xcur"
        u32(16)                         // header size
        u32(0x0001_0000)                // version
        u32(UInt32(images.count))       // table of contents entries
        var at = 16 + 12 * images.count
        for im in images {
            u32(imageType); u32(UInt32(im.size)); u32(UInt32(at))
            at += 36 + im.pixels.count * 4
        }
        for im in images {
            u32(36); u32(imageType); u32(UInt32(im.size)); u32(1)
            u32(UInt32(im.size)); u32(UInt32(im.size))
            u32(UInt32(im.hotX)); u32(UInt32(im.hotY)); u32(0)
            for p in im.pixels { u32(p) }
        }
        return b
    }

    /// Write the theme `name` into `dir/name`: `index.theme`, `cursors/<css
    /// name>` for all 34 shapes, and `cursors/<x11 name>` links. Returns how
    /// many files and links, or nil if a write failed.
    public static func install(in dir: String, name: String) -> (files: Int, links: Int)? {
        let root = dir + "/" + name, cursors = root + "/cursors"
        for d in [dir, root, cursors] { _ = mkdir(d, 0o755) }
        let index = "[Icon Theme]\nName=\(name)\nComment=The pointer, from the desktop's theme\n"
        guard put(root + "/index.theme", Array(index.utf8)) else { return nil }
        var files = 0, links = 0
        for n in Cursor.shapeNames {
            let images = sizes.compactMap { Cursor.rasterise(n, scale: Double($0) / Cursor.size) }
            guard images.count == sizes.count, put(cursors + "/" + n, encode(images)) else { return nil }
            files += 1
        }
        for (x, css) in x11Names.sorted(by: { $0.key < $1.key }) {
            let p = cursors + "/" + x
            _ = unlink(p)
            guard symlink(css, p) == 0 else { return nil }
            links += 1
        }
        return (files, links)
    }

    /// Whole, or not at all: written beside and renamed over.
    private static func put(_ path: String, _ bytes: [UInt8]) -> Bool {
        let tmp = path + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        let ok = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) } == bytes.count
        close(fd)
        return ok && rename(tmp, path) == 0
    }
}
