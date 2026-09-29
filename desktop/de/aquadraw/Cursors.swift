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
