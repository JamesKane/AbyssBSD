// Wallpaper — the desktop backdrop: the shell's BACKGROUND wlr-layer-shell
// client. It reads its look from `desktop.ini` via PoolConfig and hot-reloads
// when that file changes (the `reef-desktop` analog, in Aqua dress).
//
// Config (domain `desktop`), highest precedence first — matching the sibling:
//   image     = /path/to/wallpaper.png   (PNG; scaled to fill/cover)
//   grad_top, grad_bot = #aarrggbb        (vertical gradient)
//   bg        = #aarrggbb                 (flat fill)
//   (none)    -> the built-in Jaguar "Aqua Blue" gradient
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
    cairo_pattern_add_color_stop_rgba(g, 0.0, 0.36, 0.52, 0.75, 1)
    cairo_pattern_add_color_stop_rgba(g, 0.55, 0.20, 0.34, 0.58, 1)
    cairo_pattern_add_color_stop_rgba(g, 1.0, 0.11, 0.21, 0.42, 1)
    cairo_set_source(cr, g)
    cairo_paint(cr)
    cairo_pattern_destroy(g)

    let cx = w * 0.42, cy = h * 0.30
    let radius = max(w, h) * 0.75
    let glow = cairo_pattern_create_radial(cx, cy, 0, cx, cy, radius)
    cairo_pattern_add_color_stop_rgba(glow, 0.0, 0.68, 0.80, 0.96, 0.55)
    cairo_pattern_add_color_stop_rgba(glow, 1.0, 0.68, 0.80, 0.96, 0.0)
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

public final class Wallpaper: LayerSurfaceDelegate {
    private var layer: LayerSurface?
    private var style: DesktopStyle
    private var watcher: Pool.Watcher?

    /// Create and map the desktop. Returns nil if the compositor lacks
    /// wlr-layer-shell. Reads `desktop.ini` now and watches for changes.
    public init?(display: Display) {
        let config = (try? Pool.load("desktop")) ?? Config()
        style = DesktopStyle.from(config)
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
        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }
}
