// Wallpaper — the desktop backdrop: the shell's BACKGROUND wlr-layer-shell
// client. It reads its look from `desktop.ini` via PoolConfig and hot-reloads
// when that file changes (the `reef-desktop` analog, in Aqua dress).
//
// It also carries the **desktop icons** (DesktopIcons.swift): the boot volume
// and the contents of ~/Desktop, arranged from the top-right corner down. A
// double-click opens a Finder window — the Desktop and the Finder are one app on
// Mac, so this process hosts a `FinderApp` that does *not* own its lifetime (the
// desktop outlives every window it opens).
//
// Config (domain `desktop`), highest precedence first — matching the sibling:
//   image     = /path/to/wallpaper.png   (PNG; scaled to fill/cover)
//   grad_top, grad_bot = #aarrggbb        (vertical gradient)
//   bg        = #aarrggbb                 (flat fill)
//   (none)    -> the built-in Jaguar "Aqua Blue" gradient
//   show_icons = true | false             (desktop icons; default true)
// The Desktop folder is $ABYSS_DESKTOP_DIR, else $HOME/Desktop.
//
// The LayerSurface fills the output (BACKGROUND, all edges, exclusive -1). A
// Pool.Watcher on the config directory is folded into Display's run loop, so a
// rewrite of desktop.ini repaints the desktop with no polling.

import Surface
import PoolConfig
import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// How the desktop is filled, resolved from a `Config`.
public struct DesktopStyle: Equatable, Sendable {
    public enum Fill: Equatable, Sendable {
        case defaultAqua
        case flat(Color)
        case gradient(top: Color, bottom: Color)
        case image(String)
    }
    public var fill: Fill
    public init(fill: Fill) { self.fill = fill }

    /// Resolve from the `desktop` domain, applying the precedence above.
    public static func from(_ config: Config) -> DesktopStyle {
        if let img = config.string("desktop", "image"), !img.isEmpty {
            return DesktopStyle(fill: .image(img))
        }
        if let top = config.string("desktop", "grad_top").flatMap(Color.init(cssHex:)),
           let bot = config.string("desktop", "grad_bot").flatMap(Color.init(cssHex:)) {
            return DesktopStyle(fill: .gradient(top: top, bottom: bot))
        }
        if let bg = config.string("desktop", "bg").flatMap(Color.init(cssHex:)) {
            return DesktopStyle(fill: .flat(bg))
        }
        return DesktopStyle(fill: .defaultAqua)
    }

    /// A short tag for logging (the live test asserts on these).
    public var kind: String {
        switch fill {
        case .defaultAqua:  return "default"
        case .flat:         return "flat"
        case .gradient:     return "gradient"
        case .image:        return "image"
        }
    }
}

/// The built-in Jaguar "Aqua Blue" backdrop: a light sky top deepening to ocean
/// blue, with a broad soft sheen high and left of centre. The default when
/// desktop.ini specifies nothing (and the fallback for a broken image path).
public func paintWallpaper(_ cr: OpaquePointer, w: Double, h: Double) {
    let g = cairo_pattern_create_linear(0, 0, 0, h)
    for (at, c) in [(0.0, Theme.desktopTop), (0.55, Theme.desktopMiddle), (1.0, Theme.desktopBottom)] {
        cairo_pattern_add_color_stop_rgba(g, at, c.r, c.g, c.b, c.a)
    }
    cairo_set_source(cr, g)
    cairo_paint(cr)
    cairo_pattern_destroy(g)

    let cx = w * 0.42, cy = h * 0.30
    let radius = max(w, h) * 0.75
    let glow = cairo_pattern_create_radial(cx, cy, 0, cx, cy, radius)
    let gc = Theme.desktopGlow
    cairo_pattern_add_color_stop_rgba(glow, 0.0, gc.r, gc.g, gc.b, gc.a)
    cairo_pattern_add_color_stop_rgba(glow, 1.0, gc.r, gc.g, gc.b, 0.0)
    cairo_set_source(cr, glow)
    cairo_paint(cr)
    cairo_pattern_destroy(glow)
}

/// Paint the desktop backdrop for `style` into `w`×`h` logical pixels. Pure (no
/// Wayland), so it drives both the live layer surface and PNG/unit tests. An
/// image that fails to load falls back to the built-in Aqua gradient.
public func paintDesktop(_ cr: OpaquePointer, w: Double, h: Double, style: DesktopStyle) {
    switch style.fill {
    case .defaultAqua:
        paintWallpaper(cr, w: w, h: h)
    case .flat(let c):
        cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a)
        cairo_paint(cr)
    case .gradient(let top, let bot):
        let g = cairo_pattern_create_linear(0, 0, 0, h)
        cairo_pattern_add_color_stop_rgba(g, 0, top.r, top.g, top.b, top.a)
        cairo_pattern_add_color_stop_rgba(g, 1, bot.r, bot.g, bot.b, bot.a)
        cairo_set_source(cr, g)
        cairo_paint(cr)
        cairo_pattern_destroy(g)
    case .image(let path):
        guard paintImageCover(cr, w: w, h: h, path: path) else {
            paintWallpaper(cr, w: w, h: h)   // missing/broken file → Aqua default
            return
        }
    }
}

/// Paint `path` (a PNG) scaled to *cover* w×h (fill, preserve aspect, centre-crop
/// — the Mac "Fill Screen" default). Returns false if the file can't be loaded.
private func paintImageCover(_ cr: OpaquePointer, w: Double, h: Double, path: String) -> Bool {
    guard let img = path.withCString({ cairo_image_surface_create_from_png($0) }),
          cairo_surface_status(img) == CAIRO_STATUS_SUCCESS else {
        return false
    }
    defer { cairo_surface_destroy(img) }
    let iw = Double(cairo_image_surface_get_width(img))
    let ih = Double(cairo_image_surface_get_height(img))
    guard iw > 0, ih > 0 else { return false }
    let scale = max(w / iw, h / ih)
    let dw = iw * scale, dh = ih * scale
    cairo_save(cr)
    cairo_translate(cr, (w - dw) / 2, (h - dh) / 2)
    cairo_scale(cr, scale, scale)
    cairo_set_source_surface(cr, img, 0, 0)
    if let pat = cairo_get_source(cr) { cairo_pattern_set_extend(pat, CAIRO_EXTEND_PAD) }
    cairo_paint(cr)
    cairo_restore(cr)
    return true
}

private let kBtnLeft: UInt32 = 0x110
private let kBtnRight: UInt32 = 0x111
private let kDoubleClickMs: Int64 = 450

public final class Wallpaper: LayerSurfaceDelegate {
    private var layer: LayerSurface?
    private var style: DesktopStyle
    private var watcher: Pool.Watcher?

    // Desktop icons.
    private let showIcons: Bool
    private let desktopFolder: String?
    private var entries: [FinderEntry] = []
    private var selection: Int?
    /// The desktop's open contextual menu (P10.8).
    private var context: ContextMenu?

    /// The desktop's own commands (P10.8).
    static let newFolder = Command("desktop.new-folder", "New Folder",
                                   summary: "Make an untitled folder on the desktop.")
    static let changeBackground = Command("desktop.change-background", "Change Desktop Background…",
                                          summary: "Choose the desktop picture or colour.")
    static let contextMenu = Menu("Desktop", [.command(newFolder), .separator,
                                              .command(changeBackground)])
    private var iconWatcher: Pool.Watcher?
    private var finder: FinderApp?
    private var pointerX = 0.0
    private var pointerY = 0.0
    private var lastClickIndex: Int?
    private var lastClickMs: Int64 = 0

    /// The folder whose contents appear on the desktop.
    public static func desktopDirectory() -> String? {
        if let d = getenv("ABYSS_DESKTOP_DIR") {
            let s = String(cString: d)
            if !s.isEmpty { return s }
        }
        guard let h = getenv("HOME") else { return nil }
        let dir = String(cString: h) + "/Desktop"
        return finderIsDirectory(dir) ? dir : nil
    }

    /// The name shown under the volume icon (the machine, as on Mac).
    public static func volumeName() -> String { "AbyssBSD HD" }

    /// Create and map the desktop. Returns nil if the compositor lacks
    /// wlr-layer-shell. Reads `desktop.ini` now and watches for changes.
    public init?(display: Display) {
        let config = (try? Pool.load("desktop")) ?? Config()
        style = DesktopStyle.from(config)
        showIcons = config.bool("desktop", "show_icons") ?? true
        desktopFolder = Wallpaper.desktopDirectory()
        Wallpaper.log("applied \(style.kind)")

        let (scale, auto) = Wallpaper.scaleConfig()
        guard let ls = LayerSurface(
            display: display, layer: .background, namespace: "abyss.wallpaper",
            width: 0, height: 0, anchor: .all, exclusiveZone: -1,
            keyboard: .none, scale: scale, autoScale: auto, delegate: self)
        else { return nil }
        layer = ls

        // Hot-reload: fold the config-dir watch fd into the run loop.
        if let w = try? Pool.Watcher() {
            watcher = w
            display.addFileDescriptor(w.fileDescriptor) { [weak self] in
                self?.configChanged()
            }
        }

        if showIcons {
            // The Finder hosted by the desktop: it must NOT quit the process
            // when its last window closes — the desktop is still there.
            finder = FinderApp(display: display, quitsWithLastWindow: false)
            // **The desktop is the Finder** (PHASE10 P10.4): with no window
            // focused, Jaguar's menu bar shows the Finder's menus, because the
            // Finder is what draws the desktop. So the desktop's own surface
            // publishes this Finder's address, and the compositor falls back to
            // it when nothing else is frontmost.
            if let name = finder?.menuServiceName, layer?.publishMenus(at: name) == true {
                Wallpaper.log("the desktop publishes the Finder's menus at \(name)")
            }
            reloadIcons()
            // Same trick as the config watch, on the Desktop folder: drop a file
            // in ~/Desktop and it appears, with no polling.
            if let dir = desktopFolder, let w = try? Pool.Watcher(in: dir) {
                iconWatcher = w
                display.addFileDescriptor(w.fileDescriptor) { [weak self] in
                    self?.desktopFolderChanged()
                }
            }
        }
    }

    // MARK: desktop icons

    private func reloadIcons() {
        entries = desktopEntries(volumeName: Wallpaper.volumeName(),
                                 desktopFolder: desktopFolder)
        if let s = selection, s >= entries.count { selection = nil }
        Wallpaper.log("\(entries.count) icons")
    }

    private func desktopFolderChanged() {
        _ = iconWatcher?.drain()
        let before = entries.map(\.name)
        reloadIcons()
        guard entries.map(\.name) != before else { return }
        layer?.setNeedsDisplay()
    }

    /// The area icons may occupy: the whole output, less the menu bar's strip.
    private func iconBounds(w: Double, h: Double) -> Rect {
        Rect(0, DesktopMetrics.topInset, w, h - DesktopMetrics.topInset)
    }

    private func nowMs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }

    /// Open what was double-clicked: a folder (or the volume) in a Finder
    /// window; anything else just logs, as launching needs exec.
    private func activate(_ i: Int) {
        guard i >= 0, i < entries.count else { return }
        let entry = entries[i]
        let path: String
        if entry.kind == .disk {
            path = "/"                                   // the boot volume
        } else if let dir = desktopFolder {
            path = finderJoin(dir, entry.name)
        } else {
            return
        }
        guard entry.isContainer else {
            Wallpaper.log(Launcher.open(path).description + " (\(path))")
            return
        }
        Wallpaper.log("opened \(path)")
        finder?.openFolder(path)
    }

    /// Right-click on bare desktop (P10.8). On an icon it is the Finder's item
    /// menu in Jaguar; here the icons have no menu yet, so a right-click on one
    /// selects it and opens nothing, rather than offering the desktop's.
    private func openContextMenu() {
        context?.close(); context = nil
        let size = layer?.size ?? (width: 0, height: 0)
        let bounds = iconBounds(w: Double(size.width), h: Double(size.height))
        if let hit = desktopIndex(atX: pointerX, y: pointerY, count: entries.count, bounds: bounds) {
            selection = hit
            layer?.setNeedsDisplay()
            return
        }
        let (ax, ay) = (Int32(pointerX), Int32(pointerY))
        let folder = desktopFolder
        context = ContextMenu.open(
            Wallpaper.contextMenu, name: "desktop",
            enablement: { c in
                switch c.verb {
                case "desktop.new-folder":
                    return folder == nil ? .disabled("there is no Desktop folder") : .enabled
                default: return .disabled("not available yet")
                }
            },
            log: { Wallpaper.log($0) },
            open: { [weak self] w, h, am in
                self?.layer?.openPopup(anchorX: ax, anchorY: ay, anchorW: 1, anchorH: 1,
                                       width: w, height: h, delegate: am)
            },
            choose: { c in
                guard c.verb == "desktop.new-folder", let dir = folder else { return }
                let name = finderNewFolderName { finderExists(finderJoin(dir, $0)) }
                let ok = finderCreateDirectory(finderJoin(dir, name))
                // The Desktop folder's watcher redraws the icons (P2.x).
                Wallpaper.log(ok ? "new folder \(finderJoin(dir, name))" : "could not create \(name)")
            },
            onClose: { [weak self] in self?.context = nil })
    }

    public func pointerMoved(x: Double, y: Double) {
        pointerX = x
        pointerY = y
    }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        if showIcons, button == kBtnRight, pressed { openContextMenu(); return }
        guard showIcons, button == kBtnLeft, pressed else { return }
        let size = layer?.size ?? (width: 0, height: 0)
        let bounds = iconBounds(w: Double(size.width), h: Double(size.height))
        let hit = desktopIndex(atX: pointerX, y: pointerY, count: entries.count,
                               bounds: bounds)
        let now = nowMs()
        if let hit {
            let isDouble = hit == lastClickIndex && now - lastClickMs <= kDoubleClickMs
            lastClickIndex = hit
            lastClickMs = now
            if isDouble {
                lastClickIndex = nil
                activate(hit)
            } else {
                selection = hit
                Wallpaper.log("selected \(entries[hit].name)")
            }
        } else {
            lastClickIndex = nil
            selection = nil          // a click on bare desktop deselects
        }
        layer?.setNeedsDisplay()
    }

    private func configChanged() {
        _ = watcher?.drain()   // clear the pending events
        let config = (try? Pool.load("desktop")) ?? Config()
        let newStyle = DesktopStyle.from(config)
        guard newStyle != style else { return }
        style = newStyle
        Wallpaper.log("applied \(style.kind)")
        layer?.setNeedsDisplay()
    }

    private static func scaleConfig() -> (scale: Int32, auto: Bool) {
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 {
            return (v, false)
        }
        return (1, true)
    }

    private static func log(_ msg: String) {
        let line = "Wallpaper: \(msg)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    public func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale)
        let h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(
            buffer.data.assumingMemoryBound(to: UInt8.self),
            CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else {
            cairo_surface_destroy(cs)
            return
        }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        paintDesktop(cr, w: w, h: h, style: style)
        if showIcons {
            paintDesktopIcons(cr, bounds: iconBounds(w: w, h: h), entries: entries,
                              selection: selection)
        }
        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }
}
