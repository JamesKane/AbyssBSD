// AquaMenu — the contents/behaviour of a pop-up menu, driving a real
// Surface.Popup (an xdg-popup child surface). It renders the item list into the
// popup's buffer, tracks the hovered row from pointer motion, checkmarks the
// current selection, and reports a choice back via `onChoose`. AquaWindow
// creates one when the pop-up button is clicked and owns it until it dismisses.
//
// Since P10.1 a row is an `AquaMenuItem`, so a menu can say no: disabled rows
// are drawn grey and can be neither hovered nor chosen, separators are thin
// rules, a key equivalent sits right-aligned in its own column, and a submenu
// row carries its ▸. Row geometry comes from `aquaMenuRows` for paint and
// hit-test alike (§2.9).

import Surface
import CCairo

public final class AquaMenu: PopupDelegate {
    public static var itemHeight: Double { AquaMenuMetrics.itemHeight }
    public static var padV: Double { AquaMenuMetrics.padV }

    public let items: [AquaMenuItem]
    private let selected: Int
    private var hovered = -1

    /// Set by the owner once the Popup exists, so hover can request a redraw.
    public weak var popup: Popup?
    /// Called with the chosen index (the owner sets the value + closes). Only
    /// ever an enabled, non-separator row.
    public var onChoose: (Int) -> Void = { _ in }
    /// Called when the popup is dismissed without a choice (outside click).
    public var onDismiss: () -> Void = {}

    public init(items: [AquaMenuItem], selected: Int = -1) {
        self.items = items
        self.selected = selected
    }

    /// Plain titles, every one enabled — a pop-up button's choices.
    public convenience init(items: [String], selected: Int) {
        self.init(items: items.map { AquaMenuItem($0) }, selected: selected)
    }

    /// The popup height that fits every item.
    public var preferredHeight: Double { aquaMenuHeight(items) }

    /// The popup width that fits the longest title, the key column and the
    /// submenu arrow — measured on a scratch surface, since the owner asks
    /// before any buffer exists.
    public var preferredWidth: Double {
        guard let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1),
              let cr = cairo_create(cs) else { return 160 }
        defer { cairo_destroy(cr); cairo_surface_destroy(cs) }
        let rows = items.filter { !$0.isSeparator }
        let title = rows.map { Draw.textWidth(cr, $0.title, size: Theme.fontSize) }.max() ?? 0
        let key = rows.map { Draw.textWidth(cr, $0.keyText, size: Theme.fontSize) }.max() ?? 0
        let arrow = rows.contains { $0.hasSubmenu } ? 12.0 : 0
        let keyCol = key > 0 ? AquaMenuMetrics.keyGap + key : 0
        return (AquaMenuMetrics.titleX + title + max(keyCol, arrow)
                + AquaMenuMetrics.rightInset).rounded(.up)
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

        let whole = Rect(0, 0, w, h)
        Draw.paint("menu", cr, whole)

        for (i, (item, row)) in zip(items, aquaMenuRows(items)).enumerated() {
            if item.isSeparator {
                Draw.paint("menu.separator", cr, Rect(0, (row.y + row.h / 2).rounded(.down), w, 1))
                continue
            }
            let textColor: Color
            let line = Rect(0, row.y, w, row.h)
            if i == hovered {
                Draw.paint("menu.highlight", cr, line)
                textColor = Theme.menuTextOnHighlight
            } else {
                textColor = item.enabled ? Theme.menuText : Theme.menuTextDisabled
            }
            let baseline = row.y + row.h - 6
            if i == selected { Draw.paint("menu.check", cr, line, colors: ["color": textColor]) }
            Draw.textLeft(cr, item.title, x: AquaMenuMetrics.titleX, baselineY: baseline,
                          color: textColor, size: Theme.fontSize)
            if !item.keyText.isEmpty {
                let kw = Draw.textWidth(cr, item.keyText, size: Theme.fontSize)
                Draw.textLeft(cr, item.keyText, x: w - AquaMenuMetrics.rightInset - kw,
                              baselineY: baseline, color: textColor, size: Theme.fontSize)
            }
            if item.hasSubmenu { Draw.paint("menu.submenu", cr, line, colors: ["color": textColor]) }
        }

        Draw.paint("menu.frame", cr, whole)

        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }

    public func pointerMoved(x: Double, y: Double) {
        let idx = aquaMenuRow(atY: y, items) ?? -1
        if idx != hovered { hovered = idx; popup?.setNeedsDisplay() }
    }

    public func pointerButton(pressed: Bool) {
        // Choose on release over an item (click-open then click-select).
        guard !pressed, hovered >= 0, hovered < items.count,
              items[hovered].isChoosable else { return }
        onChoose(hovered)
    }

    public func popupDismissed() { onDismiss() }

    /// Keyboard navigation while the menu is open. Up/Down move the highlight
    /// (starting from the current selection), Return/Space choose it, Escape
    /// dismisses. Returns whether the key was consumed.
    @discardableResult
    public func keyDown(_ keysym: UInt32) -> Bool {
        switch keysym {
        case KeySym.up:    moveHighlight(-1); return true
        case KeySym.down:  moveHighlight(1); return true
        case KeySym.enter, KeySym.space:
            if hovered >= 0, hovered < items.count, items[hovered].isChoosable {
                onChoose(hovered)
            }
            return true
        case KeySym.escape:
            // `close()` is a *programmatic* teardown: it destroys the proxies
            // and deliberately does NOT call popupDismissed (the owner calls it
            // itself after a choice). Escape *is* a dismissal, though, so say so
            // — otherwise the owner keeps thinking the menu is still open, and
            // the menu bar leaves its title highlighted for a menu that's gone.
            popup?.close()
            onDismiss()
            return true
        default:
            return false
        }
    }

    private func moveHighlight(_ d: Int) {
        // Starting from the checked item when nothing is hovered, so a pop-up
        // button's arrows move from its current value.
        let start: Int? = hovered >= 0 ? hovered
            : (selected >= 0 && selected < items.count ? selected : nil)
        guard let next = aquaMenuStep(from: start, step: d, items) else { return }
        hovered = next
        popup?.setNeedsDisplay()
    }
}
