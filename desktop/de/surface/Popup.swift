// Surface.Popup — a grabbing xdg-popup child surface (the basis of a menu).
//
// A popup is a second wl_surface parented (via xdg_positioner) to a rect in the
// owning window, backed by its own shm buffers. `grab` makes the compositor
// route input to it and emit `popup_done` when the user clicks outside, which is
// how a menu dismisses. Display routes pointer events to whichever surface the
// pointer entered (see Display.swift). Buffer/render/frame handling mirrors
// Window; a menu is small, but it still needs the double-buffer + frame pacing
// so hover-highlight redraws don't stall on buffer release.

import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public protocol PopupDelegate: AnyObject {
    func render(_ buffer: PixelBuffer)
    func pointerMoved(x: Double, y: Double)
    func pointerButton(pressed: Bool)
    /// The popup was torn down (outside click / compositor dismissal / close).
    func popupDismissed()
}

// xdg_positioner anchor/gravity/constraint values (avoid importing the C enums).
private let kAnchorBottomLeft: UInt32 = 6
private let kGravityBottomRight: UInt32 = 8
private let kConstraintSlideX: UInt32 = 1
private let kConstraintSlideY: UInt32 = 2
private let kConstraintFlipY: UInt32 = 8

public final class Popup {
    let display: Display
    let surface: OpaquePointer
    let xdgSurface: OpaquePointer
    let xdgPopup: OpaquePointer

    public weak var delegate: PopupDelegate?

    let scale: Int32
    private let logicalW: Int32
    private let logicalH: Int32

    private var buffers: [ShmBuffer] = []
    private var needsRedraw = true
    private var framePending = false
    private var tornDown = false

    init?(parent: Window, anchorX: Int32, anchorY: Int32, anchorW: Int32,
          anchorH: Int32, width: Int32, height: Int32, delegate: PopupDelegate) {
        let display = parent.display
        guard let compositor = display.compositor, let wmBase = display.wmBase,
              let seat = display.seat,
              let surf = opt(aw_compositor_create_surface(raw(compositor)))
        else { return nil }
        self.display = display
        self.surface = surf
        self.scale = parent.scale
        self.logicalW = width
        self.logicalH = height
        self.delegate = delegate

        guard let xs = opt(aw_xdg_wm_base_get_xdg_surface(raw(wmBase), raw(surf)))
        else { return nil }
        xdgSurface = xs

        guard let pos = opt(aw_xdg_wm_base_create_positioner(raw(wmBase)))
        else { return nil }
        aw_xdg_positioner_set_size(raw(pos), width, height)
        aw_xdg_positioner_set_anchor_rect(raw(pos), anchorX, anchorY, anchorW, anchorH)
        aw_xdg_positioner_set_anchor(raw(pos), kAnchorBottomLeft)
        aw_xdg_positioner_set_gravity(raw(pos), kGravityBottomRight)
        aw_xdg_positioner_set_constraint_adjustment(
            raw(pos), kConstraintSlideX | kConstraintSlideY | kConstraintFlipY)

        guard let pop = opt(aw_xdg_surface_get_popup(
            raw(xs), raw(parent.xdgSurface), raw(pos))) else {
            aw_xdg_positioner_destroy(raw(pos))
            return nil
        }
        xdgPopup = pop
        aw_xdg_positioner_destroy(raw(pos))

        let me = Unmanaged.passUnretained(self).toOpaque()

        var xsl = xdg_surface_listener()
        xsl.configure = { data, _, serial in
            guard let data else { return }
            let p = Unmanaged<Popup>.fromOpaque(data).takeUnretainedValue()
            p.applyConfigure(serial: serial)
        }
        display.addListener(to: xs, listener: xsl, data: me)

        var pl = xdg_popup_listener()
        pl.configure = { _, _, _, _, _, _ in }  // position/size; we use our own
        pl.popup_done = { data, _ in
            guard let data else { return }
            let p = Unmanaged<Popup>.fromOpaque(data).takeUnretainedValue()
            p.handleDone()
        }
        // xdg_popup v3+ adds `repositioned`; harmless to leave unset at the
        // version xdg_wm_base was bound (2), but fill it if present.
        display.addListener(to: pop, listener: pl, data: me)

        // Grab input using the serial of the click that opened us, so the
        // compositor dismisses on an outside click.
        aw_xdg_popup_grab(raw(pop), raw(seat), display.lastPointerSerial)
        aw_surface_commit(raw(surf))  // triggers the initial configure
        wl_display_flush(display.display)

        display.activePopup = self
    }

    private func applyConfigure(serial: UInt32) {
        if buffers.isEmpty { allocateBuffers() }
        aw_xdg_surface_ack_configure(raw(xdgSurface), serial)
        needsRedraw = true
        if !framePending { renderAndCommit() }
    }

    private func allocateBuffers() {
        let bw = logicalW * scale
        let bh = logicalH * scale
        for _ in 0..<2 {
            guard let b = ShmBuffer(display: display, width: bw, height: bh)
            else { continue }
            b.attachReleaseListener(display: display)
            buffers.append(b)
        }
    }

    public func setNeedsDisplay() {
        needsRedraw = true
        if !framePending { renderAndCommit() }
    }

    private func renderAndCommit() {
        guard !tornDown, let buf = buffers.first(where: { !$0.busy }) else {
            needsRedraw = true
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
                let p = Unmanaged<Popup>.fromOpaque(data).takeUnretainedValue()
                p.framePending = false
                if p.needsRedraw { p.renderAndCommit() }
            }
            let me = Unmanaged.passUnretained(self).toOpaque()
            display.addListener(to: cb, listener: cl, data: me)
            framePending = true
        }
        needsRedraw = false
        aw_surface_commit(raw(surface))
        wl_display_flush(display.display)
    }

    func pointerMoved(fx: Int32, fy: Int32) {
        delegate?.pointerMoved(x: Double(fx) / 256.0, y: Double(fy) / 256.0)
    }

    func pointerButton(pressed: Bool) {
        delegate?.pointerButton(pressed: pressed)
    }

    // Compositor dismissed us (outside click). Tear down our proxies first, then
    // notify — the delegate may drop its last strong ref to us during this call.
    private func handleDone() {
        guard !tornDown else { return }
        teardown()
        delegate?.popupDismissed()
    }

    /// Programmatic close (e.g. after choosing an item). Idempotent.
    public func close() { teardown() }

    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if display.activePopup === self { display.activePopup = nil }
        for b in buffers { b.destroy() }
        buffers.removeAll()
        aw_xdg_popup_destroy(raw(xdgPopup))
        aw_proxy_destroy(raw(xdgSurface))
        aw_proxy_destroy(raw(surface))
        wl_display_flush(display.display)
    }

    deinit { teardown() }
}
