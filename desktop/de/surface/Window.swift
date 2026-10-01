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

    /// Public so a delegate can be rendered offscreen — the golden-image
    /// scenes paint a menu into a cairo image this way (PHASE11 P11.1).
    public init(data: UnsafeMutableRawPointer, width: Int32, height: Int32,
                stride: Int32, scale: Int32) {
        self.data = data; self.width = width; self.height = height
        self.stride = stride; self.scale = scale
    }
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
    // The compositor told us what this window now *is* — maximized, fullscreen,
    // activated — which the client cannot know any other way (P9.4). Same
    // dispatch caveat as the two above.
    func windowStateChanged(_ window: Window)
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
    // Most windows draw the same either way; the ones that do not override it.
    func windowStateChanged(_ window: Window) {}
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
        // A dictated stride is the compositor's to choose, and it need not be
        // four bytes a pixel: a GPU renderer offers screencopy 24-bit `BG24`,
        // and this guard refused it — the second half of U.3's screenshot bug,
        // after the format table. Only our own default is held to ARGB8888.
        guard width > 0, height > 0,
              stride >= (explicitStride == nil ? width * 4 : width) else { return nil }
        let length = Int(stride) * Int(height)
        let fd = aw_create_shm(length)
        if fd < 0 { return nil }
        let map = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        let failed = UnsafeMutableRawPointer(bitPattern: -1)
        guard let map, map != failed else { close(fd); return nil }
        guard let pool = wl_shm_create_pool(shm, fd, Int32(length)) else {
            munmap(map, length); close(fd); return nil
        }
        guard let buf = wl_shm_pool_create_buffer(
            pool, 0, width, height, stride, format) else {
            wl_shm_pool_destroy(pool); munmap(map, length); close(fd)
            return nil
        }
        wl_shm_pool_destroy(pool)
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
        wl_buffer_destroy(wlBuffer)
        munmap(data, length)
    }
}

/// Which edge or corner an interactive resize is dragging.
///
/// The values are `xdg_toplevel_resize_edge`'s own, so the compositor knows
/// which corner to keep anchored — a resize from the left that moves the right
/// edge instead is the classic symptom of guessing here.
public struct ResizeEdge: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let top    = ResizeEdge(rawValue: 1)
    public static let bottom = ResizeEdge(rawValue: 2)
    public static let left   = ResizeEdge(rawValue: 4)
    public static let right  = ResizeEdge(rawValue: 8)
    public static let topLeft: ResizeEdge = [.top, .left]
    public static let topRight: ResizeEdge = [.top, .right]
    public static let bottomLeft: ResizeEdge = [.bottom, .left]
    public static let bottomRight: ResizeEdge = [.bottom, .right]
}

public final class Window {
    let display: Display
    /// The `wl_surface` this window draws on.
    ///
    /// Public because a drag has to name the surface it started from — the
    /// compositor validates the press against *that* surface, so an application
    /// cannot start a drag on somebody else's window.
    public let surface: OpaquePointer
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
    private var pendingStates: Set<UInt32> = []
    /// What the compositor last told us this window is. Read it rather than
    /// remembering what you asked for: the compositor may refuse, and on some it
    /// is the only way to learn a window was maximized by a keybind or a snap.
    public private(set) var isMaximized = false
    public private(set) var isFullscreen = false
    public private(set) var isActivated = false
    /// True while the compositor is running an interactive resize we asked for.
    public private(set) var isResizing = false
    /// **Nobody can see it** (xdg-shell v6, T.3): minimised, or on no output.
    /// While it is, nothing is drawn or committed — a redraw asked for waits,
    /// and happens once, when the window can be seen again.
    public private(set) var isSuspended = false
    /// What the compositor serves (`wm_capabilities`, v5), or nil before it
    /// says — a compositor that never says serves everything, as before v5.
    public private(set) var capabilities: Set<UInt32>?
    /// The most room the compositor will give a window (`configure_bounds`,
    /// v4), or nil for no limit it knows of.
    public private(set) var bounds: (width: Int32, height: Int32)?
    public var canMinimize: Bool { capabilities?.contains(XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE.rawValue) ?? true }
    public var canMaximize: Bool { capabilities?.contains(XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE.rawValue) ?? true }

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
              let surf = wl_compositor_create_surface(compositor)
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

        guard let xs = xdg_wm_base_get_xdg_surface(wmBase, surf)
        else { return nil }
        xdgSurface = xs
        guard let tl = xdg_surface_get_toplevel(xs) else { return nil }
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
        tll.configure = { data, _, width, height, states in
            guard let data else { return }
            let w = Unmanaged<Window>.fromOpaque(data).takeUnretainedValue()
            if width > 0 { w.pendingW = width }
            if height > 0 { w.pendingH = height }
            // **The states are half of what a configure says.** A window that
            // ignores them cannot know it was maximized — so its zoom light
            // never un-zooms, and it goes on drawing a resize grip in a corner
            // that can no longer be dragged. The array is `wl_array` of
            // `uint32` state values.
            w.pendingStates = Window.states(from: states)
        }
        tll.close = { data, _ in
            guard let data else { return }
            let w = Unmanaged<Window>.fromOpaque(data).takeUnretainedValue()
            w.delegate?.windowShouldClose(w)
        }
        // v4 and v5 (T.3). Bound at v6, the compositor sends both; a NULL slot
        // is libwayland's abort.
        tll.configure_bounds = { data, _, width, height in
            guard let data else { return }
            let w = Unmanaged<Window>.fromOpaque(data).takeUnretainedValue()
            w.bounds = width > 0 && height > 0 ? (width, height) : nil
        }
        tll.wm_capabilities = { data, _, caps in
            guard let data else { return }
            let w = Unmanaged<Window>.fromOpaque(data).takeUnretainedValue()
            w.capabilities = Window.states(from: caps)
            let names = [(XDG_TOPLEVEL_WM_CAPABILITIES_WINDOW_MENU, "window-menu"),
                         (XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE, "maximize"),
                         (XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN, "fullscreen"),
                         (XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE, "minimize")]
                .filter { w.capabilities!.contains($0.0.rawValue) }.map(\.1)
            Window.log("the compositor serves: " + (names.isEmpty ? "nothing" : names.joined(separator: " ")))
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

        title.withCString { xdg_toplevel_set_title(tl, $0) }
        appID.withCString { xdg_toplevel_set_app_id(tl, $0) }

        wl_surface_commit(surf)  // triggers the initial configure
        display.register(window: self)
    }

    deinit { close() }

    /// Destroy this window's surfaces and drop it from the display's routing.
    /// Idempotent — a multi-window app calls it, and so does deinit.
    /// The frame callback in flight, so `close()` can cancel it.
    private var frameCallback: OpaquePointer?

    public func close() {
        guard !tornDown else { return }
        tornDown = true
        display.unregister(window: self)
        for b in buffers { b.destroy() }
        buffers.removeAll()
        // **The destructor requests, not `wl_proxy_destroy`.** Freeing the
        // local proxy tells the compositor nothing: the surface stays mapped
        // there for ever, keeps its buffer, and goes on swallowing every click
        // and every drag that lands in the rectangle where the window used to
        // be. Nothing in the client can see it — the window is gone here — and
        // the compositor is behaving correctly, which is why this survived
        // every close test the project has: they all asked whether the client
        // closed the window (P9.3).
        // **The pending frame callback first** (P15.6): its data is this object,
        // unretained, and a `done` that arrives after the object is gone is a
        // call into freed memory — Grab's overlay, closed between a frame's
        // commit and its `done`, took the process down with SIGBUS.
        if let c = frameCallback { wl_callback_destroy(c); frameCallback = nil }
        xdg_toplevel_destroy(xdgToplevel)
        xdg_surface_destroy(xdgSurface)
        wl_surface_destroy(surface)
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
        // **The states take effect here, with the size.** A configure is one
        // atomic answer: the toplevel event carries the size and the states, the
        // xdg_surface event says "that is the whole of it", and applying half of
        // them leaves a window that has been maximized and does not know it —
        // whose zoom light then asks to maximize a second time and never
        // un-zooms.
        let wasMax = isMaximized, wasFull = isFullscreen, wasActive = isActivated
        let wasSuspended = isSuspended
        isMaximized  = pendingStates.contains(XDG_TOPLEVEL_STATE_MAXIMIZED.rawValue)
        isFullscreen = pendingStates.contains(XDG_TOPLEVEL_STATE_FULLSCREEN.rawValue)
        isActivated  = pendingStates.contains(XDG_TOPLEVEL_STATE_ACTIVATED.rawValue)
        isResizing   = pendingStates.contains(XDG_TOPLEVEL_STATE_RESIZING.rawValue)
        isSuspended  = pendingStates.contains(XDG_TOPLEVEL_STATE_SUSPENDED.rawValue)
        if isSuspended != wasSuspended {
            Window.log(isSuspended ? "suspended: nobody can see it; drawing nothing"
                                   : "resumed after \(redrawsHeld) redraw(s) held; drawing once")
            if !isSuspended { redrawsHeld = 0 }
        }
        // The compositor left the size to us (0x0): keep within its bounds —
        // a window on a small display that fits it rather than hangs off it.
        if let b = bounds, pendingW > b.width || pendingH > b.height, !isMaximized, !isFullscreen {
            pendingW = min(pendingW, b.width)
            pendingH = min(pendingH, b.height)
        }
        if isMaximized != wasMax || isFullscreen != wasFull || isActivated != wasActive {
            needsRedraw = true
            delegate?.windowStateChanged(self)
        }
        if pendingW != logicalW || pendingH != logicalH || buffers.isEmpty {
            logicalW = pendingW
            logicalH = pendingH
            allocateBuffers()
        }
        xdg_surface_ack_configure(xdgSurface, serial)
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

    /// Redraws asked for while suspended, for the line that says so.
    private var redrawsHeld = 0

    private func renderAndCommit() {
        guard !tornDown else { return }
        // **Not for nobody** (T.3). The redraw waits; the configure that ends
        // the suspension asks for it again. A configure's ack still needs a
        // commit, which carries no new buffer.
        if isSuspended {
            if needsRedraw { redrawsHeld += 1 }
            needsRedraw = true
            wl_surface_commit(surface)
            wl_display_flush(display.display)
            return
        }
        guard let buf = freeBuffer() else {
            needsRedraw = true  // both busy; retry on release/frame
            return
        }
        delegate?.render(PixelBuffer(data: buf.data, width: buf.width,
                                     height: buf.height, stride: buf.stride,
                                     scale: scale))
        buf.busy = true
        wl_surface_attach(surface, buf.wlBuffer, 0, 0)
        wl_surface_set_buffer_scale(surface, scale)
        wl_surface_damage_buffer(surface, 0, 0, buf.width, buf.height)

        if let cb = wl_surface_frame(surface) {
            frameCallback = cb
            var cl = wl_callback_listener()
            cl.done = { data, cb, _ in
                if let cb { wl_callback_destroy(cb) }     // `done` ends its life
                guard let data else { return }
                let w = Unmanaged<Window>.fromOpaque(data).takeUnretainedValue()
                w.frameCallback = nil
                w.frameDone()
            }
            let me = Unmanaged.passUnretained(self).toOpaque()
            display.addListener(to: cb, listener: cl, data: me)
            framePending = true
        }
        needsRedraw = false
        wl_surface_commit(surface)
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
    /// Decode an `xdg_toplevel.configure` states array.
    private static func states(from array: UnsafeMutablePointer<wl_array>?) -> Set<UInt32> {
        guard let a = array, let base = a.pointee.data else { return [] }
        var out: Set<UInt32> = []
        let count = a.pointee.size / MemoryLayout<UInt32>.size
        let values = base.assumingMemoryBound(to: UInt32.self)
        for i in 0..<count { out.insert(values[i]) }
        return out
    }

    // MARK: - What a window may ask about itself (P9.4)

    /// Hand the pointer to the compositor and let it move this window.
    ///
    /// **A Wayland client cannot place its own window**, so a title-bar drag is
    /// not something the client implements — it is a request, made once, on the
    /// press. The serial has to be from that press: the compositor validates it
    /// (§4.2), which is what stops a program grabbing the pointer out of turn.
    public func beginMove() {
        guard !tornDown, let seat = display.seat else { return }
        xdg_toplevel_move(xdgToplevel, seat, display.lastPointerSerial)
        display.flush()
    }

    /// The same, for a resize from `edge` — see `ResizeEdge`.
    public func beginResize(_ edge: ResizeEdge) {
        guard !tornDown, let seat = display.seat else { return }
        xdg_toplevel_resize(xdgToplevel, seat,
                               display.lastPointerSerial, edge.rawValue)
        display.flush()
    }

    /// Zoom, in Mac terms. The compositor decides what "maximized" means — for
    /// undertow that is the usable area, not the output, because the menu bar's
    /// exclusive zone is part of the answer.
    public func setMaximized(_ on: Bool) {
        guard !tornDown else { return }
        guard canMaximize else { Window.log("not zooming: the compositor does not maximise"); return }
        if on { xdg_toplevel_set_maximized(xdgToplevel) }
        else { xdg_toplevel_unset_maximized(xdgToplevel) }
        display.flush()
    }

    /// Tell the compositor this window's menus are published at `address` (a
    /// MenuWire service name), or withdraw them with "" (PHASE10.md P10.3).
    /// False when the compositor does not speak the protocol — under anything
    /// but undertow, which is a real case and not an error.
    @discardableResult
    public func publishMenus(at address: String) -> Bool {
        guard let m = display.menuManager else { return false }
        abyss_menu_manager_v1_set_address(m, surface, address)
        display.flush()
        return true
    }

    /// Minimize. There is no `unset_minimized` in the protocol: a minimized
    /// window is restored by the compositor (a Dock tile, a switcher), never by
    /// the client, because a client that could un-minimize itself would.
    /// False, and nothing asked, when the compositor said it does not
    /// minimise (`wm_capabilities`, T.3).
    @discardableResult
    public func minimize() -> Bool {
        guard !tornDown else { return false }
        guard canMinimize else { Window.log("not minimising: the compositor does not"); return false }
        xdg_toplevel_set_minimized(xdgToplevel)
        display.flush()
        return true
    }

    /// Send this window behind the others — the depth gadget (P11.6). False
    /// when the compositor does not speak abyss-window-v1 (anything but
    /// undertow); xdg-shell has no such request.
    @discardableResult
    public func lower() -> Bool {
        guard !tornDown, let m = display.windowManager else { return false }
        abyss_window_manager_v1_lower(m, xdgToplevel)
        display.flush()
        return true
    }

    public func setFullscreen(_ on: Bool) {
        guard !tornDown else { return }
        if on { xdg_toplevel_set_fullscreen(xdgToplevel, nil) }
        else { xdg_toplevel_unset_fullscreen(xdgToplevel) }
        display.flush()
    }

    public func setTitle(_ title: String) {
        title.withCString { xdg_toplevel_set_title(xdgToplevel, $0) }
    }

    /// Logical (surface) size, useful to the toolkit for layout.
    public var size: (width: Int32, height: Int32) { (logicalW, logicalH) }

    static func log(_ msg: String) {
        let line = "Surface.Window: \(msg)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }
}
