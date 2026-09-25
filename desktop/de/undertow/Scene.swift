// Undertow — the scene the present path reads (PHASE6.md P6.3; DESKTOP.md §4).
//
// Structure-of-arrays, not a widget tree: parallel arrays of rects and texture
// handles, walked linearly, with no per-node allocation and nothing to chase.
// That shape is not an optimisation detail, it is the reason C2 is affordable —
// a snapshot is a memcpy of a few arrays rather than a traversal of somebody
// else's object graph.
//
// **Latch, don't ask.** `latchAndComposite` copies the current window list into
// the arrays and then works only from them. It never calls back into a client,
// never takes a lock a client holds, and never waits: everything it reads was
// already committed. That is C2 by construction, and the reason the whole
// pipeline can be driven from a scheduler that refuses to block.
//
// P6.3 latches from the compositor's window list directly, which is correct
// while there is one thread. When the reactor/present split lands (P6.5), the
// latch becomes a read of a triple-buffered snapshot the reactor publishes —
// the arrays here are already the right shape for that, which is the point of
// building them this way now.

import CWlroots

/// The compositor's scene: windows latched from the compositor, composited into
/// a wlroots render pass.
public final class SurfaceScene: FrameSink {
    public let capacity: Int
    public private(set) var count: Int = 0

    // The SoA proper. Preallocated once; the present path only ever writes
    // into these, never grows them.
    private let texture: UnsafeMutableBufferPointer<UnsafeMutablePointer<wlr_texture>?>
    private let x, y, w, h: UnsafeMutableBufferPointer<Int32>

    private unowned let compositor: Compositor
    private let outputWidth: Int32
    private let outputHeight: Int32

    public init(compositor: Compositor, outputWidth: Int32, outputHeight: Int32,
                capacity: Int = 256) {
        self.compositor = compositor
        self.capacity = capacity
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        let t = UnsafeMutablePointer<UnsafeMutablePointer<wlr_texture>?>.allocate(capacity: capacity)
        t.initialize(repeating: nil, count: capacity)
        texture = UnsafeMutableBufferPointer(start: t, count: capacity)
        func ints() -> UnsafeMutableBufferPointer<Int32> {
            let p = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
            p.initialize(repeating: 0, count: capacity)
            return UnsafeMutableBufferPointer(start: p, count: capacity)
        }
        x = ints(); y = ints(); w = ints(); h = ints()
    }

    public func release() {
        texture.baseAddress?.deinitialize(count: capacity)
        texture.baseAddress?.deallocate()
        for b in [x, y, w, h] {
            b.baseAddress?.deinitialize(count: capacity)
            b.baseAddress?.deallocate()
        }
    }

    /// Latch the window list and compute what is visible.
    ///
    /// The cull is the bounded part: whatever the scene contains, the work is
    /// linear in `count` and every branch is arithmetic on values we already
    /// hold.
    public func latchAndComposite(now: UInt64, target: UInt64) -> FrameStats {
        count = 0
        // Paint order, and it is the shell's whole visual grammar:
        //
        //   BACKGROUND(0), BOTTOM(1)  — the wallpaper, under everything
        //   the toplevels             — application windows
        //   TOP(2), OVERLAY(3)        — the menu bar, the Dock, toasts
        //
        // Layer surfaces are NOT sorted in with the windows: a menu bar that a
        // window could cover is not a menu bar. Splitting the list at BOTTOM/TOP
        // is what puts the shell above the apps and the wallpaper below them.
        let layers = compositor.mappedLayers
        for l in layers where l.layer <= 1 { add(layer: l) }
        for t in compositor.mappedToplevels {
            guard count < capacity else { break }   // bounded, never grows
            // **The frame goes under the window it frames** (P9.6). One entry
            // in the same arrays as everything else: the present path does not
            // learn a second kind of thing, it just walks one more rect.
            if t.decorated, let deco = compositor.decorations,
               let renderer = compositor.rendererForFrames,
               let frame = deco.texture(for: t, renderer: renderer,
                                        active: compositor.seat?.focused === t) {
                let box = FrameMetrics.frame(forSurfaceAt: t.x, t.y,
                                             width: t.width, height: t.height)
                texture[count] = frame
                x[count] = box.x; y[count] = box.y
                w[count] = box.w; h[count] = box.h
                count += 1
                guard count < capacity else { break }
            }
            guard let tex = wlr_surface_get_texture(t.surface) else { continue }
            texture[count] = tex
            x[count] = t.x; y[count] = t.y
            w[count] = t.width; h[count] = t.height
            count += 1
        }
        for l in layers where l.layer >= 2 { add(layer: l) }
        // Menus above everything, parent before child (P10.4).
        for p in compositor.mappedPopups {
            guard count < capacity, let o = p.origin,
                  let tex = wlr_surface_get_texture(p.surface) else { continue }
            texture[count] = tex
            x[count] = o.x; y[count] = o.y
            w[count] = p.width; h[count] = p.height
            count += 1
        }

        var painted: Int32 = 0
        var area: Int64 = 0
        for i in 0..<count {
            let r = x[i] &+ w[i], b = y[i] &+ h[i]
            if r <= 0 || b <= 0 || x[i] >= outputWidth || y[i] >= outputHeight { continue }
            let cw = min(r, outputWidth) &- max(x[i], 0)
            let ch = min(b, outputHeight) &- max(y[i], 0)
            if cw > 0 && ch > 0 {
                area &+= Int64(cw) &* Int64(ch)
                painted &+= 1
            }
        }
        return FrameStats(surfaces: painted, damageArea: area, degraded: false)
    }

    @inline(__always)
    private func add(layer l: LayerSurface) {
        guard count < capacity else { return }
        guard let tex = wlr_surface_get_texture(l.surface) else { return }
        texture[count] = tex
        x[count] = l.rect.x; y[count] = l.rect.y
        w[count] = l.width; h[count] = l.height
        count += 1
    }

    /// Draw the latched scene into a wlroots render pass.
    ///
    /// Separate from `latchAndComposite` because they belong to different
    /// budgets: the latch+cull is the CPU work C1 constrains, while this is the
    /// renderer's. Keeping them apart is also what lets the same scene be
    /// captured to a file and presented to an output from one latch.
    /// `pass` is a `wlr_render_pass`, which wlroots keeps opaque — so Swift
    /// imports it as `OpaquePointer` and it needs no conversion at all.
    public func render(into pass: OpaquePointer, background: wlr_render_color) {
        var bg = wlr_render_rect_options()
        bg.box = wlr_box(x: 0, y: 0, width: outputWidth, height: outputHeight)
        bg.color = background
        bg.blend_mode = WLR_RENDER_BLEND_MODE_NONE
        wlr_render_pass_add_rect(pass, &bg)

        for i in 0..<count {
            guard let tex = texture[i] else { continue }
            var opts = wlr_render_texture_options()
            opts.texture = tex
            opts.dst_box = wlr_box(x: x[i], y: y[i], width: w[i], height: h[i])
            opts.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED
            wlr_render_pass_add_texture(pass, &opts)
        }
    }
}
