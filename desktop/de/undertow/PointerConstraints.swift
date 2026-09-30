// PointerConstraints — relative-pointer-v1 and pointer-constraints-v1 (BACKLOG U.6).
//
// A game turns the camera by moving the mouse; Blender rotates the view the
// same way. Neither wants the pointer to *go* anywhere: they want how far the
// mouse moved, and a pointer that stays put however far it moves. Two
// protocols between them, and without them every such application either
// cannot turn at all or turns until the pointer reaches the edge of the display
// and stops.
//
//   - **relative-pointer**: every motion is also sent as a delta — accelerated
//     and not — to the client with the pointer, even at the edge of the
//     display, where the pointer itself can go no further;
//   - **pointer-constraints**: a client may LOCK the pointer (it does not move
//     at all; only deltas arrive) or CONFINE it to a region of its surface.
//
// When a constraint takes effect is the compositor's call. The rules here, as
// sway keeps them: a constraint is active while its surface has the pointer
// AND belongs to the focused window — a lock must not survive ⌘-Tab, or the
// person cannot get their pointer back — and it starts only once the pointer
// is inside the constraint's region. A lock may carry a cursor-position hint:
// where the client drew its own cursor while locked; when the lock ends, the
// real pointer goes there, so it does not jump back to where the lock began.
//
// A move or resize grab owns the pointer, constraint or not: the person
// dragging a title bar is not playing the game.

import CWlroots
import CPixman

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class ConstraintEntry {
    let constraint: UnsafeMutablePointer<wlr_pointer_constraint_v1>
    var listeners: [UnsafeMutablePointer<tw_listener>?] = []
    init(_ c: UnsafeMutablePointer<wlr_pointer_constraint_v1>) { constraint = c }
    deinit { for l in listeners { tw_listener_free(l) } }
}

public final class PointerConstraints {
    private unowned let compositor: Compositor
    private let seat: UnsafeMutablePointer<wlr_seat>
    private let relative: UnsafeMutablePointer<wlr_relative_pointer_manager_v1>
    private let manager: UnsafeMutablePointer<wlr_pointer_constraints_v1>
    private var entries: [ConstraintEntry] = []
    private var listeners: [UnsafeMutablePointer<tw_listener>?] = []
    /// The constraint in force, if any.
    private(set) var active: UnsafeMutablePointer<wlr_pointer_constraint_v1>?
    public var isActive: Bool { active != nil }

    /// For the log a test reads. `held` counts motions a constraint changed:
    /// swallowed by a lock, or pulled back into a confinement.
    public private(set) var locks = 0, confines = 0, held = 0, warps = 0

    init?(compositor: Compositor, seat: UnsafeMutablePointer<wlr_seat>) {
        guard let r = wlr_relative_pointer_manager_v1_create(compositor.session.display),
              let m = wlr_pointer_constraints_v1_create(compositor.session.display) else { return nil }
        self.compositor = compositor
        self.seat = seat
        relative = r
        manager = m
        let me = Unmanaged.passUnretained(self).toOpaque()
        listeners.append(tw_listen(&m.pointee.events.new_constraint, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<PointerConstraints>.fromOpaque(ctx).takeUnretainedValue()
                .newConstraint(data.assumingMemoryBound(to: wlr_pointer_constraint_v1.self))
        }, me))
    }

    deinit { for l in listeners { tw_listener_free(l) } }

    private func newConstraint(_ c: UnsafeMutablePointer<wlr_pointer_constraint_v1>) {
        let e = ConstraintEntry(c)
        let me = Unmanaged.passUnretained(self).toOpaque()
        // The region is double-buffered: it changes on the surface's commit.
        e.listeners.append(tw_listen(&c.pointee.events.set_region, { ctx, _ in
            guard let ctx else { return }
            Unmanaged<PointerConstraints>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, me))
        e.listeners.append(tw_listen(&c.pointee.events.destroy, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<PointerConstraints>.fromOpaque(ctx).takeUnretainedValue()
                .constraintGone(data.assumingMemoryBound(to: wlr_pointer_constraint_v1.self))
        }, me))
        entries.append(e)
        // It may apply at once: the pointer is often already over the window
        // that asks (a game locks when clicked).
        refresh()
    }

    private func constraintGone(_ c: UnsafeMutablePointer<wlr_pointer_constraint_v1>) {
        if active == c {
            active = nil
            warpToHint(c)
        }
        // Off both signals here: wlroots 0.19 asserts every listener on a
        // destroyed object is gone (HANDOFF §2.82). The entry's deinit frees
        // them; removal during the emit is safe.
        entries.removeAll { $0.constraint == c }
    }

    // MARK: - Motion

    /// Every motion, as a delta, to whoever has the pointer — before any
    /// constraint decides where the pointer itself goes.
    func sendRelative(dx: Double, dy: Double, unaccelDX: Double, unaccelDY: Double, timeMsec: UInt32) {
        wlr_relative_pointer_manager_v1_send_relative_motion(relative, seat, UInt64(timeMsec) * 1000,
                                                             dx, dy, unaccelDX, unaccelDY)
    }

    /// Where a motion from the cursor toward (x, y) goes, in layout
    /// coordinates; nil when it goes nowhere — the pointer is locked.
    func constrain(fromX: Double, fromY: Double, toX x: Double, toY y: Double) -> (Double, Double)? {
        guard let c = active, let (ox, oy) = origin(of: c, cursorX: fromX, cursorY: fromY) else { return (x, y) }
        if c.pointee.type == WLR_POINTER_CONSTRAINT_V1_LOCKED { held += 1; return nil }
        let (lx, ly) = (x - ox, y - oy)
        if contains(c, lx, ly) { return (x, y) }
        // Outside: the nearest point of the region, box by box.
        var n: Int32 = 0
        guard let boxes = pixman_region32_rectangles(&c.pointee.region, &n), n > 0 else {
            held += 1
            return (fromX, fromY)
        }
        var best = (fromX - ox, fromY - oy), bestD = Double.infinity
        for i in 0..<Int(n) {
            let b = boxes[i]
            let cx = min(max(lx, Double(b.x1)), Double(b.x2) - 1)
            let cy = min(max(ly, Double(b.y1)), Double(b.y2) - 1)
            let d = (cx - lx) * (cx - lx) + (cy - ly) * (cy - ly)
            if d < bestD { bestD = d; best = (cx, cy) }
        }
        held += 1
        return (ox + best.0, oy + best.1)
    }

    // MARK: - Activation

    /// Bring the constraint in force up to date with who has the pointer and
    /// the keyboard. Called after every motion, on every focus change, and
    /// when a constraint arrives or its region changes.
    func refresh() {
        let ps = seat.pointee.pointer_state
        var want: UnsafeMutablePointer<wlr_pointer_constraint_v1>?
        if let s = ps.focused_surface, focused(s),
           let c = wlr_pointer_constraints_v1_constraint_for_surface(manager, s, seat),
           c == active || contains(c, ps.sx, ps.sy) {
            want = c
        }
        guard want != active else { return }
        if let a = active {
            active = nil
            warpToHint(a)
            // May destroy it (a oneshot constraint): constraintGone then finds
            // it no longer active.
            wlr_pointer_constraint_v1_send_deactivated(a)
        }
        if let w = want {
            active = w
            if w.pointee.type == WLR_POINTER_CONSTRAINT_V1_LOCKED { locks += 1 } else { confines += 1 }
            wlr_pointer_constraint_v1_send_activated(w)
        }
    }

    /// Whether `s` is part of the window with keyboard focus.
    private func focused(_ s: UnsafeMutablePointer<wlr_surface>) -> Bool {
        guard let t = compositor.seat?.focused else { return false }
        return wlr_surface_get_root_surface(s) == t.surface
    }

    private func contains(_ c: UnsafeMutablePointer<wlr_pointer_constraint_v1>, _ x: Double, _ y: Double) -> Bool {
        pixman_region32_contains_point(&c.pointee.region, Int32(floor(x)), Int32(floor(y)), nil) != 0
    }

    /// The constraint's surface's origin in layout coordinates — from where
    /// the seat last told it the pointer was. Nil unless it has the pointer.
    private func origin(of c: UnsafeMutablePointer<wlr_pointer_constraint_v1>,
                        cursorX: Double, cursorY: Double) -> (Double, Double)? {
        let ps = seat.pointee.pointer_state
        guard ps.focused_surface == c.pointee.surface else { return nil }
        return (cursorX - ps.sx, cursorY - ps.sy)
    }

    /// A lock ending: the pointer goes where the client said it drew it.
    private func warpToHint(_ c: UnsafeMutablePointer<wlr_pointer_constraint_v1>) {
        guard c.pointee.type == WLR_POINTER_CONSTRAINT_V1_LOCKED,
              c.pointee.current.cursor_hint.enabled,
              let s = compositor.seat,
              let (ox, oy) = origin(of: c, cursorX: s.cursorX, cursorY: s.cursorY) else { return }
        let hx = c.pointee.current.cursor_hint.x, hy = c.pointee.current.cursor_hint.y
        s.warpCursor(to: ox + hx, oy + hy, surfaceX: hx, surfaceY: hy)
        warps += 1
    }
}
