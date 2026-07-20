// AquaMenu — the contents/behaviour of a pop-up menu, driving a real
// Surface.Popup (an xdg-popup child surface). It renders the item list into the
// popup's buffer, tracks the hovered row from pointer motion, checkmarks the
// current selection, and reports a choice back via `onChoose`. AquaWindow
// creates one when the pop-up button is clicked and owns it until it dismisses.

import Surface
import CCairo

public final class AquaMenu: PopupDelegate {
    public static let itemHeight = 20.0
    public static let padV = 4.0

    private let items: [String]
    private let selected: Int
    private var hovered = -1

    /// Set by the owner once the Popup exists, so hover can request a redraw.
    public weak var popup: Popup?
    /// Called with the chosen index (the owner sets the value + closes).
    public var onChoose: (Int) -> Void = { _ in }
    /// Called when the popup is dismissed without a choice (outside click).
    public var onDismiss: () -> Void = {}

    public init(items: [String], selected: Int) {
        self.items = items
        self.selected = selected
    }

    /// The popup height that fits every item.
    public var preferredHeight: Double {
        Double(items.count) * AquaMenu.itemHeight + 2 * AquaMenu.padV
    }

    // MARK: PopupDelegate

    public func render(_ buffer: PixelBuffer) {
        let w = Double(buffer.width / buffer.scale)
        let h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(
            buffer.data.assumingMemoryBound(to: UInt8.self),
            CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))

        // Transparent ground so the rounded corners read.
        cairo_save(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
        cairo_paint(cr)
        cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)

        let frame = Rect(0.5, 0.5, w - 1, h - 1)
        Draw.roundedRect(cr, frame, radius: 5)
        Draw.setColor(cr, Theme.menuBackground)
        cairo_fill(cr)

        let ih = AquaMenu.itemHeight
        for (i, item) in items.enumerated() {
            let iy = AquaMenu.padV + Double(i) * ih
            let textColor: Color
            if i == hovered {
                Draw.roundedRect(cr, Rect(3, iy, w - 6, ih), radius: 3)
                Draw.setColor(cr, Theme.menuHighlight)
                cairo_fill(cr)
                textColor = Theme.menuTextOnHighlight
            } else {
                textColor = Theme.menuText
            }
            if i == selected { drawCheck(cr, x: 8, cy: iy + ih / 2, color: textColor) }
            Draw.textLeft(cr, item, x: 22, baselineY: iy + ih - 6,
                          color: textColor, size: Theme.fontSize)
        }

        Draw.roundedRect(cr, frame, radius: 5)
        Draw.setColor(cr, Theme.menuBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)

        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }

    private func drawCheck(_ cr: OpaquePointer, x: Double, cy: Double, color: Color) {
        Draw.setColor(cr, color)
        cairo_set_line_width(cr, 1.6)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_move_to(cr, x, cy + 1)
        cairo_line_to(cr, x + 3, cy + 4)
        cairo_line_to(cr, x + 8, cy - 4)
        cairo_stroke(cr)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER)
    }

    public func pointerMoved(x: Double, y: Double) {
        let idx = itemAt(y)
        if idx != hovered { hovered = idx; popup?.setNeedsDisplay() }
    }

    public func pointerButton(pressed: Bool) {
        // Choose on release over an item (click-open then click-select).
        guard !pressed, hovered >= 0, hovered < items.count else { return }
        onChoose(hovered)
    }

    public func popupDismissed() { onDismiss() }

    private func itemAt(_ y: Double) -> Int {
        guard y >= AquaMenu.padV else { return -1 }
        let i = Int((y - AquaMenu.padV) / AquaMenu.itemHeight)
        return i >= 0 && i < items.count ? i : -1
    }
}
