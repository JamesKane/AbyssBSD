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
        // The one rasteriser (AquaDraw's Cursor.rasterise): the XCursor theme
        // a toolkit loads (U.7b) is these same pixels.
        guard let im = Cursor.rasterise(name, scale: scale) else { return nil }
        // DRM_FORMAT_ARGB8888: cairo's premultiplied ARGB32, as the frames are.
        let tex = im.pixels.withUnsafeBytes { p in
            wlr_texture_from_pixels(renderer, UInt32(0x34325241), UInt32(im.size * 4),
                                    UInt32(im.size), UInt32(im.size), p.baseAddress)
        }
        guard let tex else { return nil }
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
