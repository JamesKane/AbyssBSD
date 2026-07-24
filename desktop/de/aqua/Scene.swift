// Scene — Jaguar window painting. Chrome (frame, title bar, lights, pill) is
// shared; each scene draws its own content. Drives both the live Wayland path
// (AquaWindow) and the offscreen PNG render used for visual verification.

import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum SceneKind: Sendable {
    case window
    case systemPreferences
    case widgets
    case scroll
    case tabs
    case sheet
    case wallpaper   // full-bleed desktop backdrop (a layer-shell client live)
    case menubar     // the top menu bar (a layer-shell TOP client live)
    case dock        // the magnifying Dock (a layer-shell BOTTOM client live)
}

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
    Draw.pill(cr, Rect(w - 30, cy - 6.5, 22, 13))

    cairo_restore(cr)

    Draw.roundedRectTop(cr, frame, radius: radius)
    Draw.setColor(cr, Theme.windowBorder)
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)

    return Rect(0, Theme.titleBarHeight, w, h - Theme.titleBarHeight)
}

/// The simple demo window (a heading + a live default gel button). Returns the
/// button rect for hit-testing.
@discardableResult
public func paintAquaWindow(_ cr: OpaquePointer, w: Double, h: Double,
                            title: String, clickCount: Int,
                            buttonPressed: Bool, typed: String = "",
                            focused: Bool = false) -> Rect {
    paintWindowChrome(cr, w: w, h: h, title: title)

    Draw.textLeft(cr, "Welcome to AbyssBSD", x: 24, baselineY: 70,
                  color: Theme.bodyText, size: 16)
    Draw.textLeft(cr, "A Swift 6 desktop, dressed in Aqua.", x: 24, baselineY: 94,
                  color: Theme.bodyText.with(a: 0.7), size: Theme.fontSize)
    Draw.textLeft(cr, "Clicks: \(clickCount)", x: 24, baselineY: 132,
                  color: Theme.bodyText, size: Theme.fontSize)

    // A live text field: real keyboard input lands here (see AquaWindow).
    let field = Rect(24, 150, w - 48, 26)
    Draw.textField(cr, field, text: typed, caret: focused)

    let bw = 120.0, bh = 30.0
    let buttonRect = Rect(w - bw - 20, h - bh - 20, bw, bh)
    Draw.gelButton(cr, buttonRect, label: "Click Me", blue: true,
                   pressed: buttonPressed)
    return buttonRect
}

// MARK: System Preferences

private let prefSections: [(String, [(PrefIcon, String)])] = [
    ("Personal", [
        (.desktop, "Desktop"), (.dock, "Dock"), (.general, "General"),
        (.international, "International"), (.loginItems, "Login Items"),
        (.myAccount, "My Account"), (.screenEffects, "Screen Effects"),
    ]),
    ("Hardware", [
        (.cdsDvds, "CDs & DVDs"), (.colorSync, "ColorSync"),
        (.displays, "Displays"), (.energySaver, "Energy Saver"),
        (.keyboard, "Keyboard"), (.mouse, "Mouse"), (.sound, "Sound"),
    ]),
    ("Internet & Network", [
        (.internetIcon, "Internet"), (.network, "Network"),
        (.quicktime, "QuickTime"), (.sharing, "Sharing"),
    ]),
    ("System", [
        (.accounts, "Accounts"), (.classic, "Classic"),
        (.dateTime, "Date & Time"), (.softwareUpdate, "Software Update"),
        (.speech, "Speech"), (.startupDisk, "Startup Disk"),
        (.universalAccess, "Universal Access"),
    ]),
]

private let prefToolbar: [(PrefIcon, String)] = [
    (.displays, "Displays"), (.sound, "Sound"), (.network, "Network"),
    (.startupDisk, "Startup Disk"),
]

public func paintSystemPreferences(_ cr: OpaquePointer, w: Double, h: Double) {
    paintWindowChrome(cr, w: w, h: h, title: "System Preferences")

    // Toolbar.
    let tbY = Theme.titleBarHeight
    let tbH = 58.0
    cairo_rectangle(cr, 0, tbY, w, tbH)
    Draw.fillVerticalGradient(cr, y: tbY, h: tbH, stops: [
        (0, Color(hex: 0xededed)), (1, Color(hex: 0xd8d8d8)),
    ])
    Draw.setColor(cr, Theme.separator)
    cairo_set_line_width(cr, 1)
    cairo_move_to(cr, 0, tbY + tbH - 0.5)
    cairo_line_to(cr, w, tbY + tbH - 0.5)
    cairo_stroke(cr)

    let tbItemTop = tbY + 6
    toolbarItem(cr, .showAll, "Show All", centerX: 44, top: tbItemTop)
    // Dotted vertical separator after Show All.
    cairo_set_source_rgba(cr, 0, 0, 0, 0.25)
    cairo_set_line_width(cr, 1)
    cairo_set_dash(cr, [1, 2], 2, 0)
    cairo_move_to(cr, 86, tbY + 10); cairo_line_to(cr, 86, tbY + tbH - 10)
    cairo_stroke(cr)
    cairo_set_dash(cr, [], 0, 0)
    var tx = 130.0
    for (icon, label) in prefToolbar {
        toolbarItem(cr, icon, label, centerX: tx, top: tbItemTop)
        tx += 70
    }

    // Sections.
    let margin = 24.0
    let cols = 7
    let cellW = (w - 2 * margin) / Double(cols)
    let rowH = 80.0
    var y = tbY + tbH + 16

    for (title, items) in prefSections {
        Draw.textLeft(cr, title, x: margin, baselineY: y + 12,
                      color: Color(hex: 0x1a1a1a), size: 13)
        y += 24
        let rows = (items.count + cols - 1) / cols
        for (i, item) in items.enumerated() {
            let col = i % cols, row = i / cols
            let cx = margin + Double(col) * cellW + cellW / 2
            let iy = y + Double(row) * rowH
            Icons.draw(cr, item.0, in: Rect(cx - 24, iy, 48, 48))
            centeredLabel(cr, item.1, centerX: cx, top: iy + 54,
                          maxWidth: cellW - 6)
        }
        y += Double(rows) * rowH + 6
        if title != "System" {
            Draw.setColor(cr, Theme.separator)
            cairo_set_line_width(cr, 1)
            cairo_move_to(cr, margin, y + 0.5)
            cairo_line_to(cr, w - margin, y + 0.5)
            cairo_stroke(cr)
            y += 14
        }
    }
}

private func toolbarItem(_ cr: OpaquePointer, _ icon: PrefIcon, _ label: String,
                         centerX: Double, top: Double) {
    Icons.draw(cr, icon, in: Rect(centerX - 16, top, 32, 32))
    Draw.text(cr, label, centerX: centerX, centerY: top + 42,
              color: Color(hex: 0x303030), size: 10)
}

/// Centred icon label, wrapped to two lines when it doesn't fit `maxWidth`.
private func centeredLabel(_ cr: OpaquePointer, _ s: String, centerX: Double,
                           top: Double, maxWidth: Double) {
    let size = 11.0
    if Draw.textWidth(cr, s, size: size) <= maxWidth {
        Draw.text(cr, s, centerX: centerX, centerY: top + size / 2,
                  color: Color(hex: 0x202020), size: size)
        return
    }
    // Split into two balanced lines at a space.
    let words = s.split(separator: " ").map(String.init)
    var first = "", second = ""
    if words.count <= 1 {
        first = s
    } else {
        let mid = (words.count + 1) / 2
        first = words[0..<mid].joined(separator: " ")
        second = words[mid...].joined(separator: " ")
    }
    Draw.text(cr, first, centerX: centerX, centerY: top + size / 2,
              color: Color(hex: 0x202020), size: size)
    if !second.isEmpty {
        Draw.text(cr, second, centerX: centerX, centerY: top + size * 1.5 + 1,
                  color: Color(hex: 0x202020), size: size)
    }
}

// MARK: offscreen render

/// Render one scene to a PNG file — headless visual verification.
@discardableResult
public func renderScenePNG(path: String, kind: SceneKind, width: Int32,
                           height: Int32, scale: Int32 = 1,
                           title: String = "AbyssBSD",
                           clickCount: Int = 0) -> Bool {
    let bw = width * scale, bh = height * scale
    guard let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, bw, bh),
          let cr = cairo_create(cs) else { return false }
    cairo_scale(cr, Double(scale), Double(scale))
    Text.renderScale = scale   // shape/hint on the device pixel grid

    defer { Text.renderScale = 1 }

    // The wallpaper is full-bleed (no grey desktop, no window inset). The menu
    // bar / Dock previews composite the shell surfaces over the wallpaper.
    if kind == .wallpaper || kind == .menubar || kind == .dock {
        paintWallpaper(cr, w: Double(width), h: Double(height))
        if kind == .menubar {
            paintMenuBar(cr, w: Double(width), h: MenuBarMetrics.height,
                         menus: MenuBar.defaultMenus(appName: "Finder"),
                         clock: formatMenuClock(hour24: 9, minute: 41, wday: 1),
                         openIndex: nil, showClock: true)
        }
        if kind == .dock {
            let dockH = DockMetrics.surfaceHeight(tileSize: 48)
            var items = Dock.defaultPinned()
            items.append(DockItem(icon: .trash, label: "Trash", appID: nil, isTrash: true))
            cairo_save(cr)
            cairo_translate(cr, 0, Double(height) - dockH)
            // Pointer near a tile to show the magnification curve in the preview.
            paintDock(cr, w: Double(width), h: dockH, items: items,
                      running: items.map { _ in false },
                      pointerX: Double(width) * 0.42, tileSize: 48, magnify: true)
            cairo_restore(cr)
        }
        cairo_surface_flush(cs)
        let status = cairo_surface_write_to_png(cs, path)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
        return status == CAIRO_STATUS_SUCCESS
    }

    // Desktop-grey backdrop so the window edges read.
    let g = cairo_pattern_create_linear(0, 0, 0, Double(height))
    cairo_pattern_add_color_stop_rgba(g, 0, 0.62, 0.66, 0.72, 1)
    cairo_pattern_add_color_stop_rgba(g, 1, 0.50, 0.54, 0.60, 1)
    cairo_set_source(cr, g)
    cairo_paint(cr)
    cairo_pattern_destroy(g)

    let inset = 16.0
    cairo_save(cr)
    cairo_translate(cr, inset, inset)
    let cw = Double(width) - 2 * inset, ch = Double(height) - 2 * inset
    switch kind {
    case .window:
        paintAquaWindow(cr, w: cw, h: ch, title: title, clickCount: clickCount,
                        buttonPressed: false)
    case .systemPreferences:
        paintSystemPreferences(cr, w: cw, h: ch)
    case .widgets:
        paintWidgets(cr, w: cw, h: ch, state: WidgetState(), focus: .ok)
    case .scroll:
        paintScroll(cr, w: cw, h: ch, offset: 0)
    case .tabs:
        paintTabs(cr, w: cw, h: ch, state: TabsState())
    case .sheet:
        // Show the sheet fully out for the static shot.
        paintSheetScene(cr, w: cw, h: ch, progress: 1, visible: true,
                        lastAction: "—")
    case .wallpaper, .menubar, .dock:
        break  // handled full-bleed above
    }
    cairo_restore(cr)

    cairo_surface_flush(cs)
    let status = cairo_surface_write_to_png(cs, path)
    cairo_destroy(cr)
    cairo_surface_destroy(cs)
    return status == CAIRO_STATUS_SUCCESS
}
