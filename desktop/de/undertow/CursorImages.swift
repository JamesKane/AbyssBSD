// CursorImages — the theme's cursors, as textures (BACKLOG U.7).
//
// A cursor is a draw list (AquaDraw's `Cursor`); here it becomes pixels, once
// per shape, per display scale, per theme — the same caching policy as the
// window frames (Decorations): nothing is rasterised on the frame path unless
// the shape, the scale or the theme has just changed. A scale-2 display gets a
// cursor drawn at scale 2, not a 1x one stretched.

import AquaDraw
import CCairo
import CWlroots

final class CursorTexture {
    let texture: UnsafeMutablePointer<wlr_texture>
    /// Where the pointer's position is in the picture, in points.
    let hotX: Double, hotY: Double
    let themeGeneration = Theme.generation

    init?(renderer: UnsafeMutablePointer<wlr_renderer>, name: String, scale: Double) {
        let px = Int32((Cursor.size * scale).rounded(.up))
        guard px > 0, let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, px, px),
              let cr = cairo_create(surface) else { return nil }
        defer { cairo_destroy(cr); cairo_surface_destroy(surface) }
        cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
        cairo_set_source_rgba(cr, 0, 0, 0, 0)
        cairo_paint(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        cairo_scale(cr, scale, scale)
        let was = Text.renderScale
        Text.renderScale = Int32(scale.rounded(.up))
        defer { Text.renderScale = was }
        Cursor.draw(name, cr, x: 0, y: 0)
        cairo_surface_flush(surface)
        guard let data = cairo_image_surface_get_data(surface) else { return nil }
        // DRM_FORMAT_ARGB8888: cairo's premultiplied ARGB32, as the frames are.
        guard let tex = wlr_texture_from_pixels(renderer, UInt32(0x34325241),
                                                UInt32(cairo_image_surface_get_stride(surface)),
                                                UInt32(px), UInt32(px), data) else { return nil }
        texture = tex
        (hotX, hotY) = Cursor.hotspot(name)
    }

    deinit { wlr_texture_destroy(texture) }
}

public final class CursorImages {
    private var cache: [String: CursorTexture] = [:]
    /// How many cursors have been drawn — once per shape and scale, which a
    /// test can hold undertow to.
    public private(set) var rasterisations = 0

    /// The shape `name` (after the theme's fallbacks) at `scale`.
    func image(_ name: String, scale: Double, renderer: UnsafeMutablePointer<wlr_renderer>) -> CursorTexture? {
        let shape = Cursor.resolve(name)
        let key = "\(shape)@\(scale)"
        if let have = cache[key], have.themeGeneration == Theme.generation { return have }
        guard let fresh = CursorTexture(renderer: renderer, name: shape, scale: scale) else { return nil }
        cache[key] = fresh
        rasterisations += 1
        return fresh
    }

    func release() { cache.removeAll() }
}
