// Scroll — a scrolling list scene that exercises the Aqua scrollbar against a
// real clipped viewport. Like the widgets scene, one pure layout function feeds
// both the painter and the hit-tester so the thumb you drag is the thumb you
// see. Jaguar's default scrollbar pairs both arrows at the bottom, which is what
// scrollLayout lays out.

import CCairo

public let scrollItemCount = 24
public let scrollRowHeight = 26.0

/// Geometry that doesn't depend on the scroll offset.
public struct ScrollLayout {
    public var list = Rect(0, 0, 0, 0)     // the clipped content viewport
    public var track = Rect(0, 0, 0, 0)    // the thumb's travel channel
    public var upArrow = Rect(0, 0, 0, 0)
    public var downArrow = Rect(0, 0, 0, 0)
    public var barWidth = 15.0
}

public func scrollContentHeight() -> Double {
    Double(scrollItemCount) * scrollRowHeight
}

/// Largest valid scroll offset for a viewport of height `viewportH`.
public func scrollMaxOffset(viewportH: Double) -> Double {
    max(0, scrollContentHeight() - viewportH)
}

/// Pure geometry for the scroll scene at logical size (w, h).
public func scrollLayout(w: Double, h: Double) -> ScrollLayout {
    var L = ScrollLayout()
    let m = 14.0
    let barW = L.barWidth
    let top = Theme.titleBarHeight + m
    let outer = Rect(m, top, w - 2 * m, h - top - m)
    L.list = Rect(outer.x, outer.y, outer.w - barW, outer.h)
    let barX = outer.x + outer.w - barW
    L.track = Rect(barX, outer.y, barW, outer.h - 2 * barW)
    L.upArrow = Rect(barX, outer.y + outer.h - 2 * barW, barW, barW)
    L.downArrow = Rect(barX, outer.y + outer.h - barW, barW, barW)
    return L
}

/// The thumb rect for `offset` over content of height `contentH`, or nil when
/// the content fits (Aqua hides the thumb then). Shared by every scrolling view
/// — the scroll scene and the Finder both size their thumb from this.
public func thumbRect(track: Rect, offset: Double, viewportH: Double,
                      contentH: Double) -> Rect? {
    guard contentH > viewportH, track.h > 0 else { return nil }
    let thumbH = max(24, track.h * (viewportH / contentH))
    let maxOff = contentH - viewportH
    let t = maxOff > 0 ? max(0, min(1, offset / maxOff)) : 0
    let y = track.y + t * (track.h - thumbH)
    return Rect(track.x + 2, y, track.w - 4, thumbH)
}

/// The scroll scene's thumb (its content height is fixed).
public func scrollThumbRect(track: Rect, offset: Double,
                            viewportH: Double) -> Rect? {
    thumbRect(track: track, offset: offset, viewportH: viewportH,
              contentH: scrollContentHeight())
}

/// Paint the scroll scene and return its (offset-independent) layout.
@discardableResult
public func paintScroll(_ cr: OpaquePointer, w: Double, h: Double,
                        offset: Double) -> ScrollLayout {
    paintWindowChrome(cr, w: w, h: h, title: "Scroll")
    let L = scrollLayout(w: w, h: h)
    let viewportH = L.list.h
    let off = max(0, min(offset, scrollMaxOffset(viewportH: viewportH)))

    // Clipped, striped content.
    cairo_save(cr)
    cairo_rectangle(cr, L.list.x, L.list.y, L.list.w, L.list.h)
    cairo_clip(cr)
    Draw.setColor(cr, Theme.listBackground)
    cairo_rectangle(cr, L.list.x, L.list.y, L.list.w, L.list.h)
    cairo_fill(cr)
    let first = max(0, Int(off / scrollRowHeight))
    let last = min(scrollItemCount - 1,
                   Int((off + viewportH) / scrollRowHeight))
    if first <= last {
        for i in first...last {
            let ry = L.list.y + Double(i) * scrollRowHeight - off
            if i % 2 == 1 {
                Draw.setColor(cr, Theme.listStripe)
                cairo_rectangle(cr, L.list.x, ry, L.list.w, scrollRowHeight)
                cairo_fill(cr)
            }
            let n = i + 1
            let label = n < 10 ? "Item 0\(n)" : "Item \(n)"
            Draw.textLeft(cr, label,
                          x: L.list.x + 12, baselineY: ry + scrollRowHeight - 8,
                          color: Theme.bodyText, size: Theme.fontSize)
        }
    }
    cairo_restore(cr)

    // List border.
    Draw.setColor(cr, Theme.controlBorder)
    cairo_set_line_width(cr, 1)
    cairo_rectangle(cr, L.list.x + 0.5, L.list.y + 0.5, L.list.w - 1, L.list.h - 1)
    cairo_stroke(cr)

    // Scrollbar: track, thumb, paired arrows.
    Draw.scrollTrack(cr, L.track, vertical: true)
    if let thumb = scrollThumbRect(track: L.track, offset: off, viewportH: viewportH) {
        Draw.scrollThumb(cr, thumb, vertical: true)
    }
    let maxOff = scrollMaxOffset(viewportH: viewportH)
    Draw.scrollArrow(cr, L.upArrow, .up, enabled: off > 0.5)
    Draw.scrollArrow(cr, L.downArrow, .down, enabled: off < maxOff - 0.5)
    return L
}
