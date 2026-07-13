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

    /// Draw text centred on a point. Uses shaped FreeType/HarfBuzz glyphs when
    /// a font is loaded; falls back to cairo toy-text otherwise.
    public static func text(_ cr: OpaquePointer, _ s: String, centerX: Double,
                            centerY: Double, color: Color, size: Double) {
        if Text.available {
            let px = Text.px(size)
            let glyphs = Text.shape(s, px: px)
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
                                baselineY: Double, color: Color, size: Double) {
        if Text.available {
            let px = Text.px(size)
            setColor(cr, color)
            Text.drawShaped(cr, Text.shape(s, px: px), x: x, baselineY: baselineY, px: px)
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
    public static func textWidth(_ cr: OpaquePointer, _ s: String, size: Double) -> Double {
        if Text.available {
            return Text.width(Text.shape(s, px: Text.px(size)))
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
