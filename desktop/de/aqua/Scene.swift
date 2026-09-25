// Scene — Jaguar window painting. Chrome (frame, title bar, lights, pill) is
// shared; each scene draws its own content. Drives both the live Wayland path
// (AquaWindow) and the offscreen PNG render used for visual verification.

// **Re-exported on purpose.** `Rect`, `Theme`, `Draw` and `Text` moved to
// `AquaDraw` in P9.6 so the compositor can link them for server-side
// decorations. Every file in this toolkit uses them unqualified and always has;
// re-exporting keeps that true and means the extraction changed no call site.
// `MenuModel` likewise (P10.1): an application built on Aqua defines its
// commands with it, and should not need a second import to do so.
@_exported import AquaDraw
@_exported import MenuModel
import CCairo
import Surface
import Vents

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
    case notify      // notification toasts (a layer-shell OVERLAY client live)
    case finder      // the file browser (an ordinary xdg-shell toplevel)
    case installer   // the guided installer (PHASE5 P5.4)
}

/// What the pointer is over in a window's chrome.
///
/// Client-side decorations mean the *client* decides what a press on its own
/// frame means — but only the compositor can act on it, so each of these turns
/// into an `xdg_toplevel` request (P9.4). Keeping the rule here, pure, means
/// every window kind gets the same answer and the answer can be tested without
/// a compositor (§2.9).
public enum WindowChromeHit: Equatable, Sendable {
    case close
    case minimize
    case zoom
    case pill                  // the toolbar toggle; only the Finder uses it
    case title                 // drag it to move the window
    case resize(ResizeEdge)
    case content               // not chrome — the scene's own business
}

/// How deep the invisible resize band along a window's **bottom** is.
///
/// **Only the bottom edge and the two bottom corners resize.** Two reasons, and
/// they agree:
///
///   - 10.2 resized from the corner grip and nothing else, so side bands would
///     be a modern habit wearing a Jaguar frame;
///   - the side bands are not free. The Finder's scrollbar is the rightmost
///     15px of its window, so a 6px band takes the right 6px of every thumb and
///     arrow in it — a scrollbar that resizes the window when you grab the
///     wrong half of it. The sway suite passed with the bands in, because no
///     test drags a thumb by its outer edge; a person would find it in a day.
///
/// The top is the title bar's, for the same reason: aiming at it to *move* the
/// window and resizing it instead is the worse failure of the two.
public let windowResizeBand: Double = 6
public let windowResizeCorner: Double = 14

/// What is under (x, y) in a window of logical size (w, h).
public func windowChromeHit(x: Double, y: Double, w: Double, h: Double) -> WindowChromeHit {
    // The bottom first: it is the outermost few pixels, and a control that
    // overlapped it would be unreachable from the other side.
    let cornerL = x <= windowResizeCorner, cornerR = x >= w - windowResizeCorner
    let cornerB = y >= h - windowResizeCorner
    if cornerB && cornerR { return .resize(.bottomRight) }
    if cornerB && cornerL { return .resize(.bottomLeft) }
    if y >= h - windowResizeBand { return .resize(.bottom) }

    if y < Theme.titleBarHeight {
        let lights = windowTrafficRects()
        if lights.close.contains(x, y) { return .close }
        if lights.minimize.contains(x, y) { return .minimize }
        if lights.zoom.contains(x, y) { return .zoom }
        if windowPillRect(w: w).contains(x, y) { return .pill }
        return .title
    }
    return .content
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
        if kind == .wallpaper {
            // The desktop's own icons, over a synthetic listing.
            let bounds = Rect(0, DesktopMetrics.topInset, Double(width),
                              Double(height) - DesktopMetrics.topInset)
            paintDesktopIcons(cr, bounds: bounds, entries: desktopSampleEntries(),
                              selection: 1)
        }
        if kind == .menubar {
            // The headless render reads the machine the same way the live bar
            // does, so a status item that would appear on screen appears here
            // too (and one the machine can't feed is absent in both).
            paintMenuBar(cr, w: Double(width), h: MenuBarMetrics.height,
                         menus: MenuBar.menus(for: finderMenuBar()),
                         clock: formatMenuClock(hour24: 9, minute: 41, wday: 1),
                         openIndex: nil, showClock: true,
                         status: MenuBarStatus.read(mixer: Vents.Mixer()))
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
    case .finder:
        // A fixed synthetic home folder, so the preview is reproducible on any
        // machine (the live FinderWindow reads the real filesystem).
        let entries = finderSampleEntries()
        let listView = getenv("AQUA_FINDER_VIEW").map { String(cString: $0) } == "list"
        paintFinder(cr, w: cw, h: ch,
                    state: FinderState(path: "/Users/abyss", entries: entries,
                                       selection: 2, view: listView ? .list : .icon,
                                       freeBytes: 39_600_000_000))
    case .installer:
        // A fixed synthetic machine, so the preview is the same on any box —
        // the live installer asks `abyss-install` what disks are really there.
        // `AQUA_INSTALLER_PAGE` picks which screen, the way AQUA_FINDER_VIEW
        // picks the Finder's, so every one of them can be looked at.
        var m = installerSampleModel()
        switch getenv("AQUA_INSTALLER_PAGE").map({ String(cString: $0) }) {
        case "empty":    m = InstallerModel(inventory: m.inventory)
        case "disk":     m.enter(.disk)
        case "account":  m.enter(.account)
        case "keyboard": m.enter(.keyboard)
        case "confirm":  m.page = .confirm
        case "installing":
            m.page = .installing; m.stepIndex = 24; m.stepTotal = 39
            m.stepWhat = "extract base.txz"
        case "done":     m.page = .done(ok: true, error: "")
        default: break
        }
        paintInstaller(cr, w: cw, h: ch, model: m,
                       focus: getenv("AQUA_INSTALLER_PAGE").map({ String(cString: $0) })
                                == "account" ? .password : nil)
    case .wallpaper, .menubar, .dock:
        break  // handled full-bleed above
    case .notify:
        // A sample stack, so the PNG render shows the toast design without a
        // live service to post into it.
        let sample = [
            Toast(id: 1, summary: "Build finished", body: "all tests green", expiresAt: .infinity),
            Toast(id: 2, summary: "Disk ejected",
                  body: "AbyssBSD HD may now be safely removed", expiresAt: .infinity),
        ]
        let heights = sample.map { t -> Double in
            let lines = t.body.map {
                toastWrap(cr, $0, width: ToastMetrics.width - ToastMetrics.padX * 2 - 20,
                          size: ToastMetrics.bodySize, maxLines: ToastMetrics.maxBodyLines)
            } ?? []
            return toastHeight(bodyLines: lines.count)
        }
        let l = toastLayout(heights: heights)
        for (i, t) in sample.enumerated() {
            let lines = t.body.map {
                toastWrap(cr, $0, width: ToastMetrics.width - ToastMetrics.padX * 2 - 20,
                          size: ToastMetrics.bodySize, maxLines: ToastMetrics.maxBodyLines)
            } ?? []
            let r = l.rects[i]
            paintToast(cr, Rect(cw - ToastMetrics.width - 12, r.y + 8, r.w, r.h),
                       toast: t, bodyLines: lines)
        }
    }
    cairo_restore(cr)

    cairo_surface_flush(cs)
    let status = cairo_surface_write_to_png(cs, path)
    cairo_destroy(cr)
    cairo_surface_destroy(cs)
    return status == CAIRO_STATUS_SUCCESS
}

// MARK: - Golden-image scenes that are not windows (PHASE11 P11.1)

/// An open menu, as a popup draws it: the Finder's File menu with its real
/// enablement (the static rule the bar uses without an application to ask),
/// key equivalents, separators, a disabled row — and one row hovered, so the
/// highlight is in the picture. Transparent corners, as the popup has.
public func renderMenuPNG(path: String, scale: Int32 = 1) -> Bool {
    guard let file = finderMenuBar().menus.first(where: { $0.title == "File" }) else { return false }
    let rows = aquaMenuItems(file, enablement: MenuBar.staticEnablement)
    let menu = AquaMenu(items: rows)
    let w = Int32(max(150, menu.preferredWidth)), h = Int32(menu.preferredHeight.rounded(.up))
    // Hover "New Folder" — the second row — so the highlight is drawn.
    let geo = aquaMenuRows(rows)
    menu.pointerMoved(x: 20, y: geo[1].y + geo[1].h / 2)
    guard let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w * scale, h * scale)
    else { return false }
    defer { cairo_surface_destroy(cs) }
    Text.renderScale = scale
    defer { Text.renderScale = 1 }
    guard let data = cairo_image_surface_get_data(cs) else { return false }
    menu.render(PixelBuffer(data: UnsafeMutableRawPointer(data), width: w * scale,
                            height: h * scale,
                            stride: cairo_image_surface_get_stride(cs), scale: scale))
    cairo_surface_mark_dirty(cs)
    return cairo_surface_write_to_png(cs, path) == CAIRO_STATUS_SUCCESS
}

/// The frame undertow paints around a foreign window (P9.6), from the same
/// `paintWindowChrome` it calls — so the compositor's chrome is under the gate
/// without a compositor.
public func renderFramePNG(path: String, width: Int32 = 480, height: Int32 = 300,
                           scale: Int32 = 1) -> Bool {
    guard let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width * scale, height * scale),
          let cr = cairo_create(cs) else { return false }
    defer { cairo_destroy(cr); cairo_surface_destroy(cs) }
    cairo_scale(cr, Double(scale), Double(scale))
    Text.renderScale = scale
    defer { Text.renderScale = 1 }
    paintWindowChrome(cr, w: Double(width), h: Double(height), title: "Untitled — gedit")
    cairo_surface_flush(cs)
    return cairo_surface_write_to_png(cs, path) == CAIRO_STATUS_SUCCESS
}
