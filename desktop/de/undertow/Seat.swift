// Undertow — input (PHASE6.md P6.4).
//
// The compositor's half of everything `Surface`/`Aqua` have spoken as a *client*
// since Phase 1: a `wl_seat`, a cursor, focus, and the routing that decides
// which surface a click belongs to. The client half being four phases old is
// what makes this pass tractable — the assertions write themselves, because the
// Finder already knows exactly how it should behave.
//
// **Input devices arrive through the virtual-input protocols**, not libinput.
// A headless backend has no devices, and `wlr-virtual-pointer` /
// `virtual-keyboard` are how the harness has driven sway since Phase 1 — so
// implementing their *server* side means `abyss/tests/vpointer.c` and
// `vkeyboard.c` drive `undertow` completely unchanged. Real libinput devices
// come with real hardware in Phase 4 and land in the same `newInput` path.
//
// **The cursor is compositor-drawn.** DESKTOP.md §3/§9 makes that a latency
// argument — the pointer must not round-trip to a client — and it is also the
// only way a headless capture can show where the pointer is. It is a plain
// rectangle for now; a real cursor theme belongs with the hardware cursor plane
// in Phase 4.

import CWlroots

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A window's rectangle, for hit-testing.
public struct WindowRect: Equatable, Sendable {
    public var x, y, width, height: Int32
    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Where the pointer is, and what is under it — as pure functions.
///
/// Extracted from the seat so they can be tested without a compositor, a client
/// or a display. This is §2.9's discipline (one pure function feeds both the
/// drawing and the hit-testing) applied a layer down: the rule that decides
/// which window a click belongs to is the kind of thing that must not need a
/// running desktop to verify.
public enum PointerRouting {
    /// Clamp a position to the output. A cursor that can leave the screen can
    /// address a surface nobody can see.
    public static func clamp(_ x: Double, _ y: Double,
                             width: Double, height: Double) -> (Double, Double) {
        (min(max(x, 0), max(width - 1, 0)), min(max(y, 0), max(height - 1, 0)))
    }

    /// The index of the topmost rect containing the point, and the point in its
    /// local coordinates. `rects` is bottom-to-top, so the search runs
    /// backwards: the top window wins, which is the whole reason raising a
    /// window changes what a click hits.
    public static func hit(_ x: Double, _ y: Double, rects: [WindowRect])
        -> (index: Int, localX: Double, localY: Double)? {
        for i in stride(from: rects.count - 1, through: 0, by: -1) {
            let r = rects[i]
            let lx = x - Double(r.x), ly = y - Double(r.y)
            if lx >= 0, ly >= 0, lx < Double(r.width), ly < Double(r.height) {
                return (i, lx, ly)
            }
        }
        return nil
    }
}

/// The seat: pointer, keyboard, focus, and the routing between them.
public final class Seat {
    private let seat: UnsafeMutablePointer<wlr_seat>
    private unowned let compositor: Compositor
    private var listeners: [UnsafeMutablePointer<tw_listener>?] = []

    /// Cursor position in output coordinates. Ours, not a client's.
    public private(set) var cursorX: Double = 0
    public private(set) var cursorY: Double = 0
    public var cursorVisible = true

    private let outputWidth: Double
    private let outputHeight: Double
    private var capabilities: UInt32 = 0

    /// The toplevel with keyboard focus, if any.
    public private(set) weak var focused: Toplevel?

    public init(compositor: Compositor, outputWidth: Int32, outputHeight: Int32) throws {
        self.compositor = compositor
        self.outputWidth = Double(outputWidth)
        self.outputHeight = Double(outputHeight)
        cursorX = Double(outputWidth) / 2
        cursorY = Double(outputHeight) / 2

        guard let s = wlr_seat_create(compositor.session.display, "seat0") else {
            throw BackendError.noGlobals("wl_seat")
        }
        seat = s
        compositor.seat = self

        let me = Unmanaged.passUnretained(self).toOpaque()

        // Real devices, when there are any (Phase 4).
        listeners.append(tw_listen(&compositor.session.backend.pointee.events.new_input,
                                   { ctx, data in
            guard let ctx, let data else { return }
            let seat = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            seat.attach(device: data.assumingMemoryBound(to: wlr_input_device.self))
        }, me))

        // Virtual devices — how the harness drives us, exactly as it drives sway.
        guard let vp = wlr_virtual_pointer_manager_v1_create(compositor.session.display)
        else { throw BackendError.noGlobals("zwlr_virtual_pointer_manager_v1") }
        listeners.append(tw_listen(&vp.pointee.events.new_virtual_pointer, { ctx, data in
            guard let ctx, let data else { return }
            let seat = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let ev = data.assumingMemoryBound(to: wlr_virtual_pointer_v1_new_pointer_event.self)
            guard let pointer = ev.pointee.new_pointer else { return }
            seat.attach(pointer: &pointer.pointee.pointer)
        }, me))

        guard let vk = wlr_virtual_keyboard_manager_v1_create(compositor.session.display)
        else { throw BackendError.noGlobals("zwp_virtual_keyboard_manager_v1") }
        listeners.append(tw_listen(&vk.pointee.events.new_virtual_keyboard, { ctx, data in
            guard let ctx, let data else { return }
            let seat = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let vkbd = data.assumingMemoryBound(to: wlr_virtual_keyboard_v1.self)
            seat.attach(keyboard: &vkbd.pointee.keyboard)
        }, me))
    }

    deinit {
        for l in listeners { tw_listener_free(l) }
    }

    // MARK: - Devices

    private func attach(device: UnsafeMutablePointer<wlr_input_device>) {
        switch device.pointee.type {
        case WLR_INPUT_DEVICE_POINTER:
            if let p = wlr_pointer_from_input_device(device) { attach(pointer: p) }
        case WLR_INPUT_DEVICE_KEYBOARD:
            if let k = wlr_keyboard_from_input_device(device) { attach(keyboard: k) }
        default:
            break
        }
    }

    private func attach(pointer: UnsafeMutablePointer<wlr_pointer>) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        listeners.append(tw_listen(&pointer.pointee.events.motion_absolute, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_pointer_motion_absolute_event.self)
            // The protocol reports 0…1 across the output.
            s.moveCursor(to: e.pointee.x * s.outputWidth, e.pointee.y * s.outputHeight,
                         timeMsec: e.pointee.time_msec)
        }, me))
        listeners.append(tw_listen(&pointer.pointee.events.motion, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_pointer_motion_event.self)
            s.moveCursor(to: s.cursorX + e.pointee.delta_x, s.cursorY + e.pointee.delta_y,
                         timeMsec: e.pointee.time_msec)
        }, me))
        listeners.append(tw_listen(&pointer.pointee.events.button, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_pointer_button_event.self)
            s.button(e.pointee.button, state: e.pointee.state,
                     timeMsec: e.pointee.time_msec)
        }, me))
        listeners.append(tw_listen(&pointer.pointee.events.axis, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_pointer_axis_event.self)
            wlr_seat_pointer_notify_axis(s.seat, e.pointee.time_msec,
                                         e.pointee.orientation, e.pointee.delta,
                                         e.pointee.delta_discrete, e.pointee.source,
                                         e.pointee.relative_direction)
            wlr_seat_pointer_notify_frame(s.seat)
        }, me))
        addCapability(UInt32(WL_SEAT_CAPABILITY_POINTER.rawValue))
    }

    private func attach(keyboard: UnsafeMutablePointer<wlr_keyboard>) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        listeners.append(tw_listen(&keyboard.pointee.events.key, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_keyboard_key_event.self)
            wlr_seat_keyboard_notify_key(s.seat, e.pointee.time_msec,
                                         e.pointee.keycode, UInt32(e.pointee.state.rawValue))
        }, me))
        listeners.append(tw_listen(&keyboard.pointee.events.modifiers, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let kbd = data.assumingMemoryBound(to: wlr_keyboard.self)
            wlr_seat_keyboard_notify_modifiers(s.seat, &kbd.pointee.modifiers)
        }, me))
        // The seat carries one active keyboard; its keymap is what clients are
        // told. A virtual keyboard brings its own, from the client's fd.
        wlr_seat_set_keyboard(seat, keyboard)
        addCapability(UInt32(WL_SEAT_CAPABILITY_KEYBOARD.rawValue))
    }

    private func addCapability(_ cap: UInt32) {
        capabilities |= cap
        wlr_seat_set_capabilities(seat, capabilities)
    }

    // MARK: - Routing

    /// The topmost window under a point, and the point in its surface's
    /// coordinates. Front to back, because the top window wins.
    public func toplevel(at x: Double, _ y: Double) -> (Toplevel, Double, Double)? {
        let windows = compositor.mappedToplevels
        let rects = windows.map {
            WindowRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        guard let h = PointerRouting.hit(x, y, rects: rects) else { return nil }
        return (windows[h.index], h.localX, h.localY)
    }

    private func moveCursor(to x: Double, _ y: Double, timeMsec: UInt32) {
        (cursorX, cursorY) = PointerRouting.clamp(x, y, width: outputWidth,
                                                  height: outputHeight)

        // A drag in progress owns the pointer: the window follows it, and no
        // client is told about the motion. That is what stops a drag from
        // "falling through" onto whatever the pointer passes over.
        if compositor.moving != nil {
            compositor.updateMove(cursorX: cursorX, cursorY: cursorY)
            return
        }

        guard let (t, lx, ly) = toplevel(at: cursorX, cursorY) else {
            // Off every window: the pointer belongs to the desktop, and a client
            // that still thought it had the pointer must be told it does not.
            wlr_seat_pointer_clear_focus(seat)
            return
        }
        // `notify_enter` is idempotent — wlroots only sends the protocol enter
        // when the surface actually changes — so this is the whole of
        // enter/leave bookkeeping.
        wlr_seat_pointer_notify_enter(seat, t.surface, lx, ly)
        wlr_seat_pointer_notify_motion(seat, timeMsec, lx, ly)
        wlr_seat_pointer_notify_frame(seat)
    }

    private func button(_ button: UInt32, state: wl_pointer_button_state,
                        timeMsec: UInt32) {
        // Releasing the button ends a drag, and the window's new position is
        // remembered there.
        if state == WL_POINTER_BUTTON_STATE_RELEASED, compositor.moving != nil {
            compositor.endMove()
            _ = wlr_seat_pointer_notify_button(seat, timeMsec, button, state)
            wlr_seat_pointer_notify_frame(seat)
            return
        }
        // Click to focus and raise, before the click is delivered: the client
        // should receive the press already focused, which is what makes
        // click-through-to-a-control behave the way a Mac user expects.
        if state == WL_POINTER_BUTTON_STATE_PRESSED,
           let (t, _, _) = toplevel(at: cursorX, cursorY) {
            focus(t)
        }
        _ = wlr_seat_pointer_notify_button(seat, timeMsec, button, state)
        wlr_seat_pointer_notify_frame(seat)
    }

    /// Give a window keyboard focus and raise it to the top of the stack.
    public func focus(_ t: Toplevel) {
        compositor.raise(t)
        guard focused !== t else { return }
        focused = t
        guard let kbd = wlr_seat_get_keyboard(seat) else {
            // No keyboard on the seat yet: focus is still ours to record, and
            // the client will be told when one arrives.
            return
        }
        wlr_seat_keyboard_notify_enter(seat, t.surface,
                                       &kbd.pointee.keycodes.0,
                                       kbd.pointee.num_keycodes,
                                       &kbd.pointee.modifiers)
    }

    /// Draw the cursor. Called after the scene, so it is on top of everything.
    public func renderCursor(into pass: OpaquePointer) {
        guard cursorVisible else { return }
        var opts = wlr_render_rect_options()
        opts.box = wlr_box(x: Int32(cursorX), y: Int32(cursorY), width: 10, height: 16)
        opts.color = wlr_render_color(r: 1, g: 1, b: 1, a: 1)
        opts.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED
        wlr_render_pass_add_rect(pass, &opts)
    }
}
