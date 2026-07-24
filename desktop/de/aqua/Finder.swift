// Finder — the AbyssBSD file browser, in Jaguar dress. Unlike the desktop, menu
// bar and Dock (wlr-layer-shell shell components), the Finder is an ordinary
// xdg-shell application: it reuses Surface.Window and the whole Aqua toolkit.
//
// Fidelity note: the 10.2 Finder is a *browser*, not a spatial file manager —
// a toolbar with Back and a view switch, and folders open in place. (Brushed
// metal arrived with 10.3; Jaguar's Finder is standard Aqua, which is why this
// reuses paintWindowChrome.) The Rust sibling's `reef-fm` was spatial and
// GNOME-2 flavoured, so only its structure carries over, not its behaviour.
//
// Everything geometric lives in FinderModel.swift as pure functions, so the
// painter below and the pointer/keyboard handlers hit-test identical rects.
//
// Config (domain `finder`, ~/.config/abyss/finder.ini):
//   view        = icon | list
//   show_hidden = true | false
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

    public init(path: String, entries: [FinderEntry], selection: Int? = nil,
                scroll: Double = 0, view: FinderView = .icon,
                canGoBack: Bool = false, freeBytes: UInt64 = 0,
                backPressed: Bool = false) {
        self.path = path
        self.entries = entries
        self.selection = selection
        self.scroll = scroll
        self.view = view
        self.canGoBack = canGoBack
        self.freeBytes = freeBytes
        self.backPressed = backPressed
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
    paintWindowChrome(cr, w: w, h: h, title: finderDisplayName(state.path))
    let L = finderLayout(w: w, h: h)

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
        switch state.view {
        case .icon: paintFinderIconCell(cr, entry, cell, selected: selected)
        case .list: paintFinderListRow(cr, entry, cell, selected: selected)
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
                                 _ cell: Rect, selected: Bool) {
    let size = FinderMetrics.iconSize
    let icon = Rect(cell.x + (cell.w - size) / 2, cell.y + 4, size, size)
    if selected {
        // Jaguar tints the selected icon with a soft blue wash.
        Draw.roundedRect(cr, Rect(icon.x - 3, icon.y - 3, size + 6, size + 6), radius: 6)
        Draw.setColor(cr, Theme.menuHighlight.with(a: 0.22))
        cairo_fill(cr)
    }
    drawFinderIcon(cr, entry.kind, icon)

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
                                _ row: Rect, selected: Bool) {
    if selected {
        cairo_rectangle(cr, row.x, row.y, row.w, row.h)
        Draw.setColor(cr, Theme.menuHighlight)
        cairo_fill(cr)
    }
    let fg = selected ? Theme.menuTextOnHighlight : Theme.bodyText
    let cols = finderListColumns(row)
    let iconSide = FinderMetrics.listIcon
    let icon = Rect(cols[0].x + 4, row.y + (row.h - iconSide) / 2, iconSide, iconSide)
    drawFinderIcon(cr, entry.kind, icon)

    let baseline = row.y + row.h - 5
    let nameX = icon.x + iconSide + 5
    let name = finderTruncated(cr, entry.name, maxWidth: cols[0].w - (nameX - cols[0].x) - 6,
                               size: 11)
    Draw.textLeft(cr, name, x: nameX, baselineY: baseline, color: fg, size: 11)
    let sizeText = entry.isContainer || entry.kind == .application
        ? "--" : finderFormatBytes(entry.size)
    Draw.textLeft(cr, sizeText, x: cols[1].x + 6, baselineY: baseline, color: fg, size: 11)
    Draw.textLeft(cr, finderKindLabel(entry.kind), x: cols[2].x + 6, baselineY: baseline,
                  color: fg, size: 11)
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

/// A volume: a grey drive slab with a lighter top face.
private func drawDiskIcon(_ cr: OpaquePointer, _ r: Rect) {
    let body = Rect(r.x + r.w * 0.08, r.y + r.h * 0.26, r.w * 0.84, r.h * 0.48)
    Draw.roundedRect(cr, body, radius: r.w * 0.08)
    let g = cairo_pattern_create_linear(0, body.y, 0, body.y + body.h)
    cairo_pattern_add_color_stop_rgba(g, 0, 0.90, 0.91, 0.94, 1)
    cairo_pattern_add_color_stop_rgba(g, 1, 0.63, 0.65, 0.70, 1)
    cairo_set_source(cr, g)
    cairo_fill(cr)
    cairo_pattern_destroy(g)
    Draw.roundedRect(cr, body, radius: r.w * 0.08)
    cairo_set_source_rgba(cr, 0.35, 0.37, 0.42, 0.85)
    cairo_set_line_width(cr, max(0.6, r.w * 0.02))
    cairo_stroke(cr)
    cairo_new_path(cr)
    cairo_arc(cr, body.x + body.w * 0.8, body.y + body.h * 0.5, r.w * 0.05, 0, 2 * .pi)
    cairo_set_source_rgba(cr, 0.35, 0.55, 0.85, 1)
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

// MARK: - The live window

public final class FinderWindow: WindowDelegate {
    private var window: Window?
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
    private var thumbGrabDy = 0.0
    private var backPressed = false
    private var lastClickIndex: Int?
    private var lastClickMs: Int64 = 0

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

    public init?(display: Display, path: String? = nil,
                 width: Int32 = 520, height: Int32 = 400) {
        let config = (try? Pool.load("finder")) ?? Config()
        showHidden = config.bool("finder", "show_hidden") ?? false
        view = config.string("finder", "view") == "list" ? .list : .icon
        self.path = path ?? FinderWindow.startDirectory()

        let (scale, auto) = FinderWindow.scaleConfig()
        guard let win = Window(display: display,
                               title: finderDisplayName(self.path),
                               appID: "org.abyssbsd.finder",
                               width: width, height: height,
                               scale: scale, autoScale: auto, delegate: self)
        else { return nil }
        window = win
        display.window = win
        reload()
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
        navigate(to: parent, selecting: finderDisplayName(path))
    }

    /// Activate an item: containers open in this window, everything else logs
    /// (launching an app / opening a document needs exec + xdg-activation).
    private func activate(_ i: Int) {
        guard i >= 0, i < entries.count else { return }
        let entry = entries[i]
        let full = finderJoin(path, entry.name)
        if entry.isContainer {
            navigate(to: full)
        } else {
            FinderWindow.log("open item \(full)")
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
                                backPressed: backPressed)
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
        guard pressed else {
            draggingThumb = false
            if backPressed {
                backPressed = false
                if layout.backButton.contains(pointerX, pointerY) { goBack() }
                window?.setNeedsDisplay()
            }
            return
        }

        if layout.backButton.contains(pointerX, pointerY) {
            if !backStack.isEmpty { backPressed = true; window?.setNeedsDisplay() }
            return
        }
        let segs = Draw.segmentRects(layout.viewControl, count: 2)
        if segs.count == 2 {
            if segs[0].contains(pointerX, pointerY) { setView(.icon); return }
            if segs[1].contains(pointerX, pointerY) { setView(.list); return }
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
            }
        } else {
            lastClickIndex = nil
            select(nil)                 // click in empty space deselects
        }
    }

    public func keyEvent(_ event: KeyEvent) {
        guard event.pressed else { return }
        let vp = viewport
        switch event.keysym {
        case KeySym.enter:
            if let s = selection { activate(s) }
        case KeySym.backspace:
            goUp()
        case KeySym.escape:
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
            guard !event.text.isEmpty, event.text != " " else { return }
            if let i = finderTypeSelect(entries, prefix: event.text, after: selection) {
                select(i)
            }
        }
    }
}
