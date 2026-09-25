// Aqua drawing primitives over cairo: the gloss/gradient/rounded-rect grammar
// the Jaguar look is built from. All coordinates are in logical points; the
// caller has already applied the HiDPI scale to the cairo context.

import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct Rect: Equatable, Sendable {
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

    // MARK: Controls — each one a draw list (PHASE11 P11.4)
    //
    // How a control looks is the theme's: `themes/<theme>/draw/*.dl`, with
    // Jaguar's (themes/aqua/draw/aqua.dl, compiled in as JaguarLists) behind
    // any a theme does not ship. What is left here is the part that is not
    // look: which list, which state, and the geometry a value decides — where
    // a slider's thumb sits, how far a progress bar has run.

    /// Run the current theme's list `name` for one widget.
    public static func paint(_ name: String, _ cr: OpaquePointer, _ r: Rect,
                             _ state: DrawState = [], label: String = "",
                             placeholder: String = "", parameters: [String: Double] = [:],
                             colors: [String: Color] = [:]) {
        guard let list = Theme.lists[name] else { return }
        DrawListRunner.run(list, cr, DrawContext(rect: r, state: state, label: label,
                                                 placeholder: placeholder, parameters: parameters,
                                                 colors: colors))
    }

    /// Clip to the current theme's shape `name` and leave it set (the caller
    /// saves and restores): what a window's gadgets and title are drawn in.
    public static func clip(_ name: String, _ cr: OpaquePointer, _ r: Rect) {
        guard let list = Theme.lists[name] else { return }
        DrawListRunner.clip(list, cr, DrawContext(rect: r))
    }

    /// The Aqua keyboard-focus halo: a soft blue ring hugging `r`. Drawn just
    /// outside the control (round-rect or, with `radius: r.h/2`, a pill), so it
    /// reads as the focused element without disturbing the control's own paint.
    public static func focusRing(_ cr: OpaquePointer, _ r: Rect, radius: Double) {
        paint("focusring", cr, r, parameters: ["radius": radius])
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
        paint("pinstripe", cr, r, colors: ["color": c])
    }

    /// A lickable gel button. `blue` = default/aqua button, else white gel.
    public static func gelButton(_ cr: OpaquePointer, _ r: Rect, label: String,
                                 blue: Bool, pressed: Bool) {
        paint(blue ? "button.default" : "button", cr, r, pressed ? .pressed : [], label: label)
    }

    /// An Aqua text field: a white well with an inset top-shadow and a 1px
    /// border, the focused variant ringed in Aqua blue. `text` is drawn
    /// left-aligned and vertically centred; `caret` adds an insertion bar after
    /// it (shown when the field has keyboard focus). `placeholder` greys in when
    /// `text` is empty.
    public static func textField(_ cr: OpaquePointer, _ r: Rect, text: String,
                                 caret: Bool, placeholder: String = "") {
        paint("textfield", cr, r, caret ? .focused : [], label: text, placeholder: placeholder)
    }

    /// An Aqua checkbox: white gel when off, blue gel + white check when on.
    public static func checkbox(_ cr: OpaquePointer, _ r: Rect, checked: Bool) {
        paint("checkbox", cr, r, checked ? .selected : [])
    }

    /// An Aqua radio button centred at (cx, cy): white gel ring when off, blue
    /// gel + white centre dot when selected.
    public static func radioButton(_ cr: OpaquePointer, cx: Double, cy: Double,
                                   radius: Double, selected: Bool) {
        paint("radio", cr, Rect(cx - radius, cy - radius, radius * 2, radius * 2),
              selected ? .selected : [], parameters: ["r": radius])
    }

    /// A horizontal Aqua slider inside `track` (the full interactive rect): a
    /// recessed groove with a round white gel thumb at `value` (0…1).
    public static let sliderThumbRadius = 8.0
    public static func slider(_ cr: OpaquePointer, _ track: Rect, value: Double) {
        let v = max(0, min(1, value)), tr = sliderThumbRadius
        paint("slider", cr, track, parameters: ["thumb": tr + v * (track.w - 2 * tr)])
    }

    /// An Aqua pop-up (menu) button: a white gel body with the label, and a
    /// blue gel end-cap on the right bearing a white up/down double chevron.
    public static func popUpButton(_ cr: OpaquePointer, _ r: Rect, label: String) {
        paint("popup", cr, r, label: label)
    }

    /// A determinate Aqua progress bar: a recessed track with a blue gel fill
    /// carrying the diagonal candy-stripe, `value` in 0…1.
    public static func progressBar(_ cr: OpaquePointer, _ r: Rect, value: Double) {
        let v = max(0, min(1, value))
        paint("progress", cr, r, parameters: ["fill": v > 0 ? max(r.h, v * r.w) : 0])
    }

    /// The recessed channel a scrollbar thumb travels in (square corners, sits
    /// flush to a window edge).
    public static func scrollTrack(_ cr: OpaquePointer, _ r: Rect, vertical: Bool) {
        paint("scrolltrack", cr, r)
    }

    /// The blue gel scrollbar thumb (a rounded "gumdrop" capsule) inside `r`.
    public static func scrollThumb(_ cr: OpaquePointer, _ r: Rect, vertical: Bool) {
        paint("scrollthumb", cr, r)
    }

    /// A scrollbar arrow button: a small white gel square bearing a blue
    /// triangle pointing in `dir`. `enabled` dims the glyph when there's no
    /// travel left in that direction.
    public static func scrollArrow(_ cr: OpaquePointer, _ r: Rect, _ dir: Arrow,
                                   enabled: Bool = true) {
        let name: String
        switch dir {
        case .up: name = "scrollarrow.up"
        case .down: name = "scrollarrow.down"
        case .left: name = "scrollarrow.left"
        case .right: name = "scrollarrow.right"
        }
        paint(name, cr, r, enabled ? [] : .disabled)
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
    /// outline, divider lines, and the selected segment in blue gel. Drawn in
    /// passes (the lists say why): bodies, gloss, dividers, frame, labels.
    public static func segmentedControl(_ cr: OpaquePointer, _ r: Rect,
                                        labels: [String], selected: Int) {
        let rects = segmentRects(r, count: labels.count)
        let segW = r.w / Double(max(1, labels.count))
        func seg(_ name: String, _ i: Int) {
            paint(name, cr, r, i == selected ? .selected : [], label: labels[i],
                  parameters: ["x": Double(i) * segW, "w": rects[i].w])
        }
        for i in rects.indices { seg("segmented.segment", i) }
        paint("segmented.gloss", cr, r)
        for i in rects.indices.dropFirst() { seg("segmented.divider", i) }
        paint("segmented.frame", cr, r)
        for i in rects.indices { seg("segmented.label", i) }
    }

    /// The content pane of a tab view: a light rounded box with a 1px border.
    public static func tabPane(_ cr: OpaquePointer, _ r: Rect) {
        paint("tabpane", cr, r)
    }

    /// A single tab (rounded top, square bottom) sitting on the pane's top edge.
    /// The selected tab is bright and (via a caller-side erase) merges into the
    /// pane; unselected tabs are a flatter grey.
    public static func tab(_ cr: OpaquePointer, _ r: Rect, label: String,
                           selected: Bool) {
        paint("tab", cr, r, selected ? .selected : [], label: label)
    }

    /// A titled group box: a faint rounded outline with the title notched into
    /// its top-left. Returns nothing; purely decorative grouping.
    public static func groupBox(_ cr: OpaquePointer, _ r: Rect, title: String) {
        paint("groupbox", cr, r, label: title)
    }

    /// Draw text centred on a point. Uses shaped FreeType/HarfBuzz glyphs when
    /// a font is loaded; falls back to cairo toy-text otherwise.
    public static func text(_ cr: OpaquePointer, _ s: String, centerX: Double,
                            centerY: Double, color: Color, size: Double,
                            style: Text.Style = .regular) {
        if Text.available {
            let px = Text.px(size)   // device px
            let glyphs = Text.shape(s, px: px, style: style)
            let m = Text.metrics(px: px)
            // Positions are logical; px-shaped metrics/width are device px, so
            // convert down by the render scale for the centring math.
            let sc = Double(Text.renderScale)
            let w = Text.width(glyphs) / sc
            let ascent = m.ascent / sc, descent = m.descent / sc
            setColor(cr, color)
            // Centre the line box (top = baseline−ascent, bottom = baseline+descent)
            // on centerY; left-align the run around centerX.
            Text.drawShaped(cr, glyphs, x: centerX - w / 2,
                            baselineY: centerY + (ascent - descent) / 2, px: px)
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
            // Shaped at device px; return the logical width for layout.
            return Text.width(Text.shape(s, px: Text.px(size), style: style))
                / Double(Text.renderScale)
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
