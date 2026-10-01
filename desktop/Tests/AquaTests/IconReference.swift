// The icon painters as they were in Swift before P11.8 moved them into
// themes/aqua/icons/*.dl — frozen here, verbatim, as the reference the icon
// lists are proved byte-identical against (IconParityTests). Not used by the
// product. Delete once the icon set has held through P11.9.

import CCairo
@testable import AquaDraw
@testable import Aqua

enum IconsRef {
    /// Draw `icon` filling the square `box` (logical points).
    static func draw(_ cr: OpaquePointer, _ icon: PrefIcon, in box: Rect) {
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
        case .islands:        break   // born a draw list (P13.7): no Swift painter to match
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

// MARK: - The Finder's file icons

/// The Aqua folder: a steel-blue body with a raised tab on the left, a glassy
/// top sheen and a soft rim.
func refDrawFolderIcon(_ cr: OpaquePointer, _ r: Rect) {
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
func refDrawDocumentIcon(_ cr: OpaquePointer, _ r: Rect) {
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
func refDrawAppIcon(_ cr: OpaquePointer, _ r: Rect) {
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

/// A volume: a grey drive slab with a lighter top face and a status LED.
func refDrawDiskIcon(_ cr: OpaquePointer, _ r: Rect) {
    let body = Rect(r.x + r.w * 0.06, r.y + r.h * 0.22, r.w * 0.88, r.h * 0.58)
    Draw.roundedRect(cr, body, radius: r.w * 0.08)
    let g = cairo_pattern_create_linear(0, body.y, 0, body.y + body.h)
    cairo_pattern_add_color_stop_rgba(g, 0, 0.90, 0.91, 0.94, 1)
    cairo_pattern_add_color_stop_rgba(g, 1, 0.63, 0.65, 0.70, 1)
    cairo_set_source(cr, g)
    cairo_fill(cr)
    cairo_pattern_destroy(g)
    // A brighter top face, so the slab reads as a drive rather than a card.
    Draw.roundedRect(cr, Rect(body.x + r.w * 0.04, body.y + r.h * 0.04,
                              body.w - r.w * 0.08, body.h * 0.34),
                     radius: r.w * 0.05)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.45)
    cairo_fill(cr)
    Draw.roundedRect(cr, body, radius: r.w * 0.08)
    cairo_set_source_rgba(cr, 0.35, 0.37, 0.42, 0.85)
    cairo_set_line_width(cr, max(0.6, r.w * 0.02))
    cairo_stroke(cr)
    // Front slot + status LED.
    cairo_new_path(cr)
    cairo_rectangle(cr, body.x + body.w * 0.14, body.y + body.h * 0.70,
                    body.w * 0.44, max(1, r.h * 0.045))
    cairo_set_source_rgba(cr, 0.45, 0.47, 0.52, 0.75)
    cairo_fill(cr)
    cairo_new_path(cr)
    cairo_arc(cr, body.x + body.w * 0.80, body.y + body.h * 0.74, max(1, r.w * 0.045),
              0, 2 * .pi)
    cairo_set_source_rgba(cr, 0.35, 0.62, 0.92, 1)
    cairo_fill(cr)
}


// MARK: - The Dock's tiles

func refDrawDockIcon(_ cr: OpaquePointer, _ kind: DockIcon, _ r: Rect) {
    switch kind {
    case .trash:     refDrawTrash(cr, r, full: false); return
    case .trashFull: refDrawTrash(cr, r, full: true); return
    default: break
    }
    // A rounded app tile with a per-app hue, a top sheen, and a white emblem.
    let (top, bot): (Color, Color)
    switch kind {
    case .finder:   (top, bot) = (Color(hex: 0x5a86c4), Color(hex: 0x2f5698))
    case .browser:  (top, bot) = (Color(hex: 0x3fb0a6), Color(hex: 0x1d7d78))
    case .mail:     (top, bot) = (Color(hex: 0x6fa8e6), Color(hex: 0x3a6fc0))
    case .music:    (top, bot) = (Color(hex: 0xc06fd0), Color(hex: 0x8236a8))
    case .prefs:    (top, bot) = (Color(hex: 0x9aa2ad), Color(hex: 0x5c636e))
    default:        (top, bot) = (Color(hex: 0xb8beca), Color(hex: 0x7c8494))
    }
    let radius = r.w * 0.22
    Draw.roundedRect(cr, r, radius: radius)
    let g = cairo_pattern_create_linear(0, r.y, 0, r.y + r.h)
    cairo_pattern_add_color_stop_rgba(g, 0, top.r, top.g, top.b, 1)
    cairo_pattern_add_color_stop_rgba(g, 1, bot.r, bot.g, bot.b, 1)
    cairo_set_source(cr, g); cairo_fill(cr); cairo_pattern_destroy(g)
    // top sheen
    Draw.roundedRect(cr, Rect(r.x + 2, r.y + 2, r.w - 4, r.h * 0.42), radius: radius * 0.7)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.22); cairo_fill(cr)

    cairo_save(cr)
    cairo_translate(cr, r.x, r.y)
    let s = r.w
    switch kind {
    case .finder:   refEmblemFolder(cr, s)
    case .browser:  refEmblemGlobe(cr, s)
    case .mail:     refEmblemEnvelope(cr, s)
    case .music:    refEmblemNote(cr, s)
    case .prefs:    refEmblemGear(cr, s)
    default:        refEmblemWindow(cr, s)
    }
    cairo_restore(cr)
}

func refEmblemFolder(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    let x = s * 0.24, y = s * 0.34, w = s * 0.52, h = s * 0.34
    Draw.roundedRect(cr, Rect(x, y + s * 0.06, w, h), radius: s * 0.04); cairo_fill(cr)
    Draw.roundedRect(cr, Rect(x, y, w * 0.42, s * 0.10), radius: s * 0.03); cairo_fill(cr)
}

func refEmblemGlobe(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    cairo_set_line_width(cr, s * 0.05)
    let cx = s / 2, cy = s / 2, rad = s * 0.26
    cairo_new_sub_path(cr); cairo_arc(cr, cx, cy, rad, 0, 2 * .pi); cairo_stroke(cr)
    cairo_new_sub_path(cr); cairo_arc(cr, cx, cy, rad * 0.5, 0, 2 * .pi)
    cairo_save(cr); cairo_translate(cr, cx, cy); cairo_scale(cr, 0.45, 1); cairo_translate(cr, -cx, -cy)
    cairo_new_sub_path(cr); cairo_arc(cr, cx, cy, rad, 0, 2 * .pi); cairo_restore(cr)
    cairo_move_to(cr, cx - rad, cy); cairo_line_to(cr, cx + rad, cy)
    cairo_stroke(cr)
}

func refEmblemEnvelope(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    let x = s * 0.24, y = s * 0.34, w = s * 0.52, h = s * 0.32
    Draw.roundedRect(cr, Rect(x, y, w, h), radius: s * 0.03); cairo_fill(cr)
    cairo_set_source_rgba(cr, 0.3, 0.45, 0.7, 0.9)
    cairo_set_line_width(cr, s * 0.045)
    cairo_move_to(cr, x + s * 0.02, y + s * 0.02)
    cairo_line_to(cr, x + w / 2, y + h * 0.55)
    cairo_line_to(cr, x + w - s * 0.02, y + s * 0.02)
    cairo_stroke(cr)
}

func refEmblemNote(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    cairo_set_line_width(cr, s * 0.06)
    cairo_move_to(cr, s * 0.42, s * 0.30); cairo_line_to(cr, s * 0.42, s * 0.64); cairo_stroke(cr)
    cairo_move_to(cr, s * 0.62, s * 0.26); cairo_line_to(cr, s * 0.62, s * 0.60); cairo_stroke(cr)
    cairo_move_to(cr, s * 0.42, s * 0.30); cairo_line_to(cr, s * 0.62, s * 0.26); cairo_stroke(cr)
    cairo_new_sub_path(cr); cairo_arc(cr, s * 0.36, s * 0.64, s * 0.07, 0, 2 * .pi); cairo_fill(cr)
    cairo_new_sub_path(cr); cairo_arc(cr, s * 0.56, s * 0.60, s * 0.07, 0, 2 * .pi); cairo_fill(cr)
}

func refEmblemGear(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    let cx = s / 2, cy = s / 2, rad = s * 0.2
    for k in 0..<8 {
        let a = Double(k) * .pi / 4
        cairo_save(cr); cairo_translate(cr, cx, cy); cairo_rotate(cr, a)
        cairo_rectangle(cr, -s * 0.04, -rad - s * 0.09, s * 0.08, s * 0.1); cairo_fill(cr)
        cairo_restore(cr)
    }
    cairo_new_sub_path(cr); cairo_arc(cr, cx, cy, rad, 0, 2 * .pi); cairo_fill(cr)
    cairo_set_source_rgba(cr, 0.36, 0.4, 0.45, 1)
    cairo_new_sub_path(cr); cairo_arc(cr, cx, cy, rad * 0.45, 0, 2 * .pi); cairo_fill(cr)
}

func refEmblemWindow(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    let x = s * 0.26, y = s * 0.30, w = s * 0.48, h = s * 0.4
    Draw.roundedRect(cr, Rect(x, y, w, h), radius: s * 0.03); cairo_fill(cr)
    cairo_set_source_rgba(cr, 0.4, 0.45, 0.55, 0.9)
    cairo_rectangle(cr, x, y, w, s * 0.1); cairo_fill(cr)
}

func refDrawTrash(_ cr: OpaquePointer, _ r: Rect, full: Bool) {
    cairo_save(cr)
    cairo_translate(cr, r.x, r.y)
    let s = r.w
    // A full Trash shows crumpled paper heaped above the rim, drawn *before* the
    // can so the wire mesh reads over it — the same "you can tell at a glance"
    // cue as 10.2, in our own glyph vocabulary.
    if full {
        cairo_set_source_rgba(cr, 0.94, 0.93, 0.88, 1)
        for (fx, fy, fr) in [(0.40, 0.30, 0.09), (0.56, 0.28, 0.10), (0.48, 0.22, 0.07)] {
            cairo_new_sub_path(cr)
            cairo_arc(cr, s * fx, s * fy, s * fr, 0, 2 * .pi)
            cairo_fill(cr)
        }
        cairo_set_source_rgba(cr, 0.72, 0.71, 0.66, 1)
        cairo_set_line_width(cr, s * 0.025)
        cairo_move_to(cr, s * 0.40, s * 0.30); cairo_line_to(cr, s * 0.50, s * 0.26)
        cairo_move_to(cr, s * 0.52, s * 0.32); cairo_line_to(cr, s * 0.60, s * 0.27)
        cairo_stroke(cr)
    }
    cairo_set_source_rgba(cr, 0.78, 0.80, 0.85, 1)
    cairo_set_line_width(cr, s * 0.05)
    // can body (trapezoid)
    cairo_move_to(cr, s * 0.30, s * 0.34)
    cairo_line_to(cr, s * 0.70, s * 0.34)
    cairo_line_to(cr, s * 0.64, s * 0.74)
    cairo_line_to(cr, s * 0.36, s * 0.74)
    cairo_close_path(cr); cairo_stroke(cr)
    // vertical mesh lines
    for fx in [0.44, 0.5, 0.56] {
        cairo_move_to(cr, s * fx, s * 0.36); cairo_line_to(cr, s * fx, s * 0.72); cairo_stroke(cr)
    }
    // lid + handle
    cairo_move_to(cr, s * 0.26, s * 0.30); cairo_line_to(cr, s * 0.74, s * 0.30); cairo_stroke(cr)
    cairo_move_to(cr, s * 0.42, s * 0.30); cairo_line_to(cr, s * 0.44, s * 0.24)
    cairo_line_to(cr, s * 0.56, s * 0.24); cairo_line_to(cr, s * 0.58, s * 0.30); cairo_stroke(cr)
    cairo_restore(cr)
}

