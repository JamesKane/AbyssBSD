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
// only way a headless capture can show where the pointer is. What it looks like
// (U.7) is the client's to say while it has the pointer — a shape by name
// (cursor-shape-v1), a surface of its own (wl_pointer.set_cursor), or none —
// and the theme's otherwise: the arrow over the desktop, sizing arrows on a
// frame's edges. Shapes are the theme's draw lists (`cursor.*`, CursorImages).
// The hardware cursor plane is still Phase 4's.

import AquaDraw
import CWlroots
import PoolConfig
import Install
import Spawn

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
    /// text-input-v3 and input-method-v2 (U.5): the relay between a field and
    /// an input method. Nil only if wlroots could not make the globals.
    public private(set) var textInput: TextInputRelay?
    /// relative-pointer and pointer-constraints (U.6): deltas to the client
    /// with the pointer, and a pointer it may lock or confine.
    public private(set) var pointerConstraints: PointerConstraints?
    private unowned let compositor: Compositor
    private var listeners: [UnsafeMutablePointer<tw_listener>?] = []
    /// Listeners that belong to **one input device**, keyed by that device.
    ///
    /// They cannot live as long as the seat does. A virtual pointer is a client
    /// resource: when that client disconnects, wlroots destroys the device and
    /// asserts that nothing is still listening to it — so a listener we never
    /// removed takes the whole compositor down with it, at the moment a test
    /// harness lets go of its input (HANDOFF §2.41).
    private var deviceListeners: [UnsafeMutableRawPointer:
                                    [UnsafeMutablePointer<tw_listener>?]] = [:]

    /// Cursor position in output coordinates. Ours, not a client's.
    public private(set) var cursorX: Double = 0
    public private(set) var cursorY: Double = 0
    public var cursorVisible = true

    /// What the pointer looks like (U.7).
    public enum CursorImage: Equatable {
        /// A theme shape, by cursor-shape-v1's (CSS's) name.
        case shape(String)
        /// A surface the client with the pointer gave us.
        case client
        /// The client with the pointer asked for none.
        case hidden
    }
    public private(set) var cursorImage: CursorImage = .shape("default")
    private var cursorSurface: UnsafeMutablePointer<wlr_surface>?
    private var cursorHotX: Int32 = 0, cursorHotY: Int32 = 0
    private var cursorSurfaceListeners: [UnsafeMutablePointer<tw_listener>?] = []
    public let cursorImages = CursorImages()
    /// Cursor requests taken, and refused because the client asking did not
    /// have the pointer — for the log a test reads.
    public private(set) var cursorRequests = 0, cursorRefused = 0

    /// The session's keyboard layout (T.2): keyboard.ini's `kbdmap`, or empty
    /// for rc.conf's. Kept so a change is applied once, not every time the
    /// config directory stirs.
    public private(set) var sessionKbdmap = ""
    /// The keyboards whose keymap is ours to change — the ones that had none
    /// of their own. A virtual keyboard brings its own, and keeps it.
    private var keymapped: [UnsafeMutablePointer<wlr_keyboard>] = []
    private var keyboardWatch: Pool.Watcher?
    private var keyboardWatchSource: OpaquePointer?
    /// A stand-in for a hardware keyboard, for a test (`--stand-in-keyboard`).
    private var standIn: UnsafeMutablePointer<wlr_keyboard>?
    private var standInFd: Int32 = -1
    private var standInSource: OpaquePointer?
    private var standInBuffer: [UInt8] = []
    /// What the keyboards type with now, in words — for the log a test reads.
    public private(set) var layoutDescription = ""
    public private(set) var layoutChanges = 0

    // The desktop is the compositor's layout (P14.7a): the pointer ranges over
    // every display, and never into the gaps between them.
    private var capabilities: UInt32 = 0

    /// The toplevel with keyboard focus, if any.
    public private(set) weak var focused: Toplevel?
    /// How many times a client's clipboard offer has been accepted.
    ///
    /// **The positive control for a clipboard test.** "Paste produced no error"
    /// passes on a compositor that discards every copy — which is exactly what
    /// this one did until P9.1. A test that asserts on pasted *bytes* still
    /// cannot tell "nobody copied" from "the copy was dropped"; this can.
    public private(set) var selectionsAccepted = 0
    /// The same for the primary selection (U.9): what is selected, pasted
    /// with the middle button.
    public private(set) var primarySelectionsAccepted = 0
    /// How many drags the compositor has started. The positive control for a
    /// drag test, for the same reason `selectionsAccepted` is one for a copy.
    public private(set) var dragsStarted = 0
    /// The surface being dragged under the cursor, if any.
    var dragIcon: UnsafeMutablePointer<wlr_drag_icon>?
    var dragIconDestroy: UnsafeMutablePointer<tw_listener>?

    public init(compositor: Compositor) throws {
        self.compositor = compositor
        // The middle of the main display.
        let m = compositor.layout.main ?? DisplayBox(name: "", x: 0, y: 0, width: 2, height: 2)
        cursorX = Double(m.x) + Double(m.width) / 2
        cursorY = Double(m.y) + Double(m.height) / 2

        guard let s = wlr_seat_create(compositor.session.display, "seat0") else {
            throw BackendError.noGlobals("wl_seat")
        }
        seat = s
        compositor.seat = self
        textInput = TextInputRelay(compositor: compositor, seat: s)
        pointerConstraints = PointerConstraints(compositor: compositor, seat: s)

        let me = Unmanaged.passUnretained(self).toOpaque()

        // Real devices, when there are any (Phase 4).
        listeners.append(tw_listen(&compositor.session.backend.pointee.events.new_input,
                                   { ctx, data in
            guard let ctx, let data else { return }
            let seat = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            seat.attach(device: data.assumingMemoryBound(to: wlr_input_device.self))
        }, me))
        // And the devices that were there before this seat was (Backend.swift).
        for device in compositor.session.takeStartupInputs() { attach(device: device) }

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

        // **The clipboard, which has never worked for anybody.**
        //
        // `wlr_data_device_manager_create` publishes the global and nothing
        // else. wlroots says so in its own header — *"Compositors should listen
        // to this event and call `wlr_seat_set_selection()` if they want to
        // accept the client's request"* — and until now nothing did, so every
        // `set_selection` was discarded: ours, and the foreign GTK applications
        // Phase 8 exists to serve. No error, no log line, no protocol violation;
        // just a copy that goes nowhere (§2.45's shape, in a protocol).
        //
        // It went unnoticed because no test in this tree had ever copied
        // anything: every live run involving a GTK app exercises the *file
        // chooser*.
        listeners.append(tw_listen(&s.pointee.events.request_set_selection, { ctx, data in
            guard let ctx, let data else { return }
            let seat = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let ev = data.assumingMemoryBound(to: wlr_seat_request_set_selection_event.self)
            // **The serial is checked by wlroots, not by us**, which is the
            // point of routing it back through the seat rather than storing the
            // source ourselves: a client cannot set the clipboard from a serial
            // it was never given.
            wlr_seat_set_selection(seat.seat, ev.pointee.source, ev.pointee.serial)
            seat.selectionsAccepted += 1
        }, me))

        // **The primary selection (U.9)**: X11's other clipboard — select
        // text, middle-click to paste it — which every GTK application
        // offers and Linux users reach for without thinking. The same rule as
        // the clipboard: wlroots checks the serial, and we accept.
        _ = wlr_primary_selection_v1_device_manager_create(compositor.session.display)
        listeners.append(tw_listen(&s.pointee.events.request_set_primary_selection, { ctx, data in
            guard let ctx, let data else { return }
            let seat = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let ev = data.assumingMemoryBound(to: wlr_seat_request_set_primary_selection_event.self)
            wlr_seat_set_primary_selection(seat.seat, ev.pointee.source, ev.pointee.serial)
            seat.primarySelectionsAccepted += 1
        }, me))

        // **Drag and drop (P9.3), which is the selection with a grab on it.**
        //
        // The serial check is the same guard as the clipboard's and is why this
        // is routed through wlroots rather than started ourselves: a drag may
        // only begin from a pointer press the client actually received, so a
        // program cannot start one out of nowhere and collect whatever the
        // pointer passes over.
        listeners.append(tw_listen(&s.pointee.events.request_start_drag, { ctx, data in
            guard let ctx, let data else { return }
            let seat = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let ev = data.assumingMemoryBound(to: wlr_seat_request_start_drag_event.self)
            guard let drag = ev.pointee.drag else { return }
            if wlr_seat_validate_pointer_grab_serial(seat.seat, ev.pointee.origin,
                                                     ev.pointee.serial) {
                wlr_seat_start_pointer_drag(seat.seat, drag, ev.pointee.serial)
                return
            }
            // Refused. **Destroy the source rather than leaking it**: the client
            // is waiting to be told what happened to the drag it offered, and a
            // source nobody owns is a client that hangs on its own cancel.
            if let src = drag.pointee.source { wlr_data_source_destroy(src) }
        }, me))

        // The drag began. From here the pointer belongs to wlroots' drag grab —
        // our `moveCursor` still calls `notify_enter`/`notify_motion`, and the
        // grab turns those into `wl_data_device.enter`/`motion` for whichever
        // surface is under the cursor. That indirection is why nothing in the
        // motion path needed changing.
        listeners.append(tw_listen(&s.pointee.events.start_drag, { ctx, data in
            guard let ctx, let data else { return }
            let seat = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let drag = data.assumingMemoryBound(to: wlr_drag.self)
            seat.dragsStarted += 1
            seat.dragIcon = drag.pointee.icon
            guard let icon = drag.pointee.icon else { return }
            // The icon dies with the drag, and a pointer to a freed surface is
            // a crash on the next frame rather than a missing picture.
            seat.dragIconDestroy = tw_listen(&icon.pointee.events.destroy, { ctx2, _ in
                guard let ctx2 else { return }
                let s2 = Unmanaged<Seat>.fromOpaque(ctx2).takeUnretainedValue()
                s2.dragIcon = nil
                tw_listener_free(s2.dragIconDestroy)
                s2.dragIconDestroy = nil
            }, Unmanaged.passUnretained(seat).toOpaque())
        }, me))

        // **The pointer's picture (U.7).** A client may set it only while it has
        // the pointer — wlroots hands us who asked, and the check is ours: a
        // window in the background must not change the cursor over another.
        listeners.append(tw_listen(&s.pointee.events.request_set_cursor, { ctx, data in
            guard let ctx, let data else { return }
            let seat = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let ev = data.assumingMemoryBound(to: wlr_seat_pointer_request_set_cursor_event.self)
            guard ev.pointee.seat_client == seat.seat.pointee.pointer_state.focused_client else {
                seat.cursorRefused += 1
                return
            }
            seat.cursorRequests += 1
            if let surface = ev.pointee.surface {
                seat.setCursor(surface: surface, hotX: ev.pointee.hotspot_x, hotY: ev.pointee.hotspot_y)
            } else {
                seat.setCursor(.hidden)
            }
        }, me))
        if let shapes = wlr_cursor_shape_manager_v1_create(compositor.session.display, 1) {
            listeners.append(tw_listen(&shapes.pointee.events.request_set_shape, { ctx, data in
                guard let ctx, let data else { return }
                let seat = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
                let ev = data.assumingMemoryBound(to: wlr_cursor_shape_manager_v1_request_set_shape_event.self)
                guard ev.pointee.device_type == WLR_CURSOR_SHAPE_MANAGER_V1_DEVICE_TYPE_POINTER,
                      ev.pointee.seat_client == seat.seat.pointee.pointer_state.focused_client,
                      let name = wlr_cursor_shape_v1_name(ev.pointee.shape) else {
                    seat.cursorRefused += 1
                    return
                }
                seat.cursorRequests += 1
                seat.setCursor(.shape(String(cString: name)))
            }, me))
        }
        // The pointer went to another surface, or to none: the arrow, until
        // whoever has it now says otherwise (a client sets its cursor on enter).
        listeners.append(tw_listen(&s.pointee.pointer_state.events.focus_change, { ctx, data in
            guard let ctx, let data else { return }
            let seat = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let ev = data.assumingMemoryBound(to: wlr_seat_pointer_focus_change_event.self)
            if ev.pointee.old_surface != ev.pointee.new_surface { seat.setCursor(.shape("default")) }
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
        for l in cursorSurfaceListeners { tw_listener_free(l) }
        tw_listener_free(dragIconDestroy)
        for (_, group) in deviceListeners {
            for l in group { tw_listener_free(l) }
        }
    }

    /// A device has gone: drop everything we had attached to it.
    ///
    /// Called from the device's own `destroy` signal, which wlroots emits with
    /// `wl_signal_emit_mutable` precisely so a listener may remove itself here.
    private func forget(device: UnsafeMutableRawPointer) {
        keymapped.removeAll { UnsafeMutableRawPointer($0) == device }
        guard let group = deviceListeners.removeValue(forKey: device) else { return }
        for l in group { tw_listener_free(l) }
    }

    // MARK: - Devices

    private func attach(device: UnsafeMutablePointer<wlr_input_device>) {
        switch device.pointee.type {
        case WLR_INPUT_DEVICE_POINTER:
            if let p = wlr_pointer_from_input_device(device) { attach(pointer: p) }
        case WLR_INPUT_DEVICE_KEYBOARD:
            if let k = wlr_keyboard_from_input_device(device) {
                // Before `attach`, because `wlr_seat_set_keyboard` there is what
                // sends clients the keymap.
                if Seat.giveKeymap(to: k, session: sessionKbdmap) { keymapped.append(k) }
                attach(keyboard: k)
            }
        default:
            break
        }
    }

    private func attach(pointer: UnsafeMutablePointer<wlr_pointer>) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        // Keyed by the `wlr_pointer`, and recovered in the destroy handler with
        // wlroots' own accessor rather than by assuming `base` is the first
        // member of the struct.
        let key = UnsafeMutableRawPointer(pointer)
        var group: [UnsafeMutablePointer<tw_listener>?] = []
        group.append(tw_listen(&pointer.pointee.events.motion_absolute, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_pointer_motion_absolute_event.self)
            // The protocol reports 0…1 across the output.
            // Absolute devices (a tablet, the virtual pointer) span the whole
            // layout, as wlr_cursor maps them.
            // Its delta is from where the pointer is — so, locked, the
            // pointer stays put and each report is a fresh delta from there.
            let b = s.compositor.layout.bounds
            let dx = Double(b.x) + e.pointee.x * Double(b.width) - s.cursorX
            let dy = Double(b.y) + e.pointee.y * Double(b.height) - s.cursorY
            s.motion(dx: dx, dy: dy, unaccelDX: dx, unaccelDY: dy, timeMsec: e.pointee.time_msec)
        }, me))
        group.append(tw_listen(&pointer.pointee.events.motion, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_pointer_motion_event.self)
            s.motion(dx: e.pointee.delta_x, dy: e.pointee.delta_y,
                     unaccelDX: e.pointee.unaccel_dx, unaccelDY: e.pointee.unaccel_dy,
                     timeMsec: e.pointee.time_msec)
        }, me))
        group.append(tw_listen(&pointer.pointee.events.button, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_pointer_button_event.self)
            s.compositor.displaySleep?.activity()
            s.button(e.pointee.button, state: e.pointee.state,
                     timeMsec: e.pointee.time_msec)
        }, me))
        group.append(tw_listen(&pointer.pointee.events.axis, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_pointer_axis_event.self)
            s.compositor.displaySleep?.activity()
            wlr_seat_pointer_notify_axis(s.seat, e.pointee.time_msec,
                                         e.pointee.orientation, e.pointee.delta,
                                         e.pointee.delta_discrete, e.pointee.source,
                                         e.pointee.relative_direction)
            wlr_seat_pointer_notify_frame(s.seat)
        }, me))
        group.append(tw_listen(&pointer.pointee.base.events.destroy, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let device = data.assumingMemoryBound(to: wlr_input_device.self)
            guard let p = wlr_pointer_from_input_device(device) else { return }
            s.forget(device: UnsafeMutableRawPointer(p))
        }, me))
        deviceListeners[key] = group
        addCapability(UInt32(WL_SEAT_CAPABILITY_POINTER.rawValue))
    }

    private func attach(keyboard: UnsafeMutablePointer<wlr_keyboard>) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        let key = UnsafeMutableRawPointer(keyboard)
        var group: [UnsafeMutablePointer<tw_listener>?] = []
        group.append(tw_listen(&keyboard.pointee.events.key, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_keyboard_key_event.self)
            s.compositor.displaySleep?.activity()
            // **The desktop hears it first (P9.5).** Everything the compositor
            // owns — switching windows, closing one, taking a picture of the
            // screen — can only be decided here, because after this line the
            // focused client has it and the compositor never sees it again.
            // The keyboard comes from the seat rather than the closure: a C
            // function pointer cannot capture, and `wlr_seat_set_keyboard`
            // below has already told the seat which device this is.
            // **Locked (PHASE16 P16.2): the lock screen's, and nobody else's.**
            // No keybind fires behind it, and an input method holding a grab
            // must not be handed the keys of a password.
            let locked = s.compositor.isLocked
            if locked { s.breakGrabs() }
            if !locked, let kbd = wlr_seat_get_keyboard(s.seat), s.intercept(key: e, keyboard: kbd) {
                return
            }
            // An input method holding the keyboard composes with it (U.5).
            if !locked, let kbd = wlr_seat_get_keyboard(s.seat), s.textInput?.routeKey(e, keyboard: kbd) == true {
                return
            }
            wlr_seat_keyboard_notify_key(s.seat, e.pointee.time_msec,
                                         e.pointee.keycode, UInt32(e.pointee.state.rawValue))
        }, me))
        group.append(tw_listen(&keyboard.pointee.events.modifiers, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let kbd = data.assumingMemoryBound(to: wlr_keyboard.self)
            if !s.compositor.isLocked, s.textInput?.routeModifiers(kbd) == true { return }
            wlr_seat_keyboard_notify_modifiers(s.seat, &kbd.pointee.modifiers)
        }, me))
        group.append(tw_listen(&keyboard.pointee.base.events.destroy, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let device = data.assumingMemoryBound(to: wlr_input_device.self)
            guard let k = wlr_keyboard_from_input_device(device) else { return }
            s.forget(device: UnsafeMutableRawPointer(k))
        }, me))
        deviceListeners[key] = group

        // The seat carries one active keyboard; its keymap is what clients are
        // told. A virtual keyboard brings its own, from the client's fd; a
        // backend keyboard has had one compiled for it by `giveKeymap`.
        // wlroots drops it from the seat itself when it is destroyed.
        wlr_seat_set_keyboard(seat, keyboard)
        addCapability(UInt32(WL_SEAT_CAPABILITY_KEYBOARD.rawValue))

        // **Deliver the focus we recorded before there was a keyboard to
        // deliver it with.**
        //
        // `focus(_:)` records `focused` and then returns early when the seat has
        // no keyboard, with a comment saying the client will be told when one
        // arrives. Nothing told it. So a window focused before any keyboard
        // existed — which, now that mapping focuses, is *every* window on a
        // machine whose keyboard is a virtual device created afterwards — never
        // received `keyboard.enter` and was deaf for the rest of its life.
        //
        // Invisible until P9.2 wanted to send a ⌘C without clicking first: every
        // harness mode that uses a keyboard drives a pointer beforehand, and a
        // click re-runs `focus` when a keyboard does exist.
        if let s = compositor.isLocked ? lockKeyboardTarget() : focused?.surface {
            wlr_seat_keyboard_notify_enter(seat, s,
                                           &keyboard.pointee.keycodes.0,
                                           keyboard.pointee.num_keycodes,
                                           &keyboard.pointee.modifiers)
        }
    }

    /// Compile a keymap for a keyboard the backend found, and set its repeat.
    ///
    /// **A wlroots backend keyboard can arrive with no keymap.** libinput's
    /// never has one — tinywl compiles one for every keyboard for exactly this
    /// reason — and without it the seat tells
    /// clients nothing: keycodes arrive that no client can turn into text, and
    /// `intercept` finds no keysyms, so no keybind fires either. Invisible for
    /// as long as every keyboard in the harness was a virtual one, which brings
    /// its own keymap from the client that created it; the first real keyboard
    /// is the 12700KF's, on metal.
    ///
    /// Which layout is `compileKeymap`'s to decide.
    @discardableResult
    static func giveKeymap(to keyboard: UnsafeMutablePointer<wlr_keyboard>,
                           rcConf: [String] = Seat.rcConf, session: String = "") -> Bool {
        let name = keyboard.pointee.base.name.map { String(cString: $0) } ?? "a keyboard"
        if let existing = keyboard.pointee.keymap {
            // A backend that already chose one knows better than our default.
            log("\(name) came with keymap \(layoutName(existing)); keeping it")
            return false
        }
        guard let keymap = compileKeymap(rcConf: rcConf, session: session) else {
            log("no keymap compiled (are the xkeyboard-config layouts installed?) — "
                + "this keyboard's keys will reach clients as codes nobody can read")
            return false
        }
        defer { xkb_keymap_unref(keymap) }  // the keyboard takes its own reference
        if !wlr_keyboard_set_keymap(keyboard, keymap) {
            log("wlroots refused the keymap")
            return false
        }
        // wlroots' own defaults, stated rather than assumed: a rate of 0 would
        // tell clients not to repeat at all.
        wlr_keyboard_set_repeat_info(keyboard, 25, 600)
        log("\(name) had no keymap; gave it \(layoutName(keymap))")
        return true
    }

    // MARK: - The session's layout (T.2)

    /// Read keyboard.ini now, and follow it: when it changes, every keyboard
    /// whose keymap is ours types the new layout at once — and the focused
    /// client is sent the new keymap by the seat, which wlroots does when its
    /// keyboard's keymap changes.
    public func followSessionLayout() {
        sessionKbdmap = KeyboardPrefs.load(configDir: compositor.configDir).kbdmap
        describeLayout()
        guard keyboardWatch == nil, let w = try? Pool.Watcher(in: compositor.configDir) else { return }
        keyboardWatch = w
        let loop = wl_display_get_event_loop(compositor.session.display)
        keyboardWatchSource = wl_event_loop_add_fd(loop, w.fileDescriptor, UInt32(WL_EVENT_READABLE), { _, _, data in
            guard let data else { return 0 }
            let s = Unmanaged<Seat>.fromOpaque(data).takeUnretainedValue()
            _ = s.keyboardWatch?.drain()
            let now = KeyboardPrefs.load(configDir: s.compositor.configDir).kbdmap
            if now != s.sessionKbdmap { s.applySessionLayout(now) }
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func applySessionLayout(_ kbdmap: String) {
        sessionKbdmap = kbdmap
        layoutChanges += 1
        guard let keymap = Seat.compileKeymap(session: kbdmap) else { return }
        defer { xkb_keymap_unref(keymap) }
        for k in keymapped { _ = wlr_keyboard_set_keymap(k, keymap) }
        describeLayout()
        Seat.log("keyboard layout is now \(layoutDescription), on \(keymapped.count) keyboard(s)")
    }

    private func describeLayout() {
        let (source, name): (String, String) =
            getenv("XKB_DEFAULT_LAYOUT") != nil ? ("environment", String(cString: getenv("XKB_DEFAULT_LAYOUT")))
            : !sessionKbdmap.isEmpty ? ("keyboard.ini", Keymaps.displayName(forKbdmap: sessionKbdmap))
            : Keymaps.configured().map { ("rc.conf", Keymaps.displayName(forKbdmap: $0)) } ?? ("default", "U.S.")
        layoutDescription = "\(name) (\(source))"
    }

    /// A stand-in for a hardware keyboard, fed from `fifo` — lines of `k CODE`
    /// (press and release) — so a headless run has what metal has: a keyboard
    /// with no keymap of its own, which takes the session's layout.
    public func addStandInKeyboard(fifo: String) -> Bool {
        guard standIn == nil, let k = tw_stand_in_keyboard_create() else { return false }
        let fd = open(fifo, O_RDWR | O_NONBLOCK)   // RDWR: never sees EOF between writers
        guard fd >= 0 else { return false }
        standIn = k
        standInFd = fd
        if Seat.giveKeymap(to: k, session: sessionKbdmap) { keymapped.append(k) }
        attach(keyboard: k)
        let loop = wl_display_get_event_loop(compositor.session.display)
        standInSource = wl_event_loop_add_fd(loop, fd, UInt32(WL_EVENT_READABLE), { _, _, data in
            guard let data else { return 0 }
            Unmanaged<Seat>.fromOpaque(data).takeUnretainedValue().readStandIn()
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
        return true
    }

    private func readStandIn() {
        var buf = [UInt8](repeating: 0, count: 512)
        let n = read(standInFd, &buf, buf.count)
        guard n > 0, let k = standIn else { return }
        standInBuffer += buf[0..<n]
        while let nl = standInBuffer.firstIndex(of: 10) {
            let line = String(decoding: standInBuffer[..<nl], as: UTF8.self)
            standInBuffer.removeSubrange(...nl)
            let f = line.split(separator: " ")
            guard f.count == 2, f[0] == "k", let code = UInt32(f[1]) else { continue }
            var ts = timespec(); clock_gettime(CLOCK_MONOTONIC, &ts)
            let ms = UInt32(truncatingIfNeeded: Int(ts.tv_sec) * 1000 + Int(ts.tv_nsec) / 1_000_000)
            tw_stand_in_keyboard_key(k, code, true, ms)
            tw_stand_in_keyboard_key(k, code, false, ms)
        }
    }

    /// Where the system's keyboard layout is written: the installer puts a
    /// `kbdmap` name in rc.conf's `keymap=`, and the console reads it from there.
    static let rcConf = ["/etc/rc.conf", "/etc/rc.conf.local"]

    /// The keymap a backend keyboard gets, or nil when no layouts can be found.
    ///
    /// In order:
    /// 1. **`XKB_DEFAULT_LAYOUT` in the environment** — how a person overrides
    ///    everything for one session; xkbcommon reads it (and `_VARIANT`,
    ///    `_OPTIONS`, …) itself.
    /// 2. **The session's choice** — keyboard.ini's `kbdmap` (T.2): what the
    ///    installer chose on the live medium, before there was an rc.conf.
    /// 3. **rc.conf's `keymap=`, translated** (`Install.Keymaps`), so the
    ///    desktop types what the console types. A name the installer never
    ///    offered is guessed from its prefix, and a guess XKB refuses is said so.
    /// 4. **xkbcommon's default**, which is US.
    static func compileKeymap(rcConf: [String] = Seat.rcConf, session: String = "") -> OpaquePointer? {
        guard let ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS) else { return nil }
        defer { xkb_context_unref(ctx) }
        if getenv("XKB_DEFAULT_LAYOUT") == nil, !session.isEmpty {
            if let (k, _) = Keymaps.xkb(forKbdmap: session),
               let km = compile(ctx, layout: k.layout, variant: k.variant) {
                log("the session's keymap \(session) is XKB \(k.layout)"
                    + (k.variant.isEmpty ? "" : "(\(k.variant))"))
                return km
            }
            log("the session's keymap \(session) has no XKB layout that compiles; trying rc.conf's")
        }
        if getenv("XKB_DEFAULT_LAYOUT") == nil, let kbdmap = Keymaps.configured(rcConf: rcConf) {
            if let (k, exact) = Keymaps.xkb(forKbdmap: kbdmap),
               let km = compile(ctx, layout: k.layout, variant: k.variant) {
                log("rc.conf's keymap \(kbdmap) is XKB \(k.layout)"
                    + (k.variant.isEmpty ? "" : "(\(k.variant))")
                    + (exact ? "" : ", guessed from its name"))
                return km
            }
            log("rc.conf's keymap \(kbdmap) has no XKB layout that compiles; using the default")
        }
        return xkb_keymap_new_from_names(ctx, nil, XKB_KEYMAP_COMPILE_NO_FLAGS)
    }

    private static func compile(_ ctx: OpaquePointer, layout: String,
                                variant: String) -> OpaquePointer? {
        layout.withCString { l in
            variant.withCString { v in
                var names = xkb_rule_names(rules: nil, model: nil, layout: l,
                                           variant: variant.isEmpty ? nil : v,
                                           options: nil)
                return xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS)
            }
        }
    }

    /// The name of a keymap's first layout, as the log line reports it.
    static func layoutName(_ keymap: OpaquePointer) -> String {
        xkb_keymap_layout_get_name(keymap, 0).map { String(cString: $0) } ?? "(unnamed)"
    }

    static func log(_ s: String) {
        let line = "undertow: keyboard: \(s)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
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

    /// What the pointer is over: an application's window, or one of the shell's
    /// own surfaces.
    public enum PointerTarget {
        case toplevel(Toplevel, Double, Double)
        case layer(LayerSurface, Double, Double)
        /// A menu (P10.4). Topmost: a popup is drawn over everything, so it
        /// is hit before everything.
        case popup(PopupSurface, Double, Double)
        /// The compositor's own frame around a window (P9.6), in frame-local
        /// coordinates. **No client owns these pixels**, which is why it is a
        /// separate case rather than a toplevel hit with odd coordinates: a
        /// press here must never be forwarded to anybody.
        case frame(Toplevel, Double, Double)
        /// A lock surface (PHASE16 P16.2): while locked, the only thing there is.
        case lock(UnsafeMutablePointer<wlr_surface>, Double, Double)

        var surface: UnsafeMutablePointer<wlr_surface>? {
            switch self {
            case .lock(let s, _, _): return s
            case .toplevel(let t, _, _): return t.surface
            case .layer(let l, _, _): return l.surface
            case .popup(let p, _, _): return p.surface
            case .frame: return nil
            }
        }
        var local: (Double, Double) {
            switch self {
            case .toplevel(_, let x, let y): return (x, y)
            case .layer(_, let x, let y): return (x, y)
            case .popup(_, let x, let y): return (x, y)
            case .frame(_, let x, let y): return (x, y)
            case .lock(_, let x, let y): return (x, y)
            }
        }
    }

    /// Hit-test everything the pointer can address, in paint order.
    ///
    /// **Layer surfaces were never in this search, so the shell's own surfaces
    /// could not be clicked at all under undertow.** The Dock, the menu bar and
    /// the desktop are layer surfaces; every test that clicked one ran on sway,
    /// which does route them, so nothing here ever noticed — the same shape as
    /// §2.37, a probe that only ever ran against a positive control.
    ///
    /// Found by P9.3: a file dragged onto the Trash never arrived, because the
    /// drag could not enter a surface the pointer could not reach.
    ///
    /// The order is the layer-shell protocol's own: overlay and top sit above
    /// the windows, bottom and background below them.
    public func target(at x: Double, _ y: Double) -> PointerTarget? {
        // Locked: the lock surface of the display under the pointer, or nothing.
        if compositor.isLocked {
            for m in compositor.sessionLock?.mapped ?? [] {
                let lx = x - Double(m.display.x), ly = y - Double(m.display.y)
                if lx >= 0, ly >= 0, lx < Double(m.display.width), ly < Double(m.display.height),
                   Seat.leaf(of: m.surface, lx, ly) != nil {
                    return .lock(m.surface, lx, ly)
                }
            }
            return nil
        }
        for p in compositor.mappedPopups.reversed() {
            guard let o = p.origin else { continue }
            let lx = x - Double(o.x), ly = y - Double(o.y)
            if Seat.leaf(of: p.surface, lx, ly) != nil { return .popup(p, lx, ly) }
        }
        let layers = compositor.mappedLayers            // bottom-to-top
        if let h = hitLayer(layers.filter { $0.layer >= 2 }, x, y) { return h }
        // Windows top to bottom, and **each window's frame belongs to it**: the
        // surface first, then the frame around it, before considering the window
        // underneath. Testing every surface and then every frame would let a
        // window below take a click on the frame of the window above it.
        for t in compositor.mappedToplevels.reversed() {
            let lx = x - Double(t.x), ly = y - Double(t.y)
            if Seat.leaf(of: t.surface, lx, ly) != nil { return .toplevel(t, lx, ly) }
            guard t.decorated else { continue }
            let box = FrameMetrics.frame(forSurfaceAt: t.x, t.y,
                                         width: t.width, height: t.height)
            let fx = x - Double(box.x), fy = y - Double(box.y)
            if fx >= 0, fy >= 0, fx < Double(box.w), fy < Double(box.h) {
                return .frame(t, fx, fy)
            }
        }
        return hitLayer(layers.filter { $0.layer < 2 }, x, y)
    }

    /// What a press on the compositor's own frame means.
    ///
    /// **The same answer the painter drew from** (P11.6): `chromeHit` over
    /// `windowChrome(foreign: true)` — the one layout both sides use, so the
    /// gadgets are exactly where they were drawn, and a foreign frame has no
    /// pill in either (P11.1 found one painted where this said "title").
    enum FrameHit: Equatable { case close, minimize, zoom, depth, title, resize(UInt32), body }

    func frameHit(_ t: Toplevel, x: Double, y: Double) -> FrameHit {
        let box = FrameMetrics.frame(forSurfaceAt: t.x, t.y,
                                     width: t.width, height: t.height)
        switch chromeHit(windowChrome(w: Double(box.w), h: Double(box.h), foreign: true), x: x, y: y) {
        case .gadget(.close): return .close
        case .gadget(.minimize): return .minimize
        case .gadget(.zoom): return .zoom
        case .gadget(.depth): return .depth
        case .gadget(.pill): return .title        // never laid out on a foreign frame
        case .title: return .title
        case .resize(.bottom): return .resize(UInt32(WLR_EDGE_BOTTOM.rawValue))
        case .resize(.bottomLeft): return .resize(UInt32(WLR_EDGE_BOTTOM.rawValue | WLR_EDGE_LEFT.rawValue))
        case .resize(.bottomRight): return .resize(UInt32(WLR_EDGE_BOTTOM.rawValue | WLR_EDGE_RIGHT.rawValue))
        case .content: return .body
        }
    }

    private func hitLayer(_ layers: [LayerSurface], _ x: Double, _ y: Double)
        -> PointerTarget? {
        for l in layers.reversed() {                   // the top one wins
            let lx = x - Double(l.rect.x), ly = y - Double(l.rect.y)
            if Seat.leaf(of: l.surface, lx, ly) != nil { return .layer(l, lx, ly) }
        }
        return nil
    }

    /// The surface in `root`'s tree under a root-local point, and the point in
    /// **that surface's** coordinates.
    ///
    /// A window is a tree, not a rectangle: a subsurface may lie over its
    /// parent or outside it, and a pointer event belongs to the leaf, in the
    /// leaf's own coordinates. Until U.1 undertow tested each root's rectangle
    /// and told the root, so a click on a subsurface arrived at its parent at
    /// the wrong place, and one outside the parent arrived nowhere. wlroots
    /// walks the tree top-down and honours each surface's input region, which
    /// a rectangle never did.
    static func leaf(of root: UnsafeMutablePointer<wlr_surface>, _ lx: Double, _ ly: Double)
        -> (surface: UnsafeMutablePointer<wlr_surface>, x: Double, y: Double)? {
        var sx = 0.0, sy = 0.0
        guard let s = wlr_surface_surface_at(root, lx, ly, &sx, &sy) else { return nil }
        return (s, sx, sy)
    }

    /// The displays moved (P14.7b): keep the pointer on one of them.
    func keepCursorOnDisplays() {
        (cursorX, cursorY) = compositor.layout.clamp(cursorX, cursorY)
    }

    /// wlroots' seat, for the protocols that take it (idle-notify, U.9).
    var wlrSeat: UnsafeMutablePointer<wlr_seat> { seat }

    /// A motion, from any pointer: the delta goes to the client with the
    /// pointer, then a constraint decides where the pointer itself goes (U.6).
    private func motion(dx: Double, dy: Double, unaccelDX: Double, unaccelDY: Double, timeMsec: UInt32) {
        // Any input is a person, and wakes sleeping displays (U.9).
        compositor.displaySleep?.activity()
        guard let pc = pointerConstraints else {
            moveCursor(to: cursorX + dx, cursorY + dy, timeMsec: timeMsec)
            return
        }
        pc.sendRelative(dx: dx, dy: dy, unaccelDX: unaccelDX, unaccelDY: unaccelDY, timeMsec: timeMsec)
        // A move or resize grab owns the pointer, constraint or not.
        if compositor.moving != nil || compositor.resizing != nil {
            moveCursor(to: cursorX + dx, cursorY + dy, timeMsec: timeMsec)
            return
        }
        guard let (x, y) = pc.constrain(fromX: cursorX, fromY: cursorY, toX: cursorX + dx, toY: cursorY + dy) else {
            // Locked: the pointer stays, and the delta's frame closes here.
            wlr_seat_pointer_notify_frame(seat)
            return
        }
        moveCursor(to: x, y, timeMsec: timeMsec)
        pc.refresh()
    }

    /// Put the pointer somewhere without telling the client it moved — a lock
    /// ending at the client's cursor hint, which is where it already drew it.
    func warpCursor(to x: Double, _ y: Double, surfaceX: Double, surfaceY: Double) {
        (cursorX, cursorY) = compositor.layout.clamp(x, y)
        wlr_seat_pointer_warp(seat, surfaceX, surfaceY)
    }

    private func moveCursor(to x: Double, _ y: Double, timeMsec: UInt32) {
        if compositor.isLocked { breakGrabs() }
        (cursorX, cursorY) = compositor.layout.clamp(x, y)

        // A drag in progress owns the pointer: the window follows it, and no
        // client is told about the motion. That is what stops a drag from
        // "falling through" onto whatever the pointer passes over.
        if compositor.moving != nil {
            compositor.updateMove(cursorX: cursorX, cursorY: cursorY)
            return
        }
        // The same for a resize: the pointer belongs to the grab, and no client
        // is told about the motion (P9.4).
        if compositor.resizing != nil {
            compositor.updateResize(cursorX: cursorX, cursorY: cursorY)
            return
        }
        // Ebb open: the pointer is Ebb's — it says which window it is over,
        // and no client is told it moved (P13.5).
        if compositor.ebb != nil {
            compositor.ebbHover(cursorX, cursorY)
            wlr_seat_pointer_clear_focus(seat)
            setCursor(.shape("default"))
            return
        }

        guard let hit = target(at: cursorX, cursorY) else {
            // Off every surface: the pointer belongs to the desktop, and a client
            // that still thought it had the pointer must be told it does not.
            wlr_seat_pointer_clear_focus(seat)
            setCursor(.shape("default"))
            return
        }
        // A frame has no client behind it: nobody is told the pointer is there,
        // and whoever had it is told it left. Its picture is ours: sizing
        // arrows on the edges that size.
        guard let surface = hit.surface else {
            wlr_seat_pointer_clear_focus(seat)
            if case .frame(let t, let fx, let fy) = hit {
                setCursor(.shape(Seat.cursorName(for: frameHit(t, x: fx, y: fy))))
            }
            return
        }
        let (rx, ry) = hit.local
        // The leaf, not the root: a subsurface is told about the pointer in
        // its own coordinates.
        let (leaf, lx, ly) = Seat.leaf(of: surface, rx, ry) ?? (surface, rx, ry)
        // `notify_enter` is idempotent — wlroots only sends the protocol enter
        // when the surface actually changes — so this is the whole of
        // enter/leave bookkeeping, between subsurfaces as between windows.
        wlr_seat_pointer_notify_enter(seat, leaf, lx, ly)
        wlr_seat_pointer_notify_motion(seat, timeMsec, lx, ly)
        wlr_seat_pointer_notify_frame(seat)
    }

    /// The picture for a place on a window's frame.
    static func cursorName(for hit: FrameHit) -> String {
        guard case .resize(let edges) = hit else { return "default" }
        let bottom = edges & UInt32(WLR_EDGE_BOTTOM.rawValue) != 0
        let left = edges & UInt32(WLR_EDGE_LEFT.rawValue) != 0
        let right = edges & UInt32(WLR_EDGE_RIGHT.rawValue) != 0
        switch (bottom, left, right) {
        case (true, true, _): return "nesw-resize"
        case (true, _, true): return "nwse-resize"
        case (true, _, _): return "ns-resize"
        default: return "ew-resize"
        }
    }

    /// A theme shape, or none.
    private func setCursor(_ image: CursorImage) {
        dropCursorSurface()
        cursorImage = image
    }

    /// The client's own surface, its hotspot `hotX, hotY` in from its corner.
    private func setCursor(surface: UnsafeMutablePointer<wlr_surface>, hotX: Int32, hotY: Int32) {
        if surface != cursorSurface {
            dropCursorSurface()
            cursorSurface = surface
            let me = Unmanaged.passUnretained(self).toOpaque()
            // The surface may go before the pointer moves: the arrow then.
            cursorSurfaceListeners.append(tw_listen(&surface.pointee.events.destroy, { ctx, _ in
                guard let ctx else { return }
                Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue().setCursor(.shape("default"))
            }, me))
            // An attach offset moves the hotspot the other way, as wlr_cursor has it.
            cursorSurfaceListeners.append(tw_listen(&surface.pointee.events.commit, { ctx, _ in
                guard let ctx else { return }
                let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
                guard let cs = s.cursorSurface else { return }
                s.cursorHotX -= cs.pointee.current.dx
                s.cursorHotY -= cs.pointee.current.dy
            }, me))
        }
        cursorHotX = hotX
        cursorHotY = hotY
        cursorImage = .client
    }

    /// Off the client's surface's signals (§2.82: wlroots asserts they are
    /// gone when it destroys the surface).
    private func dropCursorSurface() {
        for l in cursorSurfaceListeners { tw_listener_free(l) }
        cursorSurfaceListeners = []
        cursorSurface = nil
    }

    private func button(_ button: UInt32, state: wl_pointer_button_state,
                        timeMsec: UInt32) {
        if compositor.isLocked { breakGrabs() }
        // Ebb open: a click picks a window or puts the tide back (P13.5).
        if compositor.ebb != nil, !compositor.isLocked {
            if state == WL_POINTER_BUTTON_STATE_PRESSED { compositor.ebbClick(cursorX, cursorY) }
            return
        }
        // The Shoals strip takes a click on one of its tiles (P13.6); a click
        // anywhere else goes where it always went.
        if state == WL_POINTER_BUTTON_STATE_PRESSED, !compositor.isLocked,
           compositor.stripClick(cursorX, cursorY) {
            stripPressed = true
            return
        }
        if state == WL_POINTER_BUTTON_STATE_RELEASED, stripPressed { stripPressed = false; return }
        // Releasing the button ends a drag, and the window's new position is
        // remembered there.
        if state == WL_POINTER_BUTTON_STATE_RELEASED,
           compositor.moving != nil || compositor.resizing != nil {
            compositor.endMove()
            compositor.endResize()
            _ = wlr_seat_pointer_notify_button(seat, timeMsec, button, state)
            wlr_seat_pointer_notify_frame(seat)
            return
        }
        // Click to focus and raise, before the click is delivered: the client
        // should receive the press already focused, which is what makes
        // click-through-to-a-control behave the way a Mac user expects.
        // Only a window takes focus: a click on the Dock or the menu bar must
        // not steal the keyboard from whatever you were typing into, which is
        // what `keyboard_interactivity: none` on those surfaces asks for.
        let hit = target(at: cursorX, cursorY)
        if state == WL_POINTER_BUTTON_STATE_PRESSED, case .toplevel(let t, _, _)? = hit {
            focus(t)
        }
        // **A layer surface that asked for the keyboard gets it on a click**
        // (`on_demand`) — the menu bar, so its menus can be driven with the
        // arrow keys once a title is clicked (HANDOFF §2.27). undertow honoured
        // `keyboard_interactivity` for nobody, so under our own compositor the
        // keys went to the window behind the menu; every test of it ran on
        // sway. Found in P10.4. The window stays *active* — the bar is not an
        // application, and clicking it must not change who is frontmost.
        if state == WL_POINTER_BUTTON_STATE_PRESSED, case .layer(let l, _, _)? = hit,
           l.takesKeyboardOnClick {
            giveKeyboard(to: l)
        }
        // A press on the compositor's own frame is answered here and forwarded
        // to nobody — there is no client on the other side of those pixels.
        if state == WL_POINTER_BUTTON_STATE_PRESSED, case .frame(let t, let fx, let fy)? = hit {
            focus(t)
            switch frameHit(t, x: fx, y: fy) {
            case .close:    wlr_xdg_toplevel_send_close(t.xdgToplevel)
            case .minimize: compositor.setMinimized(t, true)
            case .zoom:     compositor.setMaximized(t, !t.maximized)
            case .depth:    compositor.lower(t)
            case .title:    compositor.beginMove(t)
            case .resize(let edges): compositor.beginResize(t, edges: edges)
            case .body:     break
            }
            frameClicks += 1
            return
        }
        _ = wlr_seat_pointer_notify_button(seat, timeMsec, button, state)
        wlr_seat_pointer_notify_frame(seat)
    }

    /// The layer surface holding the keyboard, if one does (P10.4).
    public private(set) weak var keyboardLayer: LayerSurface?

    func giveKeyboard(to l: LayerSurface) {
        guard !compositor.isLocked, keyboardLayer !== l, let kbd = wlr_seat_get_keyboard(seat) else { return }
        keyboardLayer = l
        wlr_seat_keyboard_notify_enter(seat, l.surface, &kbd.pointee.keycodes.0,
                                       kbd.pointee.num_keycodes, &kbd.pointee.modifiers)
    }

    // MARK: - The session lock (PHASE16 P16.2)

    /// The lock surface the keyboard belongs to: the main display's, else any.
    func lockKeyboardTarget() -> UnsafeMutablePointer<wlr_surface>? {
        guard let lock = compositor.sessionLock else { return nil }
        if let main = compositor.layout.main, let s = lock.surface(on: main.name) { return s }
        return lock.mapped.first?.surface
    }

    /// **No grab survives a lock.** wlroots answers `xdg_popup.grab` itself,
    /// and while a popup's keyboard grab holds, a change of keyboard focus is
    /// ignored — so a client behind the lock that opened a grabbing popup
    /// (with any serial it was ever given) would be handed the keys typed into
    /// the lock screen. Ended before every key and button while locked.
    func breakGrabs() {
        if seat.pointee.keyboard_state.grab != seat.pointee.keyboard_state.default_grab {
            wlr_seat_keyboard_end_grab(seat)
            grabsBroken += 1
            if let s = lockKeyboardTarget(), let kbd = wlr_seat_get_keyboard(seat) {
                wlr_seat_keyboard_notify_enter(seat, s, &kbd.pointee.keycodes.0,
                                               kbd.pointee.num_keycodes, &kbd.pointee.modifiers)
            }
        }
        if seat.pointee.pointer_state.grab != seat.pointee.pointer_state.default_grab {
            wlr_seat_pointer_end_grab(seat)
            grabsBroken += 1
        }
    }
    /// Grabs ended because the session was locked, for the log a test reads.
    public private(set) var grabsBroken = 0

    /// Locked: nothing behind the lock keeps the pointer, the keys, a grab or
    /// the bar's keyboard. They go to the lock surface as it appears.
    func sessionLocked() {
        breakGrabs()
        keyboardLayer = nil
        compositor.endMove()
        compositor.endResize()
        wlr_seat_pointer_clear_focus(seat)
        wlr_seat_keyboard_notify_clear_focus(seat)
        if let s = lockKeyboardTarget() { lockSurfaceCommitted(s) }
    }

    /// A lock surface has drawn: it takes the keyboard if no lock surface has
    /// it, and the pointer if the pointer is over it.
    func lockSurfaceCommitted(_ s: UnsafeMutablePointer<wlr_surface>) {
        guard compositor.isLocked, wlr_surface_has_buffer(s) else { return }
        let current = seat.pointee.keyboard_state.focused_surface
        let onLock = current.map { c in compositor.sessionLock?.surfaces.contains { $0.surface == c } == true } ?? false
        if !onLock, let target = lockKeyboardTarget(), let kbd = wlr_seat_get_keyboard(seat) {
            wlr_seat_keyboard_notify_enter(seat, target, &kbd.pointee.keycodes.0,
                                           kbd.pointee.num_keycodes, &kbd.pointee.modifiers)
        }
        rehover()
    }

    /// Unlocked: the keys go back to the window that was frontmost, and the
    /// pointer to whatever is under it.
    func sessionUnlocked() {
        wlr_seat_keyboard_notify_clear_focus(seat)
        wlr_seat_pointer_clear_focus(seat)
        if let t = focused, let kbd = wlr_seat_get_keyboard(seat) {
            wlr_seat_keyboard_notify_enter(seat, t.surface, &kbd.pointee.keycodes.0,
                                           kbd.pointee.num_keycodes, &kbd.pointee.modifiers)
        } else if focused == nil {
            focusTopmost()
        }
        rehover()
    }

    /// Tell whatever is under the pointer that it is, without the pointer moving.
    private func rehover() {
        var ts = timespec(); clock_gettime(CLOCK_MONOTONIC, &ts)
        moveCursor(to: cursorX, cursorY, timeMsec: UInt32(truncatingIfNeeded: Int(ts.tv_sec) * 1000 + Int(ts.tv_nsec) / 1_000_000))
    }

    /// Hand the keyboard back to the active window — when the bar's menu
    /// closes, or the layer that had it goes away. Mac-like: the keys go back
    /// to the application you were in, which never stopped being frontmost.
    func restoreKeyboard() {
        guard !compositor.isLocked, keyboardLayer != nil else { return }
        keyboardLayer = nil
        guard let t = focused, let kbd = wlr_seat_get_keyboard(seat) else {
            wlr_seat_keyboard_notify_clear_focus(seat)
            return
        }
        wlr_seat_keyboard_notify_enter(seat, t.surface, &kbd.pointee.keycodes.0,
                                       kbd.pointee.num_keycodes, &kbd.pointee.modifiers)
    }

    /// Give a window keyboard focus and raise it to the top of the stack.
    public func focus(_ t: Toplevel) {
        // **Locked (PHASE16 P16.2): focus does not move at all.** A window
        // that maps behind the lock is not raised, made frontmost or told it
        // is active, so unlocking finds you where you left off — and nothing
        // behind the lock learns it has the keyboard.
        guard !compositor.isLocked else { return }
        compositor.raise(t)
        // Clicking the active window while the bar held the keyboard gives it
        // back, even though focus as such did not move.
        if focused === t, keyboardLayer != nil { restoreKeyboard(); return }
        guard focused !== t else { return }
        keyboardLayer = nil
        // The shell is told which window is active the same way it is told one
        // exists — through its foreign-toplevel handle. Without this the Dock
        // can list running applications and never say which one you are in.
        // **Tell the windows, not just the shell.** `keyboard_notify_enter`
        // routes the keys; the *activated* state is what a client draws with —
        // an active title bar, a live caret, a selection that is not grey — and
        // undertow set it on nobody, so every Aqua window in this tree has been
        // drawing itself focused since Phase 6, including the five that were
        // not. Found in P9.5, because Cmd-Tab's only observable effect is which
        // window says it now has focus.
        if let old = focused {
            _ = wlr_xdg_toplevel_set_activated(old.xdgToplevel, false)
            old.setForeignActivated(false)
        }
        focused = t
        _ = wlr_xdg_toplevel_set_activated(t.xdgToplevel, true)
        t.setForeignActivated(true)
        // And the menu bar, which shows whoever is frontmost (P10.3).
        compositor.menus?.focusChanged()
        // A constraint holds only for the focused window: ⌘-Tab ends a lock.
        pointerConstraints?.refresh()
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

    // MARK: - Keybinds (P9.5)

    /// Keycodes whose press this compositor swallowed.
    ///
    /// **A release must follow its press or not exist.** Consuming Cmd-Tab's
    /// press and forwarding its release hands the client half an event: a key it
    /// never saw go down, coming up — which toolkits variously ignore, log, or
    /// treat as a stuck modifier. Cheaper to remember the keycode than to debug
    /// that in an application six months from now.
    private var consumedKeys: Set<UInt32> = []
    /// A press the Shoals strip took: its release is the strip's too.
    private var stripPressed = false
    /// The table, and when its file was last looked at.
    private var bindings = KeyBindings()
    private var bindingsLoadedAt: time_t = 0
    private var bindingsChecked: time_t = 0

    /// Answer a key event ourselves, or say we did not. True means consumed.
    fileprivate func intercept(key e: UnsafeMutablePointer<wlr_keyboard_key_event>,
                               keyboard: UnsafeMutablePointer<wlr_keyboard>) -> Bool {
        let keycode = e.pointee.keycode
        guard e.pointee.state == WL_KEYBOARD_KEY_STATE_PRESSED else {
            return consumedKeys.remove(keycode) != nil
        }
        // Ctrl-Alt-F*n*, before any table: leaving for a text console is not
        // the desktop's to rebind. Only unlocked (this whole function is), so
        // a locked session stays locked; with no session to ask, the key goes
        // on to the client.
        if let vt = VTSwitch.vt(for: symbols(keyboard: keyboard, keycode: keycode)),
           compositor.session.changeVT(vt) {
            consumedKeys.insert(keycode)
            print("undertow: switching to VT \(vt)")
            return true
        }
        reloadBindingsIfStale()
        let mods = KeyModifiers(rawValue: wlr_keyboard_get_modifiers(keyboard)).normalized()
        // **Ebb has the keyboard while it is open** (P13.5): Escape puts the
        // tide back, an Ebb key changes or closes it, an island key switches
        // (and closes an island-scope Ebb); nothing reaches a window under it.
        if let e = compositor.ebb, !e.closing {
            let syms = symbols(keyboard: keyboard, keycode: keycode)
            consumedKeys.insert(keycode)
            if syms.contains(0xff1b) { compositor.ebbDismiss(); return true }       // Escape
            for sym in syms {
                if let a = bindings.match(sym: sym, modifiers: mods, focusedAppID: nil) {
                    switch a {
                    case .ebb, .island, .islandStep: perform(a)
                    default: break
                    }
                    break
                }
            }
            return true
        }
        let app = focused?.appID

        // Two symbols, and both are needed. The **translated** one is what the
        // layout produces with the modifiers applied — which for Cmd-Shift-3 on
        // a US layout is `numbersign`, not `3`. The **raw** one is the symbol
        // printed on the key. A table written the way a person thinks ("Cmd,
        // Shift and the 3 key") only works if both are tried.
        var action: KeyAction? = nil
        for sym in symbols(keyboard: keyboard, keycode: keycode) {
            if let a = bindings.match(sym: sym, modifiers: mods, focusedAppID: app) {
                action = a
                break
            }
        }
        guard let act = action else { return false }
        consumedKeys.insert(keycode)
        perform(act)
        return true
    }

    /// The translated symbol, then the raw one. Duplicates are harmless: the
    /// table is small and a second lookup of the same symbol costs nothing.
    private func symbols(keyboard: UnsafeMutablePointer<wlr_keyboard>,
                         keycode: UInt32) -> [UInt32] {
        var out: [UInt32] = []
        let xkbCode = keycode + 8
        if let state = keyboard.pointee.xkb_state {
            var syms: UnsafePointer<xkb_keysym_t>? = nil
            let n = xkb_state_key_get_syms(state, xkbCode, &syms)
            if let syms, n > 0 { for i in 0..<Int(n) { out.append(syms[i]) } }
        }
        if let keymap = keyboard.pointee.keymap {
            let layout = keyboard.pointee.xkb_state.map {
                xkb_state_key_get_layout($0, xkbCode)
            } ?? 0
            var syms: UnsafePointer<xkb_keysym_t>? = nil
            let n = xkb_keymap_key_get_syms_by_level(keymap, xkbCode, layout, 0, &syms)
            if let syms, n > 0 { for i in 0..<Int(n) where !out.contains(syms[i]) {
                out.append(syms[i])
            } }
        }
        return out
    }

    private func perform(_ action: KeyAction) {
        switch action {
        case .nextWindow:      compositor.cycleWindow(forward: true)
        case .previousWindow:  compositor.cycleWindow(forward: false)
        case .closeWindow:     compositor.closeFocusedWindow()
        case .quitApplication: compositor.quitFocusedApplication()
        case .island(let n):   compositor.switchIsland(n)
        case .ebb(let scope):  compositor.toggleEbb(scope)
        case .shoalNew:        compositor.newShoal()
        case .shoalAdd:        compositor.addFocusedToShoal()
        case .shoalRemove:     compositor.removeFocusedFromShoal()
        case .shoalRecall(let n): compositor.recallShoal(number: n)
        case .shoalStrip:      compositor.toggleShoalStrip()
        case .islandStep(let d): compositor.stepIsland(d)
        case .moveToIsland(let n, let follow): compositor.moveFocusedWindow(toIsland: n, follow: follow)
        case .run(let words):
            // Said, not swallowed: a binding whose program is not on PATH did
            // nothing at all, and nothing said so (HANDOFF §2.115).
            if !Spawn.detached(words) {
                Compositor.log("keybind: could not run \(words.joined(separator: " ")) — not found on PATH (\(getenv("PATH").map { String(cString: $0) } ?? "no PATH"))")
            }
        }
        keybindsFired += 1
    }

    /// How many bound keystrokes this compositor has answered — the positive
    /// control, for the same reason `dragsStarted` is one (§2.37). "The key did
    /// nothing" and "the key was never bound" look identical from outside.
    public private(set) var keybindsFired = 0
    /// Presses answered by the compositor's own window frames (P9.6) — the
    /// positive control again: a frame that is drawn and not clickable and one
    /// that is never drawn look identical from a screenshot.
    public private(set) var frameClicks = 0

    /// The table, from `~/.config/abyss/keys.ini` over the built-in defaults.
    ///
    /// Re-read when the file's timestamp moves, checked at most once a second
    /// and only on a keystroke — the shell's other configuration hot-reloads
    /// (§2.18) and a shortcut table that needed a restart would be the one piece
    /// of it that did not. No watcher, no timer: the only moment the answer can
    /// matter is the moment somebody presses a key.
    private func reloadBindingsIfStale() {
        let now = time(nil)
        if bindingsLoadedAt != 0, now - bindingsChecked < 1 { return }
        bindingsChecked = now
        let path = (compositor.configDir ?? Seat.defaultConfigDir()) + "/keys.ini"
        var st = stat()
        let mtime: time_t = stat(path, &st) == 0 ? st.st_mtim.tv_sec : 0
        if bindingsLoadedAt != 0 && mtime == bindingsLoadedAt { return }
        bindingsLoadedAt = mtime == 0 ? -1 : mtime

        var config = Config()
        for (spec, action) in KeyBindingParser.defaults {
            config = config.set("keys", spec, action)
        }
        if let onDisk = try? Pool.load("keys", in: compositor.configDir) {
            // Row by row, so a file that binds one key keeps the other defaults.
            for (spec, action) in onDisk.pairs("keys") {
                config = config.set("keys", spec, action)
            }
            for (app, specs) in onDisk.pairs("passthrough") {
                config = config.set("passthrough", app, specs)
            }
        }
        bindings = KeyBindingParser.table(from: config) { name in
            name.withCString { xkb_keysym_from_name($0, XKB_KEYSYM_CASE_INSENSITIVE) }
        }
    }

    private static func defaultConfigDir() -> String {
        if let x = getenv("ABYSS_CONFIG_DIR") { return String(cString: x) }
        if let h = getenv("HOME") { return String(cString: h) + "/.config/abyss" }
        return "/tmp"
    }

    /// Focus whatever is now on top, or nobody.
    ///
    /// For when the focused window stops being available without closing —
    /// minimized, in this pass. Leaving focus on a window that is not on screen
    /// makes the desktop deaf in a way nothing on screen explains.
    public func focusTopmost() {
        // **Locked: the keyboard is the lock screen's**, whatever closes
        // behind it. Clearing it here — the last window closing while locked,
        // the power dialog that asked for the sleep — left the lock screen
        // deaf: a password typed into it went nowhere (found in P16.4b).
        // Forget the window that went; unlocking picks the topmost then.
        if compositor.isLocked {
            if let f = focused, !compositor.mappedToplevels.contains(where: { $0 === f }) {
                f.setForeignActivated(false)
                focused = nil
            }
            return
        }
        guard let t = compositor.mappedToplevels.last else {
            focused?.setForeignActivated(false)
            focused = nil
            wlr_seat_keyboard_notify_clear_focus(seat)
            compositor.menus?.focusChanged()
            return
        }
        focus(t)
    }

    /// Draw the cursor. Called after the scene, so it is on top of everything.
    ///
    /// **The drag icon goes under it**, because that is what a person expects:
    /// the thing being dragged follows the pointer and the pointer stays on top
    /// of it. Without this a drag is invisible — the file moves, and nothing on
    /// screen ever showed it moving, which reads as the desktop ignoring you.
    /// Drawn by every output; one whose rectangle the cursor is not in draws
    /// it off its own edge, which costs a clipped rect and nothing else.
    public func renderCursor(into pass: OpaquePointer, scene: SurfaceScene) {
        if let icon = dragIcon, let surface = icon.pointee.surface,
           let tex = wlr_surface_get_texture(surface) {
            var opts = wlr_render_texture_options()
            opts.texture = tex
            opts.dst_box = scene.box(Int32(cursorX), Int32(cursorY),
                                     surface.pointee.current.width, surface.pointee.current.height)
            opts.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED
            wlr_render_pass_add_texture(pass, &opts)
        }
        guard cursorVisible else { return }
        let cx = Int32(cursorX.rounded(.down)), cy = Int32(cursorY.rounded(.down))
        switch cursorImage {
        case .hidden:
            return
        case .client:
            guard let cs = cursorSurface else { return }
            // Its clock too: an animated cursor draws on frame callbacks.
            var now = timespec()
            clock_gettime(CLOCK_MONOTONIC, &now)
            defer { wlr_surface_send_frame_done(cs, &now) }
            guard let tex = wlr_surface_get_texture(cs) else { return }
            var opts = wlr_render_texture_options()
            opts.texture = tex
            opts.dst_box = scene.box(cx - cursorHotX, cy - cursorHotY,
                                     cs.pointee.current.width, cs.pointee.current.height)
            opts.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED
            wlr_render_pass_add_texture(pass, &opts)
        case .shape(let name):
            guard let renderer = compositor.rendererForFrames,
                  let img = cursorImages.image(name, scale: scene.scale, renderer: renderer) else { return }
            let size = Int32(Cursor.size.rounded(.up))
            var opts = wlr_render_texture_options()
            opts.texture = img.texture
            opts.dst_box = scene.box(cx - Int32(img.hotX.rounded()), cy - Int32(img.hotY.rounded()), size, size)
            opts.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED
            wlr_render_pass_add_texture(pass, &opts)
        }
    }
}
