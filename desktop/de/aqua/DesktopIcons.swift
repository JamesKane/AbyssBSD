// DesktopIcons — the icons that live on the desktop itself: the boot volume and
// whatever is in ~/Desktop, drawn onto the wallpaper's BACKGROUND layer surface.
//
// The arrangement is the Jaguar one and it is *not* the Finder's: desktop icons
// stack **from the top-right corner downwards**, then wrap into a new column to
// the left — so the volume sits under the menu bar's right end and new items
// grow down and inward. `desktopIconLayout` is pure, so the placement and the
// hit-test can't disagree (HANDOFF §2.9), and it's unit-testable with no
// compositor.
//
// Labels are white with a dark shadow rather than the Finder's dark-on-white:
// they sit on an arbitrary wallpaper and have to stay legible over both a pale
// gradient and a photograph.

import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum DesktopMetrics {
    public static var cellW: Double { Theme.current.desktopCellW }
    public static var cellH: Double { Theme.current.desktopCellH }
    public static var iconSize: Double { Theme.current.desktopIconSize }
    public static var margin: Double { Theme.current.desktopMargin }
    /// Room left at the top for the menu bar, which overlaps the wallpaper.
    public static var topInset: Double { Theme.current.desktopTopInset }
}

/// How many rows of icons fit in `bounds` (at least one).
public func desktopRows(bounds: Rect) -> Int {
    max(1, Int((bounds.h - 2 * DesktopMetrics.margin) / DesktopMetrics.cellH))
}

/// The cell rect for icon `i`: filling the right-hand column top to bottom, then
/// wrapping to the column on its left.
public func desktopIconRect(_ i: Int, bounds: Rect) -> Rect {
    let rows = desktopRows(bounds: bounds)
    let col = i / rows, row = i % rows
    let x = bounds.x + bounds.w - DesktopMetrics.margin
            - Double(col + 1) * DesktopMetrics.cellW
    let y = bounds.y + DesktopMetrics.margin + Double(row) * DesktopMetrics.cellH
    return Rect(x, y, DesktopMetrics.cellW, DesktopMetrics.cellH)
}

/// The icon under a point, or nil. Only the icon and its label are hit — the
/// blank half of a cell belongs to the desktop, as on Mac.
public func desktopIndex(atX x: Double, y: Double, count: Int, bounds: Rect) -> Int? {
    guard count > 0 else { return nil }
    for i in 0..<count {
        let cell = desktopIconRect(i, bounds: bounds)
        let icon = desktopIconBox(cell)
        let label = Rect(cell.x + 4, icon.y + icon.h + 2, cell.w - 8, 16)
        if icon.contains(x, y) || label.contains(x, y) { return i }
    }
    return nil
}

/// Where the icon art sits inside a cell (the label goes underneath).
public func desktopIconBox(_ cell: Rect) -> Rect {
    Rect(cell.x + (cell.w - DesktopMetrics.iconSize) / 2, cell.y + 4,
         DesktopMetrics.iconSize, DesktopMetrics.iconSize)
}

/// The desktop's items: the boot volume first (so it lands top-right, where the
/// Mac puts it), then the contents of the Desktop folder in Finder order.
public func desktopEntries(volumeName: String, desktopFolder: String?,
                           showHidden: Bool = false) -> [FinderEntry] {
    var items = [FinderEntry(name: volumeName, kind: .disk)]
    if let dir = desktopFolder {
        items += readDirectory(dir, showHidden: showHidden)
    }
    return items
}

/// A fixed desktop for the PNG preview, so the shot is the same on any machine.
public func desktopSampleEntries() -> [FinderEntry] {
    [FinderEntry(name: "AbyssBSD HD", kind: .disk)]
        + finderSort([
            FinderEntry(name: "Projects", kind: .folder),
            FinderEntry(name: "Screenshot.png", kind: .document, size: 148_000),
            FinderEntry(name: "Notes.rtf", kind: .document, size: 3_200),
        ])
}

/// Paint the desktop icons over an already-painted wallpaper.
public func paintDesktopIcons(_ cr: OpaquePointer, bounds: Rect,
                              entries: [FinderEntry], selection: Int?) {
    for (i, entry) in entries.enumerated() {
        let cell = desktopIconRect(i, bounds: bounds)
        guard cell.x + cell.w > bounds.x else { break }   // ran off the left edge
        let icon = desktopIconBox(cell)
        let selected = selection == i

        if selected {
            Draw.paint("desktop.selection", cr, icon)
        }
        drawFinderIcon(cr, entry, icon)

        let label = desktopTruncated(cr, entry.name, maxWidth: cell.w - 10, size: 11)
        let tw = Draw.textWidth(cr, label, size: 11)
        let cx = cell.x + cell.w / 2
        let labelY = icon.y + icon.h + 3

        if selected {
            Draw.paint("iconlabel.selected", cr, Rect(cx - tw / 2 - 4, labelY, tw + 8, 14))
            Draw.text(cr, label, centerX: cx, centerY: labelY + 7,
                      color: Theme.menuTextOnHighlight, size: 11)
        } else {
            // White on a dark shadow, so the label reads over any wallpaper.
            Draw.text(cr, label, centerX: cx + 1, centerY: labelY + 8,
                      color: Theme.desktopLabelShadow, size: 11)
            Draw.text(cr, label, centerX: cx, centerY: labelY + 7,
                      color: Theme.desktopLabelText, size: 11)
        }
    }
}

/// Shorten a label with an ellipsis until it fits (the desktop has no column to
/// widen, unlike a Finder window).
private func desktopTruncated(_ cr: OpaquePointer, _ s: String, maxWidth: Double,
                              size: Double) -> String {
    guard maxWidth > 0, Draw.textWidth(cr, s, size: size) > maxWidth else { return s }
    var out = s
    while !out.isEmpty, Draw.textWidth(cr, out + "…", size: size) > maxWidth {
        out.removeLast()
    }
    return out + "…"
}
