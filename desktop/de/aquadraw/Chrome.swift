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
// **Since P11.6 the chrome is theme data, and one function reads it.**
// `windowChrome` lays the frame out from `[chrome]` and the chrome metrics —
// which gadgets, on which side, where the title goes — and *everything* takes
// its geometry from that one answer: the toolkit's painter and hit-test, and
// undertow's painter and hit-test for the frames it draws around foreign
// windows. What is drawn is what is clickable (§2.9), on both sides, because
// there is only one place it could be computed.

import CCairo

/// A title-bar control. Jaguar has the first three; `depth` sends a window to
/// the back (Amiga's, and Plan Neo's); `pill` is the Aqua toolkit's toolbar
/// toggle, and only a window with a toolbar has one.
public enum Gadget: String, Equatable, Hashable, Sendable, CaseIterable {
    case close, minimize, zoom, depth, pill
}

public enum TitleAlign: String, Equatable, Sendable { case left, center }

/// A resize the frame offers — only along the bottom (P9.4 says why).
public enum ChromeEdge: Equatable, Sendable { case bottom, bottomLeft, bottomRight }

/// What is under a point in a window's frame.
public enum ChromeHit: Equatable, Sendable {
    case gadget(Gadget)
    case title                 // drag it to move the window
    case resize(ChromeEdge)
    case content               // not chrome — the window's own business
}

public struct PlacedGadget: Equatable, Sendable {
    public let gadget: Gadget
    public let rect: Rect
}

/// A window frame, laid out: the answer every painter and hit-test reads.
public struct ChromeLayout: Equatable, Sendable {
    public let width: Double, height: Double
    public let titleBar: Rect
    public let gadgets: [PlacedGadget]
    /// The title's anchor: its centre (`.center`) or its left edge (`.left`).
    public let titleX: Double
    public let titleAlign: TitleAlign
    public let titleBold: Bool
    /// Below the title bar.
    public let body: Rect

    public func rect(_ g: Gadget) -> Rect? { gadgets.first { $0.gadget == g }?.rect }
}

/// Lay out the frame of a `w`×`h` window from the current theme. `foreign` is
/// a frame undertow draws around a window it did not write: such a window has
/// no toolbar, so no pill — the pill P11.1 found painted there, and that
/// undertow's own hit-test treated as title bar.
public func windowChrome(w: Double, h: Double, foreign: Bool = false) -> ChromeLayout {
    let t = Theme.current
    let r = t.trafficRadius, cy = t.titleBarHeight / 2
    let gap = t.trafficSpacing - r * 2
    func keep(_ g: Gadget) -> Bool { !(foreign && g == .pill) }
    func round(_ cx: Double) -> Rect { Rect(cx - r, cy - r, r * 2, r * 2) }

    var placed: [PlacedGadget] = []
    // Left: centres `spacing` apart from the inset — Jaguar's lights.
    let x0 = t.trafficInset + r
    var leftEnd = 0.0
    for (i, g) in t.chromeLeft.filter(keep).enumerated() {
        let box = g == .pill
            ? Rect(leftEnd + (i == 0 ? t.chromePillInset : gap), cy - t.chromePillHeight / 2,
                   t.chromePillWidth, t.chromePillHeight)
            : round(x0 + Double(i) * t.trafficSpacing)
        placed.append(PlacedGadget(gadget: g, rect: box))
        leftEnd = box.x + box.w
    }
    // Right: the mirror, laid from the right edge inwards.
    var edge = w
    var right: [PlacedGadget] = []
    for (i, g) in t.chromeRight.filter(keep).reversed().enumerated() {
        let box: Rect
        if g == .pill {
            box = Rect(edge - (i == 0 ? t.chromePillInset : gap) - t.chromePillWidth,
                       cy - t.chromePillHeight / 2, t.chromePillWidth, t.chromePillHeight)
        } else {
            box = round(edge - (i == 0 ? t.trafficInset : gap) - r)
        }
        right.insert(PlacedGadget(gadget: g, rect: box), at: 0)
        edge = box.x
    }
    placed += right

    let titleX = t.titleAlign == .center ? w / 2 : leftEnd + gap + 4
    return ChromeLayout(width: w, height: h, titleBar: Rect(0, 0, w, t.titleBarHeight),
                        gadgets: placed, titleX: titleX, titleAlign: t.titleAlign,
                        titleBold: t.titleBold,
                        body: Rect(0, t.titleBarHeight, w, h - t.titleBarHeight))
}

/// What is under (x, y) in a window laid out as `l`.
///
/// **The bottom first**: its band is the outermost few pixels, and a control
/// that overlapped it would be unreachable from the other side. Only the bottom
/// and its two corners resize — 10.2 resized from the corner grip, and a side
/// band would take the right 6 px of every scrollbar (P9.4).
public func chromeHit(_ l: ChromeLayout, x: Double, y: Double) -> ChromeHit {
    let t = Theme.current
    let corner = t.chromeResizeCorner, band = t.chromeResizeBand
    let cornerB = y >= l.height - corner
    if cornerB && x >= l.width - corner { return .resize(.bottomRight) }
    if cornerB && x <= corner { return .resize(.bottomLeft) }
    if y >= l.height - band { return .resize(.bottom) }
    if y < l.titleBar.h {
        for g in l.gadgets where g.rect.contains(x, y) { return .gadget(g.gadget) }
        return .title
    }
    return .content
}

/// Draw a window's frame: the body, the title bar, its gadgets and title, and
/// the border — from `windowChrome`, through the theme's lists (`window`,
/// `gadget.<name>`, `window.frame`). Returns the body rect below the title bar.
@discardableResult
public func paintWindowChrome(_ cr: OpaquePointer, w: Double, h: Double,
                              title: String, foreign: Bool = false) -> Rect {
    let l = windowChrome(w: w, h: h, foreign: foreign)
    let whole = Rect(0, 0, w, h)
    // The gadgets and the title are drawn inside the frame's rounded clip, as
    // they always were: text composited under a clip is not the same bytes as
    // text composited without one (one pixel of the window@2x title, by 12).
    cairo_save(cr)
    Draw.clip("window.shape", cr, whole)
    Draw.paint("window", cr, whole)
    // The lights are always drawn lit: an inactive frame is washed over
    // afterwards (undertow's `window.inactive`), as P9.6 did it. Left side,
    // title, right side — the order Jaguar's frame was painted in.
    func gadget(_ g: PlacedGadget) {
        Draw.paint("gadget." + g.gadget.rawValue, cr, g.rect, .active,
                   parameters: ["r": g.rect.w / 2])
    }
    let split = min(Theme.current.chromeLeft.filter { !(foreign && $0 == .pill) }.count, l.gadgets.count)
    l.gadgets[..<split].forEach(gadget)
    let cy = l.titleBar.h / 2
    let style: Text.Style = l.titleBold ? .bold : .regular
    switch l.titleAlign {
    case .center:
        Draw.text(cr, title, centerX: l.titleX, centerY: cy, color: Theme.titleText,
                  size: Theme.fontSize, style: style)
    case .left:
        let tw = Draw.textWidth(cr, title, size: Theme.fontSize, style: style)
        Draw.text(cr, title, centerX: l.titleX + tw / 2, centerY: cy, color: Theme.titleText,
                  size: Theme.fontSize, style: style)
    }
    l.gadgets[split...].forEach(gadget)
    cairo_restore(cr)
    Draw.paint("window.frame", cr, whole)
    return l.body
}
