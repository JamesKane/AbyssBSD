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
import Terminal
import TextModel
import Install
import Volumes

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
    case terminal    // Terminal (PHASE15 P15.4b)
    case textedit    // TextEdit (PHASE15 P15.5)
    case grab        // Grab (PHASE15 P15.6)
    case activity    // Activity Monitor (PHASE15 P15.7)
    case diskutility // Disk Utility (PHASE15 P15.8)
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
    case depth                 // send the window to the back (P11.6)
    case pill                  // the toolbar toggle; only the Finder uses it
    case title                 // drag it to move the window
    case resize(ResizeEdge)
    case content               // not chrome — the scene's own business
}

/// How deep the resize band along a window's bottom is, and its corners — the
/// theme's (`chrome.resizeBand`, `chrome.resizeCorner`); `chromeHit` says why
/// only the bottom resizes.
public var windowResizeBand: Double { Theme.current.chromeResizeBand }
public var windowResizeCorner: Double { Theme.current.chromeResizeCorner }

/// What is under (x, y) in a window of logical size (w, h): `chromeHit` over
/// `windowChrome` — the one layout the painter used (P11.6).
public func windowChromeHit(x: Double, y: Double, w: Double, h: Double) -> WindowChromeHit {
    switch chromeHit(windowChrome(w: w, h: h), x: x, y: y) {
    case .gadget(.close): return .close
    case .gadget(.minimize): return .minimize
    case .gadget(.zoom): return .zoom
    case .gadget(.depth): return .depth
    case .gadget(.pill): return .pill
    case .title: return .title
    case .resize(.bottom): return .resize(.bottom)
    case .resize(.bottomLeft): return .resize(.bottomLeft)
    case .resize(.bottomRight): return .resize(.bottomRight)
    case .content: return .content
    }
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
                         // AQUA_MENUBAR_OPEN=i pictures title i open (the
                         // highlight, P11.5) — 0 is the system menu's mark.
                         openIndex: getenv("AQUA_MENUBAR_OPEN").flatMap { Int(String(cString: $0)) },
                         showClock: true,
                         status: MenuBarStatus.read())
        }
        if kind == .dock {
            let dockH = DockMetrics.surfaceHeight(tileSize: 48)
            var items = Dock.defaultPinned()
            items.append(DockItem(icon: .trash, label: "Trash", appID: nil, isTrash: true))
            cairo_save(cr)
            cairo_translate(cr, 0, Double(height) - dockH)
            // Pointer near a tile to show the magnification curve in the preview.
            paintDock(cr, w: Double(width), h: dockH, items: items,
                      // AQUA_DOCK_RUNNING: every other application running, so
                      // the running mark is pictured (P11.5) — never the Trash,
                      // which cannot run and which the old placeholders hid.
                      running: items.indices.map {
                          getenv("AQUA_DOCK_RUNNING") != nil && $0 % 2 == 0 && !items[$0].isTrash },
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
        // AQUA_PREFS_PANE=<id> pictures a pane's page (P14.1); else the grid.
        var m = PrefsModel()
        var network: NetworkPaneState?
        if let p = getenv("AQUA_PREFS_PANE").map({ String(cString: $0) }) {
            // "network-wifi": the Network pane with its radio chosen (P14.5c).
            if p == "network-wifi" {
                m.view = .pane("network")
                var n = NetworkPaneState.sample
                n.radios = ["iwn0"]
                n.wifi = .sample
                network = n
            } else {
                m.view = .pane(p)
            }
        }
        paintSystemPreferences(cr, w: cw, h: ch, model: m, network: network)
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
    case .diskutility:
        // A fixed machine: one disk, a pool, a dataset with two snapshots selected.
        var v = DiskUtilityView()
        v.disks = [Disk(name: "nvd0", bytes: 1_000_204_886_016, description: "Samsung SSD 980 PRO 1TB",
                        mountedAt: ["/"], holdsRunningRoot: true, partitionKinds: ["efi", "freebsd-swap", "freebsd-zfs"])]
        v.volumes.datasets = [
            ZFSDataset(name: "zroot", used: 42_719_010_816, available: 45_561_032_704, mountpoint: "none", mounted: false),
            ZFSDataset(name: "zroot/ROOT", used: 13_056_704_512, available: 45_561_032_704, mountpoint: "none", mounted: false),
            ZFSDataset(name: "zroot/ROOT/default", used: 13_056_270_336, available: 45_561_032_704, mountpoint: "/", mounted: true),
            ZFSDataset(name: "zroot/home", used: 6_774_800_384, available: 45_561_032_704, mountpoint: "/home", mounted: true),
        ]
        v.volumes.snapshots = [ZFSSnapshot(name: "zroot/home@abyss-2026-09-30-180000", created: 1_790_791_200, used: 1_310_720),
                               ZFSSnapshot(name: "zroot/home@abyss-2026-10-01-090507", created: 1_790_845_507, used: 98_304)]
        v.selected = "ds:zroot/home"
        v.selectedSnapshot = "zroot/home@abyss-2026-10-01-090507"
        v.status = "snapshot zroot/home@abyss-2026-10-01-090507: done."
        v.utcDates = true
        _ = paintDiskUtility(cr, w: cw, h: ch, view: v)
    case .activity:
        // A fixed table: names, users and numbers that do not change from run to run.
        func p(_ pid: Int32, _ name: String, _ uid: UInt32, _ rss: UInt64, _ thr: Int32, sys: Bool = false) -> Processes.Info {
            Processes.Info(pid: pid, uid: uid, threads: thr, residentBytes: rss, started: 100, system: sys, name: name)
        }
        let procs = [p(1, "init", 0, 1_200_000, 1), p(14, "kernel", 0, 0, 230, sys: true),
                     p(812, "undertow", 1001, 96_000_000, 6), p(840, "AquaDemo", 1001, 58_000_000, 3),
                     p(901, "firefox", 1001, 412_000_000, 64), p(1203, "sh", 1001, 2_400_000, 1)]
        let before = Processes.Sample(processes: procs, at: 0)
        let cpu: [Int32: UInt64] = [812: 120_000, 840: 40_000, 901: 310_000]
        let after = Processes.Sample(processes: procs.map { q in
            Processes.Info(pid: q.pid, uid: q.uid, threads: q.threads, residentBytes: q.residentBytes,
                           cpuMicroseconds: cpu[q.pid] ?? 0, started: q.started, system: q.system, name: q.name)
        }, at: 1_000_000, memoryTotal: 16 << 30, memoryAvailable: 9 << 30)
        var v = ActivityView()
        v.mineOnly = false
        v.rows = ProcessTable(now: after, before: before).view(filter: .all, sortBy: .cpu, ascending: false,
                                                               userName: { $0 == 0 ? "root" : "abyss" })
        v.selected = v.rows.first { $0.info.pid == 840 }?.info.identity
        v.memoryTotal = 16 << 30; v.memoryAvailable = 9 << 30; v.cpuTotal = 11.8
        _ = paintActivity(cr, w: cw, h: ch, view: v, userName: { $0 == 0 ? "root" : "abyss" })
    case .grab:
        _ = paintGrabPanel(cr, w: cw, h: ch, status: "Choose what to capture.")
    case .textedit:
        // A fixed document: wrapped lines, a tab, a selection across a line
        // break, and the find bar with its text.
        let view = TextView()
        view.setText("Welcome to TextEdit.\n\nPlain text, opened and saved through the Finder, with undo and find. A long line wraps at the window's edge, after the last space that fits.\n\tIndented with a tab.\nThe end.")
        view.edit { $0.select(TextRange(TextPosition(line: 2, column: 6), TextPosition(line: 3, column: 9))) }
        paintTextEdit(cr, w: cw, h: ch, title: "Notes.txt — Edited", view: view,
                      findBar: "wraps", findFocused: false, caretOn: true)
    case .terminal:
        // A fixed transcript through the real screen model: a prompt, colours,
        // bold, inverse, a line-drawing box, and the caret on the last line.
        var s = Screen(rows: 20, cols: 70)
        s.feed("$ ls --color\r\n\u{1B}[1;34mDocuments\u{1B}[0m  \u{1B}[1;32mbuild.sh\u{1B}[0m  notes.txt  \u{1B}[7m inverse \u{1B}[m\r\n")
        s.feed("$ printf '\\e(0lqqqk\\nx   x\\nmqqqj\\e(B\\n'\r\n\u{1B}(0lqqqk\r\nx   x\r\nmqqqj\u{1B}(B\r\n")
        s.feed("\u{1B}[31mred\u{1B}[m \u{1B}[42;30m green bg \u{1B}[m \u{1B}[4munderlined\u{1B}[m \u{1B}[38;5;208m208\u{1B}[m\r\n$ ")
        paintTerminal(cr, w: cw, h: ch, title: "sh — 70×20", screen: s, caretOn: true, focused: true)
    case .finder:
        // A fixed synthetic home folder, so the preview is reproducible on any
        // machine (the live FinderWindow reads the real filesystem).
        let entries = finderSampleEntries()
        let listView = getenv("AQUA_FINDER_VIEW").map { String(cString: $0) } == "list"
        var fs = FinderState(path: "/Users/abyss", entries: entries,
                             selection: 2, view: listView ? .list : .icon,
                             freeBytes: 39_600_000_000)
        // AQUA_FINDER_STATE pictures what the default never shows (P11.5):
        // "rename" — item 2's name being edited, part of it selected, with
        // Back enabled; "back" — Back held down, the rename down to its caret.
        switch getenv("AQUA_FINDER_STATE").map({ String(cString: $0) }) {
        case "rename":
            fs.canGoBack = true
            fs.edit = FinderEdit(index: 2, text: entries[2].name, selectedPrefix: 4)
        case "back":
            fs.canGoBack = true; fs.backPressed = true
            fs.edit = FinderEdit(index: 2, text: entries[2].name + " copy")
        default: break
        }
        paintFinder(cr, w: cw, h: ch, state: fs)
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
    // AQUA_MENU_MARKS: the parts the File menu never shows (P11.5) — a checked
    // row, and a submenu's ▸ plain, disabled and highlighted.
    let marks = getenv("AQUA_MENU_MARKS") != nil
    let rows = marks
        ? [AquaMenuItem("as Icons"), AquaMenuItem("as List"), AquaMenuItem.separator,
           AquaMenuItem("Arrange By", hasSubmenu: true), AquaMenuItem("Label", enabled: false, hasSubmenu: true),
           AquaMenuItem("Show View Options", keyText: "⌘J", hasSubmenu: true)]
        : aquaMenuItems(file, enablement: MenuBar.staticEnablement)
    let menu = AquaMenu(items: rows, selected: marks ? 0 : -1)
    let w = Int32(max(150, menu.preferredWidth)), h = Int32(menu.preferredHeight.rounded(.up))
    // Hover "New Folder" — the second row — so the highlight is drawn (or,
    // with marks, the last submenu row).
    let geo = aquaMenuRows(rows)
    let hover = marks ? rows.count - 1 : 1
    menu.pointerMoved(x: 20, y: geo[hover].y + geo[hover].h / 2)
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
    paintWindowChrome(cr, w: Double(width), h: Double(height), title: "Untitled — gedit",
                      foreign: true)
    cairo_surface_flush(cs)
    return cairo_surface_write_to_png(cs, path) == CAIRO_STATUS_SUCCESS
}

/// A sheet of every draw-list primitive (PHASE11 P11.3), from
/// `abyss/tests/drawlist-sample.dl` (or `$AQUA_DRAWLIST`) — so the interpreter
/// is under the golden gate before anything depends on it.
public func renderDrawListPNG(path: String, listFile: String, scale: Int32 = 1) -> Bool {
    guard let text = ThemeLoader.readFile(listFile) else { return false }
    let file: DrawListFile
    do { file = try DrawListFile(parsing: text) } catch {
        let line = "AquaDemo: \(listFile): \(error)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
        return false
    }
    let w: Int32 = 520, h: Int32 = 200
    guard let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w * scale, h * scale),
          let cr = cairo_create(cs) else { return false }
    defer { cairo_destroy(cr); cairo_surface_destroy(cs) }
    cairo_scale(cr, Double(scale), Double(scale))
    Text.renderScale = scale
    defer { Text.renderScale = 1 }
    cairo_set_source_rgb(cr, 0.04, 0.04, 0.094)   // Plan Neo's void
    cairo_paint(cr)
    func draw(_ name: String, _ r: Rect, _ state: DrawState = .normal, _ label: String = "") {
        if let l = file[name] { DrawListRunner.run(l, cr, DrawContext(rect: r, state: state, label: label)) }
    }
    draw("mui-button", Rect(20, 20, 120, 28), .normal, "Save")
    draw("mui-button", Rect(160, 20, 120, 28), .pressed, "Use")
    draw("mui-button", Rect(300, 20, 120, 28), .focused, "Cancel")
    draw("brushed", Rect(20, 70, 260, 26))
    draw("anodized", Rect(300, 70, 200, 110))
    draw("knob", Rect(30, 118, 54, 54))
    draw("led", Rect(110, 138, 14, 14))
    draw("lcd", Rect(150, 124, 120, 40))
    cairo_surface_flush(cs)
    return cairo_surface_write_to_png(cs, path) == CAIRO_STATUS_SUCCESS
}

/// An icon sheet (PHASE11 P11.8): every icon in `listFile`, or — with none —
/// the theme's own set (`icon.*`, `dock.icon.*`), each at 16, 32 and 64 points
/// in a row of its own, so the whole set is under the golden gate and can be
/// looked at in one picture. `Draw.icon`'s size variants apply.
public func renderIconSheetPNG(path: String, listFile: String?, scale: Int32 = 1) -> Bool {
    var lists = Theme.lists
    if let f = listFile {
        guard let text = ThemeLoader.readFile(f) else { return false }
        do { lists = try DrawListFile(parsing: text) } catch {
            let line = "AquaDemo: \(f): \(error)\n"
            line.withCString { _ = write(2, $0, strlen($0)) }
            return false
        }
    }
    let names = lists.lists.keys.filter { $0.hasPrefix("icon.") || $0.hasPrefix("dock.icon.") }
        .filter { !$0.hasSuffix(".small") }.sorted()
    guard !names.isEmpty else { return false }
    let perColumn = 20
    let columns = (names.count + perColumn - 1) / perColumn
    let rowH = 72.0, colW = 140.0
    let w = Int32(colW * Double(columns)) + 8, h = Int32(rowH * Double(min(perColumn, names.count))) + 8
    guard let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w * scale, h * scale),
          let cr = cairo_create(cs) else { return false }
    defer { cairo_destroy(cr); cairo_surface_destroy(cs) }
    cairo_scale(cr, Double(scale), Double(scale))
    Text.renderScale = scale
    defer { Text.renderScale = 1 }
    Draw.setColor(cr, Theme.contentBackground)
    cairo_paint(cr)
    for (i, n) in names.enumerated() {
        let x0 = 4 + colW * Double(i / perColumn), y0 = 4 + rowH * Double(i % perColumn)
        var x = x0
        for size in [16.0, 32.0, 64.0] {
            let r = Rect(x, y0 + (64 - size) / 2, size, size)
            if listFile == nil {
                Draw.icon(n, cr, r)
            } else if let l = lists[r.w < Theme.current.iconSmallBelow && lists[n + ".small"] != nil ? n + ".small" : n] {
                cairo_new_path(cr)
                DrawListRunner.run(l, cr, DrawContext(rect: r))
            }
            x += size + 6
        }
    }
    cairo_surface_flush(cs)
    return cairo_surface_write_to_png(cs, path) == CAIRO_STATUS_SUCCESS
}


/// The pointer's shapes (BACKLOG U.7): every name cursor-shape-v1 can ask
/// for, each as the theme draws it after the fallbacks, labelled, with its
/// hotspot marked by a red dot. What undertow puts on screen, under the
/// golden gate.
public func renderCursorSheetPNG(path: String, scale: Int32 = 1) -> Bool {
    let names = Cursor.shapeNames
    let columns = 6, cellW = 104.0, cellH = 58.0
    let rows = (names.count + columns - 1) / columns
    let w = Int32(cellW * Double(columns)), h = Int32(cellH * Double(rows))
    guard let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w * scale, h * scale),
          let cr = cairo_create(cs) else { return false }
    defer { cairo_destroy(cr); cairo_surface_destroy(cs) }
    cairo_scale(cr, Double(scale), Double(scale))
    Text.renderScale = scale
    defer { Text.renderScale = 1 }
    Draw.setColor(cr, Theme.contentBackground)
    cairo_paint(cr)
    for (i, n) in names.enumerated() {
        let x0 = cellW * Double(i % columns), y0 = cellH * Double(i / columns)
        let cx = x0 + (cellW - Cursor.size) / 2, cy = y0 + 4
        Cursor.draw(n, cr, x: cx, y: cy)
        let hot = Cursor.hotspot(n)
        cairo_set_source_rgba(cr, 1, 0, 0, 1)
        cairo_rectangle(cr, cx + hot.x - 1, cy + hot.y - 1, 2, 2)
        cairo_fill(cr)
        Draw.text(cr, n, centerX: x0 + cellW / 2, centerY: y0 + cellH - 12, color: Theme.secondaryText, size: 9)
    }
    cairo_surface_flush(cs)
    return cairo_surface_write_to_png(cs, path) == CAIRO_STATUS_SUCCESS
}
