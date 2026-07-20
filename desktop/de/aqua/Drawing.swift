// Aqua drawing primitives over cairo: the gloss/gradient/rounded-rect grammar
// the Jaguar look is built from. All coordinates are in logical points; the
// caller has already applied the HiDPI scale to the cairo context.

import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct Rect {
    public var x, y, w, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && px <= x + w && py >= y && py <= y + h
    }
}

public enum Arrow { case up, down, left, right }

public enum Draw {
    public static func setColor(_ cr: OpaquePointer, _ c: Color) {
        cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a)
    }

    /// Append a rounded-rectangle subpath (does not fill/stroke).
    public static func roundedRect(_ cr: OpaquePointer, _ r: Rect, radius: Double) {
        let rad = min(radius, min(r.w, r.h) / 2)
        let deg = Double.pi / 180
        cairo_new_sub_path(cr)
        cairo_arc(cr, r.x + r.w - rad, r.y + rad, rad, -90 * deg, 0)
        cairo_arc(cr, r.x + r.w - rad, r.y + r.h - rad, rad, 0, 90 * deg)
        cairo_arc(cr, r.x + rad, r.y + r.h - rad, rad, 90 * deg, 180 * deg)
        cairo_arc(cr, r.x + rad, r.y + rad, rad, 180 * deg, 270 * deg)
        cairo_close_path(cr)
    }

    /// Rounded top corners, square bottom — the Jaguar window-frame shape.
    public static func roundedRectTop(_ cr: OpaquePointer, _ r: Rect,
                                      radius: Double) {
        let rad = min(radius, min(r.w, r.h) / 2)
        let deg = Double.pi / 180
        cairo_new_sub_path(cr)
        cairo_move_to(cr, r.x, r.y + r.h)
        cairo_line_to(cr, r.x, r.y + rad)
        cairo_arc(cr, r.x + rad, r.y + rad, rad, 180 * deg, 270 * deg)
        cairo_arc(cr, r.x + r.w - rad, r.y + rad, rad, -90 * deg, 0)
        cairo_line_to(cr, r.x + r.w, r.y + r.h)
        cairo_close_path(cr)
    }

    /// Square top corners, rounded bottom — the Aqua sheet shape (flush under
    /// the title bar, rounded where it hangs into the window).
    public static func roundedRectBottom(_ cr: OpaquePointer, _ r: Rect,
                                         radius: Double) {
        let rad = min(radius, min(r.w, r.h) / 2)
        let deg = Double.pi / 180
        cairo_new_sub_path(cr)
        cairo_move_to(cr, r.x, r.y)
        cairo_line_to(cr, r.x + r.w, r.y)
        cairo_line_to(cr, r.x + r.w, r.y + r.h - rad)
        cairo_arc(cr, r.x + r.w - rad, r.y + r.h - rad, rad, 0, 90 * deg)
        cairo_arc(cr, r.x + rad, r.y + r.h - rad, rad, 90 * deg, 180 * deg)
        cairo_line_to(cr, r.x, r.y)
        cairo_close_path(cr)
    }

    /// The Aqua keyboard-focus halo: a soft blue ring hugging `r`. Drawn just
    /// outside the control (round-rect or, with `radius: r.h/2`, a pill), so it
    /// reads as the focused element without disturbing the control's own paint.
    public static func focusRing(_ cr: OpaquePointer, _ r: Rect, radius: Double) {
        roundedRect(cr, Rect(r.x - 1.5, r.y - 1.5, r.w + 3, r.h + 3),
                    radius: radius + 1.5)
        setColor(cr, Theme.fieldFocusRing)
        cairo_set_line_width(cr, 2.5)
        cairo_stroke(cr)
    }

    /// Vertical gradient fill of the current path's bounding band [y, y+h].
    public static func fillVerticalGradient(_ cr: OpaquePointer, y: Double,
                                            h: Double, stops: [(Double, Color)]) {
        let g = cairo_pattern_create_linear(0, y, 0, y + h)
        for (off, c) in stops {
            cairo_pattern_add_color_stop_rgba(g, off, c.r, c.g, c.b, c.a)
        }
        cairo_set_source(cr, g)
        cairo_fill_preserve(cr)
        cairo_pattern_destroy(g)
    }

    /// Faint horizontal Aqua pinstripe across a rect (every 4 logical px).
    public static func pinstripe(_ cr: OpaquePointer, _ r: Rect, _ c: Color) {
        setColor(cr, c)
        cairo_set_line_width(cr, 1)
        var y = r.y + 1.5
        while y < r.y + r.h {
            cairo_move_to(cr, r.x, y)
            cairo_line_to(cr, r.x + r.w, y)
            cairo_stroke(cr)
            y += 4
        }
    }

    /// A glassy Aqua traffic-light "water drop" centred at (cx, cy).
    public static func trafficLight(_ cr: OpaquePointer, cx: Double, cy: Double,
                                    radius: Double, base: Color, active: Bool) {
        let body = active ? base : Theme.trafficInactive

        // Body: vertical gradient, brighter at the top, a touch deeper at the
        // very bottom — the lit-from-above look.
        let lg = cairo_pattern_create_linear(0, cy - radius, 0, cy + radius)
        let top = Color(min(1, body.r + 0.30), min(1, body.g + 0.30),
                        min(1, body.b + 0.30))
        let bot = Color(max(0, body.r - 0.12), max(0, body.g - 0.12),
                        max(0, body.b - 0.12))
        cairo_pattern_add_color_stop_rgba(lg, 0, top.r, top.g, top.b, 1)
        cairo_pattern_add_color_stop_rgba(lg, 0.5, body.r, body.g, body.b, 1)
        cairo_pattern_add_color_stop_rgba(lg, 1, bot.r, bot.g, bot.b, 1)
        cairo_arc(cr, cx, cy, radius, 0, 2 * Double.pi)
        cairo_set_source(cr, lg)
        cairo_fill(cr)
        cairo_pattern_destroy(lg)

        // Dark rim.
        cairo_arc(cr, cx, cy, radius, 0, 2 * Double.pi)
        setColor(cr, Theme.trafficRim)
        cairo_set_line_width(cr, 0.75)
        cairo_stroke(cr)

        // Broad glassy highlight over the upper half (radial, white→clear).
        let hg = cairo_pattern_create_radial(cx, cy - radius * 0.45, 0,
                                             cx, cy - radius * 0.35, radius * 0.95)
        cairo_pattern_add_color_stop_rgba(hg, 0, 1, 1, 1, 0.85)
        cairo_pattern_add_color_stop_rgba(hg, 0.6, 1, 1, 1, 0.25)
        cairo_pattern_add_color_stop_rgba(hg, 1, 1, 1, 1, 0)
        cairo_save(cr)
        cairo_arc(cr, cx, cy, radius - 0.5, 0, 2 * Double.pi)
        cairo_clip(cr)
        cairo_arc(cr, cx, cy - radius * 0.18, radius * 0.78, 0, 2 * Double.pi)
        cairo_set_source(cr, hg)
        cairo_fill(cr)
        cairo_restore(cr)
        cairo_pattern_destroy(hg)

        // Tiny bright specular dot, upper-left.
        cairo_arc(cr, cx - radius * 0.28, cy - radius * 0.42, radius * 0.16,
                  0, 2 * Double.pi)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
        cairo_fill(cr)
    }

    /// An outlined Aqua "pill" (the title-bar toolbar toggle, far right).
    public static func pill(_ cr: OpaquePointer, _ r: Rect) {
        roundedRect(cr, r, radius: r.h / 2)
        cairo_set_source_rgba(cr, 0, 0, 0, 0.30)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
    }

    /// A lickable gel button. `blue` = default/aqua button, else white gel.
    public static func gelButton(_ cr: OpaquePointer, _ r: Rect, label: String,
                                 blue: Bool, pressed: Bool) {
        let radius = r.h / 2
        roundedRect(cr, r, radius: radius)
        let dim = pressed ? -0.08 : 0.0
        func d(_ c: Color) -> Color {
            Color(max(0, c.r + dim), max(0, c.g + dim), max(0, c.b + dim), c.a)
        }
        let stops: [(Double, Color)] = blue
            ? [(0, d(Theme.buttonBlueTop)), (0.5, d(Theme.buttonBlueMid)),
               (1, d(Theme.buttonBlueBottom))]
            : [(0, d(Theme.buttonWhiteTop)), (1, d(Theme.buttonWhiteBottom))]
        fillVerticalGradient(cr, y: r.y, h: r.h, stops: stops)

        // Border.
        roundedRect(cr, r, radius: radius)
        setColor(cr, blue ? Theme.buttonBlueBorder : Theme.buttonWhiteBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)

        // Top gloss: a translucent white capsule over the upper ~45%.
        let gloss = Rect(r.x + 1.5, r.y + 1.5, r.w - 3, r.h * 0.45)
        roundedRect(cr, gloss, radius: gloss.h / 2)
        let gg = cairo_pattern_create_linear(0, gloss.y, 0, gloss.y + gloss.h)
        cairo_pattern_add_color_stop_rgba(gg, 0, 1, 1, 1, 0.75)
        cairo_pattern_add_color_stop_rgba(gg, 1, 1, 1, 1, 0.05)
        cairo_set_source(cr, gg)
        cairo_fill(cr)
        cairo_pattern_destroy(gg)

        // Label, centred.
        text(cr, label, centerX: r.x + r.w / 2, centerY: r.y + r.h / 2,
             color: blue ? Theme.buttonTextOnBlue : Theme.buttonTextOnWhite,
             size: Theme.fontSize)
    }

    /// An Aqua text field: a white well with an inset top-shadow and a 1px
    /// border, the focused variant ringed in Aqua blue. `text` is drawn
    /// left-aligned and vertically centred; `caret` adds an insertion bar after
    /// it (shown when the field has keyboard focus). `placeholder` greys in when
    /// `text` is empty.
    public static func textField(_ cr: OpaquePointer, _ r: Rect, text: String,
                                 caret: Bool, placeholder: String = "") {
        let radius = 3.0

        // Focus ring: a soft blue halo just outside the field.
        if caret { focusRing(cr, r, radius: radius) }

        // White well.
        roundedRect(cr, r, radius: radius)
        setColor(cr, Theme.fieldBackground)
        cairo_fill(cr)

        // Inset shadow along the top inner edge (the recessed-well look).
        cairo_save(cr)
        roundedRect(cr, r, radius: radius)
        cairo_clip(cr)
        let sg = cairo_pattern_create_linear(0, r.y, 0, r.y + 4)
        let s = Theme.fieldInsetShadow
        cairo_pattern_add_color_stop_rgba(sg, 0, s.r, s.g, s.b, s.a)
        cairo_pattern_add_color_stop_rgba(sg, 1, s.r, s.g, s.b, 0)
        cairo_rectangle(cr, r.x, r.y, r.w, 5)
        cairo_set_source(cr, sg)
        cairo_fill(cr)
        cairo_pattern_destroy(sg)
        cairo_restore(cr)

        // Border.
        roundedRect(cr, r, radius: radius)
        setColor(cr, Theme.fieldBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)

        // Text (or placeholder), clipped to a small inner padding.
        let pad = 6.0
        cairo_save(cr)
        cairo_rectangle(cr, r.x + pad - 2, r.y, r.w - 2 * (pad - 2), r.h)
        cairo_clip(cr)
        let baseline = r.y + r.h / 2 + Theme.fontSize * 0.35
        if text.isEmpty && !placeholder.isEmpty {
            textLeft(cr, placeholder, x: r.x + pad, baselineY: baseline,
                     color: Theme.fieldPlaceholder, size: Theme.fontSize)
        } else {
            textLeft(cr, text, x: r.x + pad, baselineY: baseline,
                     color: Theme.fieldText, size: Theme.fontSize)
        }
        if caret {
            let cx = r.x + pad + textWidth(cr, text, size: Theme.fontSize) + 1
            setColor(cr, Theme.fieldCaret)
            cairo_set_line_width(cr, 1)
            cairo_move_to(cr, cx, r.y + 5)
            cairo_line_to(cr, cx, r.y + r.h - 5)
            cairo_stroke(cr)
        }
        cairo_restore(cr)
    }

    // MARK: Controls

    /// The white gel body shared by checkboxes, pop-up buttons and field-like
    /// controls: a top-lit white gradient, a soft inset top-shadow, a 1px rim.
    private static func whiteWell(_ cr: OpaquePointer, _ r: Rect, radius: Double) {
        roundedRect(cr, r, radius: radius)
        fillVerticalGradient(cr, y: r.y, h: r.h, stops: [
            (0, Theme.controlWhiteTop), (1, Theme.controlWhiteBottom)])
        cairo_save(cr)
        roundedRect(cr, r, radius: radius)
        cairo_clip(cr)
        let sg = cairo_pattern_create_linear(0, r.y, 0, r.y + 3)
        let s = Theme.controlInsetShadow
        cairo_pattern_add_color_stop_rgba(sg, 0, s.r, s.g, s.b, s.a)
        cairo_pattern_add_color_stop_rgba(sg, 1, s.r, s.g, s.b, 0)
        cairo_rectangle(cr, r.x, r.y, r.w, 4)
        cairo_set_source(cr, sg)
        cairo_fill(cr)
        cairo_pattern_destroy(sg)
        cairo_restore(cr)
        roundedRect(cr, r, radius: radius)
        setColor(cr, Theme.controlBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
    }

    /// Fill the current (already-constructed) path with the blue gel gradient
    /// over the vertical band [y, y+h], then a translucent top gloss capsule.
    private static func fillBlueGel(_ cr: OpaquePointer, y: Double, h: Double) {
        fillVerticalGradient(cr, y: y, h: h, stops: [
            (0, Theme.buttonBlueTop), (0.5, Theme.buttonBlueMid),
            (1, Theme.buttonBlueBottom)])
    }

    /// An Aqua checkbox: white gel when off, blue gel + white check when on.
    public static func checkbox(_ cr: OpaquePointer, _ r: Rect, checked: Bool) {
        let radius = 3.0
        if !checked {
            whiteWell(cr, r, radius: radius)
            return
        }
        roundedRect(cr, r, radius: radius)
        fillBlueGel(cr, y: r.y, h: r.h)
        // Top gloss.
        let gloss = Rect(r.x + 1, r.y + 1, r.w - 2, r.h * 0.42)
        roundedRect(cr, gloss, radius: 2)
        let gg = cairo_pattern_create_linear(0, gloss.y, 0, gloss.y + gloss.h)
        cairo_pattern_add_color_stop_rgba(gg, 0, 1, 1, 1, 0.6)
        cairo_pattern_add_color_stop_rgba(gg, 1, 1, 1, 1, 0.05)
        cairo_set_source(cr, gg)
        cairo_fill(cr)
        cairo_pattern_destroy(gg)
        roundedRect(cr, r, radius: radius)
        setColor(cr, Theme.buttonBlueBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        // White check mark.
        setColor(cr, Theme.controlGlyph)
        cairo_set_line_width(cr, 1.8)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_move_to(cr, r.x + r.w * 0.24, r.y + r.h * 0.52)
        cairo_line_to(cr, r.x + r.w * 0.43, r.y + r.h * 0.72)
        cairo_line_to(cr, r.x + r.w * 0.78, r.y + r.h * 0.28)
        cairo_stroke(cr)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER)
    }

    /// An Aqua radio button centred at (cx, cy): white gel ring when off, blue
    /// gel + white centre dot when selected.
    public static func radioButton(_ cr: OpaquePointer, cx: Double, cy: Double,
                                   radius: Double, selected: Bool) {
        let twoPi = 2 * Double.pi
        cairo_new_sub_path(cr)
        cairo_arc(cr, cx, cy, radius, 0, twoPi)
        if selected {
            fillBlueGel(cr, y: cy - radius, h: radius * 2)
        } else {
            fillVerticalGradient(cr, y: cy - radius, h: radius * 2, stops: [
                (0, Theme.controlWhiteTop), (1, Theme.controlWhiteBottom)])
        }
        // Rim (strokes the gradient-filled circle preserved above).
        setColor(cr, selected ? Theme.buttonBlueBorder : Theme.controlBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        // Upper gloss arc.
        cairo_new_sub_path(cr)
        cairo_arc(cr, cx, cy - radius * 0.35, radius * 0.62, 0, twoPi)
        let gg = cairo_pattern_create_linear(0, cy - radius, 0, cy)
        cairo_pattern_add_color_stop_rgba(gg, 0, 1, 1, 1, selected ? 0.5 : 0.7)
        cairo_pattern_add_color_stop_rgba(gg, 1, 1, 1, 1, 0)
        cairo_set_source(cr, gg)
        cairo_fill(cr)
        cairo_pattern_destroy(gg)
        if selected {
            cairo_new_sub_path(cr)
            cairo_arc(cr, cx, cy, radius * 0.34, 0, twoPi)
            setColor(cr, Theme.controlGlyph)
            cairo_fill(cr)
        }
    }

    /// A horizontal Aqua slider inside `track` (the full interactive rect): a
    /// recessed groove with a round white gel thumb at `value` (0…1).
    public static let sliderThumbRadius = 8.0
    public static func slider(_ cr: OpaquePointer, _ track: Rect, value: Double) {
        let v = max(0, min(1, value))
        let tr = sliderThumbRadius
        let grooveH = 5.0
        let groove = Rect(track.x, track.y + (track.h - grooveH) / 2,
                          track.w, grooveH)
        roundedRect(cr, groove, radius: grooveH / 2)
        setColor(cr, Theme.sliderTrack)
        cairo_fill(cr)
        // Inset shadow along the groove's top.
        cairo_save(cr)
        roundedRect(cr, groove, radius: grooveH / 2)
        cairo_clip(cr)
        setColor(cr, Theme.sliderTrackEdge)
        cairo_rectangle(cr, groove.x, groove.y, groove.w, 1.5)
        cairo_fill(cr)
        cairo_restore(cr)
        roundedRect(cr, groove, radius: grooveH / 2)
        setColor(cr, Theme.controlBorder.with(a: 0.6))
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        // Round thumb.
        let cx = track.x + tr + v * (track.w - 2 * tr)
        let cy = track.y + track.h / 2
        let twoPi = 2 * Double.pi
        cairo_new_sub_path(cr)
        cairo_arc(cr, cx, cy, tr, 0, twoPi)
        fillVerticalGradient(cr, y: cy - tr, h: tr * 2, stops: [
            (0, Theme.controlWhiteTop), (1, Color(hex: 0xc8c8c8))])
        setColor(cr, Theme.controlBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        cairo_new_sub_path(cr)
        cairo_arc(cr, cx, cy - tr * 0.3, tr * 0.6, 0, twoPi)
        let gg = cairo_pattern_create_linear(0, cy - tr, 0, cy)
        cairo_pattern_add_color_stop_rgba(gg, 0, 1, 1, 1, 0.85)
        cairo_pattern_add_color_stop_rgba(gg, 1, 1, 1, 1, 0)
        cairo_set_source(cr, gg)
        cairo_fill(cr)
        cairo_pattern_destroy(gg)
    }

    /// An Aqua pop-up (menu) button: a white gel body with the label, and a
    /// blue gel end-cap on the right bearing a white up/down double chevron.
    public static func popUpButton(_ cr: OpaquePointer, _ r: Rect, label: String) {
        let radius = 4.0
        whiteWell(cr, r, radius: radius)
        let capW = r.h
        let capX = r.x + r.w - capW
        // Blue cap, clipped to the body's rounded right side.
        cairo_save(cr)
        roundedRect(cr, r, radius: radius)
        cairo_clip(cr)
        cairo_rectangle(cr, capX, r.y, capW, r.h)
        fillBlueGel(cr, y: r.y, h: r.h)
        let gloss = Rect(capX, r.y + 1, capW, r.h * 0.42)
        cairo_rectangle(cr, gloss.x, gloss.y, gloss.w, gloss.h)
        let gg = cairo_pattern_create_linear(0, gloss.y, 0, gloss.y + gloss.h)
        cairo_pattern_add_color_stop_rgba(gg, 0, 1, 1, 1, 0.5)
        cairo_pattern_add_color_stop_rgba(gg, 1, 1, 1, 1, 0.02)
        cairo_set_source(cr, gg)
        cairo_fill(cr)
        cairo_pattern_destroy(gg)
        cairo_restore(cr)
        // Divider left of the cap.
        setColor(cr, Theme.buttonBlueBorder)
        cairo_set_line_width(cr, 1)
        cairo_move_to(cr, capX + 0.5, r.y + 1)
        cairo_line_to(cr, capX + 0.5, r.y + r.h - 1)
        cairo_stroke(cr)
        // White double chevron.
        let ccx = capX + capW / 2, ccy = r.y + r.h / 2
        setColor(cr, Theme.controlGlyph)
        cairo_set_line_width(cr, 1.3)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_move_to(cr, ccx - 3, ccy - 2.5)
        cairo_line_to(cr, ccx, ccy - 5)
        cairo_line_to(cr, ccx + 3, ccy - 2.5)
        cairo_stroke(cr)
        cairo_move_to(cr, ccx - 3, ccy + 2.5)
        cairo_line_to(cr, ccx, ccy + 5)
        cairo_line_to(cr, ccx + 3, ccy + 2.5)
        cairo_stroke(cr)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER)
        // Label, left-aligned in the body.
        text(cr, label, centerX: (r.x + capX) / 2, centerY: r.y + r.h / 2,
             color: Theme.fieldText, size: Theme.fontSize)
        roundedRect(cr, r, radius: radius)
        setColor(cr, Theme.controlBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
    }

    /// A determinate Aqua progress bar: a recessed track with a blue gel fill
    /// carrying the diagonal candy-stripe, `value` in 0…1.
    public static func progressBar(_ cr: OpaquePointer, _ r: Rect, value: Double) {
        let v = max(0, min(1, value))
        let radius = r.h / 2
        roundedRect(cr, r, radius: radius)
        setColor(cr, Theme.progressTrack)
        cairo_fill(cr)
        cairo_save(cr)
        roundedRect(cr, r, radius: radius)
        cairo_clip(cr)
        setColor(cr, Theme.controlInsetShadow)
        cairo_rectangle(cr, r.x, r.y, r.w, 1.5)
        cairo_fill(cr)
        cairo_restore(cr)
        if v > 0 {
            let fw = max(r.h, v * r.w)
            cairo_save(cr)
            roundedRect(cr, r, radius: radius)
            cairo_clip(cr)
            cairo_rectangle(cr, r.x, r.y, fw, r.h)
            fillBlueGel(cr, y: r.y, h: r.h)
            cairo_clip(cr)  // now bounded to the filled portion too
            // Candy stripes.
            setColor(cr, Color(1, 1, 1, 0.20))
            cairo_set_line_width(cr, 3.5)
            var sx = r.x - r.h
            while sx < r.x + fw {
                cairo_move_to(cr, sx, r.y + r.h)
                cairo_line_to(cr, sx + r.h, r.y)
                cairo_stroke(cr)
                sx += 9
            }
            cairo_restore(cr)
        }
        roundedRect(cr, r, radius: radius)
        setColor(cr, Theme.controlBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
    }

    /// The recessed channel a scrollbar thumb travels in (square corners, sits
    /// flush to a window edge). `vertical` picks the inset-shadow orientation.
    public static func scrollTrack(_ cr: OpaquePointer, _ r: Rect, vertical: Bool) {
        cairo_rectangle(cr, r.x, r.y, r.w, r.h)
        fillVerticalGradient(cr, y: r.y, h: r.h, stops: [
            (0, Color(hex: 0xdedede)), (1, Color(hex: 0xeaeaea))])
        // Inset shadow along the leading inner edge.
        setColor(cr, Color(0, 0, 0, 0.10))
        if vertical {
            cairo_rectangle(cr, r.x, r.y, 1.5, r.h)
        } else {
            cairo_rectangle(cr, r.x, r.y, r.w, 1.5)
        }
        cairo_fill(cr)
        setColor(cr, Theme.controlBorder.with(a: 0.55))
        cairo_set_line_width(cr, 1)
        cairo_rectangle(cr, r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1)
        cairo_stroke(cr)
    }

    /// The blue gel scrollbar thumb (a rounded "gumdrop" capsule) inside `r`.
    public static func scrollThumb(_ cr: OpaquePointer, _ r: Rect, vertical: Bool) {
        let radius = (vertical ? r.w : r.h) / 2
        roundedRect(cr, r, radius: radius)
        fillBlueGel(cr, y: r.y, h: r.h)
        // Top gloss capsule.
        let gloss = Rect(r.x + 1.5, r.y + 1.5, r.w - 3, r.h * 0.42)
        roundedRect(cr, gloss, radius: min(gloss.w, gloss.h) / 2)
        let gg = cairo_pattern_create_linear(0, gloss.y, 0, gloss.y + gloss.h)
        cairo_pattern_add_color_stop_rgba(gg, 0, 1, 1, 1, 0.65)
        cairo_pattern_add_color_stop_rgba(gg, 1, 1, 1, 1, 0.05)
        cairo_set_source(cr, gg)
        cairo_fill(cr)
        cairo_pattern_destroy(gg)
        roundedRect(cr, r, radius: radius)
        setColor(cr, Theme.buttonBlueBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
    }

    /// A scrollbar arrow button: a small white gel square bearing a blue
    /// triangle pointing in `dir`. `enabled` dims the glyph when there's no
    /// travel left in that direction.
    public static func scrollArrow(_ cr: OpaquePointer, _ r: Rect, _ dir: Arrow,
                                   enabled: Bool = true) {
        whiteWell(cr, r, radius: 2)
        let cx = r.x + r.w / 2, cy = r.y + r.h / 2
        let s = min(r.w, r.h) * 0.26
        cairo_new_sub_path(cr)
        switch dir {
        case .up:
            cairo_move_to(cr, cx, cy - s); cairo_line_to(cr, cx + s, cy + s)
            cairo_line_to(cr, cx - s, cy + s)
        case .down:
            cairo_move_to(cr, cx, cy + s); cairo_line_to(cr, cx + s, cy - s)
            cairo_line_to(cr, cx - s, cy - s)
        case .left:
            cairo_move_to(cr, cx - s, cy); cairo_line_to(cr, cx + s, cy - s)
            cairo_line_to(cr, cx + s, cy + s)
        case .right:
            cairo_move_to(cr, cx + s, cy); cairo_line_to(cr, cx - s, cy - s)
            cairo_line_to(cr, cx - s, cy + s)
        }
        cairo_close_path(cr)
        setColor(cr, enabled ? Theme.buttonBlueMid : Theme.controlBorder)
        cairo_fill(cr)
    }

    /// Equal-width segment rects dividing `r` — the single source of segmented
    /// geometry, shared by the painter and the hit-tester.
    public static func segmentRects(_ r: Rect, count: Int) -> [Rect] {
        guard count > 0 else { return [] }
        let segW = r.w / Double(count)
        return (0..<count).map {
            Rect(r.x + Double($0) * segW, r.y, segW, r.h)
        }
    }

    /// An Aqua segmented control: joined gel buttons with a shared rounded
    /// outline, divider lines, and the selected segment in blue gel.
    public static func segmentedControl(_ cr: OpaquePointer, _ r: Rect,
                                        labels: [String], selected: Int) {
        let radius = 4.0
        let rects = segmentRects(r, count: labels.count)

        cairo_save(cr)
        roundedRect(cr, r, radius: radius)
        cairo_clip(cr)
        for (i, seg) in rects.enumerated() {
            cairo_rectangle(cr, seg.x, seg.y, seg.w, seg.h)
            if i == selected {
                fillVerticalGradient(cr, y: r.y, h: r.h, stops: [
                    (0, Theme.buttonBlueTop), (0.5, Theme.buttonBlueMid),
                    (1, Theme.buttonBlueBottom)])
            } else {
                fillVerticalGradient(cr, y: r.y, h: r.h, stops: [
                    (0, Theme.controlWhiteTop), (1, Theme.controlWhiteBottom)])
            }
            // fillVerticalGradient preserves the path; clear it so the next
            // segment's rectangle doesn't union with (and re-fill) this one.
            cairo_new_path(cr)
        }
        // Top gloss across the whole strip.
        cairo_rectangle(cr, r.x, r.y, r.w, r.h * 0.45)
        let gg = cairo_pattern_create_linear(0, r.y, 0, r.y + r.h * 0.45)
        cairo_pattern_add_color_stop_rgba(gg, 0, 1, 1, 1, 0.55)
        cairo_pattern_add_color_stop_rgba(gg, 1, 1, 1, 1, 0.03)
        cairo_set_source(cr, gg)
        cairo_fill(cr)
        cairo_pattern_destroy(gg)
        cairo_restore(cr)

        // Divider lines between segments.
        setColor(cr, Theme.controlBorder.with(a: 0.55))
        cairo_set_line_width(cr, 1)
        for i in 1..<max(1, rects.count) {
            let x = rects[i].x
            cairo_move_to(cr, x + 0.5, r.y + 1)
            cairo_line_to(cr, x + 0.5, r.y + r.h - 1)
            cairo_stroke(cr)
        }
        // Outer border.
        roundedRect(cr, r, radius: radius)
        setColor(cr, Theme.controlBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)

        for (i, seg) in rects.enumerated() {
            text(cr, labels[i], centerX: seg.x + seg.w / 2, centerY: r.y + r.h / 2,
                 color: i == selected ? Theme.buttonTextOnBlue : Theme.fieldText,
                 size: Theme.fontSize)
        }
    }

    /// The content pane of a tab view: a light rounded box with a 1px border.
    public static func tabPane(_ cr: OpaquePointer, _ r: Rect) {
        roundedRect(cr, r, radius: 6)
        setColor(cr, Theme.tabPaneBackground)
        cairo_fill(cr)
        roundedRect(cr, r, radius: 6)
        setColor(cr, Theme.tabBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
    }

    /// A single tab (rounded top, square bottom) sitting on the pane's top edge.
    /// The selected tab is bright and (via a caller-side erase) merges into the
    /// pane; unselected tabs are a flatter grey.
    public static func tab(_ cr: OpaquePointer, _ r: Rect, label: String,
                           selected: Bool) {
        roundedRectTop(cr, r, radius: 6)
        if selected {
            fillVerticalGradient(cr, y: r.y, h: r.h, stops: [
                (0, Theme.tabSelectedTop), (1, Theme.tabSelectedBottom)])
        } else {
            fillVerticalGradient(cr, y: r.y, h: r.h, stops: [
                (0, Theme.tabUnselectedTop), (1, Theme.tabUnselectedBottom)])
        }
        roundedRectTop(cr, r, radius: 6)
        setColor(cr, Theme.tabBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        text(cr, label, centerX: r.x + r.w / 2, centerY: r.y + r.h / 2 + 0.5,
             color: Theme.tabText, size: Theme.fontSize)
    }

    /// A titled group box: a faint rounded outline with the title notched into
    /// its top-left. Returns nothing; purely decorative grouping.
    public static func groupBox(_ cr: OpaquePointer, _ r: Rect, title: String) {
        roundedRect(cr, r, radius: 5)
        setColor(cr, Theme.groupBoxBorder)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        let tw = textWidth(cr, title, size: 11) + 8
        setColor(cr, Theme.contentBackground)
        cairo_rectangle(cr, r.x + 10, r.y - 6, tw, 12)
        cairo_fill(cr)
        textLeft(cr, title, x: r.x + 14, baselineY: r.y + 4,
                 color: Theme.controlLabel.with(a: 0.75), size: 11)
    }

    /// Draw text centred on a point. Uses shaped FreeType/HarfBuzz glyphs when
    /// a font is loaded; falls back to cairo toy-text otherwise.
    public static func text(_ cr: OpaquePointer, _ s: String, centerX: Double,
                            centerY: Double, color: Color, size: Double,
                            style: Text.Style = .regular) {
        if Text.available {
            let px = Text.px(size)
            let glyphs = Text.shape(s, px: px, style: style)
            let m = Text.metrics(px: px)
            setColor(cr, color)
            // Centre the line box (top = baseline−ascent, bottom = baseline+descent)
            // on centerY; left-align the run around centerX.
            Text.drawShaped(cr, glyphs,
                            x: centerX - Text.width(glyphs) / 2,
                            baselineY: centerY + (m.ascent - m.descent) / 2, px: px)
            return
        }
        selectFont(cr, size: size)
        setColor(cr, color)
        s.withCString { c in
            var ext = cairo_text_extents_t()
            cairo_text_extents(cr, c, &ext)
            let tx = centerX - (ext.width / 2 + ext.x_bearing)
            let ty = centerY - (ext.height / 2 + ext.y_bearing)
            cairo_move_to(cr, tx, ty)
            cairo_show_text(cr, c)
        }
    }

    /// Draw left-aligned text with the baseline at (x, baselineY).
    public static func textLeft(_ cr: OpaquePointer, _ s: String, x: Double,
                                baselineY: Double, color: Color, size: Double,
                                style: Text.Style = .regular) {
        if Text.available {
            let px = Text.px(size)
            setColor(cr, color)
            Text.drawShaped(cr, Text.shape(s, px: px, style: style),
                            x: x, baselineY: baselineY, px: px)
            return
        }
        selectFont(cr, size: size)
        setColor(cr, color)
        s.withCString { c in
            cairo_move_to(cr, x, baselineY)
            cairo_show_text(cr, c)
        }
    }

    /// Width in points of `s` at `size` — shaped metrics when a font is loaded,
    /// else cairo toy-text extents. Used for layout (centring, wrapping).
    public static func textWidth(_ cr: OpaquePointer, _ s: String, size: Double,
                                 style: Text.Style = .regular) -> Double {
        if Text.available {
            return Text.width(Text.shape(s, px: Text.px(size), style: style))
        }
        selectFont(cr, size: size)
        return s.withCString { c in
            var ext = cairo_text_extents_t()
            cairo_text_extents(cr, c, &ext)
            return ext.width
        }
    }

    private static func selectFont(_ cr: OpaquePointer, size: Double) {
        // Toy-text fallback path only (no FreeType face available). cairo picks
        // a sans face when Lucida Grande is absent.
        cairo_select_font_face(cr, Theme.fontFamily, CAIRO_FONT_SLANT_NORMAL,
                               CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, size)
    }
}
