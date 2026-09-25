// Popups — menus, under our own compositor, for the first time (PHASE10.md P10.4).
//
// **undertow had never handled an `xdg_popup`.** wlroots speaks the protocol
// and sends a popup its initial configure by itself, so a client's menu
// *mapped* — and then undertow neither drew it, nor hit-tested it, nor sent it
// frame callbacks. Every menu in this tree — the menu bar's dropdowns, the
// Dock's Trash menu, a pop-up button — was a mapped surface nobody could see
// or click, and the client logged "opened" about it in good faith. Every test
// that opened a menu ran under sway, which does all of this. Found when the
// menu bar became real and a click on "New Folder" landed on nothing.
//
// (The first draft of this file also scheduled the initial configure, and
// said that was the missing piece. Removing it changed nothing: wlroots does
// it. The injected fault that *does* break menus is removing the hit-test.)
//
// The grab — and dismissing a popup when the person clicks outside it — is
// wlroots' own too (`wlr_xdg_popup_grab`), driven by the pointer and keyboard
// events the seat already forwards. What a *compositor* owes a popup, and
// undertow did not pay, is: a box to stay inside, a place on screen, a place
// in the paint order and the hit-test, and frame callbacks so it can redraw
// its hover.

import CWlroots

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Where a popup's surface goes, as a pure function (§2.9).
///
/// xdg-shell positions a popup **relative to its parent's window geometry**,
/// and its own surface may carry a window-geometry offset of its own (a
/// shadow, say). So: the parent's surface origin, plus the parent's geometry
/// offset, plus the popup's position, minus the popup's own geometry offset.
public enum PopupGeometry {
    public static func surfaceOrigin(parentSurfaceX px: Int32, parentSurfaceY py: Int32,
                                     parentGeometry pg: (x: Int32, y: Int32),
                                     popupPosition pp: (x: Int32, y: Int32),
                                     popupGeometry og: (x: Int32, y: Int32)) -> (x: Int32, y: Int32) {
        (px &+ pg.x &+ pp.x &- og.x, py &+ pg.y &+ pp.y &- og.y)
    }
}

public final class PopupSurface {
    let popup: UnsafeMutablePointer<wlr_xdg_popup>
    public let surface: UnsafeMutablePointer<wlr_surface>
    public private(set) var mapped = false
    private unowned let compositor: Compositor
    private var listeners: [UnsafeMutablePointer<tw_listener>?] = []

    init(_ popup: UnsafeMutablePointer<wlr_xdg_popup>, compositor: Compositor) {
        self.popup = popup
        self.surface = popup.pointee.base.pointee.surface
        self.compositor = compositor
        let me = Unmanaged.passUnretained(self).toOpaque()
        listeners.append(tw_listen(&surface.pointee.events.commit, { ctx, _ in
            guard let ctx else { return }
            let p = Unmanaged<PopupSurface>.fromOpaque(ctx).takeUnretainedValue()
            // Keep it on the output. wlroots sends the initial configure on
            // its own; unconstraining schedules another with the position
            // adjusted, before the client has drawn anything.
            if p.popup.pointee.base.pointee.initial_commit { p.unconstrain() }
        }, me))
        listeners.append(tw_listen(&surface.pointee.events.map, { ctx, _ in
            guard let ctx else { return }
            let p = Unmanaged<PopupSurface>.fromOpaque(ctx).takeUnretainedValue()
            p.mapped = true
            p.compositor.popupsMapped += 1
        }, me))
        listeners.append(tw_listen(&surface.pointee.events.unmap, { ctx, _ in
            guard let ctx else { return }
            Unmanaged<PopupSurface>.fromOpaque(ctx).takeUnretainedValue().mapped = false
        }, me))
        listeners.append(tw_listen(&popup.pointee.events.destroy, { ctx, _ in
            guard let ctx else { return }
            let p = Unmanaged<PopupSurface>.fromOpaque(ctx).takeUnretainedValue()
            p.mapped = false
            p.compositor.forgetPopup(p)
        }, me))
    }

    func teardown() {
        for l in listeners { tw_listener_free(l) }
        listeners.removeAll()
    }

    /// The parent's surface origin and window-geometry offset, in output
    /// coordinates — a window, a layer surface, or another popup.
    private var parentFrame: (x: Int32, y: Int32, gx: Int32, gy: Int32)? {
        guard let parent = popup.pointee.parent else { return nil }
        if let t = compositor.toplevels.first(where: { $0.surface == parent }) {
            let g = t.xdgToplevel.pointee.base.pointee.current.geometry
            return (t.x, t.y, g.x, g.y)
        }
        if let l = compositor.layers.first(where: { $0.surface == parent }) {
            return (l.rect.x, l.rect.y, 0, 0)   // a layer surface is its geometry
        }
        if let p = compositor.popups.first(where: { $0.surface == parent }),
           let o = p.origin {
            let g = p.popup.pointee.base.pointee.current.geometry
            return (o.x, o.y, g.x, g.y)
        }
        return nil
    }

    /// This popup's surface origin in output coordinates, or nil while its
    /// parent is not one we know.
    public var origin: (x: Int32, y: Int32)? {
        guard let f = parentFrame else { return nil }
        let pos = popup.pointee.current.geometry
        let own = popup.pointee.base.pointee.current.geometry
        return PopupGeometry.surfaceOrigin(parentSurfaceX: f.x, parentSurfaceY: f.y,
                                           parentGeometry: (f.gx, f.gy),
                                           popupPosition: (pos.x, pos.y),
                                           popupGeometry: (own.x, own.y))
    }

    public var width: Int32 { surface.pointee.current.width }
    public var height: Int32 { surface.pointee.current.height }

    /// Keep it on the output: the box is the output, in the coordinates the
    /// popup is positioned in — its parent's window geometry. A menu opened
    /// near the right edge flips or slides, as the positioner asked, instead of
    /// hanging off the screen.
    private func unconstrain() {
        guard let f = parentFrame else { return }
        var box = wlr_box(x: -(f.x &+ f.gx), y: -(f.y &+ f.gy),
                          width: compositor.outputWidth, height: compositor.outputHeight)
        wlr_xdg_popup_unconstrain_from_box(popup, &box)
    }
}

extension Compositor {
    /// Popups that can be seen, in creation order — a child after its parent,
    /// which is also the order they must be painted in.
    public var mappedPopups: [PopupSurface] {
        popups.filter { $0.mapped && wlr_surface_has_buffer($0.surface) && $0.origin != nil }
    }
}
