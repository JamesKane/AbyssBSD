// Finder — the AbyssBSD file browser, in Jaguar dress. Unlike the desktop, menu
// bar and Dock (wlr-layer-shell shell components), the Finder is an ordinary
// xdg-shell application: it reuses Surface.Window and the whole Aqua toolkit.
//
// Fidelity note: the 10.2 Finder is a *browser* by default — a toolbar with
// Back and a view switch, folders opening in place. Clicking the title bar's
// pill hides the toolbar, and that is exactly what turns it **spatial**: each
// folder then gets its own window, and re-opening a folder that already has one
// raises it (via xdg-activation) instead of making a second. Both modes live
// here, switched by `toolbarVisible`. (This reuses `paintWindowChrome` because the
// pinstriped/white Aqua window is the only window we ship — brushed metal and
// every successor texture are excluded on taste. PLAN.md decision 2.) The Rust
// sibling's `reef-fm` was spatial-only and GNOME-2 flavoured, so only its
// structure carries over, not its behaviour.
//
// One process owns every window: `FinderApp` holds them and routes
// open/raise/close, while each `FinderWindow` owns one directory's view. Input
// reaches the right one because `Display` routes by wl_surface (the pointer and
// keyboard `enter` events name it).
//
// Everything geometric lives in FinderModel.swift as pure functions, so the
// painter below and the pointer/keyboard handlers hit-test identical rects.
//
// File operations follow the Mac's verbs, not a PC file manager's: **Return
// renames** the selection (⌘O or ⌘↓ opens it — double-click still does too),
// ⌘⇧N makes a new folder and drops straight into renaming it, ⌘D duplicates,
// ⌘C/⌘X/⌘V copy/cut/paste through a clipboard shared by every window, and ⌘⌫
// moves to the Trash (~/.Trash — nothing here unlinks what you asked to delete).
// The naming rules ("untitled folder 2", "Read Me copy.txt") and the syscall
// layer live in FinderOps.swift.
//
// Config (domain `finder`, ~/.config/abyss/finder.ini):
//   view        = icon | list
//   show_hidden = true | false
//   toolbar     = true | false   (false = spatial; remembered across launches)
// Start directory: $ABYSS_FINDER_DIR, else $HOME, else "/".

import Surface
import PoolConfig
import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private let kBtnLeft: UInt32 = 0x110
private let kDoubleClickMs: Int64 = 450

/// Everything the painter needs — a value, so the PNG preview can render a
/// synthetic listing and the live window renders the real one.
public struct FinderState {
    public var path: String
    public var entries: [FinderEntry]
    public var selection: Int?
    public var scroll: Double
    public var view: FinderView
    public var canGoBack: Bool
    public var freeBytes: UInt64
    public var backPressed: Bool
    /// Toolbar shown = browser mode; hidden = spatial (one window per folder).
    public var toolbarVisible: Bool
    /// Non-nil while an item's name is being edited in place.
    public var edit: FinderEdit?
    /// Set when this window is a portal's file picker, so the title bar says
    /// what the window is *for* rather than which folder it happens to show.
    public var pickerTitle: String?

    public init(path: String, entries: [FinderEntry], selection: Int? = nil,
                scroll: Double = 0, view: FinderView = .icon,
                canGoBack: Bool = false, freeBytes: UInt64 = 0,
                backPressed: Bool = false, toolbarVisible: Bool = true,
                edit: FinderEdit? = nil, pickerTitle: String? = nil) {
        self.path = path
        self.entries = entries
        self.selection = selection
        self.scroll = scroll
        self.view = view
        self.canGoBack = canGoBack
        self.freeBytes = freeBytes
        self.backPressed = backPressed
        self.toolbarVisible = toolbarVisible
        self.edit = edit
        self.pickerTitle = pickerTitle
    }
}

/// An in-progress inline rename: which item, the text so far, and how many
/// leading characters are still *selected*. The Finder opens a rename with the
/// base name selected (the extension left out of it), so the first thing you
/// type replaces the name rather than appending to it.
public struct FinderEdit: Equatable, Sendable {
    public var index: Int
    public var text: String
    public var selectedPrefix: Int

    public init(index: Int, text: String, selectedPrefix: Int = 0) {
        self.index = index
        self.text = text
        self.selectedPrefix = selectedPrefix
    }

    /// The edit that starts a rename of `name`: base selected, extension kept.
    public static func renaming(_ index: Int, name: String) -> FinderEdit {
        FinderEdit(index: index, text: name,
                   selectedPrefix: finderSplitExtension(name).base.count)
    }

    /// Replace the selected prefix with `typed` (or append when nothing is
    /// selected). Returns the edit after the keystroke.
    public func typing(_ typed: String) -> FinderEdit {
        guard selectedPrefix > 0 else {
            return FinderEdit(index: index, text: text + typed, selectedPrefix: 0)
        }
        return FinderEdit(index: index, text: typed + String(text.dropFirst(selectedPrefix)),
                          selectedPrefix: 0)
    }

    /// Backspace: clears the selection if there is one, else deletes a character.
    public func deletingBackward() -> FinderEdit {
        if selectedPrefix > 0 {
            return FinderEdit(index: index, text: String(text.dropFirst(selectedPrefix)),
                              selectedPrefix: 0)
        }
        return FinderEdit(index: index, text: String(text.dropLast()), selectedPrefix: 0)
    }
}

/// Height of the list view's column header (0 in icon view).
public let finderListHeaderHeight = 17.0

/// The scrolling item area: the content rect, less the list-view column header.
/// Paint and hit-test both go through this so they agree.
public func finderItemViewport(_ L: FinderLayout, view: FinderView) -> Rect {
    guard view == .list else { return L.content }
    return Rect(L.content.x, L.content.y + finderListHeaderHeight,
                L.content.w, max(0, L.content.h - finderListHeaderHeight))
}

// MARK: - Painting

/// Paint a Finder window and return its layout (which the caller keeps for
/// hit-testing — the layout is the truth for both).
@discardableResult
public func paintFinder(_ cr: OpaquePointer, w: Double, h: Double,
                        state: FinderState) -> FinderLayout {
    paintWindowChrome(cr, w: w, h: h, title: state.pickerTitle
                      ?? finderDisplayName(state.path))
    let L = finderLayout(w: w, h: h, toolbarVisible: state.toolbarVisible)

    // A small folder proxy icon to the left of the centred title, as the Finder
    // shows for the folder a window represents.
    let titleW = Draw.textWidth(cr, finderDisplayName(state.path), size: Theme.fontSize)
    drawFinderIcon(cr, .folder,
                   Rect(w / 2 - titleW / 2 - 19, (Theme.titleBarHeight - 14) / 2, 14, 14))

    paintFinderToolbar(cr, L, state: state)

    let viewport = finderItemViewport(L, view: state.view)
    let count = state.entries.count
    let contentH = finderContentHeight(count: count, view: state.view, viewport: viewport)
    let maxScroll = max(0, contentH - viewport.h)
    let scroll = max(0, min(state.scroll, maxScroll))

    // The item well: white, clipped, scrolled.
    Draw.setColor(cr, Color(hex: 0xffffff))
    cairo_rectangle(cr, L.content.x, L.content.y, L.content.w, L.content.h)
    cairo_fill(cr)

    if state.view == .list { paintFinderListHeader(cr, L) }

    cairo_save(cr)
    cairo_rectangle(cr, viewport.x, viewport.y, viewport.w, viewport.h)
    cairo_clip(cr)
    for (i, entry) in state.entries.enumerated() {
        let cell = finderItemRect(i, view: state.view, viewport: viewport, scroll: scroll)
        guard cell.y + cell.h >= viewport.y, cell.y <= viewport.y + viewport.h else { continue }
        let selected = state.selection == i
        let editing = state.edit?.index == i ? state.edit : nil
        switch state.view {
        case .icon:
            paintFinderIconCell(cr, entry, cell, selected: selected, editing: editing)
        case .list:
            paintFinderListRow(cr, entry, cell, selected: selected, editing: editing)
        }
    }
    cairo_restore(cr)

    // Well border (drawn over the content edge, under the scrollbar).
    Draw.setColor(cr, Theme.separator)
    cairo_set_line_width(cr, 1)
    cairo_move_to(cr, L.content.x, L.content.y + 0.5)
    cairo_line_to(cr, L.content.x + L.content.w, L.content.y + 0.5)
    cairo_stroke(cr)

    // Scrollbar: track, thumb (hidden when everything fits), paired arrows.
    Draw.scrollTrack(cr, L.track, vertical: true)
    if let thumb = thumbRect(track: L.track, offset: scroll,
                             viewportH: viewport.h, contentH: contentH) {
        Draw.scrollThumb(cr, thumb, vertical: true)
    }
    Draw.scrollArrow(cr, L.upArrow, .up, enabled: scroll > 0.5)
    Draw.scrollArrow(cr, L.downArrow, .down, enabled: scroll < maxScroll - 0.5)

    paintFinderStatusBar(cr, L, count: count, freeBytes: state.freeBytes)
    return L
}

private func paintFinderToolbar(_ cr: OpaquePointer, _ L: FinderLayout,
                                state: FinderState) {
    let bar = L.toolbar
    guard bar.h > 0 else { return }
    cairo_rectangle(cr, bar.x, bar.y, bar.w, bar.h)
    Draw.fillVerticalGradient(cr, y: bar.y, h: bar.h, stops: [
        (0, Color(hex: 0xf0f0f0)), (1, Color(hex: 0xdcdcdc)),
    ])
    cairo_new_path(cr)
    Draw.setColor(cr, Theme.separator)
    cairo_set_line_width(cr, 1)
    cairo_move_to(cr, bar.x, bar.y + bar.h - 0.5)
    cairo_line_to(cr, bar.x + bar.w, bar.y + bar.h - 0.5)
    cairo_stroke(cr)

    drawBackButton(cr, L.backButton, enabled: state.canGoBack,
                   pressed: state.backPressed)
    drawViewSwitch(cr, L.viewControl, view: state.view)
}

/// The toolbar's Back control: a white gel capsule with a left-pointing glyph,
/// greyed out at the top of the history.
private func drawBackButton(_ cr: OpaquePointer, _ r: Rect, enabled: Bool,
                            pressed: Bool) {
    Draw.roundedRect(cr, r, radius: 5)
    if pressed && enabled {
        Draw.fillVerticalGradient(cr, y: r.y, h: r.h, stops: [
            (0, Color(hex: 0xc8c8c8)), (1, Color(hex: 0xe4e4e4))])
    } else {
        Draw.fillVerticalGradient(cr, y: r.y, h: r.h, stops: [
            (0, Theme.controlWhiteTop), (1, Theme.controlWhiteBottom)])
    }
    cairo_new_path(cr)
    Draw.roundedRect(cr, r, radius: 5)
    Draw.setColor(cr, Theme.controlBorder.with(a: enabled ? 1 : 0.5))
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)

    let cx = r.x + r.w / 2, cy = r.y + r.h / 2
    cairo_new_path(cr)
    cairo_move_to(cr, cx - 4, cy)
    cairo_line_to(cr, cx + 3, cy - 5)
    cairo_line_to(cr, cx + 3, cy + 5)
    cairo_close_path(cr)
    Draw.setColor(cr, Color(hex: 0x3a3a3a, a: enabled ? 1 : 0.35))
    cairo_fill(cr)
}

/// The icon/list view switch: a two-segment Aqua control with glyphs instead of
/// labels (a 2×2 grid of tiles, and a stack of lines).
private func drawViewSwitch(_ cr: OpaquePointer, _ r: Rect, view: FinderView) {
    let selected = view == .icon ? 0 : 1
    Draw.segmentedControl(cr, r, labels: ["", ""], selected: selected)
    let segs = Draw.segmentRects(r, count: 2)
    guard segs.count == 2 else { return }

    // Icon-view glyph: four small tiles.
    let a = segs[0]
    let onBlue = Color(hex: 0xffffff), onWhite = Color(hex: 0x4a4a4a)
    Draw.setColor(cr, selected == 0 ? onBlue : onWhite)
    let s = 4.0, gap = 2.0
    let gx = a.x + a.w / 2 - s - gap / 2, gy = a.y + a.h / 2 - s - gap / 2
    for row in 0..<2 {
        for col in 0..<2 {
            cairo_rectangle(cr, gx + Double(col) * (s + gap),
                            gy + Double(row) * (s + gap), s, s)
        }
    }
    cairo_fill(cr)

    // List-view glyph: three lines.
    let b = segs[1]
    Draw.setColor(cr, selected == 1 ? onBlue : onWhite)
    cairo_set_line_width(cr, 1.6)
    let lx = b.x + b.w / 2 - 5.5, ly = b.y + b.h / 2 - 4
    for k in 0..<3 {
        let y = ly + Double(k) * 4
        cairo_move_to(cr, lx, y)
        cairo_line_to(cr, lx + 11, y)
    }
    cairo_stroke(cr)
}

private func paintFinderListHeader(_ cr: OpaquePointer, _ L: FinderLayout) {
    let hdr = Rect(L.content.x, L.content.y, L.content.w, finderListHeaderHeight)
    cairo_rectangle(cr, hdr.x, hdr.y, hdr.w, hdr.h)
    Draw.fillVerticalGradient(cr, y: hdr.y, h: hdr.h, stops: [
        (0, Color(hex: 0xf6f6f6)), (1, Color(hex: 0xdedede)),
    ])
    cairo_new_path(cr)
    Draw.setColor(cr, Theme.separator)
    cairo_set_line_width(cr, 1)
    cairo_move_to(cr, hdr.x, hdr.y + hdr.h - 0.5)
    cairo_line_to(cr, hdr.x + hdr.w, hdr.y + hdr.h - 0.5)
    cairo_stroke(cr)

    let cols = finderListColumns(hdr)
    for (i, c) in cols.enumerated() where i > 0 {
        cairo_move_to(cr, c.x + 0.5, hdr.y + 2)
        cairo_line_to(cr, c.x + 0.5, hdr.y + hdr.h - 2)
        cairo_stroke(cr)
    }
    let titles = ["Name", "Size", "Kind"]
    for (i, c) in cols.enumerated() {
        Draw.textLeft(cr, titles[i], x: c.x + 6, baselineY: hdr.y + hdr.h - 5,
                      color: Theme.bodyText.with(a: 0.8), size: 10)
    }
}

/// Name / Size / Kind column rects for a list-view row (or the header).
private func finderListColumns(_ row: Rect) -> [Rect] {
    let sizeW = 70.0, kindW = 90.0
    let nameW = max(60, row.w - sizeW - kindW)
    return [
        Rect(row.x, row.y, nameW, row.h),
        Rect(row.x + nameW, row.y, sizeW, row.h),
        Rect(row.x + nameW + sizeW, row.y, kindW, row.h),
    ]
}

private func paintFinderIconCell(_ cr: OpaquePointer, _ entry: FinderEntry,
                                 _ cell: Rect, selected: Bool,
                                 editing: FinderEdit? = nil) {
    let size = FinderMetrics.iconSize
    let icon = Rect(cell.x + (cell.w - size) / 2, cell.y + 4, size, size)
    if selected {
        // Jaguar tints the selected icon with a soft blue wash.
        Draw.roundedRect(cr, Rect(icon.x - 3, icon.y - 3, size + 6, size + 6), radius: 6)
        Draw.setColor(cr, Theme.menuHighlight.with(a: 0.22))
        cairo_fill(cr)
    }
    drawFinderIcon(cr, entry, icon)

    if let edit = editing {
        // The name is being edited: a white field with the Aqua focus ring, in
        // place of the label.
        let tw = Draw.textWidth(cr, edit.text, size: 11)
        let fw = max(46, min(cell.w + 16, tw + 16))
        let field = Rect(cell.x + cell.w / 2 - fw / 2, icon.y + size + 2, fw, 16)
        drawFinderNameField(cr, field, edit: edit, size: 11)
        return
    }

    let label = finderTruncated(cr, entry.name, maxWidth: cell.w - 8, size: 11)
    let tw = Draw.textWidth(cr, label, size: 11)
    let labelY = icon.y + size + 4
    if selected {
        Draw.roundedRect(cr, Rect(cell.x + cell.w / 2 - tw / 2 - 4, labelY, tw + 8, 14),
                         radius: 3)
        Draw.setColor(cr, Theme.menuHighlight)
        cairo_fill(cr)
    }
    Draw.text(cr, label, centerX: cell.x + cell.w / 2, centerY: labelY + 7,
              color: selected ? Theme.menuTextOnHighlight : Theme.bodyText, size: 11)
}

private func paintFinderListRow(_ cr: OpaquePointer, _ entry: FinderEntry,
                                _ row: Rect, selected: Bool,
                                editing: FinderEdit? = nil) {
    if selected {
        cairo_rectangle(cr, row.x, row.y, row.w, row.h)
        Draw.setColor(cr, Theme.menuHighlight)
        cairo_fill(cr)
    }
    let fg = selected ? Theme.menuTextOnHighlight : Theme.bodyText
    let cols = finderListColumns(row)
    let iconSide = FinderMetrics.listIcon
    let icon = Rect(cols[0].x + 4, row.y + (row.h - iconSide) / 2, iconSide, iconSide)
    drawFinderIcon(cr, entry, icon)

    let baseline = row.y + row.h - 5
    let nameX = icon.x + iconSide + 5
    if let edit = editing {
        let fw = max(60, min(cols[0].w - (nameX - cols[0].x) - 6,
                             Draw.textWidth(cr, edit.text, size: 11) + 16))
        drawFinderNameField(cr, Rect(nameX - 2, row.y + 1, fw, row.h - 2),
                            edit: edit, size: 11)
    } else {
        let name = finderTruncated(cr, entry.name,
                                   maxWidth: cols[0].w - (nameX - cols[0].x) - 6,
                                   size: 11)
        Draw.textLeft(cr, name, x: nameX, baselineY: baseline, color: fg, size: 11)
    }
    let sizeText = entry.isContainer || entry.kind == .application
        ? "--" : finderFormatBytes(entry.size)
    Draw.textLeft(cr, sizeText, x: cols[1].x + 6, baselineY: baseline, color: fg, size: 11)
    Draw.textLeft(cr, finderKindLabel(entry.kind), x: cols[2].x + 6, baselineY: baseline,
                  color: fg, size: 11)
}

/// The inline rename field: a white well, the Aqua focus ring, the selected
/// prefix on a blue highlight, and a caret at the end (editing replaces the
/// selection, then appends/backspaces — no cursor motion yet).
private func drawFinderNameField(_ cr: OpaquePointer, _ r: Rect, edit: FinderEdit,
                                 size: Double) {
    let text = edit.text
    Draw.setColor(cr, Theme.fieldBackground)
    cairo_rectangle(cr, r.x, r.y, r.w, r.h)
    cairo_fill(cr)
    Draw.focusRing(cr, r, radius: 2)
    Draw.setColor(cr, Theme.fieldBorder)
    cairo_set_line_width(cr, 1)
    cairo_rectangle(cr, r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1)
    cairo_stroke(cr)

    let inset = 4.0
    let shown = finderTruncated(cr, text, maxWidth: r.w - 2 * inset - 2, size: size)
    if edit.selectedPrefix > 0 {
        let selected = String(shown.prefix(edit.selectedPrefix))
        let selW = Draw.textWidth(cr, selected, size: size)
        Draw.setColor(cr, Theme.menuHighlight)
        cairo_rectangle(cr, r.x + inset - 1, r.y + 2, selW + 2, r.h - 4)
        cairo_fill(cr)
    }
    Draw.textLeft(cr, shown, x: r.x + inset, baselineY: r.y + r.h - 4,
                  color: Theme.fieldText, size: size)
    if edit.selectedPrefix > 0 {
        // Redraw the selected run in the highlight's text colour.
        let selected = String(shown.prefix(edit.selectedPrefix))
        Draw.textLeft(cr, selected, x: r.x + inset, baselineY: r.y + r.h - 4,
                      color: Theme.menuTextOnHighlight, size: size)
    }
    let caretX = min(r.x + r.w - 3, r.x + inset + Draw.textWidth(cr, shown, size: size) + 1)
    Draw.setColor(cr, Theme.fieldCaret)
    cairo_rectangle(cr, caretX, r.y + 2, 1, r.h - 4)
    cairo_fill(cr)
}

public func finderKindLabel(_ kind: FinderItemKind) -> String {
    switch kind {
    case .folder:      return "Folder"
    case .application: return "Application"
    case .document:    return "Document"
    case .disk:        return "Volume"
    }
}

/// Shorten `s` with an ellipsis until it fits `maxWidth`.
private func finderTruncated(_ cr: OpaquePointer, _ s: String, maxWidth: Double,
                             size: Double) -> String {
    guard maxWidth > 0, Draw.textWidth(cr, s, size: size) > maxWidth else { return s }
    var out = s
    while !out.isEmpty, Draw.textWidth(cr, out + "…", size: size) > maxWidth {
        out.removeLast()
    }
    return out + "…"
}

private func paintFinderStatusBar(_ cr: OpaquePointer, _ L: FinderLayout,
                                  count: Int, freeBytes: UInt64) {
    let bar = L.status
    cairo_rectangle(cr, bar.x, bar.y, bar.w, bar.h)
    Draw.fillVerticalGradient(cr, y: bar.y, h: bar.h, stops: [
        (0, Color(hex: 0xeaeaea)), (1, Color(hex: 0xd8d8d8)),
    ])
    cairo_new_path(cr)
    Draw.setColor(cr, Theme.separator)
    cairo_set_line_width(cr, 1)
    cairo_move_to(cr, bar.x, bar.y + 0.5)
    cairo_line_to(cr, bar.x + bar.w, bar.y + 0.5)
    cairo_stroke(cr)
    Draw.text(cr, finderStatusText(count: count, freeBytes: freeBytes),
              centerX: bar.x + bar.w / 2, centerY: bar.y + bar.h / 2,
              color: Theme.bodyText.with(a: 0.75), size: 10)
}

// MARK: - Procedural item icons (original glyphs, not Apple artwork)

public func drawFinderIcon(_ cr: OpaquePointer, _ kind: FinderItemKind, _ r: Rect) {
    switch kind {
    case .folder:      drawFolderIcon(cr, r)
    case .application: drawAppIcon(cr, r)
    case .document:    drawDocumentIcon(cr, r)
    case .disk:        drawDiskIcon(cr, r)
    }
}

/// An entry's icon: the bundle's own artwork when it has some, else the
/// procedural glyph for its kind. Everything that draws a listed item goes
/// through here, so the Finder and the desktop agree.
public func drawFinderIcon(_ cr: OpaquePointer, _ entry: FinderEntry, _ r: Rect) {
    if let path = entry.iconPath, AppIcon.draw(cr, path: path, r) { return }
    drawFinderIcon(cr, entry.kind, r)
}

/// The Aqua folder: a steel-blue body with a raised tab on the left, a glassy
/// top sheen and a soft rim.
private func drawFolderIcon(_ cr: OpaquePointer, _ r: Rect) {
    let bodyTop = r.y + r.h * 0.22
    let body = Rect(r.x + r.w * 0.04, bodyTop, r.w * 0.92, r.h * 0.66)
    // Back tab.
    Draw.roundedRect(cr, Rect(body.x, r.y + r.h * 0.10, body.w * 0.44, r.h * 0.22),
                     radius: r.w * 0.05)
    Draw.setColor(cr, Color(hex: 0x6f9cd4))
    cairo_fill(cr)
    // Front body.
    Draw.roundedRect(cr, body, radius: r.w * 0.07)
    let g = cairo_pattern_create_linear(0, body.y, 0, body.y + body.h)
    cairo_pattern_add_color_stop_rgba(g, 0, 0.62, 0.78, 0.94, 1)
    cairo_pattern_add_color_stop_rgba(g, 0.5, 0.44, 0.63, 0.86, 1)
    cairo_pattern_add_color_stop_rgba(g, 1, 0.31, 0.50, 0.76, 1)
    cairo_set_source(cr, g)
    cairo_fill(cr)
    cairo_pattern_destroy(g)
    // Top sheen.
    Draw.roundedRect(cr, Rect(body.x + r.w * 0.05, body.y + r.h * 0.04,
                              body.w - r.w * 0.10, body.h * 0.34),
                     radius: r.w * 0.05)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.28)
    cairo_fill(cr)
    // Rim.
    Draw.roundedRect(cr, body, radius: r.w * 0.07)
    cairo_set_source_rgba(cr, 0.16, 0.28, 0.45, 0.55)
    cairo_set_line_width(cr, max(0.6, r.w * 0.02))
    cairo_stroke(cr)
}

/// A document: a white page with a folded top-right corner and ruled lines.
private func drawDocumentIcon(_ cr: OpaquePointer, _ r: Rect) {
    let page = Rect(r.x + r.w * 0.16, r.y + r.h * 0.06, r.w * 0.68, r.h * 0.88)
    let fold = page.w * 0.32
    cairo_new_path(cr)
    cairo_move_to(cr, page.x, page.y)
    cairo_line_to(cr, page.x + page.w - fold, page.y)
    cairo_line_to(cr, page.x + page.w, page.y + fold)
    cairo_line_to(cr, page.x + page.w, page.y + page.h)
    cairo_line_to(cr, page.x, page.y + page.h)
    cairo_close_path(cr)
    let g = cairo_pattern_create_linear(0, page.y, 0, page.y + page.h)
    cairo_pattern_add_color_stop_rgba(g, 0, 1, 1, 1, 1)
    cairo_pattern_add_color_stop_rgba(g, 1, 0.90, 0.91, 0.93, 1)
    cairo_set_source(cr, g)
    cairo_fill_preserve(cr)
    cairo_pattern_destroy(g)
    cairo_set_source_rgba(cr, 0.45, 0.47, 0.52, 0.9)
    cairo_set_line_width(cr, max(0.6, r.w * 0.02))
    cairo_stroke(cr)
    // The folded corner.
    cairo_new_path(cr)
    cairo_move_to(cr, page.x + page.w - fold, page.y)
    cairo_line_to(cr, page.x + page.w, page.y + fold)
    cairo_line_to(cr, page.x + page.w - fold, page.y + fold)
    cairo_close_path(cr)
    cairo_set_source_rgba(cr, 0.78, 0.80, 0.85, 1)
    cairo_fill_preserve(cr)
    cairo_set_source_rgba(cr, 0.45, 0.47, 0.52, 0.9)
    cairo_stroke(cr)
    // Ruled lines (only legible at full size).
    guard r.w >= 24 else { return }
    cairo_set_source_rgba(cr, 0.55, 0.58, 0.64, 0.8)
    cairo_set_line_width(cr, max(0.6, r.w * 0.018))
    for k in 0..<4 {
        let y = page.y + page.h * (0.46 + Double(k) * 0.12)
        cairo_move_to(cr, page.x + page.w * 0.14, y)
        cairo_line_to(cr, page.x + page.w * 0.86, y)
    }
    cairo_stroke(cr)
}

/// An application bundle: a blue gel tile with a white "A" — original artwork,
/// standing in for a bundle's own icon (which we don't read yet).
private func drawAppIcon(_ cr: OpaquePointer, _ r: Rect) {
    let tile = Rect(r.x + r.w * 0.08, r.y + r.h * 0.08, r.w * 0.84, r.h * 0.84)
    Draw.roundedRect(cr, tile, radius: tile.w * 0.22)
    let g = cairo_pattern_create_linear(0, tile.y, 0, tile.y + tile.h)
    cairo_pattern_add_color_stop_rgba(g, 0, 0.55, 0.72, 0.95, 1)
    cairo_pattern_add_color_stop_rgba(g, 1, 0.18, 0.38, 0.74, 1)
    cairo_set_source(cr, g)
    cairo_fill(cr)
    cairo_pattern_destroy(g)
    Draw.roundedRect(cr, Rect(tile.x + tile.w * 0.06, tile.y + tile.h * 0.06,
                              tile.w * 0.88, tile.h * 0.40),
                     radius: tile.w * 0.16)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.30)
    cairo_fill(cr)
    Draw.text(cr, "A", centerX: tile.x + tile.w / 2, centerY: tile.y + tile.h / 2,
              color: Color(1, 1, 1, 0.95), size: max(7, tile.h * 0.55),
              style: .bold)
    Draw.roundedRect(cr, tile, radius: tile.w * 0.22)
    cairo_set_source_rgba(cr, 0.10, 0.22, 0.45, 0.6)
    cairo_set_line_width(cr, max(0.6, r.w * 0.02))
    cairo_stroke(cr)
}

/// A volume: a grey drive slab with a lighter top face and a status LED.
private func drawDiskIcon(_ cr: OpaquePointer, _ r: Rect) {
    let body = Rect(r.x + r.w * 0.06, r.y + r.h * 0.22, r.w * 0.88, r.h * 0.58)
    Draw.roundedRect(cr, body, radius: r.w * 0.08)
    let g = cairo_pattern_create_linear(0, body.y, 0, body.y + body.h)
    cairo_pattern_add_color_stop_rgba(g, 0, 0.90, 0.91, 0.94, 1)
    cairo_pattern_add_color_stop_rgba(g, 1, 0.63, 0.65, 0.70, 1)
    cairo_set_source(cr, g)
    cairo_fill(cr)
    cairo_pattern_destroy(g)
    // A brighter top face, so the slab reads as a drive rather than a card.
    Draw.roundedRect(cr, Rect(body.x + r.w * 0.04, body.y + r.h * 0.04,
                              body.w - r.w * 0.08, body.h * 0.34),
                     radius: r.w * 0.05)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.45)
    cairo_fill(cr)
    Draw.roundedRect(cr, body, radius: r.w * 0.08)
    cairo_set_source_rgba(cr, 0.35, 0.37, 0.42, 0.85)
    cairo_set_line_width(cr, max(0.6, r.w * 0.02))
    cairo_stroke(cr)
    // Front slot + status LED.
    cairo_new_path(cr)
    cairo_rectangle(cr, body.x + body.w * 0.14, body.y + body.h * 0.70,
                    body.w * 0.44, max(1, r.h * 0.045))
    cairo_set_source_rgba(cr, 0.45, 0.47, 0.52, 0.75)
    cairo_fill(cr)
    cairo_new_path(cr)
    cairo_arc(cr, body.x + body.w * 0.80, body.y + body.h * 0.74, max(1, r.w * 0.045),
              0, 2 * .pi)
    cairo_set_source_rgba(cr, 0.35, 0.62, 0.92, 1)
    cairo_fill(cr)
}

// MARK: - Type-ahead selection

/// Finder type-select: the index of the next entry whose name starts with
/// `prefix` (case-insensitive), searching forward from `after` and wrapping.
public func finderTypeSelect(_ entries: [FinderEntry], prefix: String,
                             after: Int?) -> Int? {
    guard !prefix.isEmpty, !entries.isEmpty else { return nil }
    let needle = prefix.lowercased()
    let start = (after.map { $0 + 1 } ?? 0) % entries.count
    for k in 0..<entries.count {
        let i = (start + k) % entries.count
        if entries[i].name.lowercased().hasPrefix(needle) { return i }
    }
    return nil
}

// MARK: - The application (one process, many windows)

/// Owns every Finder window and the mode they share. In browser mode there is
/// normally one window that navigates in place; in spatial mode each folder gets
/// its own, and asking for a folder that already has one raises it.
public final class FinderApp {
    let display: Display
    private var windows: [FinderWindow] = []
    private let width: Int32
    private let height: Int32

    /// Browser (toolbar shown) vs spatial (hidden). Windows inherit this and a
    /// toggle in any window updates it — the Finder remembers the mode.
    public private(set) var toolbarVisible: Bool

    /// What we ourselves last put on the clipboard.
    ///
    /// **A cache, not the clipboard** (P9.2). It used to be the whole of it: a
    /// field on this object, so ⌘C in one Finder window and ⌘V in another
    /// worked, and nothing crossed a process boundary — copy in the Finder and
    /// paste in a GTK application was not merely unimplemented, it was
    /// unreachable. The desktop's Edit menu has listed Cut/Copy/Paste since
    /// P2.4, wired to nothing.
    ///
    /// It stays because `cut` has no representation on the wire: the selection
    /// carries a path, and whether the person meant *move* is ours to remember.
    /// The path itself now comes from the seat.
    private(set) var clipboard: (path: String, cut: Bool)?

    /// Put a path on the **system** clipboard, and remember whether it was a cut.
    ///
    /// Offered as `text/uri-list` (a `file://` URI, which is what another file
    /// manager reads) and `text/plain` (the bare path, which is what everything
    /// else does).
    func setClipboard(path: String, cut: Bool) {
        clipboard = (path, cut)
        if let clip = display.clipboard {
            // The serial comes from the ⌘C that caused this — see
            // `Display.lastInputSerial`. A copy nobody asked for has no serial
            // and is refused, which is the protocol's guard and not ours.
            let uri = finderFileURI(path)
            let ok = clip.write(Array(uri.utf8),
                                types: [ClipboardMIME.uriList, ClipboardMIME.text])
            FinderWindow.log("\(cut ? "cut" : "copied") \(path)"
                             + (ok ? " — offered to the desktop" : " — locally only"))
        } else {
            // A compositor with no data device is a real case; the Finder still
            // copies between its own windows rather than refusing to work.
            FinderWindow.log("\(cut ? "cut" : "copied") \(path) — locally only")
        }
    }

    func clearClipboard() { clipboard = nil }

    /// The path to paste: **what is on the seat**, falling back to our own cache.
    ///
    /// The seat wins because somebody else may have copied since we did — that
    /// is the whole point of a system clipboard. The cache answers when the
    /// selection is not something we can read, and carries the `cut` flag either
    /// way, since only we know whether our own copy meant move.
    func clipboardPath() -> (path: String, cut: Bool)? {
        // Our own copy is answered from the cache — reading it off the wire
        // would be this process asking itself for bytes while blocked waiting
        // for them (`Clipboard.ownsSelection`). `read` returns nil in that case
        // anyway; asking first keeps the intent visible.
        if display.clipboard?.ownsSelection == true { return clipboard }
        if let r = display.clipboard?.read(preferring: [ClipboardMIME.uriList,
                                                        ClipboardMIME.text]) {
            // The same parser a drop uses: a uri-list may carry several lines
            // and CRLF endings, and its entries are percent-encoded, so the
            // Finder takes the first and decodes it (`finderDroppedPath`).
            if let s = finderDroppedPath(r.bytes) {
                // Ours, if it is the same path — so a cut we made stays a cut.
                if let c = clipboard, c.path == s { return c }
                return (s, false)
            }
        }
        return clipboard
    }

    /// Re-read every window showing `directory` (a file operation in one window
    /// must show up in the others looking at the same folder).
    func refreshWindows(showing directory: String, selecting name: String? = nil) {
        for w in windows where w.directory == directory {
            w.refresh(selecting: name)
        }
    }

    /// Whether closing the last window ends the process. True when the Finder is
    /// the app being run; false when something else hosts it (the Desktop opens
    /// Finder windows but must outlive them).
    private let quitsWithLastWindow: Bool

    public init(display: Display, width: Int32 = 520, height: Int32 = 400,
                quitsWithLastWindow: Bool = true) {
        self.display = display
        self.width = width
        self.height = height
        self.quitsWithLastWindow = quitsWithLastWindow
        let config = (try? Pool.load("finder")) ?? Config()
        toolbarVisible = config.bool("finder", "toolbar") ?? true
    }

    /// Open the window the app starts with. Returns false if the window can't be
    /// created (no compositor surface).
    @discardableResult
    public func openInitialWindow(path: String? = nil) -> Bool {
        guard let first = FinderWindow(display: display, app: self,
                                       path: path ?? FinderWindow.startDirectory(),
                                       toolbarVisible: toolbarVisible,
                                       width: width, height: height)
        else { return false }
        windows.append(first)
        acceptDrops()
        return true
    }

    /// Take files dropped on any of our windows.
    ///
    /// **One handler for the application, not one per window**, because the
    /// clipboard belongs to the connection: `wl_data_device` is per seat, and
    /// the drop event says *where* it landed rather than *which window* took it.
    /// The window is found from the `wl_surface` the drag entered — see
    /// `Clipboard.dragSurface` for why the pointer cannot answer this.
    private func acceptDrops() {
        guard let clip = display.clipboard else { return }
        clip.acceptedDragTypes = [ClipboardMIME.uriList, ClipboardMIME.text]
        clip.onDrop = { [weak self] _, bytes, _, _ in
            guard let self else { return }
            guard let s = finderDroppedPath(bytes), finderExists(s) else { return }
            // The window the drag was over is the one that was dropped on. A
            // drop on a surface that is not one of our windows is not ours.
            let surf = clip.dragSurface
            guard let target = self.windows.first(where: { $0.surface == surf })
            else { return }
            target.receiveDrop(of: s)
        }
    }

    /// Open (or raise) a window for `path` — what the Desktop calls when an icon
    /// is double-clicked.
    public func openFolder(_ path: String) {
        if let existing = windows.first(where: { $0.directory == path }) {
            FinderWindow.log("raised \(path)")
            existing.raise()
            return
        }
        guard let w = FinderWindow(display: display, app: self, path: path,
                                   toolbarVisible: toolbarVisible,
                                   width: width, height: height) else { return }
        windows.append(w)
        FinderWindow.log("new window \(path) (\(windows.count) open)")
    }

    /// Spatial mode's defining behaviour: a folder opens in its own window, or
    /// raises the window it already has.
    func open(path: String, from: FinderWindow) { openFolder(path) }

    /// Close one window; the last one out ends the process.
    func close(_ w: FinderWindow) {
        windows.removeAll { $0 === w }
        w.tearDown()
        FinderWindow.log("closed \(w.directory) (\(windows.count) open)")
        if windows.isEmpty, quitsWithLastWindow { display.stop() }
    }

    /// A window switched mode: apply it everywhere and remember it.
    func setToolbarVisible(_ visible: Bool) {
        toolbarVisible = visible
        for w in windows { w.applyToolbarVisible(visible) }
        FinderWindow.log(visible ? "toolbar shown (browser mode)"
                                 : "toolbar hidden (spatial mode)")
        var config = (try? Pool.load("finder")) ?? Config()
        _ = config.set("finder", "toolbar", bool: visible)
        try? config.store("finder")
    }

    public var windowCount: Int { windows.count }
}

// MARK: - The live window

public final class FinderWindow: WindowDelegate {
    private var window: Window?
    private weak var app: FinderApp?
    private var toolbarVisible: Bool
    private var path: String
    private var entries: [FinderEntry] = []
    private var selection: Int?
    private var scroll = 0.0
    private var view: FinderView
    private let showHidden: Bool
    private var freeBytes: UInt64 = 0
    private var backStack: [String] = []
    private var layout = FinderLayout()

    private var pointerX = 0.0
    private var pointerY = 0.0
    private var draggingThumb = false
    /// The row a press landed on, until it becomes a click or a drag.
    private var pressedRow: Int?
    private var pressAtX = 0.0
    private var pressAtY = 0.0
    private var thumbGrabDy = 0.0
    private var backPressed = false
    private var lastClickIndex: Int?
    private var lastClickMs: Int64 = 0
    // Non-nil while renaming an item in place.
    private var edit: FinderEdit?

    /// Where a Finder window opens: $ABYSS_FINDER_DIR, else $HOME, else "/".
    public static func startDirectory() -> String {
        if let d = getenv("ABYSS_FINDER_DIR") {
            let s = String(cString: d)
            if !s.isEmpty { return s }
        }
        if let h = getenv("HOME") {
            let s = String(cString: h)
            if !s.isEmpty { return s }
        }
        return "/"
    }

    init?(display: Display, app: FinderApp, path: String,
          toolbarVisible: Bool, width: Int32, height: Int32) {
        let config = (try? Pool.load("finder")) ?? Config()
        showHidden = config.bool("finder", "show_hidden") ?? false
        view = config.string("finder", "view") == "list" ? .list : .icon
        self.app = app
        self.toolbarVisible = toolbarVisible
        self.path = path

        let (scale, auto) = FinderWindow.scaleConfig()
        guard let win = Window(display: display,
                               title: finderDisplayName(path),
                               appID: "org.abyssbsd.finder",
                               width: width, height: height,
                               scale: scale, autoScale: auto, delegate: self)
        else { return nil }
        window = win
        reload()
    }

    /// The directory this window shows (FinderApp matches on it to raise).
    var directory: String { path }

    /// Whether folders open in a new window rather than in place.
    private var isSpatial: Bool { !toolbarVisible }

    /// Bring this window forward (xdg-activation).
    func raise() {
        if window?.activate() != true {
            FinderWindow.log("raise unavailable (no xdg-activation)")
        }
    }

    func applyToolbarVisible(_ visible: Bool) {
        guard visible != toolbarVisible else { return }
        toolbarVisible = visible
        scroll = 0
        window?.setNeedsDisplay()
    }

    /// Re-read this window's directory (after a file operation, possibly one
    /// made in another window), keeping `name` selected if it's still there.
    func refresh(selecting name: String? = nil) {
        let keep = name ?? selection.map { $0 < entries.count ? entries[$0].name : "" }
        let savedScroll = scroll
        reload(selecting: keep)
        scroll = min(savedScroll, maxScroll)
        revealSelection()
        window?.setNeedsDisplay()
    }

    /// Destroy this window's surface (called by FinderApp).
    func tearDown() {
        window?.close()
        window = nil
    }

    private static func scaleConfig() -> (scale: Int32, auto: Bool) {
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 {
            return (v, false)
        }
        return (1, true)
    }

    static func log(_ msg: String) {
        let line = "Finder: \(msg)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    // MARK: navigation

    /// Re-read the current directory. `selecting` names the entry to leave
    /// selected — the Finder highlights the folder you just came out of.
    private func reload(selecting name: String? = nil) {
        entries = readDirectory(path, showHidden: showHidden)
        freeBytes = finderFreeSpace(path)
        selection = name.flatMap { n in entries.firstIndex { $0.name == n } }
        scroll = 0
        revealSelection()
        window?.setTitle(finderDisplayName(path))
        FinderWindow.log("listed \(path) (\(entries.count) items)")
        window?.setNeedsDisplay()
    }

    /// Open `dest` in this window, remembering where we came from (the 10.2
    /// Finder browses in place; Back returns).
    private func navigate(to dest: String, selecting name: String? = nil) {
        backStack.append(path)
        path = dest
        FinderWindow.log("opened \(dest)")
        reload(selecting: name)
    }

    private func goBack() {
        guard let prev = backStack.popLast() else { return }
        let leaving = finderDisplayName(path)
        path = prev
        FinderWindow.log("back to \(prev)")
        reload(selecting: leaving)
    }

    private func goUp() {
        guard let parent = finderParent(path) else { return }
        if isSpatial {
            app?.open(path: parent, from: self)
        } else {
            navigate(to: parent, selecting: finderDisplayName(path))
        }
    }

    /// Activate an item. A folder opens in place (browser mode) or in its own
    /// window (spatial mode); a file is launched — or, when this Finder is
    /// running as a portal's picker, *chosen* (PHASE7.md P7.1). A file dialog
    /// that launched what you clicked would be both surprising and a way to make
    /// the picker run things on the requesting app's behalf.
    private func activate(_ i: Int) {
        guard i >= 0, i < entries.count else { return }
        switch finderActivation(entry: entries[i], in: path,
                                picking: FinderPicker.isPicking) {
        case .choose(let full):
            FinderWindow.log("picked \(full)")
            FinderPicker.chose(full)
        case .launch(let full):
            // An app bundle, an executable, or the opener command (Launcher).
            FinderWindow.log(Launcher.open(full).description + " (\(full))")
        case .navigate(let full):
            if isSpatial {
                app?.open(path: full, from: self)
            } else {
                navigate(to: full)
            }
        }
    }

    /// The pill in the title bar: show/hide the toolbar, which is what switches
    /// between browser and spatial behaviour (as in 10.2).
    private func toggleToolbar() {
        app?.setToolbarVisible(!toolbarVisible)
    }

    /// The red traffic light. In spatial mode windows come and go constantly, so
    /// this closes just this one; the last one out stops the display.
    private func closeWindow() {
        if let app {
            app.close(self)
        } else {
            window?.close()
            window?.stopDisplay()
        }
    }

    // MARK: scrolling

    private var viewport: Rect { finderItemViewport(layout, view: view) }

    private var maxScroll: Double {
        finderMaxScroll(count: entries.count, view: view, viewport: viewport)
    }

    private func scrollBy(_ dy: Double) {
        let old = scroll
        scroll = max(0, min(scroll + dy, maxScroll))
        if scroll != old { window?.setNeedsDisplay() }
    }

    private func revealSelection() {
        guard let s = selection else { return }
        scroll = finderScrollToShow(s, scroll: scroll, count: entries.count,
                                    view: view, viewport: viewport)
    }

    private func select(_ i: Int?) {
        selection = i
        if let i, i >= 0, i < entries.count {
            FinderWindow.log("selected \(entries[i].name)")
        }
        revealSelection()
        window?.setNeedsDisplay()
    }

    private func setView(_ v: FinderView) {
        guard v != view else { return }
        view = v
        scroll = 0
        revealSelection()
        FinderWindow.log("view -> \(v == .icon ? "icon" : "list")")
        window?.setNeedsDisplay()
    }

    // MARK: file operations

    /// Does `name` already exist in this directory?
    private func exists(_ name: String) -> Bool {
        finderExists(finderJoin(path, name))
    }

    private var selectedEntry: FinderEntry? {
        guard let s = selection, s >= 0, s < entries.count else { return nil }
        return entries[s]
    }

    /// ⌘⇧N: make "untitled folder" and go straight into renaming it, as the
    /// Finder does.
    private func newFolder() {
        let name = finderNewFolderName(exists: exists)
        guard finderCreateDirectory(finderJoin(path, name)) else {
            FinderWindow.log("could not create \(name) in \(path)")
            return
        }
        FinderWindow.log("new folder \(finderJoin(path, name))")
        app?.refreshWindows(showing: path, selecting: name) ?? refresh(selecting: name)
        beginRename()
    }

    /// Return: edit the selected item's name in place.
    private func beginRename() {
        guard let s = selection, let entry = selectedEntry else { return }
        edit = FinderEdit.renaming(s, name: entry.name)
        window?.setNeedsDisplay()
    }

    private func cancelRename() {
        guard edit != nil else { return }
        edit = nil
        window?.setNeedsDisplay()
    }

    private func commitRename() {
        guard let e = edit, e.index < entries.count else { return cancelRename() }
        let old = entries[e.index].name
        let new = e.text
        edit = nil
        guard new != old else { window?.setNeedsDisplay(); return }
        guard finderIsValidName(new), !exists(new) else {
            FinderWindow.log("rename refused: '\(new)' is taken or not a valid name")
            window?.setNeedsDisplay()
            return
        }
        guard finderRenameEntry(from: finderJoin(path, old),
                               to: finderJoin(path, new)) else {
            FinderWindow.log("rename failed: \(old) -> \(new)")
            window?.setNeedsDisplay()
            return
        }
        FinderWindow.log("renamed \(old) -> \(new) in \(path)")
        app?.refreshWindows(showing: path, selecting: new) ?? refresh(selecting: new)
    }

    /// ⌘D: copy the selection beside itself ("Read Me copy.txt").
    private func duplicateSelection() {
        guard let entry = selectedEntry else { return }
        let name = finderCopyName(entry.name, exists: exists)
        guard finderCopyPath(from: finderJoin(path, entry.name),
                             to: finderJoin(path, name)) else {
            FinderWindow.log("duplicate failed: \(entry.name)")
            return
        }
        FinderWindow.log("duplicated \(entry.name) -> \(name) in \(path)")
        app?.refreshWindows(showing: path, selecting: name) ?? refresh(selecting: name)
    }

    /// ⌘C / ⌘X.
    private func clipSelection(cut: Bool) {
        guard let entry = selectedEntry else { return }
        app?.setClipboard(path: finderJoin(path, entry.name), cut: cut)
    }

    /// ⌘V: copy (or move, after a cut) the clipboard item into this folder.
    private func paste() {
        guard let clip = app?.clipboardPath() else { return }
        let source = clip.path
        guard finderExists(source) else {
            FinderWindow.log("paste failed: \(source) is gone")
            app?.clearClipboard()
            return
        }
        let sourceDir = finderParent(source) ?? ""
        let name = finderPasteName(finderDisplayName(source), exists: exists)
        let dest = finderJoin(path, name)
        let ok = clip.cut ? finderRenameEntry(from: source, to: dest)
                          : finderCopyPath(from: source, to: dest)
        guard ok else {
            FinderWindow.log("paste failed: \(source) -> \(dest)")
            return
        }
        FinderWindow.log("pasted \(source) -> \(dest)")
        if clip.cut {
            app?.clearClipboard()
            // A move empties the source folder's view too.
            if sourceDir != path { app?.refreshWindows(showing: sourceDir) }
        }
        app?.refreshWindows(showing: path, selecting: name) ?? refresh(selecting: name)
    }

    /// ⌘⌫: move the selection to ~/.Trash (never an unlink).
    private func trashSelection() {
        guard let entry = selectedEntry else { return }
        let source = finderJoin(path, entry.name)
        guard let dest = finderMoveToTrash(source) else {
            FinderWindow.log("could not move \(source) to the Trash")
            return
        }
        FinderWindow.log("trashed \(source) -> \(dest)")
        app?.refreshWindows(showing: path) ?? refresh()
    }

    private func nowMs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }

    // MARK: WindowDelegate

    public func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale)
        let h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(
            buffer.data.assumingMemoryBound(to: UInt8.self),
            CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
        cairo_paint(cr)
        cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)

        scroll = max(0, min(scroll, maxScroll))
        let state = FinderState(path: path, entries: entries, selection: selection,
                                scroll: scroll, view: view,
                                canGoBack: !backStack.isEmpty, freeBytes: freeBytes,
                                backPressed: backPressed,
                                toolbarVisible: toolbarVisible, edit: edit,
                                pickerTitle: FinderPicker.isPicking ? "Choose a File" : nil)
        layout = paintFinder(cr, w: w, h: h, state: state)

        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }

    public func pointerMoved(x: Double, y: Double) {
        pointerX = x
        pointerY = y
        if draggingThumb {
            dragThumb(to: y - thumbGrabDy)
            window?.setNeedsDisplay()
        }
        // **A drag begins when a press turns into movement**, not when the
        // button goes down: a click that happens to wobble by a pixel is still
        // a click, and starting a drag on every press would make selecting a
        // file impossible. Four pixels is the usual threshold and is far enough
        // that nobody reaches it by accident.
        if let idx = pressedRow, !draggingThumb {
            let dx = x - pressAtX, dy = y - pressAtY
            if dx * dx + dy * dy > 16 { beginDrag(of: idx) }
        }
    }

    /// Hand a file to the rest of the desktop.
    private func beginDrag(of index: Int) {
        pressedRow = nil                       // one drag per press
        guard entries.indices.contains(index), let surface = window?.surface,
              let clip = app?.display.clipboard else { return }
        let path = finderJoin(directory, entries[index].name)
        let uri = finderFileURI(path)
        // The serial is the pointer press that started this — the compositor
        // checks it (`validate_pointer_grab_serial`), which is what stops a
        // program starting a drag nobody initiated.
        let ok = clip.startDrag(Array(uri.utf8), from: surface,
                                serial: app?.display.lastPointerSerial ?? 0,
                                types: [ClipboardMIME.uriList, ClipboardMIME.text])
        FinderWindow.log(ok ? "dragging \(path)" : "could not start a drag of \(path)")
    }

    private func dragThumb(to thumbTopY: Double) {
        let vp = viewport
        let contentH = finderContentHeight(count: entries.count, view: view, viewport: vp)
        guard let thumb = thumbRect(track: layout.track, offset: scroll,
                                    viewportH: vp.h, contentH: contentH) else { return }
        let travel = layout.track.h - thumb.h
        guard travel > 0 else { return }
        let t = max(0, min(1, (thumbTopY - layout.track.y) / travel))
        scroll = t * maxScroll
    }

    public func pointerAxis(_ axis: UInt32, value: Double) {
        guard axis == 0 else { return }
        scrollBy(value * 2)
    }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard button == kBtnLeft else { return }
        if pressed, edit != nil { commitRename() }
        guard pressed else {
            draggingThumb = false
            pressedRow = nil
            if backPressed {
                backPressed = false
                if layout.backButton.contains(pointerX, pointerY) { goBack() }
                window?.setNeedsDisplay()
            }
            return
        }

        // Title bar: the pill toggles the toolbar (browser ⇄ spatial), the red
        // light closes this window.
        let w = Double(window?.size.width ?? 0)
        if windowPillRect(w: w).contains(pointerX, pointerY) { toggleToolbar(); return }
        if windowTrafficRects().close.contains(pointerX, pointerY) { closeWindow(); return }

        if toolbarVisible {
            if layout.backButton.contains(pointerX, pointerY) {
                if !backStack.isEmpty { backPressed = true; window?.setNeedsDisplay() }
                return
            }
            let segs = Draw.segmentRects(layout.viewControl, count: 2)
            if segs.count == 2 {
                if segs[0].contains(pointerX, pointerY) { setView(.icon); return }
                if segs[1].contains(pointerX, pointerY) { setView(.list); return }
            }
        }

        // Scrollbar: thumb drag, arrows, page-toward-click.
        let vp = viewport
        let contentH = finderContentHeight(count: entries.count, view: view, viewport: vp)
        if let thumb = thumbRect(track: layout.track, offset: scroll,
                                 viewportH: vp.h, contentH: contentH),
           thumb.contains(pointerX, pointerY) {
            draggingThumb = true
            thumbGrabDy = pointerY - thumb.y
            return
        }
        if layout.upArrow.contains(pointerX, pointerY) { scrollBy(-FinderMetrics.rowHeight * 2); return }
        if layout.downArrow.contains(pointerX, pointerY) { scrollBy(FinderMetrics.rowHeight * 2); return }
        if layout.track.contains(pointerX, pointerY) {
            if let thumb = thumbRect(track: layout.track, offset: scroll,
                                     viewportH: vp.h, contentH: contentH) {
                scrollBy(pointerY < thumb.y ? -vp.h * 0.9 : vp.h * 0.9)
            }
            return
        }

        // The item well: click selects, a second click on the same item within
        // the double-click window opens it.
        guard vp.contains(pointerX, pointerY) else { return }
        let hit = finderIndex(atX: pointerX, y: pointerY, count: entries.count,
                              view: view, viewport: vp, scroll: scroll)
        let now = nowMs()
        if let hit {
            let isDouble = hit == lastClickIndex && now - lastClickMs <= kDoubleClickMs
            lastClickIndex = hit
            lastClickMs = now
            if isDouble {
                lastClickIndex = nil    // don't chain a third click into another open
                activate(hit)
            } else {
                select(hit)
                // Armed, not started: `pointerMoved` decides whether this press
                // was a click or the beginning of a drag.
                pressedRow = hit
                pressAtX = pointerX
                pressAtY = pointerY
            }
        } else {
            lastClickIndex = nil
            select(nil)                 // click in empty space deselects
        }
    }

    /// This window's `wl_surface` — how a drop is matched back to a window.
    var surface: OpaquePointer? { window?.surface }

    /// A file was dropped here: copy it in, exactly as ⌘V would.
    func receiveDrop(of path: String) {
        let name = finderPasteName(finderDisplayName(path), exists: exists)
        let dest = finderJoin(directory, name)
        guard finderCopyPath(from: path, to: dest) else {
            FinderWindow.log("drop failed: \(path) -> \(dest)")
            return
        }
        FinderWindow.log("dropped \(path) -> \(dest)")
        app?.refreshWindows(showing: directory, selecting: name) ?? refresh(selecting: name)
    }

    public func windowShouldClose(_ window: Window) {
        // Closing a picker is declining it: exit non-zero so the portal can tell
        // "the user cancelled" from "the picker chose something".
        if FinderPicker.isPicking { FinderPicker.cancelled() }
        closeWindow()
    }

    /// The ASCII letter a keysym stands for, lowercased (X11 keysyms for ASCII
    /// *are* the ASCII values), so ⌘N and ⌘⇧N match the same case.
    private func letter(_ event: KeyEvent) -> Character? {
        guard event.keysym >= 0x21, event.keysym <= 0x7e,
              let scalar = UnicodeScalar(event.keysym) else { return nil }
        return Character(scalar).lowercased().first
    }

    /// ⌘S in a save picker: choose `<the folder on screen>/<suggested name>`.
    /// A save dialog must be able to name a file that does not exist yet, which
    /// picking from a listing cannot express (see FinderPicker.saveName).
    private func saveHere() {
        guard let name = FinderPicker.saveName() else { return }
        let full = finderJoin(path, name)
        FinderWindow.log("picked \(full)")
        FinderPicker.chose(full)
    }

    /// Keys while an inline rename is up: the field owns the keyboard.
    private func editKey(_ event: KeyEvent, _ e: FinderEdit) {
        switch event.keysym {
        case KeySym.enter:
            commitRename()
        case KeySym.escape:
            cancelRename()
        case KeySym.backspace:
            guard !e.text.isEmpty else { return }
            edit = e.deletingBackward()
            window?.setNeedsDisplay()
        default:
            guard !event.text.isEmpty, !event.modifiers.contains(.command) else { return }
            edit = e.typing(event.text)
            window?.setNeedsDisplay()
        }
    }

    /// The Finder's ⌘-shortcuts. Returns false if this isn't one of them.
    private func commandKey(_ event: KeyEvent) -> Bool {
        switch event.keysym {
        case KeySym.delete, KeySym.backspace: trashSelection(); return true
        case KeySym.down:  if let s = selection { activate(s) }; return true
        case KeySym.up:    goUp(); return true
        default: break
        }
        switch letter(event) {
        case "n" where event.modifiers.contains(.shift): newFolder()
        case "o": if let s = selection { activate(s) }
        case "d": duplicateSelection()
        case "c": clipSelection(cut: false)
        case "x": clipSelection(cut: true)
        case "v": paste()
        case "s" where FinderPicker.isSaving: saveHere()
        default: return false
        }
        return true
    }

    public func keyEvent(_ event: KeyEvent) {
        guard event.pressed else { return }
        // An open rename field takes everything.
        if let e = edit { editKey(event, e); return }
        if event.modifiers.contains(.command), commandKey(event) { return }

        let vp = viewport
        switch event.keysym {
        case KeySym.enter:
            // Mac verbs: Return renames, ⌘O / ⌘↓ (and double-click) open.
            beginRename()
        case KeySym.backspace:
            goUp()
        case KeySym.escape:
            // In a picker, Escape is Cancel — the dialog convention. It still
            // clears the selection first, so one Escape deselects and a second
            // declines, which is what a Mac file dialog does.
            if FinderPicker.isPicking && selection == nil { FinderPicker.cancelled() }
            select(nil)
        case KeySym.left:
            select(finderMove(from: selection, dx: -1, dy: 0, count: entries.count,
                              view: view, viewport: vp))
        case KeySym.right:
            select(finderMove(from: selection, dx: 1, dy: 0, count: entries.count,
                              view: view, viewport: vp))
        case KeySym.up:
            select(finderMove(from: selection, dx: 0, dy: -1, count: entries.count,
                              view: view, viewport: vp))
        case KeySym.down:
            select(finderMove(from: selection, dx: 0, dy: 1, count: entries.count,
                              view: view, viewport: vp))
        case KeySym.home:
            select(entries.isEmpty ? nil : 0)
        case KeySym.end:
            select(entries.isEmpty ? nil : entries.count - 1)
        case KeySym.pageUp:
            scrollBy(-vp.h * 0.9)
        case KeySym.pageDown:
            scrollBy(vp.h * 0.9)
        case KeySym.tab:
            setView(view == .icon ? .list : .icon)
        default:
            // Type-ahead: a printable character jumps to the next matching name.
            guard !event.text.isEmpty, event.text != " ",
                  !event.modifiers.contains(.command),
                  !event.modifiers.contains(.control) else { return }
            if let i = finderTypeSelect(entries, prefix: event.text, after: selection) {
                select(i)
            }
        }
    }
}
