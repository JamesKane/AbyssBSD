// Sheet — an Aqua modal sheet: a panel that slides down from the window's title
// bar while the content behind it dims. It isn't a separate surface; the window
// draws its base content, a dim overlay, then the sheet panel (clipped to below
// the title bar and translated up by (1 - progress) of its height, so it appears
// to emerge from under the title bar). AquaWindow animates `progress` from the
// per-frame windowDidRenderFrame tick.

import CCairo

public struct SheetScene {
    public var baseButton = Rect(0, 0, 0, 0)   // opens the sheet (base layer)
    public var cancel = Rect(0, 0, 0, 0)       // sheet buttons (hit only when open)
    public var ok = Rect(0, 0, 0, 0)
}

private let sheetPanelHeight = 132.0

/// Geometry of the sheet panel and its buttons at logical size (w, h).
public func sheetLayout(w: Double, h: Double)
    -> (panel: Rect, cancel: Rect, ok: Rect) {
    let panelW = min(w - 48, 380)
    let panel = Rect((w - panelW) / 2, Theme.titleBarHeight, panelW, sheetPanelHeight)
    let bw = 96.0, bh = 28.0
    let by = panel.y + panel.h - bh - 16
    let ok = Rect(panel.x + panel.w - bw - 16, by, bw, bh)
    let cancel = Rect(ok.x - bw - 10, by, bw, bh)
    return (panel, cancel, ok)
}

/// The base-layer "Delete…" button rect.
public func sheetBaseButton(w: Double, h: Double) -> Rect {
    Rect((w - 130) / 2, 150, 130, 30)
}

/// Paint the sheet scene: base content, then (if visible) the dim overlay and
/// the sliding panel. `progress` is 0 (hidden) … 1 (fully out). Returns the hit
/// rects; sheet buttons are only meaningful when fully open (progress >= 1).
@discardableResult
public func paintSheetScene(_ cr: OpaquePointer, w: Double, h: Double,
                            progress: Double, visible: Bool,
                            lastAction: String) -> SheetScene {
    paintWindowChrome(cr, w: w, h: h, title: "Sheets")
    var s = SheetScene()

    Draw.textLeft(cr, "Delete a file", x: 24, baselineY: 70,
                  color: Theme.bodyText, size: 16)
    Draw.textLeft(cr, "Removing it opens a confirmation sheet.", x: 24,
                  baselineY: 94, color: Theme.bodyText.with(a: 0.7),
                  size: Theme.fontSize)
    Draw.textLeft(cr, "Last action: \(lastAction)", x: 24, baselineY: 128,
                  color: Theme.bodyText, size: Theme.fontSize)

    s.baseButton = sheetBaseButton(w: w, h: h)
    Draw.gelButton(cr, s.baseButton, label: "Delete…", blue: false, pressed: false)

    guard visible else { return s }

    // Dim the body (below the title bar) as the sheet comes out.
    Draw.setColor(cr, Theme.sheetDim.with(a: Theme.sheetDim.a * progress))
    cairo_rectangle(cr, 0, Theme.titleBarHeight, w, h - Theme.titleBarHeight)
    cairo_fill(cr)

    let (panel, cancel, ok) = sheetLayout(w: w, h: h)
    s.cancel = cancel
    s.ok = ok

    cairo_save(cr)
    cairo_rectangle(cr, 0, Theme.titleBarHeight, w, h - Theme.titleBarHeight)
    cairo_clip(cr)
    cairo_translate(cr, 0, -(1 - progress) * panel.h)
    drawSheetPanel(cr, panel, cancel: cancel, ok: ok)
    cairo_restore(cr)
    return s
}

private func drawSheetPanel(_ cr: OpaquePointer, _ panel: Rect,
                            cancel: Rect, ok: Rect) {
    // Soft drop shadow under the leading edge.
    Draw.setColor(cr, Theme.sheetShadow)
    Draw.roundedRectBottom(cr, Rect(panel.x, panel.y + 2, panel.w, panel.h),
                           radius: 8)
    cairo_fill(cr)

    Draw.roundedRectBottom(cr, panel, radius: 8)
    Draw.setColor(cr, Theme.sheetBackground)
    cairo_fill(cr)
    Draw.roundedRectBottom(cr, panel, radius: 8)
    Draw.setColor(cr, Theme.windowBorder)
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)

    // The primary question is bold Lucida Grande in Aqua; the secondary is regular.
    Draw.textLeft(cr, "Delete this item?", x: panel.x + 24, baselineY: panel.y + 40,
                  color: Theme.bodyText, size: 15, style: .bold)
    Draw.textLeft(cr, "This action can’t be undone.", x: panel.x + 24,
                  baselineY: panel.y + 64, color: Theme.bodyText.with(a: 0.7),
                  size: Theme.fontSize)

    Draw.gelButton(cr, cancel, label: "Cancel", blue: false, pressed: false)
    Draw.gelButton(cr, ok, label: "Delete", blue: true, pressed: false)
}
