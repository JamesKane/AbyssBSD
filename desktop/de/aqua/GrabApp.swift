// Grab — pictures of the screen (PHASE15 P15.6).
//
// Jaguar's Grab: Capture ▸ Selection (drag a rectangle), Window (click the
// window you want), Screen, and Timed Screen; each picture opens in a window
// of its own, to be saved through the portal (a PNG, through the Finder's save
// picker) or copied. Over the screencopy `abyssgrab` already does: the picture
// is the output's pixels, cropped.
//
// **The overlay is never in the picture.** Selection and Window draw on a
// layer surface over the whole output; it is closed, and the compositor told,
// before the screen is copied. **The pointer is in it where the compositor
// draws it in software** — the build VM, with no cursor plane: wlroots'
// screencopy can leave out only a hardware cursor, which on metal it does.
// Jaguar's Grab left the pointer out unless asked; doing that everywhere needs
// undertow to render a copy without its cursor, which is not done yet.
//
// **Window mode asks the compositor which window is under the pointer**
// (`abyss_window_manager_v1.window_at`, P15.6): foreign-toplevel names windows
// but does not place them. The box includes the frame undertow draws, so a
// window is taken whole, title bar and all.
//
// Known limits, said rather than hidden: one output (the first, at the
// layout's origin); Grab's own windows are in a Screen capture, as anything
// on screen is (Timed Screen is how to keep them out of the way).
//
// What a test reads (ABYSS_GRAB_DUMP=1): where the main window's buttons are,
// what was captured, and what was saved.

import Surface
import CCairo
import AquaDraw
import MenuModel
import MenuWire
import CurrentIPC
import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - The vocabulary

public enum GrabVerb {
    public static let about = "app.about", quit = "app.quit"
    public static let close = "file.close", save = "file.save", copy = "edit.copy"
    public static let selection = "capture.selection", window = "capture.window"
    public static let screen = "capture.screen", timed = "capture.timed"
    public static let minimize = "window.minimize"
}

public func grabMenuBar() -> MenuBarModel {
    func c(_ verb: String, _ title: String, _ key: KeyEquivalent? = nil, _ summary: String) -> MenuItem {
        .command(Command(verb, title, key: key, summary: summary))
    }
    return MenuBarModel(appName: "Grab", menus: [
        Menu("Grab", [
            c(GrabVerb.about, "About Grab", nil, "Show Grab's version."),
            .separator,
            c(GrabVerb.quit, "Quit Grab", .cmd("q"), "Close Grab."),
        ]),
        Menu("File", [
            c(GrabVerb.close, "Close", .cmd("w"), "Close this picture."),
            c(GrabVerb.save, "Save…", .cmd("s"), "Save this picture as a PNG."),
        ]),
        Menu("Edit", [
            c(GrabVerb.copy, "Copy", .cmd("c"), "Copy this picture."),
        ]),
        Menu("Capture", [
            c(GrabVerb.selection, "Selection", .cmd("a", .shift), "Drag a rectangle to capture."),
            c(GrabVerb.window, "Window", .cmd("w", .shift), "Click a window to capture it."),
            c(GrabVerb.screen, "Screen", .cmd("z"), "Capture the whole screen."),
            c(GrabVerb.timed, "Timed Screen", .cmd("z", .shift), "Capture the screen in ten seconds."),
        ]),
        Menu("Window", [
            c(GrabVerb.minimize, "Minimize", .cmd("m"), "Put the window in the Dock."),
        ]),
    ])
}

// MARK: - Pictures

/// A picture: pixels as the screen gave them (B, G, R, X), four bytes each.
public struct GrabImage: Equatable, Sendable {
    public let width: Int, height: Int
    public let pixels: [UInt8]
    public var stride: Int { width * 4 }
    public init(width: Int, height: Int, pixels: [UInt8]) { self.width = width; self.height = height; self.pixels = pixels }

    /// The part of `capture` inside (x, y, w, h), in its pixels, clamped to it;
    /// nil when nothing of the rectangle is on it.
    public static func crop(_ capture: ScreenCapture, x: Int, y: Int, w: Int, h: Int) -> GrabImage? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(capture.width, x + w), y1 = min(capture.height, y + h)
        guard x1 > x0, y1 > y0 else { return nil }
        var out = [UInt8](); out.reserveCapacity((x1 - x0) * (y1 - y0) * 4)
        for row in y0..<y1 {
            let s = row * capture.stride + x0 * 4
            out.append(contentsOf: capture.pixels[s..<(s + (x1 - x0) * 4)])
        }
        return GrabImage(width: x1 - x0, height: y1 - y0, pixels: out)
    }

    /// The picture as PNG bytes (opaque RGB).
    public func png() -> [UInt8]? {
        var copy = pixels
        final class Sink { var bytes: [UInt8] = [] }
        let sink = Sink()
        let ok = copy.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let s = cairo_image_surface_create_for_data(buf.baseAddress, CAIRO_FORMAT_RGB24,
                                                             Int32(width), Int32(height), Int32(stride)),
                  cairo_surface_status(s) == CAIRO_STATUS_SUCCESS else { return false }
            defer { cairo_surface_destroy(s) }
            cairo_surface_mark_dirty(s)
            let st = cairo_surface_write_to_png_stream(s, { closure, data, length in
                guard let closure, let data else { return CAIRO_STATUS_WRITE_ERROR }
                let sink = Unmanaged<Sink>.fromOpaque(closure).takeUnretainedValue()
                sink.bytes.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(length)))
                return CAIRO_STATUS_SUCCESS
            }, Unmanaged.passUnretained(sink).toOpaque())
            return st == CAIRO_STATUS_SUCCESS
        }
        return ok ? sink.bytes : nil
    }
}

// MARK: - The overlay

/// Selection or Window, on a layer surface over the whole output.
final class GrabOverlay: LayerSurfaceDelegate {
    enum Mode { case selection, window }
    let mode: Mode
    private var layer: LayerSurface?
    private let display: Display
    private var start: (Double, Double)?
    private var current: (Double, Double) = (0, 0)
    private var hovered: Display.WindowAt?
    private var lastQuery: (Int32, Int32)?
    /// The rectangle chosen, in the overlay's (the output's logical) points,
    /// and the window it was, in Window mode; nil if cancelled.
    var onDone: ((x: Double, y: Double, w: Double, h: Double)?, Display.WindowAt?) -> Void = { _, _ in }

    init?(display: Display, mode: Mode) {
        self.display = display; self.mode = mode
        guard let l = LayerSurface(display: display, layer: .overlay, namespace: "abyss.grab",
                                   width: 0, height: 0, anchor: .all, exclusiveZone: -1,
                                   keyboard: .exclusive, delegate: self) else { return nil }
        layer = l
    }

    var size: (width: Int32, height: Int32) { layer?.size ?? (0, 0) }

    func close() { layer?.close(); layer = nil }

    func render(_ buffer: PixelBuffer) {
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr); cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        _ = (w, h)
        func outline(_ x: Double, _ y: Double, _ rw: Double, _ rh: Double, fill: Bool) {
            if fill { Draw.setColor(cr, Color(0.22, 0.46, 0.84, 0.25)); cairo_rectangle(cr, x, y, rw, rh); cairo_fill(cr) }
            cairo_set_line_width(cr, 1)
            Draw.setColor(cr, Color(0, 0, 0, 0.8)); cairo_rectangle(cr, x + 0.5, y + 0.5, max(0, rw - 1), max(0, rh - 1)); cairo_stroke(cr)
            Draw.setColor(cr, Color(1, 1, 1, 0.9)); cairo_rectangle(cr, x + 1.5, y + 1.5, max(0, rw - 3), max(0, rh - 3)); cairo_stroke(cr)
        }
        switch mode {
        case .selection:
            if let s = start {
                let r = GrabOverlay.rect(s, current)
                outline(r.x, r.y, r.w, r.h, fill: false)
                Draw.textLeft(cr, "\(Int(r.w)) × \(Int(r.h))", x: r.x + 4, baselineY: r.y + r.h + 16,
                              color: Color(1, 1, 1), size: 11)
            }
        case .window:
            if let wnd = hovered {
                outline(Double(wnd.x), Double(wnd.y), Double(wnd.width), Double(wnd.height), fill: true)
            }
        }
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
    }

    static func rect(_ a: (Double, Double), _ b: (Double, Double)) -> (x: Double, y: Double, w: Double, h: Double) {
        (min(a.0, b.0), min(a.1, b.1), abs(a.0 - b.0), abs(a.1 - b.1))
    }

    func pointerMoved(x: Double, y: Double) {
        current = (x, y)
        if mode == .window {
            let p = (Int32(x), Int32(y))
            if lastQuery.map({ $0 != p }) ?? true {
                lastQuery = p
                hovered = display.windowAt(x: p.0, y: p.1)
            }
        }
        layer?.setNeedsDisplay()
    }

    func pointerButton(_ button: UInt32, pressed: Bool) {
        guard button == 0x110 else { return }
        switch mode {
        case .selection:
            if pressed { start = current; layer?.setNeedsDisplay(); return }
            guard let s = start else { return }
            let r = GrabOverlay.rect(s, current)
            guard r.w >= 1, r.h >= 1 else { start = nil; return }
            onDone(r, nil)
        case .window:
            guard pressed else { return }
            hovered = display.windowAt(x: Int32(current.0), y: Int32(current.1))
            guard let wnd = hovered else { return }
            onDone((Double(wnd.x), Double(wnd.y), Double(wnd.width), Double(wnd.height)), wnd)
        }
    }

    func pointerLeft() {}

    func keyEvent(_ event: KeyEvent) {
        if event.pressed && event.keysym == KeySym.escape { onDone(nil, nil) }
    }
}

// MARK: - A picture's window

final class GrabDocument: WindowDelegate {
    private(set) var window: Window?
    private weak var app: GrabApp?
    let image: GrabImage
    private(set) var path: String?
    private var pointerX = 0.0, pointerY = 0.0
    private var shown = ""

    init?(display: Display, app: GrabApp, image: GrabImage) {
        self.app = app; self.image = image
        // As big as the picture, up to most of a screen; the picture scales down.
        let w = Int32(min(800, max(240, image.width))), h = Int32(Theme.titleBarHeight) + Int32(min(600, max(120, image.height)))
        let scale: Int32, auto: Bool
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 { (scale, auto) = (v, false) }
        else { (scale, auto) = (1, true) }
        guard let win = Window(display: display, title: "", appID: "org.abyssbsd.grab",
                               width: w, height: h + Int32(windowResizeBand), scale: scale, autoScale: auto,
                               delegate: self) else { return nil }
        window = win
        updateTitle()
    }

    func updateTitle() {
        let name = path.map { String($0.split(separator: "/").last ?? "") } ?? "Untitled"
        let t = "\(name) — \(image.width) × \(image.height)"
        guard t != shown else { return }
        shown = t
        window?.setTitle(t)
    }

    func saved(_ p: String) { path = p; updateTitle() }

    func close() {
        window?.close(); window = nil
        app?.documentClosed(self)
    }

    func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr); cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        paintGrabDocument(cr, w: w, h: h, title: shown, image: image)
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
    }

    func pointerMoved(x: Double, y: Double) { pointerX = x; pointerY = y }

    func pointerButton(_ button: UInt32, pressed: Bool) {
        guard pressed, let w = window else { return }
        let size = w.size
        switch windowChromeHit(x: pointerX, y: pointerY, w: Double(size.width), h: Double(size.height)) {
        case .close: close()
        case .minimize: _ = w.minimize()
        case .zoom: w.setMaximized(!w.isMaximized)
        case .depth: _ = w.lower()
        case .title: w.beginMove()
        case .resize(let e): w.beginResize(e)
        case .pill, .content: break
        }
    }

    func keyEvent(_ event: KeyEvent) { app?.key(event, in: self) }
    func windowShouldClose(_ window: Window) { close() }
}

/// A picture in a window: grey around it, scaled down to fit and never up.
public func paintGrabDocument(_ cr: OpaquePointer, w: Double, h: Double, title: String, image: GrabImage) {
    paintWindowChrome(cr, w: w, h: h, title: title)
    let area = Rect(0, Theme.titleBarHeight, w, max(0, h - Theme.titleBarHeight - windowResizeBand))
    Draw.setColor(cr, Color(hex: 0x9A9A9A)); cairo_rectangle(cr, area.x, area.y, area.w, area.h); cairo_fill(cr)
    guard image.width > 0, image.height > 0 else { return }
    let k = min(1, min(area.w / Double(image.width), area.h / Double(image.height)))
    let dw = Double(image.width) * k, dh = Double(image.height) * k
    var copy = image.pixels
    copy.withUnsafeMutableBufferPointer { buf in
        guard let s = cairo_image_surface_create_for_data(buf.baseAddress, CAIRO_FORMAT_RGB24,
                                                         Int32(image.width), Int32(image.height), Int32(image.stride)) else { return }
        defer { cairo_surface_destroy(s) }
        cairo_save(cr)
        cairo_translate(cr, area.x + (area.w - dw) / 2, area.y + (area.h - dh) / 2)
        cairo_scale(cr, k, k)
        cairo_set_source_surface(cr, s, 0, 0)
        cairo_paint(cr)
        cairo_restore(cr)
    }
}

// MARK: - The main window

/// Grab's own small window: the four captures as buttons, and where the
/// menus live while there is no picture yet.
public struct GrabPanelLayout: Equatable, Sendable {
    public let selection: Rect, window: Rect, screen: Rect, timed: Rect
    /// Along the bottom, whatever the window's height.
    public init(w: Double, h: Double) {
        let top = h - 38, bw = (w - 50) / 4
        selection = Rect(10, top, bw, 26)
        window = Rect(20 + bw, top, bw, 26)
        screen = Rect(30 + 2 * bw, top, bw, 26)
        timed = Rect(40 + 3 * bw, top, bw, 26)
    }
}

public func paintGrabPanel(_ cr: OpaquePointer, w: Double, h: Double, status: String) -> GrabPanelLayout {
    paintWindowChrome(cr, w: w, h: h, title: "Grab")
    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, 0, Theme.titleBarHeight, w, h - Theme.titleBarHeight); cairo_fill(cr)
    Draw.textLeft(cr, status, x: 12, baselineY: Theme.titleBarHeight + 24, color: Theme.bodyText, size: Theme.fontSize)
    let l = GrabPanelLayout(w: w, h: h)
    Draw.gelButton(cr, l.selection, label: "Selection", blue: false, pressed: false)
    Draw.gelButton(cr, l.window, label: "Window", blue: false, pressed: false)
    Draw.gelButton(cr, l.screen, label: "Screen", blue: false, pressed: false)
    Draw.gelButton(cr, l.timed, label: "Timed", blue: false, pressed: false)
    return l
}

final class GrabPanel: WindowDelegate {
    private(set) var window: Window?
    private weak var app: GrabApp?
    private var pointerX = 0.0, pointerY = 0.0
    var status = "Choose what to capture." { didSet { window?.setNeedsDisplay() } }
    private var logged = false

    init?(display: Display, app: GrabApp) {
        self.app = app
        let scale: Int32, auto: Bool
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 { (scale, auto) = (v, false) }
        else { (scale, auto) = (1, true) }
        guard let win = Window(display: display, title: "Grab", appID: "org.abyssbsd.grab",
                               width: 420, height: 120, scale: scale, autoScale: auto, delegate: self) else { return nil }
        window = win
    }

    func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr); cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        let l = paintGrabPanel(cr, w: w, h: h, status: status)
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
        if GrabApp.dump, !logged {
            logged = true
            func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
            GrabApp.log("panel selection=\(c(l.selection)) window=\(c(l.window)) screen=\(c(l.screen)) timed=\(c(l.timed))")
        }
    }

    func pointerMoved(x: Double, y: Double) { pointerX = x; pointerY = y }

    func pointerButton(_ button: UInt32, pressed: Bool) {
        guard pressed, let w = window else { return }
        let size = w.size
        switch windowChromeHit(x: pointerX, y: pointerY, w: Double(size.width), h: Double(size.height)) {
        case .close: _ = app?.perform(GrabVerb.quit, from: nil); return
        case .minimize: _ = w.minimize(); return
        case .depth: _ = w.lower(); return
        case .title: w.beginMove(); return
        case .zoom, .pill, .content, .resize: break
        }
        let l = GrabPanelLayout(w: Double(size.width), h: Double(size.height))
        if l.selection.contains(pointerX, pointerY) { _ = app?.perform(GrabVerb.selection, from: nil) }
        else if l.window.contains(pointerX, pointerY) { _ = app?.perform(GrabVerb.window, from: nil) }
        else if l.screen.contains(pointerX, pointerY) { _ = app?.perform(GrabVerb.screen, from: nil) }
        else if l.timed.contains(pointerX, pointerY) { _ = app?.perform(GrabVerb.timed, from: nil) }
    }

    func keyEvent(_ event: KeyEvent) { app?.key(event, in: nil) }
    func windowShouldClose(_ window: Window) { _ = app?.perform(GrabVerb.quit, from: nil) }
}

// MARK: - The application

public final class GrabApp: MenuProvider {
    private let display: Display
    private var panel: GrabPanel?
    private var documents: [GrabDocument] = []
    private var overlay: GrabOverlay?
    private var menuService: MenuService?
    private var menuName = ""
    private var countdown: (fd: Int32, left: Int)?
    public var onQuit: () -> Void = { exit(0) }

    public static let menuBar = grabMenuBar()
    static let dump = getenv("ABYSS_GRAB_DUMP") != nil
    /// Timed Screen's wait, in seconds (ten, as Grab's; a test may shorten it).
    static let timerSeconds = getenv("ABYSS_GRAB_TIMER").flatMap { Int(String(cString: $0)) } ?? 10

    public init?(display: Display) {
        self.display = display
        menuName = MenuWire.serviceName(app: "Grab", pid: getpid())
        if let service = try? MenuService(name: menuName, provider: self) {
            display.addFileDescriptor(service.fd) { [weak service] in service?.serviceReadable() }
            menuService = service
        }
        guard let p = GrabPanel(display: display, app: self) else { return nil }
        panel = p
        if let w = p.window {
            display.window = w
            if !menuName.isEmpty, w.publishMenus(at: menuName) { GrabApp.log("menus on \(menuName)") }
        }
    }

    static func log(_ s: String) { ("Grab: " + s + "\n").withCString { _ = write(2, $0, strlen($0)) } }

    func key(_ event: KeyEvent, in doc: GrabDocument?) {
        guard event.pressed, event.modifiers.contains(.command),
              let press = keyEquivalent(event), let verb = GrabApp.menuBar.verb(for: press) else { return }
        if case .refused(let why) = perform(verb, from: doc) { GrabApp.log("\(verb) refused: \(why)") }
    }

    func documentClosed(_ d: GrabDocument) {
        documents.removeAll { $0 === d }
        if let w = documents.last?.window ?? panel?.window { display.window = w }
    }

    private var front: GrabDocument? { documents.first { $0.window?.isActivated ?? false } ?? documents.last }

    // MARK: capturing

    private func startOverlay(_ mode: GrabOverlay.Mode) -> CommandResult {
        guard overlay == nil else { return .refused("a capture is already under way") }
        guard display.canCaptureScreen else { return .refused("this compositor does not offer screencopy") }
        guard let o = GrabOverlay(display: display, mode: mode) else { return .refused("no overlay could be made") }
        overlay = o
        panel?.status = mode == .selection ? "Drag across what you want. Escape cancels."
                                           : "Click the window you want. Escape cancels."
        GrabApp.log("capturing a \(mode == .selection ? "selection" : "window")")
        o.onDone = { [weak self, weak o] rect, wnd in
            guard let self, let o else { return }
            let overlaySize = o.size
            o.close()
            self.overlay = nil
            guard let rect else {
                self.panel?.status = "Cancelled."
                GrabApp.log("capture cancelled")
                return
            }
            self.capture(rect: rect, overlayWidth: Double(overlaySize.width), window: wnd)
        }
        return .ok("")
    }

    /// Copy the screen and keep `rect` of it (all of it when nil). The overlay
    /// is already closed; a round trip lets the compositor draw a frame
    /// without it before the copy is taken.
    private func capture(rect: (x: Double, y: Double, w: Double, h: Double)?, overlayWidth: Double = 0,
                         window wnd: Display.WindowAt? = nil) {
        display.roundtrip(); display.roundtrip()
        usleep(50_000)
        let shot: ScreenCapture
        do { shot = try display.captureOutput(0) } catch {
            panel?.status = "Could not capture the screen."
            GrabApp.log("capture failed: \(error)")
            return
        }
        let image: GrabImage?
        if let r = rect {
            // Points to pixels: the output may be scaled.
            let k = overlayWidth > 0 ? Double(shot.width) / overlayWidth : 1
            let x = Int((r.x * k).rounded()), y = Int((r.y * k).rounded())
            let w = Int((r.w * k).rounded()), h = Int((r.h * k).rounded())
            image = GrabImage.crop(shot, x: x, y: y, w: w, h: h)
            if let wnd { GrabApp.log("captured window \(wnd.appID) \(x),\(y) \(w)x\(h)") }
            else { GrabApp.log("captured selection \(x),\(y) \(w)x\(h)") }
        } else {
            image = GrabImage(width: shot.width, height: shot.height, pixels: shot.pixels)
            GrabApp.log("captured screen \(shot.width)x\(shot.height)")
        }
        guard let image else { panel?.status = "Nothing was captured."; return }
        guard let d = GrabDocument(display: display, app: self, image: image) else { return }
        documents.append(d)
        if let w = d.window {
            display.window = w
            if !menuName.isEmpty { _ = w.publishMenus(at: menuName) }
        }
        panel?.status = "Captured \(image.width) × \(image.height)."
    }

    private func startCountdown() -> CommandResult {
        guard countdown == nil else { return .refused("a timed capture is already counting") }
        let fd = aw_create_interval_timer(1000)
        guard fd >= 0 else { return .refused("no timer") }
        countdown = (fd, GrabApp.timerSeconds)
        panel?.status = "Capturing the screen in \(GrabApp.timerSeconds) seconds…"
        GrabApp.log("timed capture in \(GrabApp.timerSeconds) s")
        display.addFileDescriptor(fd) { [weak self] in self?.tick() }
        return .ok("")
    }

    private func tick() {
        guard let (fd, left) = countdown else { return }
        var n: UInt64 = 0
        _ = withUnsafeMutablePointer(to: &n) { read(fd, $0, MemoryLayout<UInt64>.size) }
        if left > 1 {
            countdown = (fd, left - 1)
            panel?.status = "Capturing the screen in \(left - 1) seconds…"
            return
        }
        display.removeFileDescriptor(fd); close(fd)
        countdown = nil
        capture(rect: nil)
    }

    // MARK: verbs

    func perform(_ verb: String, from doc: GrabDocument?) -> CommandResult {
        let d = doc ?? front
        switch verb {
        case GrabVerb.quit: onQuit(); return .ok("")
        case GrabVerb.selection: return startOverlay(.selection)
        case GrabVerb.window: return startOverlay(.window)
        case GrabVerb.screen: capture(rect: nil); return .ok("")
        case GrabVerb.timed: return startCountdown()
        case GrabVerb.close:
            guard let d else { return .refused("no picture") }
            d.close(); return .ok("")
        case GrabVerb.copy:
            guard let d, let png = d.image.png() else { return .refused("no picture") }
            guard display.clipboard?.write(png, types: ["image/png"]) == true else { return .refused("the clipboard would not take it") }
            GrabApp.log("copied \(d.image.width)x\(d.image.height) as image/png")
            return .ok("")
        case GrabVerb.save:
            guard let d else { return .refused("no picture") }
            var m = Msg(); m.set("method", "file.save"); m.set("name", "Untitled.png")
            PortalQuestion.ask(m, display: display) { [weak d] reply in
                guard let d else { return }
                guard var reply, reply.bool("ok") == true, let fd = reply.takeFD("file"),
                      let path = reply.string("path") else {
                    GrabApp.log("save: \(reply?.string("error") ?? "the portal did not answer")"); return
                }
                guard let png = d.image.png() else { close(fd); GrabApp.log("save: the picture would not encode"); return }
                if let why = TextFile.save(png, fd: fd) { GrabApp.log("could not save \(path): \(why)"); return }
                d.saved(path)
                GrabApp.log("saved \(path) (\(d.image.width)x\(d.image.height))")
            }
            return .ok("asked the portal")
        case GrabVerb.minimize:
            _ = (d?.window ?? panel?.window)?.minimize(); return .ok("")
        default: return .refused("Grab has no verb \(verb)")
        }
    }

    // MARK: MenuProvider

    public var menuModel: MenuBarModel { GrabApp.menuBar }

    public func menuValidate(_ command: Command) -> Enablement {
        switch command.verb {
        case GrabVerb.about: return .disabled("Grab has no About box yet")
        case GrabVerb.close, GrabVerb.save, GrabVerb.copy: return documents.isEmpty ? .disabled("no picture") : .enabled
        default: return .enabled
        }
    }

    public func menuPerform(_ command: Command, arguments: [String: String]) -> CommandResult {
        if case .disabled(let why) = menuValidate(command) { return .refused(why) }
        return perform(command.verb, from: front)
    }
}
