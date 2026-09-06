// Surface.Popup — a grabbing xdg-popup child surface (the basis of a menu).
//
// A popup is a second wl_surface parented to a rect in an owning surface, backed
// by its own shm buffers. `grab` makes the compositor route input to it and emit
// `popup_done` when the user clicks outside, which is how a menu dismisses.
// Display routes pointer events to whichever surface the pointer entered.
//
// The parent can be an xdg-shell toplevel (Window) or a wlr-layer-shell surface
// (the menu bar / Dock). Both build the same xdg_popup; only the parenting call
// differs — an xdg toplevel uses xdg_surface.get_popup(parent), a layer surface
// makes a parent-less xdg_popup then zwlr_layer_surface_v1.get_popup(). The two
// convenience inits create the proxies and hand them to one designated init that
// wires listeners, grabs, and commits.

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

    /// Designated init: given the created (surface, xdg_surface, xdg_popup),
    /// wire the configure/done listeners, grab input with the last pointer
    /// serial, and commit to trigger the first configure.
    private init(display: Display, surface: OpaquePointer, xdgSurface: OpaquePointer,
                 xdgPopup: OpaquePointer, seat: OpaquePointer, scale: Int32,
                 width: Int32, height: Int32, delegate: PopupDelegate) {
        self.display = display
        self.surface = surface
        self.xdgSurface = xdgSurface
        self.xdgPopup = xdgPopup
        self.scale = scale
        self.logicalW = width
        self.logicalH = height
        self.delegate = delegate

        let me = Unmanaged.passUnretained(self).toOpaque()

        var xsl = xdg_surface_listener()
        xsl.configure = { data, _, serial in
            guard let data else { return }
            let p = Unmanaged<Popup>.fromOpaque(data).takeUnretainedValue()
            p.applyConfigure(serial: serial)
        }
        display.addListener(to: xdgSurface, listener: xsl, data: me)

        var pl = xdg_popup_listener()
        pl.configure = { _, _, _, _, _, _ in }  // position/size; we use our own
        pl.popup_done = { data, _ in
            guard let data else { return }
            let p = Unmanaged<Popup>.fromOpaque(data).takeUnretainedValue()
            p.handleDone()
        }
        display.addListener(to: xdgPopup, listener: pl, data: me)

        // Grab input using the serial of the click that opened us, so the
        // compositor dismisses on an outside click.
        aw_xdg_popup_grab(raw(xdgPopup), raw(seat), display.lastPointerSerial)
        aw_surface_commit(raw(surface))  // triggers the initial configure
        wl_display_flush(display.display)

        display.activePopup = self
    }

    /// A popup anchored to a rect in an xdg-shell `Window`'s logical coordinates.
    convenience init?(parent: Window, anchorX: Int32, anchorY: Int32, anchorW: Int32,
                      anchorH: Int32, width: Int32, height: Int32, delegate: PopupDelegate) {
        let display = parent.display
        guard let seat = display.seat,
              let (surf, xs, pos) = Popup.makeSurfaceAndPositioner(
                  display: display, anchorX: anchorX, anchorY: anchorY,
                  anchorW: anchorW, anchorH: anchorH, width: width, height: height)
        else { return nil }
        guard let pop = opt(aw_xdg_surface_get_popup(
            raw(xs), raw(parent.xdgSurface), raw(pos))) else {
            aw_xdg_positioner_destroy(raw(pos))
            return nil
        }
        aw_xdg_positioner_destroy(raw(pos))
        self.init(display: display, surface: surf, xdgSurface: xs, xdgPopup: pop,
                  seat: seat, scale: parent.scale, width: width, height: height,
                  delegate: delegate)
    }

    /// A popup anchored to a rect in a `LayerSurface`'s logical coordinates (the
    /// menu bar's or Dock's menus). The xdg_popup is created parent-less, then
    /// parented to the layer surface.
    convenience init?(layerParent: LayerSurface, anchorX: Int32, anchorY: Int32,
                      anchorW: Int32, anchorH: Int32, width: Int32, height: Int32,
                      delegate: PopupDelegate) {
        let display = layerParent.display
        guard let seat = display.seat,
              let (surf, xs, pos) = Popup.makeSurfaceAndPositioner(
                  display: display, anchorX: anchorX, anchorY: anchorY,
                  anchorW: anchorW, anchorH: anchorH, width: width, height: height)
        else { return nil }
        guard let pop = opt(aw_xdg_surface_get_popup_no_parent(raw(xs), raw(pos))) else {
            aw_xdg_positioner_destroy(raw(pos))
            return nil
        }
        aw_xdg_positioner_destroy(raw(pos))
        aw_layer_surface_get_popup(raw(layerParent.layerSurface), raw(pop))
        self.init(display: display, surface: surf, xdgSurface: xs, xdgPopup: pop,
                  seat: seat, scale: layerParent.scale, width: width, height: height,
                  delegate: delegate)
    }

    /// Shared: create the popup's wl_surface + xdg_surface and a configured
    /// positioner (drops below the anchor rect, left-aligned, kept on-screen).
    /// Returns nil on any failure (caller destroys nothing — nothing partial
    /// escapes). The caller destroys the positioner after creating the popup.
    private static func makeSurfaceAndPositioner(
        display: Display, anchorX: Int32, anchorY: Int32, anchorW: Int32,
        anchorH: Int32, width: Int32, height: Int32
    ) -> (surface: OpaquePointer, xdgSurface: OpaquePointer, positioner: OpaquePointer)? {
        guard let compositor = display.compositor, let wmBase = display.wmBase,
              let surf = opt(aw_compositor_create_surface(raw(compositor))),
              let xs = opt(aw_xdg_wm_base_get_xdg_surface(raw(wmBase), raw(surf))),
              let pos = opt(aw_xdg_wm_base_create_positioner(raw(wmBase)))
        else { return nil }
        aw_xdg_positioner_set_size(raw(pos), width, height)
        aw_xdg_positioner_set_anchor_rect(raw(pos), anchorX, anchorY, anchorW, anchorH)
        aw_xdg_positioner_set_anchor(raw(pos), kAnchorBottomLeft)
        aw_xdg_positioner_set_gravity(raw(pos), kGravityBottomRight)
        aw_xdg_positioner_set_constraint_adjustment(
            raw(pos), kConstraintSlideX | kConstraintSlideY | kConstraintFlipY)
        return (surf, xs, pos)
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
        aw_xdg_surface_destroy(raw(xdgSurface))
        aw_surface_destroy(raw(surface))
        wl_display_flush(display.display)
    }

    deinit { teardown() }
}
