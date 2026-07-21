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

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@inline(__always) func raw(_ p: OpaquePointer) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(p)
}
@inline(__always) func opt(_ p: UnsafeMutableRawPointer?) -> OpaquePointer? {
    p.map(OpaquePointer.init)
}

// wl_seat_capability bits (avoids importing the C enum).
private let kSeatCapabilityPointer: UInt32 = 1
private let kSeatCapabilityKeyboard: UInt32 = 2

// A bound wl_output and its integer scale factor. wl_output batches its
// properties and only makes them current on the `done` event, so we stage the
// scale in `pendingScale` and commit it on `done`.
final class OutputInfo {
    let name: UInt32          // registry name, for global_remove
    let proxy: OpaquePointer
    var scale: Int32 = 1
    var pendingScale: Int32 = 1
    init(name: UInt32, proxy: OpaquePointer) { self.name = name; self.proxy = proxy }
}

public final class Display {
    let display: OpaquePointer
    let registry: OpaquePointer

    var compositor: OpaquePointer?
    var shm: OpaquePointer?
    var seat: OpaquePointer?
    var wmBase: OpaquePointer?
    var layerShell: OpaquePointer?
    var pointer: OpaquePointer?
    var keyboard: OpaquePointer?

    // Every wl_output we've bound, with its current scale. The window consults
    // these (via outputScale) for the surfaces it's shown on.
    private var outputs: [OutputInfo] = []

    // xkbcommon translation for keyboard input; created lazily with the seat.
    let keyboardState = KeyboardState()

    // The (single, for now) primary surface that receives input + drives frames.
    // A process runs either an xdg-shell app (window) or a shell component
    // (layerSurface) — exactly one is set. Input routes to whichever is present.
    public weak var window: Window?
    public weak var layerSurface: LayerSurface?

    // The active grabbing popup (menu), if any. Weak — the caller owns it; we
    // just route input to it and clear on teardown. Set in Popup.init.
    weak var activePopup: Popup?
    // Serial of the most recent pointer button event — xdg_popup.grab needs it.
    var lastPointerSerial: UInt32 = 0
    // Whether the pointer is currently over the popup surface (vs the window).
    private var pointerOnPopup = false

    // The currently held auto-repeating key, if any: its evdev code, the event
    // to re-deliver, and the monotonic-ms deadline for the next repeat.
    private var repeatKey: (evdev: UInt32, event: KeyEvent, nextMs: Int64)?

    // Extra fds polled in the run loop alongside the Wayland fd, each with a
    // handler run when it's readable — config-watch (PoolConfig), IPC sockets,
    // timers. The handler runs after the Wayland read is resolved, so it may
    // safely issue Wayland requests (e.g. setNeedsDisplay).
    private var extraFds: [(fd: Int32, handler: () -> Void)] = []

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
        rl.global_remove = { data, _, name in
            guard let data else { return }
            let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
            d.handleGlobalRemove(name: name)
        }
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
        case "zwlr_layer_shell_v1":
            // v4 brings keyboard on_demand + since-4 configure semantics; the
            // menu bar/Dock will want it. It has no events, so no listener.
            layerShell = opt(aw_bind_layer_shell(raw(registry), name, min(version, 4)))
        case "wl_output":
            // v2 is where the `scale` event lands (and `done` batches props).
            guard let o = opt(aw_bind_output(raw(registry), name, min(version, 2)))
            else { return }
            outputs.append(OutputInfo(name: name, proxy: o))
            var ol = wl_output_listener()
            ol.geometry = { _, _, _, _, _, _, _, _, _, _ in }
            ol.mode = { _, _, _, _, _, _ in }
            ol.done = { data, output in
                guard let data, let output else { return }
                let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
                d.outputDone(output)
            }
            ol.scale = { data, output, factor in
                guard let data, let output else { return }
                let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
                d.outputScaleChanged(output, factor)
            }
            addListener(to: o, listener: ol, data: me)
        default:
            break
        }
    }

    private func handleGlobalRemove(name: UInt32) {
        guard let i = outputs.firstIndex(where: { $0.name == name }) else { return }
        outputs.remove(at: i)      // compositor destroys the proxy on its side
        window?.recomputeScale()
        layerSurface?.recomputeScale()
    }

    // The pending scale for `proxy` (staged until the next `done`).
    private func outputScaleChanged(_ proxy: OpaquePointer, _ factor: Int32) {
        for o in outputs where o.proxy == proxy { o.pendingScale = max(1, factor) }
    }

    // Commit staged properties; a scale change re-evaluates the window's scale.
    private func outputDone(_ proxy: OpaquePointer) {
        for o in outputs where o.proxy == proxy && o.scale != o.pendingScale {
            o.scale = o.pendingScale
            window?.recomputeScale()
            layerSurface?.recomputeScale()
        }
    }

    /// The integer scale of a bound output (1 if we don't know it).
    func outputScale(_ proxy: OpaquePointer) -> Int32 {
        for o in outputs where o.proxy == proxy { return o.scale }
        return 1
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
            // when we ignore it. wlroots emits `frame` after every event group.
            pl.frame = { _, _ in }
            // Scroll wheel / touchpad: route the vertical/horizontal axis to the
            // window (value is wl_fixed 24.8 → logical px). Menus don't scroll.
            pl.axis = { data, _, _, axis, value in
                guard let data else { return }
                let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
                d.routePointerAxis(axis, value: Double(value) / 256.0)
            }
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
        } else if let window {
            window.pointerMoved(fx: sx, fy: sy)
        } else {
            layerSurface?.pointerMoved(fx: sx, fy: sy)
        }
    }

    private func routePointerButton(_ button: UInt32, pressed: Bool) {
        if pointerOnPopup, let popup = activePopup {
            if button == 0x110 { popup.pointerButton(pressed: pressed) }  // BTN_LEFT
        } else if let window {
            window.pointerButton(button, pressed: pressed)
        } else {
            layerSurface?.pointerButton(button, pressed: pressed)
        }
    }

    private func routePointerAxis(_ axis: UInt32, value: Double) {
        // The primary surface scrolls; an open menu just stays put.
        guard !pointerOnPopup else { return }
        if let window { window.pointerAxis(axis, value: value) }
        else { layerSurface?.pointerAxis(axis, value: value) }
    }

    // Keyboard goes to the primary surface (window or shell layer surface). A
    // grabbing popup does not steal keyboard from our client (see HANDOFF §2.12),
    // so the window/layer surface forwards to its open menu itself.
    private func routeKeyEvent(_ ev: KeyEvent) {
        if let window { window.keyEvent(ev) }
        else { layerSurface?.keyEvent(ev) }
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
            let pressed = state == 1
            guard let ev = d.keyboardState?.event(evdev: key, pressed: pressed)
            else { return }
            d.routeKeyEvent(ev)
            if pressed { d.startRepeat(evdev: key, event: ev) }
            else { d.stopRepeat(evdev: key) }
        }
        kl.modifiers = { data, _, _, dep, lat, lock, group in
            guard let data else { return }
            let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
            d.keyboardState?.updateModifiers(depressed: dep, latched: lat,
                                             locked: lock, group: group)
        }
        // Bound at seat v5, so every slot must be non-NULL (the NULL-listener
        // abort trap); repeat_info arrived in wl_keyboard v4.
        kl.repeat_info = { data, _, rate, delay in
            guard let data else { return }
            let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
            d.keyboardState?.setRepeatInfo(rate: rate, delay: delay)
        }
        addListener(to: k, listener: kl, data: me)
    }

    // MARK: Key repeat

    private func nowMs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }

    /// Begin auto-repeating `event` if the compositor enabled repeat and the
    /// keymap marks this key as repeating. Only the latest key repeats.
    private func startRepeat(evdev: UInt32, event: KeyEvent) {
        guard let ks = keyboardState, ks.repeatRate > 0,
              ks.keyRepeats(evdev: evdev) else { repeatKey = nil; return }
        repeatKey = (evdev, event, nowMs() + Int64(ks.repeatDelayMs))
    }

    private func stopRepeat(evdev: UInt32) {
        if repeatKey?.evdev == evdev { repeatKey = nil }
    }

    // ms until the next repeat is due, for the poll timeout (nil = no repeat).
    private func repeatTimeoutMs() -> Int32? {
        guard let rk = repeatKey else { return nil }
        return Int32(max(0, min(rk.nextMs - nowMs(), 1000)))
    }

    // Deliver any repeats whose deadline has passed, advancing the next deadline.
    private func fireDueRepeats() {
        guard var rk = repeatKey, let ks = keyboardState, ks.repeatRate > 0 else { return }
        let now = nowMs()
        let interval = max(Int64(1000 / ks.repeatRate), 1)
        while now >= rk.nextMs {
            routeKeyEvent(rk.event)
            rk.nextMs += interval
            if rk.nextMs <= now { rk.nextMs = now + interval }  // don't burst after a stall
        }
        repeatKey = rk
    }

    /// Dispatch events until the window closes (or the connection errors). Uses
    /// the prepare_read/read_events pattern so poll can wake on a key-repeat
    /// deadline as well as on incoming Wayland events. All input/frame callbacks
    /// run on this thread.
    public func run() {
        let wlfd = wl_display_get_fd(display)
        while running {
            // Dispatch anything already queued, then arm a read.
            while wl_display_prepare_read(display) != 0 {
                if wl_display_dispatch_pending(display) == -1 { running = false; break }
            }
            if !running { wl_display_cancel_read(display); break }
            wl_display_flush(display)

            // Poll the Wayland fd (slot 0) plus any registered extra fds.
            var pfds = [pollfd(fd: wlfd, events: Int16(POLLIN), revents: 0)]
            for e in extraFds {
                pfds.append(pollfd(fd: e.fd, events: Int16(POLLIN), revents: 0))
            }
            let timeout = repeatTimeoutMs() ?? -1
            let pr = pfds.withUnsafeMutableBufferPointer {
                poll($0.baseAddress, nfds_t($0.count), timeout)
            }

            // Resolve the armed Wayland read FIRST (read or cancel) before running
            // any extra-fd handler that might issue Wayland requests.
            if pr > 0 && (pfds[0].revents & Int16(POLLIN)) != 0 {
                if wl_display_read_events(display) == -1 { break }
                if wl_display_dispatch_pending(display) == -1 { break }
            } else {
                wl_display_cancel_read(display)  // timeout or interrupt
            }
            if pr > 0 {
                for (i, e) in extraFds.enumerated()
                where (pfds[i + 1].revents & Int16(POLLIN)) != 0 {
                    e.handler()
                }
            }
            fireDueRepeats()
        }
    }

    /// Register an extra fd to poll in the run loop; `onReadable` fires whenever
    /// it becomes readable. For config-watch (PoolConfig), IPC sockets, timers.
    public func addFileDescriptor(_ fd: Int32, onReadable: @escaping () -> Void) {
        extraFds.append((fd, onReadable))
    }

    public func stop() { running = false }
}
