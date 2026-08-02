// Surface.Window — an xdg-shell toplevel backed by wl_shm buffers.
//
// The toolkit (Aqua) plugs in as a WindowDelegate: it is handed a raw ARGB32
// pixel buffer to paint (via cairo) and receives pointer events in logical
// surface coordinates. Rendering is paced by wl_surface frame callbacks, and a
// two-buffer pool keeps the present path from stalling on buffer release.

import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A CPU-mapped, premultiplied ARGB32 (little-endian) drawing target. Width and
/// height are in *buffer* pixels (logical size × scale).
public struct PixelBuffer {
    public let data: UnsafeMutableRawPointer
    public let width: Int32
    public let height: Int32
    public let stride: Int32
    public let scale: Int32
}

public protocol WindowDelegate: AnyObject {
    func render(_ buffer: PixelBuffer)
    func pointerMoved(x: Double, y: Double)
    func pointerButton(_ button: UInt32, pressed: Bool)
    // Scroll-wheel / touchpad axis. `axis` 0 = vertical, 1 = horizontal; `value`
    // is in logical pixels (positive = down/right). Declared in the body so it
    // dynamically dispatches (see windowDidRenderFrame).
    func pointerAxis(_ axis: UInt32, value: Double)
    func keyEvent(_ event: KeyEvent)
    // Declared here (not only in the extension) so it dynamically dispatches to
    // the conformer — an extension-only method would static-dispatch to the
    // default no-op and the override would never run.
    func windowDidRenderFrame(_ window: Window)
    // The compositor asked this window to close (xdg_toplevel.close). Same
    // dispatch caveat: declared in the body so an override actually runs. A
    // multi-window app closes just this window and quits when the last goes.
    func windowShouldClose(_ window: Window)
}

public extension WindowDelegate {
    // Keyboard is optional for a delegate; default to ignoring it.
    func keyEvent(_ event: KeyEvent) {}
    // Axis (scroll) is optional too.
    func pointerAxis(_ axis: UInt32, value: Double) {}
    // Called after each committed frame is released, so a delegate can drive an
    // animation by advancing state and calling setNeedsDisplay(). Default no-op.
    func windowDidRenderFrame(_ window: Window) {}
    // Single-window default: closing the window ends the process.
    func windowShouldClose(_ window: Window) { window.stopDisplay() }
}

final class ShmBuffer {
    let wlBuffer: OpaquePointer
    let data: UnsafeMutableRawPointer
    let length: Int
    let width, height, stride: Int32
    var busy = false

    /// `stride`/`format` default to what a painted surface wants — a tightly
    /// packed ARGB8888 row, matching CAIRO_FORMAT_ARGB32. Screencopy is the one
    /// caller that must not choose: the compositor dictates the buffer it will
    /// copy into (Screencopy.swift), so both are parameters.
    init?(display: Display, width: Int32, height: Int32,
          stride explicitStride: Int32? = nil, format: UInt32 = 0) {
        guard let shm = display.shm else { return nil }
        let stride = explicitStride ?? width * 4
        guard width > 0, height > 0, stride >= width * 4 else { return nil }
        let length = Int(stride) * Int(height)
        let fd = aw_create_shm(length)
        if fd < 0 { return nil }
        let map = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        let failed = UnsafeMutableRawPointer(bitPattern: -1)
        guard let map, map != failed else { close(fd); return nil }
        guard let pool = opt(aw_shm_create_pool(raw(shm), fd, Int32(length))) else {
            munmap(map, length); close(fd); return nil
        }
        guard let buf = opt(aw_shm_pool_create_buffer(
            raw(pool), 0, width, height, stride, format)) else {
            aw_shm_pool_destroy(raw(pool)); munmap(map, length); close(fd)
            return nil
        }
        aw_shm_pool_destroy(raw(pool))
        close(fd)  // compositor holds its own mapping

        self.wlBuffer = buf
        self.data = map
        self.length = length
        self.width = width
        self.height = height
        self.stride = stride
    }

    func attachReleaseListener(display: Display) {
        var bl = wl_buffer_listener()
        bl.release = { data, _ in
            guard let data else { return }
            let b = Unmanaged<ShmBuffer>.fromOpaque(data).takeUnretainedValue()
            b.busy = false
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        display.addListener(to: wlBuffer, listener: bl, data: me)
    }

    func destroy() {
        aw_buffer_destroy(raw(wlBuffer))
        munmap(data, length)
    }
}

public final class Window {
    let display: Display
    let surface: OpaquePointer
    let xdgSurface: OpaquePointer
    let xdgToplevel: OpaquePointer

    public weak var delegate: WindowDelegate?

    // Buffer scale (device pixels per logical pixel). Mutable: when `autoScale`
    // is on it tracks the outputs the surface is shown on; otherwise it's pinned.
    public private(set) var scale: Int32
    private let autoScale: Bool
    private var enteredOutputs: [OpaquePointer] = []
    private var logicalW: Int32
    private var logicalH: Int32
    private var pendingW: Int32
    private var pendingH: Int32

    private var buffers: [ShmBuffer] = []
    private var needsRedraw = true
    private var framePending = false
    // One-shot teardown guard: close() runs from the delegate, from deinit, and
    // (indirectly) from the compositor's close event (see HANDOFF §2.10).
    private var tornDown = false

    public init?(display: Display, title: String, appID: String,
                 width: Int32, height: Int32, scale: Int32 = 1,
                 autoScale: Bool = true, delegate: WindowDelegate) {
        guard let compositor = display.compositor, let wmBase = display.wmBase,
              let surf = opt(aw_compositor_create_surface(raw(compositor)))
        else { return nil }
        self.display = display
        self.surface = surf
        self.scale = max(1, scale)
        self.autoScale = autoScale
        self.logicalW = width
        self.logicalH = height
        self.pendingW = width
        self.pendingH = height
        self.delegate = delegate

        guard let xs = opt(aw_xdg_wm_base_get_xdg_surface(raw(wmBase), raw(surf)))
        else { return nil }
        xdgSurface = xs
        guard let tl = opt(aw_xdg_surface_get_toplevel(raw(xs))) else { return nil }
        xdgToplevel = tl

        let me = Unmanaged.passUnretained(self).toOpaque()

        var xsl = xdg_surface_listener()
        xsl.configure = { data, _, serial in
            guard let data else { return }
            let w = Unmanaged<Window>.fromOpaque(data).takeUnretainedValue()
            w.applyConfigure(serial: serial)
        }
        display.addListener(to: xs, listener: xsl, data: me)

        var tll = xdg_toplevel_listener()
        tll.configure = { data, _, width, height, _ in
            guard let data else { return }
            let w = Unmanaged<Window>.fromOpaque(data).takeUnretainedValue()
            if width > 0 { w.pendingW = width }
            if height > 0 { w.pendingH = height }
        }
        tll.close = { data, _ in
            guard let data else { return }
            let w = Unmanaged<Window>.fromOpaque(data).takeUnretainedValue()
            w.delegate?.windowShouldClose(w)
        }
        display.addListener(to: tl, listener: tll, data: me)

        // Track which outputs the surface is shown on, to pick the buffer scale
        // (enter/leave carry a wl_output). Only enter/leave exist at wl_surface
        // v4, so the other (v6) listener slots stay NULL and are never dispatched.
        var sl = wl_surface_listener()
        sl.enter = { data, _, output in
            guard let data, let output else { return }
            let w = Unmanaged<Window>.fromOpaque(data).takeUnretainedValue()
            w.surfaceEntered(output)
        }
        sl.leave = { data, _, output in
            guard let data, let output else { return }
            let w = Unmanaged<Window>.fromOpaque(data).takeUnretainedValue()
            w.surfaceLeft(output)
        }
        display.addListener(to: surf, listener: sl, data: me)

        title.withCString { aw_xdg_toplevel_set_title(raw(tl), $0) }
        appID.withCString { aw_xdg_toplevel_set_app_id(raw(tl), $0) }

        aw_surface_commit(raw(surf))  // triggers the initial configure
        display.register(window: self)
    }

    deinit { close() }

    /// Destroy this window's surfaces and drop it from the display's routing.
    /// Idempotent — a multi-window app calls it, and so does deinit.
    public func close() {
        guard !tornDown else { return }
        tornDown = true
        display.unregister(window: self)
        for b in buffers { b.destroy() }
        buffers.removeAll()
        aw_proxy_destroy(raw(xdgToplevel))
        aw_proxy_destroy(raw(xdgSurface))
        aw_proxy_destroy(raw(surface))
        wl_display_flush(display.display)
    }

    /// Ask the compositor to raise/focus this window (xdg-activation). Returns
    /// false if the compositor doesn't offer the protocol.
    @discardableResult
    public func activate() -> Bool {
        guard !tornDown else { return false }
        return display.activate(surface: surface)
    }

    /// End the run loop (the single-window `windowShouldClose` default; `display`
    /// is internal, so delegates outside Surface reach it through here).
    public func stopDisplay() { display.stop() }

    public func setNeedsDisplay() {
        guard !tornDown else { return }
        needsRedraw = true
        if !framePending { renderAndCommit() }
    }

    private func applyConfigure(serial: UInt32) {
        if pendingW != logicalW || pendingH != logicalH || buffers.isEmpty {
            logicalW = pendingW
            logicalH = pendingH
            allocateBuffers()
        }
        aw_xdg_surface_ack_configure(raw(xdgSurface), serial)
        needsRedraw = true
        if !framePending { renderAndCommit() }
    }

    private func surfaceEntered(_ output: OpaquePointer) {
        if !enteredOutputs.contains(output) { enteredOutputs.append(output) }
        recomputeScale()
    }

    private func surfaceLeft(_ output: OpaquePointer) {
        enteredOutputs.removeAll { $0 == output }
        recomputeScale()
    }

    /// Re-evaluate the buffer scale from the outputs the surface is shown on
    /// (HiDPI rule: use the max). Called by Display on enter/leave and whenever a
    /// relevant output's scale changes. A no-op when the scale is pinned.
    func recomputeScale() {
        guard autoScale else { return }
        var s: Int32 = 1
        for o in enteredOutputs { s = max(s, display.outputScale(o)) }
        updateScale(s)
    }

    private func updateScale(_ newScale: Int32) {
        let s = max(1, newScale)
        guard s != scale else { return }
        scale = s
        // Log to fd 2 directly — the `stderr` global is a nonisolated mutable
        // var that Swift 6 strict concurrency rejects (see HANDOFF §2.4).
        let msg = "Surface.Window: buffer scale -> \(s)x\n"
        msg.withCString { _ = write(2, $0, strlen($0)) }
        // Buffers are sized in device pixels, so re-cut them and repaint.
        if !buffers.isEmpty {
            allocateBuffers()
            needsRedraw = true
            if !framePending { renderAndCommit() }
        }
    }

    private func allocateBuffers() {
        for b in buffers { b.destroy() }
        buffers.removeAll()
        let bw = logicalW * scale
        let bh = logicalH * scale
        for _ in 0..<2 {
            guard let b = ShmBuffer(display: display, width: bw, height: bh)
            else { continue }
            b.attachReleaseListener(display: display)
            buffers.append(b)
        }
    }

    private func freeBuffer() -> ShmBuffer? {
        buffers.first { !$0.busy }
    }

    private func renderAndCommit() {
        guard !tornDown else { return }
        guard let buf = freeBuffer() else {
            needsRedraw = true  // both busy; retry on release/frame
            return
        }
        delegate?.render(PixelBuffer(data: buf.data, width: buf.width,
                                     height: buf.height, stride: buf.stride,
                                     scale: scale))
        buf.busy = true
        aw_surface_attach(raw(surface), raw(buf.wlBuffer), 0, 0)
        aw_surface_set_buffer_scale(raw(surface), scale)
        aw_surface_damage_buffer(raw(surface), 0, 0, buf.width, buf.height)

        if let cb = opt(aw_surface_frame(raw(surface))) {
            var cl = wl_callback_listener()
            cl.done = { data, _, _ in
                guard let data else { return }
                let w = Unmanaged<Window>.fromOpaque(data).takeUnretainedValue()
                w.frameDone()
            }
            let me = Unmanaged.passUnretained(self).toOpaque()
            display.addListener(to: cb, listener: cl, data: me)
            framePending = true
        }
        needsRedraw = false
        aw_surface_commit(raw(surface))
        wl_display_flush(display.display)
    }

    private func frameDone() {
        framePending = false
        guard !tornDown else { return }
        // Let the delegate advance any animation (it may call setNeedsDisplay).
        // framePending is false here, so that render runs cleanly — unlike a
        // setNeedsDisplay from inside render(), which would re-enter.
        delegate?.windowDidRenderFrame(self)
        if needsRedraw { renderAndCommit() }
    }

    func pointerMoved(fx: Int32, fy: Int32) {
        delegate?.pointerMoved(x: Double(fx) / 256.0, y: Double(fy) / 256.0)
    }

    func pointerButton(_ button: UInt32, pressed: Bool) {
        delegate?.pointerButton(button, pressed: pressed)
    }

    func pointerAxis(_ axis: UInt32, value: Double) {
        delegate?.pointerAxis(axis, value: value)
    }

    func keyEvent(_ event: KeyEvent) {
        delegate?.keyEvent(event)
    }

    /// Open a grabbing xdg-popup (a menu) anchored to a rect in this window's
    /// logical surface coordinates. The caller owns the returned Popup; dropping
    /// it (or the compositor sending popup_done) tears it down. Returns nil if
    /// the popup can't be created.
    public func openPopup(anchorX: Int32, anchorY: Int32, anchorW: Int32,
                          anchorH: Int32, width: Int32, height: Int32,
                          delegate: PopupDelegate) -> Popup? {
        Popup(parent: self, anchorX: anchorX, anchorY: anchorY,
              anchorW: anchorW, anchorH: anchorH, width: width, height: height,
              delegate: delegate)
    }

    /// Retitle the toplevel (the Finder does this as it browses).
    public func setTitle(_ title: String) {
        title.withCString { aw_xdg_toplevel_set_title(raw(xdgToplevel), $0) }
    }

    /// Logical (surface) size, useful to the toolkit for layout.
    public var size: (width: Int32, height: Int32) { (logicalW, logicalH) }
}
