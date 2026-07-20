// Surface — the AbyssBSD Swift Wayland client runtime.
//
// Display owns the connection, the registry, and the global singletons
// (compositor, shm, seat, xdg_wm_base) plus the pointer. It runs the dispatch
// loop. Window (Window.swift) layers xdg-shell + shm buffers + rendering on top.
//
// libwayland's request/add_listener functions are static-inline; we reach them
// through the aw_* wrappers in the CWayland shim. Opaque wl_* handles are
// carried as OpaquePointer; the shim takes/returns void* (raw pointers), so we
// convert at the boundary with the raw()/opt() helpers below.

import CWayland

@inline(__always) func raw(_ p: OpaquePointer) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(p)
}
@inline(__always) func opt(_ p: UnsafeMutableRawPointer?) -> OpaquePointer? {
    p.map(OpaquePointer.init)
}

// wl_seat_capability bits (avoids importing the C enum).
private let kSeatCapabilityPointer: UInt32 = 1
private let kSeatCapabilityKeyboard: UInt32 = 2

public final class Display {
    let display: OpaquePointer
    let registry: OpaquePointer

    var compositor: OpaquePointer?
    var shm: OpaquePointer?
    var seat: OpaquePointer?
    var wmBase: OpaquePointer?
    var pointer: OpaquePointer?
    var keyboard: OpaquePointer?

    // xkbcommon translation for keyboard input; created lazily with the seat.
    let keyboardState = KeyboardState()

    // The (single, for now) window that receives input + drives frames.
    public weak var window: Window?

    // The active grabbing popup (menu), if any. Weak — the caller owns it; we
    // just route input to it and clear on teardown. Set in Popup.init.
    weak var activePopup: Popup?
    // Serial of the most recent pointer button event — xdg_popup.grab needs it.
    var lastPointerSerial: UInt32 = 0
    // Whether the pointer is currently over the popup surface (vs the window).
    private var pointerOnPopup = false

    var running = true

    // Heap-allocated listener structs; libwayland keeps the pointers, so they
    // must outlive the proxies. Freed in deinit.
    private var listenerStorage: [UnsafeMutableRawPointer] = []

    public init?() {
        guard let d = wl_display_connect(nil) else { return nil }
        display = d
        guard let reg = opt(aw_display_get_registry(raw(d))) else {
            wl_display_disconnect(d)
            return nil
        }
        registry = reg

        let me = Unmanaged.passUnretained(self).toOpaque()

        var rl = wl_registry_listener()
        rl.global = { data, _, name, iface, version in
            guard let data, let iface else { return }
            let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
            d.handleGlobal(name: name, interface: String(cString: iface),
                           version: version)
        }
        rl.global_remove = { _, _, _ in }
        addListener(to: registry, listener: rl, data: me)

        // Two roundtrips: first delivers globals, second delivers follow-ups
        // (e.g. seat capabilities) issued from inside the first.
        wl_display_roundtrip(display)
        wl_display_roundtrip(display)

        if compositor == nil || shm == nil || wmBase == nil {
            return nil
        }
    }

    deinit {
        for p in listenerStorage { p.deallocate() }
        wl_display_disconnect(display)
    }

    // Store a copy of `listener` on the heap and register it on `proxy`.
    func addListener<L>(to proxy: OpaquePointer, listener: L,
                        data: UnsafeMutableRawPointer) {
        let p = UnsafeMutablePointer<L>.allocate(capacity: 1)
        p.initialize(to: listener)
        listenerStorage.append(UnsafeMutableRawPointer(p))
        _ = aw_add_listener(raw(proxy), UnsafeRawPointer(p), data)
    }

    private func handleGlobal(name: UInt32, interface: String, version: UInt32) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        switch interface {
        case "wl_compositor":
            compositor = opt(aw_bind_compositor(raw(registry), name, min(version, 4)))
        case "wl_shm":
            shm = opt(aw_bind_shm(raw(registry), name, 1))
        case "wl_seat":
            guard let s = opt(aw_bind_seat(raw(registry), name, min(version, 5)))
            else { return }
            seat = s
            var sl = wl_seat_listener()
            sl.capabilities = { data, _, caps in
                guard let data else { return }
                let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
                d.seatCapabilities(caps)
            }
            sl.name = { _, _, _ in }
            addListener(to: s, listener: sl, data: me)
        case "xdg_wm_base":
            guard let b = opt(aw_bind_xdg_wm_base(raw(registry), name, min(version, 2)))
            else { return }
            wmBase = b
            var bl = xdg_wm_base_listener()
            bl.ping = { data, _, serial in
                guard let data else { return }
                let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
                aw_xdg_wm_base_pong(raw(d.wmBase!), serial)
            }
            addListener(to: b, listener: bl, data: me)
        default:
            break
        }
    }

    private func seatCapabilities(_ caps: UInt32) {
        guard let seat else { return }
        if caps & kSeatCapabilityKeyboard != 0, keyboard == nil {
            bindKeyboard(seat)
        }
        if caps & kSeatCapabilityPointer != 0, pointer == nil {
            guard let p = opt(aw_seat_get_pointer(raw(seat))) else { return }
            pointer = p
            let me = Unmanaged.passUnretained(self).toOpaque()
            var pl = wl_pointer_listener()
            // enter carries the surface the pointer entered; we route to the
            // window or the popup accordingly (a grabbing menu takes the
            // pointer). The serial is stashed for a subsequent popup grab.
            pl.enter = { data, _, serial, surfaceRaw, sx, sy in
                guard let data else { return }
                let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
                d.lastPointerSerial = serial
                d.updatePointerTarget(surfaceRaw)
                d.routePointerMotion(sx, sy)
            }
            pl.leave = { data, _, _, _ in
                guard let data else { return }
                let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
                d.pointerOnPopup = false
            }
            pl.motion = { data, _, _, sx, sy in
                guard let data else { return }
                let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
                d.routePointerMotion(sx, sy)
            }
            pl.button = { data, _, serial, _, button, state in
                guard let data else { return }
                let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
                d.lastPointerSerial = serial
                d.routePointerButton(button, pressed: state == 1)
            }
            // libwayland aborts if it dispatches an event whose listener slot is
            // NULL, so EVERY event of the bound version (5) needs a handler even
            // when we ignore it. wlroots emits `frame` after every event group;
            // the axis events fire on scroll. (Only surfaces with a real pointer
            // hit this, so it stayed hidden until virtual-pointer input.)
            pl.frame = { _, _ in }
            pl.axis = { _, _, _, _, _ in }
            pl.axis_source = { _, _, _ in }
            pl.axis_stop = { _, _, _, _ in }
            pl.axis_discrete = { _, _, _, _ in }
            addListener(to: p, listener: pl, data: me)
        }
    }

    // Which surface is the pointer over? A live popup surface wins (it has the
    // grab); otherwise the window.
    private func updatePointerTarget(_ surface: OpaquePointer?) {
        if let surface, let popup = activePopup, surface == popup.surface {
            pointerOnPopup = true
        } else {
            pointerOnPopup = false
        }
    }

    private func routePointerMotion(_ sx: Int32, _ sy: Int32) {
        if pointerOnPopup, let popup = activePopup {
            popup.pointerMoved(fx: sx, fy: sy)
        } else {
            window?.pointerMoved(fx: sx, fy: sy)
        }
    }

    private func routePointerButton(_ button: UInt32, pressed: Bool) {
        if pointerOnPopup, let popup = activePopup {
            if button == 0x110 { popup.pointerButton(pressed: pressed) }  // BTN_LEFT
        } else {
            window?.pointerButton(button, pressed: pressed)
        }
    }

    private func bindKeyboard(_ seat: OpaquePointer) {
        guard let k = opt(aw_seat_get_keyboard(raw(seat))) else { return }
        keyboard = k
        let me = Unmanaged.passUnretained(self).toOpaque()
        var kl = wl_keyboard_listener()
        // The compositor hands us its active keymap over a fd; xkbcommon
        // compiles it so key events resolve to the right keysyms/text.
        kl.keymap = { data, _, format, fd, size in
            guard let data else { return }
            let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
            d.keyboardState?.loadKeymap(fd: fd, size: size, format: format)
        }
        kl.enter = { _, _, _, _, _ in }
        kl.leave = { _, _, _, _ in }
        kl.key = { data, _, _, _, key, state in
            guard let data else { return }
            let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
            // wl_keyboard.key_state: 1 == pressed.
            guard let ev = d.keyboardState?.event(evdev: key, pressed: state == 1)
            else { return }
            d.window?.keyEvent(ev)
        }
        kl.modifiers = { data, _, _, dep, lat, lock, group in
            guard let data else { return }
            let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
            d.keyboardState?.updateModifiers(depressed: dep, latched: lat,
                                             locked: lock, group: group)
        }
        // Bound at seat v5, so every slot must be non-NULL (the NULL-listener
        // abort trap); repeat_info arrived in wl_keyboard v4.
        kl.repeat_info = { _, _, _, _ in }
        addListener(to: k, listener: kl, data: me)
    }

    /// Block dispatching events until the window is closed (or the connection
    /// errors). Wayland delivers all input/frame callbacks on this thread.
    public func run() {
        while running {
            if wl_display_dispatch(display) == -1 { break }
        }
    }

    public func stop() { running = false }
}
