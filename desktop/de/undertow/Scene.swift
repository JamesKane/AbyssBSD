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
    /// The client surface each entry was drawn from — nil for the frames the
    /// compositor draws itself. What presentation-time is told was on screen.
    private let source: UnsafeMutableBufferPointer<UnsafeMutablePointer<wlr_surface>?>
    /// The part of each texture drawn, in buffer pixels (U.8): a viewport's
    /// source crop, else the whole buffer. An empty box means the whole
    /// texture — the compositor's own frames.
    private let crop: UnsafeMutableBufferPointer<wlr_fbox>
    /// How each texture is turned to be drawn: the inverse of its buffer's
    /// transform (a client that rendered rotated says so, and we undo it).
    private let turn: UnsafeMutableBufferPointer<wl_output_transform>
    /// What the renderer must wait for before reading each texture (U.3b):
    /// its buffer's acquire point, when its client uses explicit sync.
    private let waitTimeline: UnsafeMutableBufferPointer<UnsafeMutablePointer<wlr_drm_syncobj_timeline>?>
    private let waitPoint: UnsafeMutableBufferPointer<UInt64>
    /// Textures drawn behind an acquire wait, all told — the test's witness
    /// that the scene, and not only wlroots, took part.
    public private(set) var acquireWaits = 0

    private unowned let compositor: Compositor
    /// The rectangle of the layout this scene shows — its output's (P14.7a).
    /// Everything latched is in layout coordinates; the cull and the draw
    /// subtract the origin, and the draw multiplies by the scale.
    public private(set) var originX: Int32, originY: Int32
    public private(set) var outputWidth: Int32, outputHeight: Int32
    public private(set) var scale: Double

    public init(compositor: Compositor, display: DisplayBox, capacity: Int = 256) {
        self.compositor = compositor
        self.capacity = capacity
        self.originX = display.x
        self.originY = display.y
        self.outputWidth = display.width
        self.outputHeight = display.height
        self.scale = display.scale
        let t = UnsafeMutablePointer<UnsafeMutablePointer<wlr_texture>?>.allocate(capacity: capacity)
        t.initialize(repeating: nil, count: capacity)
        texture = UnsafeMutableBufferPointer(start: t, count: capacity)
        let s = UnsafeMutablePointer<UnsafeMutablePointer<wlr_surface>?>.allocate(capacity: capacity)
        s.initialize(repeating: nil, count: capacity)
        source = UnsafeMutableBufferPointer(start: s, count: capacity)
        func ints() -> UnsafeMutableBufferPointer<Int32> {
            let p = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
            p.initialize(repeating: 0, count: capacity)
            return UnsafeMutableBufferPointer(start: p, count: capacity)
        }
        x = ints(); y = ints(); w = ints(); h = ints()
        let c = UnsafeMutablePointer<wlr_fbox>.allocate(capacity: capacity)
        c.initialize(repeating: wlr_fbox(), count: capacity)
        crop = UnsafeMutableBufferPointer(start: c, count: capacity)
        let tr = UnsafeMutablePointer<wl_output_transform>.allocate(capacity: capacity)
        tr.initialize(repeating: WL_OUTPUT_TRANSFORM_NORMAL, count: capacity)
        turn = UnsafeMutableBufferPointer(start: tr, count: capacity)
        let wt = UnsafeMutablePointer<UnsafeMutablePointer<wlr_drm_syncobj_timeline>?>.allocate(capacity: capacity)
        wt.initialize(repeating: nil, count: capacity)
        waitTimeline = UnsafeMutableBufferPointer(start: wt, count: capacity)
        let wp = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
        wp.initialize(repeating: 0, count: capacity)
        waitPoint = UnsafeMutableBufferPointer(start: wp, count: capacity)
    }

    /// The output moved, changed mode or scale (P14.7b applies these).
    public func show(_ display: DisplayBox) {
        originX = display.x; originY = display.y
        outputWidth = display.width; outputHeight = display.height
        scale = display.scale
    }

    public func release() {
        texture.baseAddress?.deinitialize(count: capacity)
        texture.baseAddress?.deallocate()
        source.baseAddress?.deinitialize(count: capacity)
        source.baseAddress?.deallocate()
        for b in [x, y, w, h] {
            b.baseAddress?.deinitialize(count: capacity)
            b.baseAddress?.deallocate()
        }
        crop.baseAddress?.deinitialize(count: capacity)
        crop.baseAddress?.deallocate()
        turn.baseAddress?.deinitialize(count: capacity)
        turn.baseAddress?.deallocate()
        waitTimeline.baseAddress?.deinitialize(count: capacity)
        waitTimeline.baseAddress?.deallocate()
        waitPoint.baseAddress?.deinitialize(count: capacity)
        waitPoint.baseAddress?.deallocate()
    }

    /// Latch the window list and compute what is visible.
    ///
    /// The cull is the bounded part: whatever the scene contains, the work is
    /// linear in `count` and every branch is arithmetic on values we already
    /// hold.
    public func latchAndComposite(now: UInt64, target: UInt64) -> FrameStats {
        count = 0
        // **Locked: the lock surface for this display, and nothing else**
        // (PHASE16 P16.2). Not the wallpaper, not a window, not a menu or an
        // input method's popup — a window that maps while locked is not
        // drawn either. With no lock surface (its client died, or has not
        // drawn yet), the background alone: the lock colour, never the desktop.
        if compositor.isLocked {
            if let lock = compositor.sessionLock {
                for m in lock.mapped where m.display.x == originX && m.display.y == originY {
                    addTree(m.surface, at: m.display.x, m.display.y)
                }
            }
            return FrameStats(surfaces: Int32(count), damageArea: Int64(outputWidth) * Int64(outputHeight),
                              degraded: false)
        }
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
                source[count] = nil                 // ours: nobody to tell
                crop[count] = wlr_fbox()            // all of it, as drawn
                turn[count] = WL_OUTPUT_TRANSFORM_NORMAL
                waitTimeline[count] = nil           // drawn by us, on the CPU
                x[count] = box.x; y[count] = box.y
                w[count] = box.w; h[count] = box.h
                count += 1
                guard count < capacity else { break }
            }
            addTree(t.surface, at: t.x, t.y)
        }
        for l in layers where l.layer >= 2 { add(layer: l) }
        // Menus above everything, parent before child (P10.4).
        for p in compositor.mappedPopups {
            guard let o = p.origin else { continue }
            addTree(p.surface, at: o.x, o.y)
        }
        // An input method's candidates over everything, below the text
        // cursor of the field being composed into (U.5).
        if let ti = compositor.seat?.textInput {
            for p in ti.mappedPopups { addTree(p.surface, at: p.x, p.y) }
        }

        var painted: Int32 = 0
        var area: Int64 = 0
        for i in 0..<count {
            let lx = x[i] &- originX, ly = y[i] &- originY
            let r = lx &+ w[i], b = ly &+ h[i]
            if r <= 0 || b <= 0 || lx >= outputWidth || ly >= outputHeight { continue }
            let cw = min(r, outputWidth) &- max(lx, 0)
            let ch = min(b, outputHeight) &- max(ly, 0)
            if cw > 0 && ch > 0 {
                area &+= Int64(cw) &* Int64(ch)
                painted &+= 1
            }
        }
        return FrameStats(surfaces: painted, damageArea: area, degraded: false)
    }

    @inline(__always)
    private func add(layer l: LayerSurface) {
        addTree(l.surface, at: l.rect.x, l.rect.y)
    }

    // MARK: - Surface trees

    /// Where the tree being walked sits on the output. Instance state rather
    /// than a context value, so a walk allocates nothing — the latch is C1's
    /// budget.
    private var walkX: Int32 = 0
    private var walkY: Int32 = 0

    /// A surface **and its subsurfaces**, in the order they are painted.
    ///
    /// **undertow advertised `wl_subcompositor` from Phase 6 and never drew a
    /// subsurface** — each root was one texture, and anything a client put in
    /// a subsurface (Firefox puts its whole page in one) was a mapped surface
    /// nobody could see (API-STUDY §1.3; HANDOFF §2.58's shape, a third time).
    /// wlroots keeps the tree and its stacking — `place_above`, `place_below`,
    /// each child's offset — and walks it root to leaves in paint order, which
    /// is the one order a naive "parent, then children" gets wrong: a child
    /// placed below its parent is painted first.
    @inline(__always)
    private func addTree(_ root: UnsafeMutablePointer<wlr_surface>, at ox: Int32, _ oy: Int32) {
        walkX = ox; walkY = oy
        wlr_surface_for_each_surface(root, { surface, sx, sy, data in
            guard let surface, let data else { return }
            Unmanaged<SurfaceScene>.fromOpaque(data).takeUnretainedValue()
                .addLeaf(surface, sx, sy)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func addLeaf(_ s: UnsafeMutablePointer<wlr_surface>, _ sx: Int32, _ sy: Int32) {
        guard count < capacity, let tex = wlr_surface_get_texture(s) else { return }
        texture[count] = tex
        source[count] = s
        x[count] = walkX &+ sx; y[count] = walkY &+ sy
        // The size on screen is the surface's: wlroots has already applied
        // the buffer scale, the transform and a viewport's destination.
        w[count] = s.pointee.current.width; h[count] = s.pointee.current.height
        // **What part of the buffer (U.8).** A viewport may crop it — a video
        // player showing a 16:9 picture out of a padded decoder buffer, or a
        // client that rendered at 1.5x drawing into a 1x rectangle. Drawn
        // whole, the crop's outside shows and everything inside is squeezed.
        wlr_surface_get_buffer_source_box(s, crop.baseAddress! + count)
        turn[count] = wlr_output_transform_invert(s.pointee.current.transform)
        // Not before the GPU has finished drawing it (U.3b).
        (waitTimeline[count], waitPoint[count]) = compositor.explicitSync == nil
            ? (nil, 0) : ExplicitSync.acquire(s)
        count += 1
    }

    /// Tell presentation-time which client surfaces this frame shows (U.4).
    ///
    /// wlroots then answers each surface's `wp_presentation_feedback` from the
    /// output's own present event — the real time the frame reached the
    /// display, the refresh period, the sequence and whether the clock was the
    /// hardware's. It cannot know which surfaces were in a frame unless the
    /// compositor says; `wlr_scene` would, ours must. Called before the output
    /// commit, for exactly the entries latched.
    public func markPresented(on output: UnsafeMutablePointer<wlr_output>) {
        for i in 0..<count {
            if let s = source[i] { wlr_presentation_surface_textured_on_output(s, output) }
        }
    }

    /// Draw the latched scene into a wlroots render pass.
    ///
    /// Separate from `latchAndComposite` because they belong to different
    /// budgets: the latch+cull is the CPU work C1 constrains, while this is the
    /// renderer's. Keeping them apart is also what lets the same scene be
    /// captured to a file and presented to an output from one latch.
    /// `pass` is a `wlr_render_pass`, which wlroots keeps opaque — so Swift
    /// imports it as `OpaquePointer` and it needs no conversion at all.
    /// A layout rectangle, in this output's buffer pixels.
    @inline(__always)
    public func box(_ lx: Int32, _ ly: Int32, _ lw: Int32, _ lh: Int32) -> wlr_box {
        let r = SurfaceScene.project(Rect(x: lx, y: ly, width: lw, height: lh),
                                     originX: originX, originY: originY, scale: scale)
        return wlr_box(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    /// A layout rectangle in an output's buffer pixels, as a pure function.
    /// Edges are rounded, not the size, so two rectangles that touch in the
    /// layout still touch on a scaled output.
    @inline(__always)
    public static func project(_ r: Rect, originX: Int32, originY: Int32, scale: Double) -> Rect {
        if scale == 1 { return Rect(x: r.x &- originX, y: r.y &- originY, width: r.width, height: r.height) }
        let x0 = (Double(r.x &- originX) * scale).rounded(), y0 = (Double(r.y &- originY) * scale).rounded()
        let x1 = (Double(r.x &- originX &+ r.width) * scale).rounded()
        let y1 = (Double(r.y &- originY &+ r.height) * scale).rounded()
        return Rect(x: Int32(x0), y: Int32(y0), width: Int32(x1 - x0), height: Int32(y1 - y0))
    }

    /// What a locked display shows where its lock surface is not: a dark slate,
    /// unlike any colour the desktop draws — so a test can tell "locked, and
    /// nothing drawn" from "the desktop".
    public static let lockedColour = wlr_render_color(r: 0.09, g: 0.10, b: 0.13, a: 1)

    public func render(into pass: OpaquePointer, background: wlr_render_color) {
        var bg = wlr_render_rect_options()
        bg.box = wlr_box(x: 0, y: 0, width: Int32((Double(outputWidth) * scale).rounded()),
                         height: Int32((Double(outputHeight) * scale).rounded()))
        bg.color = compositor.isLocked ? SurfaceScene.lockedColour : background
        bg.blend_mode = WLR_RENDER_BLEND_MODE_NONE
        wlr_render_pass_add_rect(pass, &bg)

        for i in 0..<count {
            guard let tex = texture[i] else { continue }
            var opts = wlr_render_texture_options()
            opts.texture = tex
            opts.dst_box = box(x[i], y[i], w[i], h[i])
            opts.src_box = crop[i]
            opts.transform = turn[i]
            if let t = waitTimeline[i] {
                opts.wait_timeline = t
                opts.wait_point = waitPoint[i]
                acquireWaits &+= 1
            }
            opts.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED
            wlr_render_pass_add_texture(pass, &opts)
        }
    }
}
