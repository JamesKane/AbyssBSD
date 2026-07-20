// Wallpaper — the desktop backdrop, and the first wlr-layer-shell client.
//
// It owns a Surface.LayerSurface in the BACKGROUND layer, anchored to all four
// edges with a -1 exclusive zone so it fills the output and sits beneath every
// other surface (menu bar, Dock, windows). Phase 2.1 paints the classic Jaguar
// blue gradient to prove the layer-shell path end to end; Phase 2.2 turns this
// into the real Desktop (pool-config colour/gradient/PNG, desktop icons).

import Surface
import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Paint the desktop backdrop into `w`×`h` logical pixels. Pure (no Wayland),
/// so it drives both the live layer surface and the offscreen PNG preview.
public func paintWallpaper(_ cr: OpaquePointer, w: Double, h: Double) {
    // Vertical Jaguar "Aqua Blue": a light sky top deepening to ocean blue.
    let g = cairo_pattern_create_linear(0, 0, 0, h)
    cairo_pattern_add_color_stop_rgba(g, 0.0, 0.36, 0.52, 0.75, 1)
    cairo_pattern_add_color_stop_rgba(g, 0.55, 0.20, 0.34, 0.58, 1)
    cairo_pattern_add_color_stop_rgba(g, 1.0, 0.11, 0.21, 0.42, 1)
    cairo_set_source(cr, g)
    cairo_paint(cr)
    cairo_pattern_destroy(g)

    // A broad, soft radial glow high and slightly left of centre — the sheen the
    // Jaguar default backdrop carries.
    let cx = w * 0.42, cy = h * 0.30
    let radius = max(w, h) * 0.75
    let glow = cairo_pattern_create_radial(cx, cy, 0, cx, cy, radius)
    cairo_pattern_add_color_stop_rgba(glow, 0.0, 0.68, 0.80, 0.96, 0.55)
    cairo_pattern_add_color_stop_rgba(glow, 1.0, 0.68, 0.80, 0.96, 0.0)
    cairo_set_source(cr, glow)
    cairo_paint(cr)
    cairo_pattern_destroy(glow)
}

public final class Wallpaper: LayerSurfaceDelegate {
    private var layer: LayerSurface?

    /// Create and map the wallpaper. Returns nil if the compositor lacks
    /// wlr-layer-shell (or shm/compositor). The caller owns this object — its
    /// LayerSurface's delegate and Display's back-reference are both weak.
    public init?(display: Display) {
        let (scale, auto) = Wallpaper.scaleConfig()
        guard let ls = LayerSurface(
            display: display, layer: .background, namespace: "abyss.wallpaper",
            width: 0, height: 0, anchor: .all, exclusiveZone: -1,
            keyboard: .none, scale: scale, autoScale: auto, delegate: self)
        else { return nil }
        layer = ls
    }

    private static func scaleConfig() -> (scale: Int32, auto: Bool) {
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 {
            return (v, false)
        }
        return (1, true)
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
        paintWallpaper(cr, w: w, h: h)
        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }
}
