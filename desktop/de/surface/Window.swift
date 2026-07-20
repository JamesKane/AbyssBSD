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
    func keyEvent(_ event: KeyEvent)
}

public extension WindowDelegate {
    // Keyboard is optional for a delegate; default to ignoring it.
    func keyEvent(_ event: KeyEvent) {}
}

final class ShmBuffer {
    let wlBuffer: OpaquePointer
    let data: UnsafeMutableRawPointer
    let length: Int
    let width, height, stride: Int32
    var busy = false

    init?(display: Display, width: Int32, height: Int32) {
        guard let shm = display.shm else { return nil }
        let stride = width * 4
        let length = Int(stride) * Int(height)
        let fd = aw_create_shm(length)
        if fd < 0 { return nil }
        let map = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        let failed = UnsafeMutableRawPointer(bitPattern: -1)
        guard let map, map != failed else { close(fd); return nil }
        guard let pool = opt(aw_shm_create_pool(raw(shm), fd, Int32(length))) else {
            munmap(map, length); close(fd); return nil
        }
        // format 0 == WL_SHM_FORMAT_ARGB8888, matching CAIRO_FORMAT_ARGB32.
        guard let buf = opt(aw_shm_pool_create_buffer(
            raw(pool), 0, width, height, stride, 0)) else {
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

    let scale: Int32
    private var logicalW: Int32
    private var logicalH: Int32
    private var pendingW: Int32
    private var pendingH: Int32

    private var buffers: [ShmBuffer] = []
    private var needsRedraw = true
    private var framePending = false

    public init?(display: Display, title: String, appID: String,
                 width: Int32, height: Int32, scale: Int32 = 1,
                 delegate: WindowDelegate) {
        guard let compositor = display.compositor, let wmBase = display.wmBase,
              let surf = opt(aw_compositor_create_surface(raw(compositor)))
        else { return nil }
        self.display = display
        self.surface = surf
        self.scale = max(1, scale)
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
            w.display.stop()
        }
        display.addListener(to: tl, listener: tll, data: me)

        title.withCString { aw_xdg_toplevel_set_title(raw(tl), $0) }
        appID.withCString { aw_xdg_toplevel_set_app_id(raw(tl), $0) }

        aw_surface_commit(raw(surf))  // triggers the initial configure
    }

    public func setNeedsDisplay() {
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
        if needsRedraw { renderAndCommit() }
    }

    func pointerMoved(fx: Int32, fy: Int32) {
        delegate?.pointerMoved(x: Double(fx) / 256.0, y: Double(fy) / 256.0)
    }

    func pointerButton(_ button: UInt32, pressed: Bool) {
        delegate?.pointerButton(button, pressed: pressed)
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

    /// Logical (surface) size, useful to the toolkit for layout.
    public var size: (width: Int32, height: Int32) { (logicalW, logicalH) }
}
