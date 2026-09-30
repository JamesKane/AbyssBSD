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
//
// Since P10.8 a submenu **opens**: hovering its row, or → / Return on it,
// opens a child AquaMenu in a popup parented to this one, beside the row.
// The owner says what the child is (`submenuFor`); the menu keeps the chain —
// which child is open, which menu has the keyboard (the deepest one the
// person moved into), and closing children before parents, which xdg-shell
// requires (destroying a popup that is not the topmost is a protocol error).

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
    /// The menu a submenu row opens, built by the owner — nil for a row with
    /// nothing to open. Its `onChoose` is the owner's to wire.
    public var submenuFor: ((Int) -> AquaMenu?)?
    /// Told when a submenu opens: its row, the child, and where the child's
    /// popup was asked to go relative to this menu's top-left (a test reads
    /// it — §2.46).
    public var onSubmenuOpened: (Int, AquaMenu) -> Void = { _, _ in }
    /// Told when the submenu on a row closes without a choice.
    public var onSubmenuClosed: (Int) -> Void = { _ in }

    /// The submenu open beside this menu, and its row.
    public private(set) var child: AquaMenu?
    private var childRow = -1
    private var childPopup: Popup?
    /// Whether the keyboard is in the child — set when the person moves the
    /// pointer into it or presses → on its row; until then it stays here, as
    /// on a Mac, where hovering a submenu row opens it without taking the keys.
    private var keysInChild = false
    /// The menu that opened this one.
    private weak var parent: AquaMenu?

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
        // The pointer is here: the keyboard follows it, and a parent's keys
        // come down the chain to this menu.
        parent?.keysInChild = true
        keysInChild = false
        let idx = aquaMenuRow(atY: y, items) ?? -1
        guard idx != hovered else { return }
        hovered = idx
        popup?.setNeedsDisplay()
        // Hovering a submenu row opens it; hovering another row closes it.
        if idx >= 0, idx < items.count, items[idx].hasSubmenu, items[idx].enabled {
            if idx != childRow { openChild(idx) }
        } else {
            closeChild()
        }
    }

    // MARK: the submenu (P10.8)

    /// Open the submenu on row `i`, beside it. With `highlightFirst` (the
    /// keyboard opened it) its first choosable row is highlighted and the
    /// keys go to it.
    @discardableResult
    public func openChild(_ i: Int, highlightFirst: Bool = false) -> Bool {
        closeChild()
        guard let pop = popup, let menu = submenuFor?(i) else { return false }
        let rows = aquaMenuRows(items)
        let w = Int32(max(150, menu.preferredWidth))
        let h = Int32(menu.preferredHeight.rounded(.up))
        // Its first row level with this one: up by the menu's top padding.
        guard let cp = Popup(parentPopup: pop, anchorY: Int32(rows[i].y), anchorH: Int32(rows[i].h),
                             offsetY: Int32(AquaMenu.padV), width: w, height: h, delegate: menu)
        else { return false }
        menu.popup = cp
        menu.parent = self
        // Dismissed from outside (the compositor ends the whole chain): forget
        // it here; the root tells the owner.
        let before = menu.onDismiss
        menu.onDismiss = { [weak self, weak menu] in
            before()
            if let self, self.child === menu { self.child = nil; self.childPopup = nil; self.childRow = -1; self.keysInChild = false }
        }
        child = menu
        childPopup = cp
        childRow = i
        if highlightFirst {
            keysInChild = true
            menu.moveHighlight(1)
        }
        onSubmenuOpened(i, menu)
        return true
    }

    /// Close the submenu, and any it opened, deepest first.
    public func closeChild() {
        guard let c = child else { return }
        c.closeChild()
        childPopup?.close()
        onSubmenuClosed(childRow)
        child = nil
        childPopup = nil
        childRow = -1
        keysInChild = false
    }

    /// Close this menu and everything opened from it, children first — the
    /// one way to take a chain down without a protocol error.
    public func closeAll() {
        closeChild()
        popup?.close()
    }

    /// Whether the highlighted row opens a submenu — so → goes into it, and
    /// not to the next title in the bar.
    public var highlightOpensSubmenu: Bool {
        hovered >= 0 && hovered < items.count && items[hovered].hasSubmenu && items[hovered].enabled
    }

    /// The menu that has the keyboard: the deepest one the person moved into.
    public var keyMenu: AquaMenu {
        if keysInChild, let c = child { return c.keyMenu }
        return self
    }

    public func pointerButton(pressed: Bool) {
        // Choose on release over an item (click-open then click-select).
        // A submenu row opens on hover; releasing on it chooses nothing.
        guard !pressed, hovered >= 0, hovered < items.count,
              items[hovered].isChoosable, !items[hovered].hasSubmenu else { return }
        onChoose(hovered)
    }

    public func popupDismissed() { onDismiss() }

    /// Keyboard navigation while the menu is open. Up/Down move the highlight
    /// (starting from the current selection), Return/Space choose it, Escape
    /// dismisses. Returns whether the key was consumed.
    @discardableResult
    public func keyDown(_ keysym: UInt32) -> Bool {
        // The deepest menu the person is in takes the key.
        if keysInChild, let c = child { return c.keyDown(keysym) }
        // Plain conditions, not `case a, b, c where …`: a `where` binds to the
        // last pattern only, and that switch took every Return for "open a
        // submenu here" — on rows that had none (HANDOFF §2.89).
        let intoSubmenu = keysym == KeySym.right || keysym == KeySym.enter || keysym == KeySym.space
        if intoSubmenu, highlightOpensSubmenu {
            // Into the submenu: → or Return on its row.
            if hovered == childRow, child != nil {
                keysInChild = true
                child?.moveHighlight(1)
                child?.popup?.setNeedsDisplay()
            } else {
                openChild(hovered, highlightFirst: true)
            }
            return true
        }
        if keysym == KeySym.left, parent != nil {
            // Out of a submenu: ← closes it, and the keys go back up.
            parent?.closeChild()
            return true
        }
        if keysym == KeySym.right, parent != nil {
            // → on a plain row inside a submenu does nothing (the bar's
            // title-walking is the root's, and only there).
            return true
        }
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
            // From a submenu it ends the whole menu, as on a Mac: the root's
            // owner is the one to tell.
            var root: AquaMenu = self
            while let p = root.parent { root = p }
            root.closeAll()
            root.onDismiss()
            return true
        default:
            return false
        }
    }

    func moveHighlight(_ d: Int) {
        // Starting from the checked item when nothing is hovered, so a pop-up
        // button's arrows move from its current value.
        let start: Int? = hovered >= 0 ? hovered
            : (selected >= 0 && selected < items.count ? selected : nil)
        guard let next = aquaMenuStep(from: start, step: d, items) else { return }
        hovered = next
        popup?.setNeedsDisplay()
    }
}
