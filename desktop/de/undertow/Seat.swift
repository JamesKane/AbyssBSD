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

import AquaDraw
import CWlroots
import PoolConfig
import Install

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

    private let outputWidth: Double
    private let outputHeight: Double
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
    /// How many drags the compositor has started. The positive control for a
    /// drag test, for the same reason `selectionsAccepted` is one for a copy.
    public private(set) var dragsStarted = 0
    /// The surface being dragged under the cursor, if any.
    var dragIcon: UnsafeMutablePointer<wlr_drag_icon>?
    var dragIconDestroy: UnsafeMutablePointer<tw_listener>?

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
                Seat.giveKeymap(to: k)
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
            s.moveCursor(to: e.pointee.x * s.outputWidth, e.pointee.y * s.outputHeight,
                         timeMsec: e.pointee.time_msec)
        }, me))
        group.append(tw_listen(&pointer.pointee.events.motion, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_pointer_motion_event.self)
            s.moveCursor(to: s.cursorX + e.pointee.delta_x, s.cursorY + e.pointee.delta_y,
                         timeMsec: e.pointee.time_msec)
        }, me))
        group.append(tw_listen(&pointer.pointee.events.button, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_pointer_button_event.self)
            s.button(e.pointee.button, state: e.pointee.state,
                     timeMsec: e.pointee.time_msec)
        }, me))
        group.append(tw_listen(&pointer.pointee.events.axis, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let e = data.assumingMemoryBound(to: wlr_pointer_axis_event.self)
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
            // **The desktop hears it first (P9.5).** Everything the compositor
            // owns — switching windows, closing one, taking a picture of the
            // screen — can only be decided here, because after this line the
            // focused client has it and the compositor never sees it again.
            // The keyboard comes from the seat rather than the closure: a C
            // function pointer cannot capture, and `wlr_seat_set_keyboard`
            // below has already told the seat which device this is.
            if let kbd = wlr_seat_get_keyboard(s.seat), s.intercept(key: e, keyboard: kbd) {
                return
            }
            wlr_seat_keyboard_notify_key(s.seat, e.pointee.time_msec,
                                         e.pointee.keycode, UInt32(e.pointee.state.rawValue))
        }, me))
        group.append(tw_listen(&keyboard.pointee.events.modifiers, { ctx, data in
            guard let ctx, let data else { return }
            let s = Unmanaged<Seat>.fromOpaque(ctx).takeUnretainedValue()
            let kbd = data.assumingMemoryBound(to: wlr_keyboard.self)
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
        if let t = focused {
            wlr_seat_keyboard_notify_enter(seat, t.surface,
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
    static func giveKeymap(to keyboard: UnsafeMutablePointer<wlr_keyboard>,
                           rcConf: [String] = Seat.rcConf) {
        let name = keyboard.pointee.base.name.map { String(cString: $0) } ?? "a keyboard"
        if let existing = keyboard.pointee.keymap {
            // A backend that already chose one knows better than our default.
            log("\(name) came with keymap \(layoutName(existing)); keeping it")
            return
        }
        guard let keymap = compileKeymap(rcConf: rcConf) else {
            log("no keymap compiled (are the xkeyboard-config layouts installed?) — "
                + "this keyboard's keys will reach clients as codes nobody can read")
            return
        }
        defer { xkb_keymap_unref(keymap) }  // the keyboard takes its own reference
        if !wlr_keyboard_set_keymap(keyboard, keymap) {
            log("wlroots refused the keymap")
            return
        }
        // wlroots' own defaults, stated rather than assumed: a rate of 0 would
        // tell clients not to repeat at all.
        wlr_keyboard_set_repeat_info(keyboard, 25, 600)
        log("\(name) had no keymap; gave it \(layoutName(keymap))")
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
    /// 2. **rc.conf's `keymap=`, translated** (`Install.Keymaps`), so the
    ///    desktop types what the console types. A name the installer never
    ///    offered is guessed from its prefix, and a guess XKB refuses is said so.
    /// 3. **xkbcommon's default**, which is US.
    static func compileKeymap(rcConf: [String] = Seat.rcConf) -> OpaquePointer? {
        guard let ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS) else { return nil }
        defer { xkb_context_unref(ctx) }
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

        var surface: UnsafeMutablePointer<wlr_surface>? {
            switch self {
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
        for p in compositor.mappedPopups.reversed() {
            guard let o = p.origin else { continue }
            let lx = x - Double(o.x), ly = y - Double(o.y)
            if lx >= 0, ly >= 0, lx < Double(p.width), ly < Double(p.height) {
                return .popup(p, lx, ly)
            }
        }
        let layers = compositor.mappedLayers            // bottom-to-top
        if let h = hitLayer(layers.filter { $0.layer >= 2 }, x, y) { return h }
        // Windows top to bottom, and **each window's frame belongs to it**: the
        // surface first, then the frame around it, before considering the window
        // underneath. Testing every surface and then every frame would let a
        // window below take a click on the frame of the window above it.
        for t in compositor.mappedToplevels.reversed() {
            let lx = x - Double(t.x), ly = y - Double(t.y)
            if lx >= 0, ly >= 0, lx < Double(t.width), ly < Double(t.height) {
                return .toplevel(t, lx, ly)
            }
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
        let rects = layers.map {
            WindowRect(x: $0.rect.x, y: $0.rect.y,
                       width: $0.rect.width, height: $0.rect.height)
        }
        guard let h = PointerRouting.hit(x, y, rects: rects) else { return nil }
        return .layer(layers[h.index], h.localX, h.localY)
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
        // The same for a resize: the pointer belongs to the grab, and no client
        // is told about the motion (P9.4).
        if compositor.resizing != nil {
            compositor.updateResize(cursorX: cursorX, cursorY: cursorY)
            return
        }

        guard let hit = target(at: cursorX, cursorY) else {
            // Off every surface: the pointer belongs to the desktop, and a client
            // that still thought it had the pointer must be told it does not.
            wlr_seat_pointer_clear_focus(seat)
            return
        }
        // A frame has no client behind it: nobody is told the pointer is there,
        // and whoever had it is told it left.
        guard let surface = hit.surface else {
            wlr_seat_pointer_clear_focus(seat)
            return
        }
        let (lx, ly) = hit.local
        // `notify_enter` is idempotent — wlroots only sends the protocol enter
        // when the surface actually changes — so this is the whole of
        // enter/leave bookkeeping.
        wlr_seat_pointer_notify_enter(seat, surface, lx, ly)
        wlr_seat_pointer_notify_motion(seat, timeMsec, lx, ly)
        wlr_seat_pointer_notify_frame(seat)
    }

    private func button(_ button: UInt32, state: wl_pointer_button_state,
                        timeMsec: UInt32) {
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
        guard keyboardLayer !== l, let kbd = wlr_seat_get_keyboard(seat) else { return }
        keyboardLayer = l
        wlr_seat_keyboard_notify_enter(seat, l.surface, &kbd.pointee.keycodes.0,
                                       kbd.pointee.num_keycodes, &kbd.pointee.modifiers)
    }

    /// Hand the keyboard back to the active window — when the bar's menu
    /// closes, or the layer that had it goes away. Mac-like: the keys go back
    /// to the application you were in, which never stopped being frontmost.
    func restoreKeyboard() {
        guard keyboardLayer != nil else { return }
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
        reloadBindingsIfStale()
        let mods = KeyModifiers(rawValue: wlr_keyboard_get_modifiers(keyboard)).normalized()
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
        case .run(let words):  Seat.spawnDetached(words)
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

    /// Run a command and forget it. No shell, and the child is reaped by init
    /// rather than by us — a compositor that accumulated zombies every time
    /// somebody pressed a volume key would be a slow leak nobody attributed.
    private static func spawnDetached(_ words: [String]) {
        guard let first = words.first else { return }
        let pid = fork()
        if pid == 0 {
            if fork() != 0 { _exit(0) }          // orphan the grandchild
            var argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) }
            argv.append(nil)
            execvp(first, &argv)
            _exit(127)
        } else if pid > 0 {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)         // the middle process, immediately
        }
    }

    /// Focus whatever is now on top, or nobody.
    ///
    /// For when the focused window stops being available without closing —
    /// minimized, in this pass. Leaving focus on a window that is not on screen
    /// makes the desktop deaf in a way nothing on screen explains.
    public func focusTopmost() {
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
    public func renderCursor(into pass: OpaquePointer) {
        if let icon = dragIcon, let surface = icon.pointee.surface,
           let tex = wlr_surface_get_texture(surface) {
            var opts = wlr_render_texture_options()
            opts.texture = tex
            opts.dst_box = wlr_box(x: Int32(cursorX), y: Int32(cursorY),
                                   width: surface.pointee.current.width,
                                   height: surface.pointee.current.height)
            opts.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED
            wlr_render_pass_add_texture(pass, &opts)
        }
        guard cursorVisible else { return }
        var opts = wlr_render_rect_options()
        opts.box = wlr_box(x: Int32(cursorX), y: Int32(cursorY), width: 10, height: 16)
        opts.color = wlr_render_color(r: 1, g: 1, b: 1, a: 1)
        opts.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED
        wlr_render_pass_add_rect(pass, &opts)
    }
}
