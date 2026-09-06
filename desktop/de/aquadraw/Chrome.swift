// AquaDraw — the drawing grammar, shared by the toolkit and the compositor.
//
// Extracted in P9.6, and the extraction *is* §6.1's decision. Server-side
// decorations mean `undertow` paints an Aqua title bar, with gel traffic lights
// and a pinstriped edge; the alternatives were a rect-and-gradient frame drawn
// inside the compositor — which cannot draw a gel light, and so fails the one
// test that matters — or writing Aqua twice and keeping two of them in step.
//
// So the vocabulary moves to a target both sides can link: `Rect`, `Theme`,
// `Draw` and `Text`, none of which ever depended on `Surface`, plus the window
// chrome they compose into. `Aqua` re-exports it, so nothing in the toolkit
// changed a line.
//
// This is also the shape Phase 11 needs: once the theme is data, the compositor
// and the toolkit read the *same* tokens, and a re-skin reaches the window
// frames without a second implementation.

import CCairo

/// The toolbar-toggle pill at the title bar's right. In the Finder this is the
/// switch between browser mode (toolbar shown) and spatial mode (hidden), so
/// paint and hit-test both take it from here.
public func windowPillRect(w: Double) -> Rect {
    Rect(w - 30, Theme.titleBarHeight / 2 - 6.5, 22, 13)
}

/// Hit rects for the three traffic lights, in title-bar order.
public func windowTrafficRects() -> (close: Rect, minimize: Rect, zoom: Rect) {
    let r = Theme.trafficRadius
    let cy = Theme.titleBarHeight / 2
    let x0 = Theme.trafficInset + r
    func box(_ cx: Double) -> Rect { Rect(cx - r, cy - r, 2 * r, 2 * r) }
    return (box(x0), box(x0 + Theme.trafficSpacing), box(x0 + 2 * Theme.trafficSpacing))
}

/// Draw the window frame, title bar (gradient + pinstripe + bright edge),

/// Draw the window frame, title bar (gradient + pinstripe + bright edge),
/// traffic lights, centred title, toolbar pill, and border. Returns the body
/// rect below the title bar.
@discardableResult
public func paintWindowChrome(_ cr: OpaquePointer, w: Double, h: Double,
                              title: String) -> Rect {
    let frame = Rect(0, 0, w, h)
    let radius = Theme.windowCornerRadius

    cairo_save(cr)
    Draw.roundedRectTop(cr, frame, radius: radius)
    cairo_clip(cr)

    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, 0, 0, w, h)
    cairo_fill(cr)

    let bar = Rect(0, 0, w, Theme.titleBarHeight)
    cairo_rectangle(cr, bar.x, bar.y, bar.w, bar.h)
    Draw.fillVerticalGradient(cr, y: bar.y, h: bar.h, stops: [
        (0, Theme.titleBarTop), (1, Theme.titleBarBottom),
    ])
    Draw.pinstripe(cr, bar, Theme.titleBarPinstripe)
    Draw.setColor(cr, Theme.titleBarHighlight)
    cairo_set_line_width(cr, 1)
    cairo_move_to(cr, 0, 0.5); cairo_line_to(cr, w, 0.5); cairo_stroke(cr)
    Draw.setColor(cr, Theme.separator)
    cairo_move_to(cr, 0, Theme.titleBarHeight - 0.5)
    cairo_line_to(cr, w, Theme.titleBarHeight - 0.5)
    cairo_stroke(cr)

    let cy = Theme.titleBarHeight / 2
    let r = Theme.trafficRadius
    let x0 = Theme.trafficInset + r
    Draw.trafficLight(cr, cx: x0, cy: cy, radius: r, base: Theme.close, active: true)
    Draw.trafficLight(cr, cx: x0 + Theme.trafficSpacing, cy: cy, radius: r,
                      base: Theme.minimize, active: true)
    Draw.trafficLight(cr, cx: x0 + 2 * Theme.trafficSpacing, cy: cy, radius: r,
                      base: Theme.zoom, active: true)

    Draw.text(cr, title, centerX: w / 2, centerY: cy, color: Theme.titleText,
              size: Theme.fontSize)
    Draw.pill(cr, windowPillRect(w: w))

    cairo_restore(cr)

    Draw.roundedRectTop(cr, frame, radius: radius)
    Draw.setColor(cr, Theme.windowBorder)
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)

    return Rect(0, Theme.titleBarHeight, w, h - Theme.titleBarHeight)
}
