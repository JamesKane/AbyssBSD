// Procedural Aqua preference-pane icons.
//
// These are original, stylized glyphs in the Jaguar idiom (glossy tiles, water
// circles, simple white emblems) — NOT Apple's icon artwork. They exist to make
// the System Preferences layout demo read correctly; faithful bespoke artwork
// is a later asset task.

import CCairo

public enum PrefIcon: Sendable {
    case showAll, displays, sound, network, startupDisk
    case desktop, dock, general, international, loginItems, myAccount, screenEffects
    case cdsDvds, colorSync, energySaver, keyboard, mouse
    case internetIcon, quicktime, sharing
    case accounts, classic, dateTime, softwareUpdate, speech, universalAccess
}

public enum Icons {
    /// Draw `icon` filling the square `box` (logical points).
    public static func draw(_ cr: OpaquePointer, _ icon: PrefIcon, in box: Rect) {
        // Clear any current point left by prior text/draws so a leading
        // cairo_arc doesn't connect a stray line into the glyph.
        cairo_new_path(cr)
        switch icon {
        case .showAll:        grid(cr, box, Color(hex: 0x9aa0a6))
        case .dock:           grid(cr, box, Color(hex: 0x4e8df0))
        case .displays:       monitor(cr, box)
        case .desktop:        monitor(cr, box, picture: true)
        case .sound:          speaker(cr, box)
        case .network:        globe(cr, box)
        case .international:   globe(cr, box)
        case .internetIcon:   globe(cr, box)
        case .startupDisk:    drive(cr, box)
        case .general:        doc(cr, box)
        case .loginItems:     doc(cr, box, lines: true)
        case .myAccount:      person(cr, box, circle: false)
        case .universalAccess: person(cr, box, circle: true)
        case .accounts:       people(cr, box)
        case .screenEffects:  swirl(cr, box)
        case .cdsDvds:        disc(cr, box)
        case .colorSync:      colorWheel(cr, box)
        case .energySaver:    bulb(cr, box)
        case .keyboard:       keyboard(cr, box)
        case .mouse:          mouse(cr, box)
        case .sharing:        folder(cr, box)
        case .dateTime:       clock(cr, box)
        case .softwareUpdate: refresh(cr, box)
        case .speech:         mic(cr, box)
        case .quicktime:      letterCircle(cr, box, "Q", Color(hex: 0x3b7fea))
        case .classic:        letterTile(cr, box, "9", Color(hex: 0xe6932a))
        }
    }

    // MARK: shared backgrounds

    /// A glossy aqua rounded tile.
    private static func tile(_ cr: OpaquePointer, _ b: Rect, top: Color,
                             bottom: Color) {
        let r = inset(b, 0.08)
        Draw.roundedRect(cr, r, radius: r.w * 0.22)
        Draw.fillVerticalGradient(cr, y: r.y, h: r.h,
                                  stops: [(0, top), (1, bottom)])
        // top gloss
        let g = Rect(r.x + 1, r.y + 1, r.w - 2, r.h * 0.42)
        Draw.roundedRect(cr, g, radius: g.w * 0.22)
        let p = cairo_pattern_create_linear(0, g.y, 0, g.y + g.h)
        cairo_pattern_add_color_stop_rgba(p, 0, 1, 1, 1, 0.7)
        cairo_pattern_add_color_stop_rgba(p, 1, 1, 1, 1, 0.05)
        cairo_set_source(cr, p)
        cairo_fill(cr)
        cairo_pattern_destroy(p)
        Draw.roundedRect(cr, r, radius: r.w * 0.22)
        cairo_set_source_rgba(cr, 0, 0, 0, 0.22)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
    }

    private static func glossyCircle(_ cr: OpaquePointer, _ b: Rect, base: Color) {
        let r = inset(b, 0.08)
        let cx = r.x + r.w / 2, cy = r.y + r.h / 2, rad = r.w / 2
        let lg = cairo_pattern_create_linear(0, cy - rad, 0, cy + rad)
        let top = lighten(base, 0.30), bot = darken(base, 0.12)
        cairo_pattern_add_color_stop_rgba(lg, 0, top.r, top.g, top.b, 1)
        cairo_pattern_add_color_stop_rgba(lg, 1, bot.r, bot.g, bot.b, 1)
        cairo_arc(cr, cx, cy, rad, 0, 2 * .pi)
        cairo_set_source(cr, lg)
        cairo_fill(cr)
        cairo_pattern_destroy(lg)
        cairo_arc(cr, cx, cy, rad, 0, 2 * .pi)
        cairo_set_source_rgba(cr, 0, 0, 0, 0.25)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        // sheen
        cairo_save(cr)
        cairo_arc(cr, cx, cy, rad - 0.5, 0, 2 * .pi)
        cairo_clip(cr)
        let hg = cairo_pattern_create_radial(cx, cy - rad * 0.5, 0,
                                             cx, cy - rad * 0.4, rad)
        cairo_pattern_add_color_stop_rgba(hg, 0, 1, 1, 1, 0.6)
        cairo_pattern_add_color_stop_rgba(hg, 1, 1, 1, 1, 0)
        cairo_arc(cr, cx, cy - rad * 0.2, rad * 0.8, 0, 2 * .pi)
        cairo_set_source(cr, hg)
        cairo_fill(cr)
        cairo_pattern_destroy(hg)
        cairo_restore(cr)
    }

    // MARK: emblems

    private static func monitor(_ cr: OpaquePointer, _ b: Rect,
                                picture: Bool = false) {
        let r = inset(b, 0.10)
        let screen = Rect(r.x, r.y, r.w, r.h * 0.72)
        Draw.roundedRect(cr, screen, radius: 3)
        Draw.fillVerticalGradient(cr, y: screen.y, h: screen.h, stops: [
            (0, Color(hex: 0xbfd6f5)), (1, Color(hex: 0x3f74c9)),
        ])
        if picture {
            // a little "mountain + sun" desktop picture
            Draw.setColor(cr, Color(hex: 0xffd34d))
            cairo_arc(cr, screen.x + screen.w * 0.3, screen.y + screen.h * 0.35,
                      screen.w * 0.1, 0, 2 * .pi)
            cairo_fill(cr)
            Draw.setColor(cr, Color(hex: 0x2e7d32))
            cairo_move_to(cr, screen.x, screen.y + screen.h)
            cairo_line_to(cr, screen.x + screen.w * 0.5, screen.y + screen.h * 0.5)
            cairo_line_to(cr, screen.x + screen.w, screen.y + screen.h)
            cairo_close_path(cr)
            cairo_fill(cr)
        }
        Draw.roundedRect(cr, screen, radius: 3)
        cairo_set_source_rgba(cr, 0.9, 0.9, 0.95, 0.9)
        cairo_set_line_width(cr, 1.5)
        cairo_stroke(cr)
        // stand
        Draw.setColor(cr, Color(hex: 0xc7ccd2))
        let nx = r.x + r.w / 2
        cairo_rectangle(cr, nx - r.w * 0.06, screen.y + screen.h, r.w * 0.12,
                        r.h * 0.16)
        cairo_fill(cr)
        cairo_rectangle(cr, nx - r.w * 0.22, r.y + r.h * 0.9, r.w * 0.44, r.h * 0.1)
        cairo_fill(cr)
    }

    private static func speaker(_ cr: OpaquePointer, _ b: Rect) {
        let r = inset(b, 0.14)
        Draw.setColor(cr, Color(hex: 0x8c9298))
        cairo_move_to(cr, r.x, r.y + r.h * 0.35)
        cairo_line_to(cr, r.x + r.w * 0.32, r.y + r.h * 0.35)
        cairo_line_to(cr, r.x + r.w * 0.6, r.y + r.h * 0.1)
        cairo_line_to(cr, r.x + r.w * 0.6, r.y + r.h * 0.9)
        cairo_line_to(cr, r.x + r.w * 0.32, r.y + r.h * 0.65)
        cairo_line_to(cr, r.x, r.y + r.h * 0.65)
        cairo_close_path(cr)
        cairo_fill(cr)
        cairo_set_source_rgba(cr, 0.27, 0.55, 0.9, 0.9)
        cairo_set_line_width(cr, 2)
        for i in 1...2 {
            let rad = r.w * (0.12 * Double(i) + 0.16)
            cairo_arc(cr, r.x + r.w * 0.62, r.y + r.h / 2, rad,
                      -0.6, 0.6)
            cairo_stroke(cr)
        }
    }

    private static func globe(_ cr: OpaquePointer, _ b: Rect) {
        glossyCircle(cr, b, base: Color(hex: 0x2f6fd0))
        let r = inset(b, 0.08)
        let cx = r.x + r.w / 2, cy = r.y + r.h / 2, rad = r.w / 2
        cairo_save(cr)
        cairo_arc(cr, cx, cy, rad - 1, 0, 2 * .pi)
        cairo_clip(cr)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.6)
        cairo_set_line_width(cr, 1)
        for k in -1...1 {
            cairo_arc(cr, cx + Double(k) * rad * 0.6, cy, rad, -.pi/2, .pi/2)
            cairo_stroke(cr)
        }
        for k in -1...1 {
            let y = cy + Double(k) * rad * 0.5
            cairo_move_to(cr, cx - rad, y)
            cairo_line_to(cr, cx + rad, y)
            cairo_stroke(cr)
        }
        cairo_restore(cr)
    }

    private static func drive(_ cr: OpaquePointer, _ b: Rect) {
        tile(cr, b, top: Color(hex: 0xeaecee), bottom: Color(hex: 0xb9bdc2))
        let r = inset(b, 0.22)
        Draw.setColor(cr, Color(hex: 0x6b7176))
        cairo_arc(cr, r.x + r.w * 0.7, r.y + r.h * 0.6, r.w * 0.08, 0, 2 * .pi)
        cairo_fill(cr)
    }

    private static func doc(_ cr: OpaquePointer, _ b: Rect, lines: Bool = false) {
        let r = inset(b, 0.18)
        let fold = r.w * 0.3
        cairo_move_to(cr, r.x, r.y)
        cairo_line_to(cr, r.x + r.w - fold, r.y)
        cairo_line_to(cr, r.x + r.w, r.y + fold)
        cairo_line_to(cr, r.x + r.w, r.y + r.h)
        cairo_line_to(cr, r.x, r.y + r.h)
        cairo_close_path(cr)
        Draw.setColor(cr, Color(hex: 0xffffff))
        cairo_fill_preserve(cr)
        cairo_set_source_rgba(cr, 0, 0, 0, 0.35)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        if lines {
            cairo_set_source_rgba(cr, 0.3, 0.5, 0.85, 0.8)
            cairo_set_line_width(cr, 1.5)
            for i in 0..<3 {
                let y = r.y + r.h * (0.45 + 0.16 * Double(i))
                cairo_move_to(cr, r.x + r.w * 0.18, y)
                cairo_line_to(cr, r.x + r.w * 0.82, y)
                cairo_stroke(cr)
            }
        }
    }

    private static func person(_ cr: OpaquePointer, _ b: Rect, circle: Bool) {
        if circle { glossyCircle(cr, b, base: Color(hex: 0x2f6fd0)) }
        let r = inset(b, 0.2)
        Draw.setColor(cr, circle ? Color(hex: 0xffffff) : Color(hex: 0x5b6168))
        cairo_arc(cr, r.x + r.w / 2, r.y + r.h * 0.3, r.w * 0.22, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_move_to(cr, r.x + r.w * 0.1, r.y + r.h)
        cairo_arc(cr, r.x + r.w / 2, r.y + r.h * 0.95, r.w * 0.4, .pi, 2 * .pi)
        cairo_close_path(cr)
        cairo_fill(cr)
    }

    private static func people(_ cr: OpaquePointer, _ b: Rect) {
        person(cr, Rect(b.x - b.w * 0.12, b.y, b.w, b.h), circle: false)
        person(cr, Rect(b.x + b.w * 0.16, b.y + b.h * 0.05, b.w * 0.9,
                        b.h * 0.95), circle: false)
    }

    private static func swirl(_ cr: OpaquePointer, _ b: Rect) {
        glossyCircle(cr, b, base: Color(hex: 0x2aa8a0))
        let r = inset(b, 0.08)
        let cx = r.x + r.w / 2, cy = r.y + r.h / 2
        cairo_set_source_rgba(cr, 1, 1, 1, 0.85)
        cairo_set_line_width(cr, 2)
        cairo_arc(cr, cx, cy, r.w * 0.22, 0, 1.6 * .pi)
        cairo_stroke(cr)
        cairo_arc(cr, cx, cy, r.w * 0.34, .pi, 2.6 * .pi)
        cairo_stroke(cr)
    }

    private static func disc(_ cr: OpaquePointer, _ b: Rect) {
        glossyCircle(cr, b, base: Color(hex: 0xc8ccd0))
        let r = inset(b, 0.08)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.9)
        cairo_arc(cr, r.x + r.w / 2, r.y + r.h / 2, r.w * 0.12, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_set_source_rgba(cr, 0.4, 0.55, 0.85, 0.5)
        cairo_arc(cr, r.x + r.w / 2, r.y + r.h / 2, r.w * 0.32, 0, 2 * .pi)
        cairo_set_line_width(cr, 4)
        cairo_stroke(cr)
    }

    private static func colorWheel(_ cr: OpaquePointer, _ b: Rect) {
        let r = inset(b, 0.1)
        let cx = r.x + r.w / 2, cy = r.y + r.h / 2, rad = r.w / 2
        let cols: [Color] = [Color(hex: 0xe53935), Color(hex: 0xfb8c00),
                             Color(hex: 0xfdd835), Color(hex: 0x43a047),
                             Color(hex: 0x1e88e5), Color(hex: 0x8e24aa)]
        for i in 0..<6 {
            let a0 = Double(i) / 6 * 2 * .pi, a1 = Double(i + 1) / 6 * 2 * .pi
            cairo_move_to(cr, cx, cy)
            cairo_arc(cr, cx, cy, rad, a0, a1)
            cairo_close_path(cr)
            Draw.setColor(cr, cols[i])
            cairo_fill(cr)
        }
        cairo_set_source_rgba(cr, 1, 1, 1, 0.9)
        cairo_arc(cr, cx, cy, rad * 0.3, 0, 2 * .pi)
        cairo_fill(cr)
    }

    private static func bulb(_ cr: OpaquePointer, _ b: Rect) {
        let r = inset(b, 0.2)
        Draw.setColor(cr, Color(hex: 0xffe14d))
        cairo_arc(cr, r.x + r.w / 2, r.y + r.h * 0.4, r.w * 0.4, 0, 2 * .pi)
        cairo_fill_preserve(cr)
        cairo_set_source_rgba(cr, 0.6, 0.5, 0, 0.5)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        Draw.setColor(cr, Color(hex: 0x9a9a9a))
        cairo_rectangle(cr, r.x + r.w * 0.36, r.y + r.h * 0.72, r.w * 0.28,
                        r.h * 0.2)
        cairo_fill(cr)
    }

    private static func keyboard(_ cr: OpaquePointer, _ b: Rect) {
        tile(cr, b, top: Color(hex: 0xf2f3f4), bottom: Color(hex: 0xc3c7cb))
        let r = inset(b, 0.22)
        cairo_set_source_rgba(cr, 0, 0, 0, 0.5)
        for row in 0..<3 {
            for col in 0..<5 {
                let x = r.x + Double(col) * r.w * 0.2
                let y = r.y + Double(row) * r.h * 0.34
                cairo_rectangle(cr, x, y, r.w * 0.15, r.h * 0.22)
                cairo_fill(cr)
            }
        }
    }

    private static func mouse(_ cr: OpaquePointer, _ b: Rect) {
        let r = inset(b, 0.26)
        Draw.roundedRect(cr, r, radius: r.w / 2)
        Draw.fillVerticalGradient(cr, y: r.y, h: r.h, stops: [
            (0, Color(hex: 0xffffff)), (1, Color(hex: 0xcfd3d7)),
        ])
        Draw.roundedRect(cr, r, radius: r.w / 2)
        cairo_set_source_rgba(cr, 0, 0, 0, 0.3)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        cairo_move_to(cr, r.x + r.w / 2, r.y + 2)
        cairo_line_to(cr, r.x + r.w / 2, r.y + r.h * 0.4)
        cairo_stroke(cr)
    }

    private static func folder(_ cr: OpaquePointer, _ b: Rect) {
        let r = inset(b, 0.16)
        Draw.setColor(cr, Color(hex: 0x6fa8e6))
        cairo_move_to(cr, r.x, r.y + r.h * 0.2)
        cairo_line_to(cr, r.x + r.w * 0.4, r.y + r.h * 0.2)
        cairo_line_to(cr, r.x + r.w * 0.5, r.y + r.h * 0.34)
        cairo_line_to(cr, r.x + r.w, r.y + r.h * 0.34)
        cairo_line_to(cr, r.x + r.w, r.y + r.h * 0.85)
        cairo_line_to(cr, r.x, r.y + r.h * 0.85)
        cairo_close_path(cr)
        Draw.fillVerticalGradient(cr, y: r.y, h: r.h, stops: [
            (0, Color(hex: 0x9cc6f4)), (1, Color(hex: 0x4f86d6)),
        ])
    }

    private static func clock(_ cr: OpaquePointer, _ b: Rect) {
        glossyCircle(cr, b, base: Color(hex: 0xf3f4f5))
        let r = inset(b, 0.08)
        let cx = r.x + r.w / 2, cy = r.y + r.h / 2
        cairo_set_source_rgba(cr, 0, 0, 0, 0.7)
        cairo_set_line_width(cr, 1.6)
        cairo_move_to(cr, cx, cy); cairo_line_to(cr, cx, cy - r.h * 0.3)
        cairo_stroke(cr)
        cairo_move_to(cr, cx, cy); cairo_line_to(cr, cx + r.w * 0.22, cy)
        cairo_stroke(cr)
    }

    private static func refresh(_ cr: OpaquePointer, _ b: Rect) {
        glossyCircle(cr, b, base: Color(hex: 0x2f6fd0))
        let r = inset(b, 0.08)
        let cx = r.x + r.w / 2, cy = r.y + r.h / 2
        cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
        cairo_set_line_width(cr, 2.4)
        cairo_arc(cr, cx, cy, r.w * 0.26, -0.4 * .pi, 1.1 * .pi)
        cairo_stroke(cr)
        // arrow head
        cairo_move_to(cr, cx + r.w * 0.26, cy - r.h * 0.02)
        cairo_line_to(cr, cx + r.w * 0.16, cy - r.h * 0.16)
        cairo_line_to(cr, cx + r.w * 0.36, cy - r.h * 0.12)
        cairo_close_path(cr)
        cairo_fill(cr)
    }

    private static func mic(_ cr: OpaquePointer, _ b: Rect) {
        let r = inset(b, 0.3)
        Draw.roundedRect(cr, Rect(r.x, r.y, r.w, r.h * 0.6), radius: r.w / 2)
        Draw.fillVerticalGradient(cr, y: r.y, h: r.h * 0.6, stops: [
            (0, Color(hex: 0xd9dde1)), (1, Color(hex: 0x8a9097)),
        ])
        cairo_set_source_rgba(cr, 0.4, 0.45, 0.5, 1)
        cairo_set_line_width(cr, 2)
        cairo_move_to(cr, r.x + r.w / 2, r.y + r.h * 0.6)
        cairo_line_to(cr, r.x + r.w / 2, r.y + r.h)
        cairo_stroke(cr)
        cairo_move_to(cr, r.x, r.y + r.h)
        cairo_line_to(cr, r.x + r.w, r.y + r.h)
        cairo_stroke(cr)
    }

    private static func grid(_ cr: OpaquePointer, _ b: Rect, _ c: Color) {
        let r = inset(b, 0.18)
        for row in 0..<3 {
            for col in 0..<3 {
                let x = r.x + Double(col) * r.w * 0.36
                let y = r.y + Double(row) * r.h * 0.36
                Draw.roundedRect(cr, Rect(x, y, r.w * 0.26, r.h * 0.26),
                                 radius: 1.5)
                Draw.setColor(cr, c)
                cairo_fill(cr)
            }
        }
    }

    private static func letterTile(_ cr: OpaquePointer, _ b: Rect, _ s: String,
                                   _ base: Color) {
        tile(cr, b, top: lighten(base, 0.2), bottom: darken(base, 0.15))
        Draw.text(cr, s, centerX: b.x + b.w / 2, centerY: b.y + b.h / 2,
                  color: Color(hex: 0xffffff), size: b.h * 0.5)
    }

    private static func letterCircle(_ cr: OpaquePointer, _ b: Rect, _ s: String,
                                     _ base: Color) {
        glossyCircle(cr, b, base: base)
        Draw.text(cr, s, centerX: b.x + b.w / 2, centerY: b.y + b.h / 2,
                  color: Color(hex: 0xffffff), size: b.h * 0.5)
    }

    // MARK: helpers

    private static func inset(_ r: Rect, _ frac: Double) -> Rect {
        let dx = r.w * frac, dy = r.h * frac
        return Rect(r.x + dx, r.y + dy, r.w - 2 * dx, r.h - 2 * dy)
    }
    private static func lighten(_ c: Color, _ d: Double) -> Color {
        Color(min(1, c.r + d), min(1, c.g + d), min(1, c.b + d), c.a)
    }
    private static func darken(_ c: Color, _ d: Double) -> Color {
        Color(max(0, c.r - d), max(0, c.g - d), max(0, c.b - d), c.a)
    }
}
