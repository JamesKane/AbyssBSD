// Undertow — server-side decorations (PHASE9.md P9.6, and §6.1's decision).
//
// A GTK application draws its own headerbar, and on this desktop that looks
// broken in a way no missing feature does. `xdg-decoration-unstable-v1` is how
// a client asks who draws the frame, and **we always answer: we do.** A desktop
// with two window styles has failed at the one thing this project is for.
//
// **The frame is rasterised once per size, never on the frame path.** Cairo is
// in the compositor process now — that is what §6.1 decided, and the reason is
// that the alternative (a rect-and-gradient renderer inside undertow) cannot
// draw a gel traffic light, so it fails the only test that matters. The cost is
// bounded by making it a cache: a window that is not being resized rasterises
// its frame exactly once, and the present path samples a texture like any
// other. A window being dragged by its corner rasterises per size — which is
// the case to watch, and the reason the C1 bench is the check on this rather
// than a claim in a comment.

import AquaDraw
import CCairo
import CWlroots

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// How much room the frame takes around a client's surface.
///
/// Pure, and separate from the drawing, because *everything* has to agree with
/// it: placement, the hit-test, the move grab, the snap rectangle. A frame whose
/// geometry the input path computes differently from the paint path is a title
/// bar you can see and cannot click.
public enum FrameMetrics {
    /// The Aqua title bar, from the toolkit's own theme — so the frame the
    /// compositor draws and the one an Aqua window draws for itself are the
    /// same height, and Phase 11 re-skins both from one place.
    public static var titleHeight: Double { Theme.titleBarHeight }
    /// The border on the other three sides (`chrome.border`, one pixel for
    /// 10.2's hard edge; the shadow is Phase 13's, with the alpha it needs).
    public static var border: Double { Theme.current.chromeBorder }

    /// The frame's rectangle, given where the client's surface sits.
    public static func frame(forSurfaceAt x: Int32, _ y: Int32,
                             width: Int32, height: Int32) -> (x: Int32, y: Int32,
                                                              w: Int32, h: Int32) {
        let t = Int32(titleHeight), b = Int32(border)
        return (x - b, y - t, width + 2 * b, height + t + b)
    }

    /// Where a client's surface sits, given where its frame goes. The inverse,
    /// and the direction placement needs: the compositor decides the frame's
    /// position and the surface follows it.
    public static func surface(forFrameAt x: Int32, _ y: Int32) -> (x: Int32, y: Int32) {
        (x + Int32(border), y + Int32(titleHeight))
    }
}

/// A rasterised frame, kept until its size or its state changes.
private final class FrameTexture {
    let texture: UnsafeMutablePointer<wlr_texture>
    let width: Int32
    let height: Int32
    let active: Bool
    let title: String
    /// `Theme.generation` when it was drawn.
    let themeGeneration = Theme.generation

    init?(renderer: UnsafeMutablePointer<wlr_renderer>, width: Int32, height: Int32,
          active: Bool, title: String) {
        guard width > 0, height > 0 else { return nil }
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height),
              let cr = cairo_create(surface) else { return nil }
        defer { cairo_destroy(cr); cairo_surface_destroy(surface) }

        // Transparent to start: the frame is drawn over whatever is behind it,
        // and the client's own pixels land inside the hole it leaves.
        cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
        cairo_set_source_rgba(cr, 0, 0, 0, 0)
        cairo_paint(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)

        // The toolkit's own chrome, at the frame's size. `paintWindowChrome`
        // fills the body too; the client's texture is composited over that, so
        // what shows is the title bar, the border and — for the one frame
        // between a resize and the client catching up — a Jaguar-grey body
        // rather than a hole.
        paintWindowChrome(cr, w: Double(width), h: Double(height), title: title, foreign: true)
        if !active {
            // Inactive windows are lighter on 10.2: one wash over the finished
            // frame (chrome.dl's window.inactive).
            Draw.paint("window.inactive", cr, AquaDraw.Rect(0, 0, Double(width), Double(height)))
        }
        cairo_surface_flush(surface)

        guard let data = cairo_image_surface_get_data(surface) else { return nil }
        let stride = cairo_image_surface_get_stride(surface)
        // DRM_FORMAT_ARGB8888 — cairo's ARGB32 is premultiplied BGRA in memory
        // on a little-endian machine, which is exactly what this format means.
        guard let tex = wlr_texture_from_pixels(renderer, UInt32(0x34325241),
                                                UInt32(stride), UInt32(width),
                                                UInt32(height), data) else { return nil }
        self.texture = tex
        self.width = width
        self.height = height
        self.active = active
        self.title = title
    }

    deinit { wlr_texture_destroy(texture) }
}

/// The decoration manager: who draws the frames, and the frames themselves.
public final class Decorations {
    private var manager: UnsafeMutablePointer<wlr_xdg_decoration_manager_v1>?
    private var newDecorationListener: UnsafeMutablePointer<tw_listener>?
    private unowned let compositor: Compositor
    /// One cached texture per window, rebuilt when its size, title or focus
    /// changes — which is the whole of the caching policy, and why a static
    /// desktop rasterises nothing at all.
    private var frames: [ObjectIdentifier: FrameTexture] = [:]
    /// How many rasterisations have happened. The number §6.1 wanted measured
    /// rather than asserted: if this climbs while nothing is being resized, the
    /// cache is not working and the comment above is a lie.
    public private(set) var rasterisations = 0

    public init(compositor: Compositor, session: WlrootsSession) {
        self.compositor = compositor
        guard let m = wlr_xdg_decoration_manager_v1_create(session.display) else { return }
        manager = m
        let me = Unmanaged.passUnretained(self).toOpaque()
        newDecorationListener = tw_listen(&m.pointee.events.new_toplevel_decoration,
                                          { ctx, data in
            guard let ctx, let data else { return }
            let d = Unmanaged<Decorations>.fromOpaque(ctx).takeUnretainedValue()
            let dec = data.assumingMemoryBound(to: wlr_xdg_toplevel_decoration_v1.self)
            d.take(dec)
        }, me)
    }

    /// Answer a client that asked who decorates: we do, always — but **not
    /// yet**.
    ///
    /// `set_mode` schedules a configure, and scheduling one on an xdg_surface
    /// that has not had its first commit is an assertion failure inside
    /// wlroots, not an error return:
    ///
    ///     wlr_xdg_surface_schedule_configure: Assertion `surface->initialized`
    ///
    /// A client that asks for decorations *before* its initial commit — which
    /// is the ordinary order, since it is setting the window up — takes the
    /// compositor down with it. So the request is recorded here and answered
    /// from the commit handler, with the initial configure it belongs in.
    private func take(_ dec: UnsafeMutablePointer<wlr_xdg_toplevel_decoration_v1>) {
        let surface = dec.pointee.toplevel.pointee.base.pointee.surface
        for t in compositor.toplevels where t.surface == surface {
            // Marking it on the Toplevel rather than keeping a second list means
            // the scene, the hit-test and the placement all read one flag.
            t.decoration = dec
            t.decorated = true
            if t.xdgToplevel.pointee.base.pointee.initialized { answer(t) }
        }
    }

    /// Tell a window we are drawing its frame. Safe to call more than once.
    func answer(_ t: Toplevel) {
        guard let dec = t.decoration else { return }
        _ = wlr_xdg_toplevel_decoration_v1_set_mode(
            dec, WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)
        t.decoration = nil
        compositor.reframe(t)
    }

    /// The frame texture for a window, rasterising only if something changed.
    func texture(for t: Toplevel, renderer: UnsafeMutablePointer<wlr_renderer>,
                 active: Bool) -> UnsafeMutablePointer<wlr_texture>? {
        let box = FrameMetrics.frame(forSurfaceAt: t.x, t.y,
                                     width: t.width, height: t.height)
        let title = t.title ?? ""
        let key = ObjectIdentifier(t)
        // …and the theme it was drawn in (P14.2): a frame from the old theme
        // matches nothing once the theme changes, so it is redrawn on the next
        // frame without anyone having to remember to invalidate it.
        if let have = frames[key], have.width == box.w, have.height == box.h,
           have.active == active, have.title == title,
           have.themeGeneration == Theme.generation {
            return have.texture
        }
        guard let fresh = FrameTexture(renderer: renderer, width: box.w, height: box.h,
                                       active: active, title: title) else { return nil }
        frames[key] = fresh
        rasterisations += 1
        return fresh.texture
    }

    /// Drop a window's frame when the window goes.
    func forget(_ t: Toplevel) { frames.removeValue(forKey: ObjectIdentifier(t)) }

    public func release() {
        frames.removeAll()
        if let l = newDecorationListener { tw_listener_free(l) }
        newDecorationListener = nil
    }
    deinit { release() }
}
