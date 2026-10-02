// Surface — the AbyssBSD Swift Wayland client runtime.
//
// Display owns the connection, the registry, and the global singletons
// (compositor, shm, seat, xdg_wm_base) plus the pointer. It runs the dispatch
// loop. Window (Window.swift) layers xdg-shell + shm buffers + rendering on top.
//
// libwayland's requests and add_listener functions are static-inline, and Swift
// calls them directly (HANDOFF §2.1); opaque wl_* handles are OpaquePointer.
// Binding a global is the exception, and goes through wlBind below.

import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// `wl_registry_bind`, for one of the interfaces CWayland lists as `*_iface`.
/// Never pass `&some_interface` or `withUnsafePointer(to: some_interface)`: in
/// a release build that is a pointer to a copy, and libwayland keeps it as the
/// proxy's interface for the life of the connection (cwayland.h).
@inline(__always) func wlBind(_ registry: OpaquePointer, _ name: UInt32,
                              _ interface: UnsafePointer<wl_interface>,
                              _ version: UInt32) -> OpaquePointer? {
    wl_registry_bind(registry, name, interface, version).map(OpaquePointer.init)
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
    /// The newest version of each of our own protocols this client handles:
    /// its bind cap (HANDOFF §2.117). Bumping a protocol's XML without this
    /// left the client on the old version, silently, twice (P13.4, P18.13b),
    /// so `ProtocolVersionTests` holds each to its XML's `version`.
    ///   abyss_menubar_v1: v3 islands, v4 shoals (PHASE13), v5 jail (P18.6),
    ///   v6 window_pid (P18.13b).
    public static let ourVersions: [String: UInt32] = [
        "abyss_menu_manager_v1": 1,
        "abyss_window_manager_v1": 2,
        "abyss_menubar_v1": 6,
    ]

    let display: OpaquePointer
    let registry: OpaquePointer

    var compositor: OpaquePointer?
    var shm: OpaquePointer?
    var seat: OpaquePointer?
    var wmBase: OpaquePointer?
    var layerShell: OpaquePointer?
    var activation: OpaquePointer?
    var screencopy: OpaquePointer?
    var screencopyVersion: UInt32 = 0
    /// `ext_session_lock_manager_v1` (PHASE16 P16.2b): the lock screen's.
    var sessionLockManager: OpaquePointer?
    public var hasSessionLock: Bool { sessionLockManager != nil }
    /// `ext_idle_notifier_v1` (P16.3): idleness, as the compositor counts it.
    var idleNotifier: OpaquePointer?
    public var hasIdleNotifier: Bool { idleNotifier != nil }
    /// A display appeared or went (index into the bound outputs / its proxy):
    /// a lock must cover every display, including one plugged in while locked.
    public var outputAdded: ((Int) -> Void)?
    var outputRemoved: ((OpaquePointer) -> Void)?
    var pointer: OpaquePointer?
    var keyboard: OpaquePointer?

    // The foreign-toplevel manager global, captured by name/version rather than
    // bound here — a client that wants it (the Dock) binds and listens in one
    // step via ForeignToplevels, so no `toplevel` event hits a NULL listener.
    public internal(set) var foreignToplevelManager: (name: UInt32, version: UInt32)?

    /// `abyss_menu_manager_v1` (PHASE10.md P10.3): how a window says where its
    /// menus are published. No events, so bound on sight.
    var menuManager: OpaquePointer?
    public var hasMenuManager: Bool { menuManager != nil }
    /// `abyss_window_manager_v1` (P11.6): window operations xdg-shell lacks —
    /// sending a window to the back. No events, so bound on sight.
    var windowManager: OpaquePointer?
    var windowManagerVersion: UInt32 = 0
    /// `abyss_menubar_v1`, by name — offered only on undertow's privileged
    /// socket, so its presence is itself the answer to "am I the menu bar's
    /// connection". Bound with its listener by `MenuBarFocus`.
    public internal(set) var menubarGlobal: (name: UInt32, version: UInt32)?

    // Every wl_output we've bound, with its current scale. The window consults
    // these (via outputScale) for the surfaces it's shown on.
    private var outputs: [OutputInfo] = []

    // xkbcommon translation for keyboard input; created lazily with the seat.
    let keyboardState = KeyboardState()

    // Every live Window, so input can be routed to the one the event names.
    // Held weakly: the caller owns its windows (see HANDOFF §2.7).
    private final class WeakWindow {
        weak var window: Window?
        init(_ w: Window) { window = w }
    }
    private var windowRegistry: [WeakWindow] = []

    // The primary window: set to the first one registered, and used as the
    // fallback target before the first pointer/keyboard `enter` names a surface.
    // A process runs either xdg-shell windows or a shell component
    // (layerSurface); input routes to whichever is present.
    public weak var window: Window?
    public weak var layerSurface: LayerSurface?

    // Which window the pointer is over / the keyboard is focused on. Both come
    // from the `enter` events, which carry the wl_surface — that is what makes a
    // multi-window app (the spatial Finder) route correctly.
    private weak var pointerWindow: Window?
    private weak var keyboardWindow: Window?
    // …and whether they're on the shell layer surface instead. A process can own
    // both (the Desktop opens Finder windows), so "is there a window?" is not a
    // safe proxy for where an event belongs — only the surface is.
    private var pointerOnLayer = false
    private var keyboardOnLayer = false

    // Lock surfaces (PHASE16 P16.2b), one per display, and which one the
    // pointer and the keyboard are on. A lock surface is checked first: while
    // a process holds the lock, they are the only surfaces it is shown.
    private var lockSurfaces: [WeakLockSurface] = []
    private weak var pointerLock: LockSurface?
    private weak var keyboardLock: LockSurface?
    func lockSurfaceAdded(_ l: LockSurface) {
        lockSurfaces.removeAll { $0.surface == nil }
        lockSurfaces.append(WeakLockSurface(l))
    }
    func lockSurfaceRemoved(_ l: LockSurface) {
        lockSurfaces.removeAll { $0.surface == nil || $0.surface === l }
    }
    private func lockSurface(for surface: OpaquePointer?) -> LockSurface? {
        guard let surface else { return nil }
        return lockSurfaces.lazy.compactMap { $0.surface }.first { $0.surface == surface }
    }

    // The open grabbing popups, oldest first — a menu and the submenus opened
    // from it (P10.8). Weak: the caller owns each; we route input to the one
    // the pointer is on. Pushed in Popup.init, removed on teardown.
    private var openPopups: [WeakPopup] = []
    /// The topmost open popup: the last one opened and not yet gone.
    var activePopup: Popup? { openPopups.last(where: { $0.popup != nil })?.popup }
    func popupOpened(_ p: Popup) { openPopups.removeAll { $0.popup == nil }; openPopups.append(WeakPopup(p)) }
    func popupClosed(_ p: Popup) {
        openPopups.removeAll { $0.popup == nil || $0.popup === p }
        if pointerPopup === p { pointerPopup = nil; pointerOnPopup = false }
    }
    /// The popup the pointer is over — any of the open ones, not only the top.
    private weak var pointerPopup: Popup?
    // Serial of the most recent pointer button event — xdg_popup.grab needs it.
    /// The most recent **pointer** serial.
    ///
    /// Kept apart from `lastInputSerial` because two things want specifically a
    /// pointer serial and would be wrong with a keyboard one: a popup grab, and
    /// starting a drag — the compositor validates both against a pointer press,
    /// which is what stops a menu opening or a drag beginning off a keystroke.
    public internal(set) var lastPointerSerial: UInt32 = 0
    /// The most recent serial from **any** input event, pointer or keyboard.
    ///
    /// The clipboard needs one: wlroots checks that a `set_selection` quotes a
    /// serial the client was actually given, which is what stops a program
    /// taking the clipboard off an input it never received. Kept separately from
    /// `lastPointerSerial` because a popup grab specifically wants a *pointer*
    /// serial, and conflating them would let a menu open off a keystroke.
    public internal(set) var lastInputSerial: UInt32 = 0

    private var dataDeviceManager: OpaquePointer?
    /// The clipboard, once both `wl_seat` and `wl_data_device_manager` exist.
    ///
    /// nil on a compositor that offers no data device — which is a real case
    /// and not a crash: an application should degrade to no clipboard rather
    /// than refuse to start.
    public private(set) var clipboard: Clipboard?

    private func attachClipboardIfReady() {
        guard clipboard == nil, let m = dataDeviceManager, let s = seat else { return }
        clipboard = Clipboard(display: self, manager: m, seat: s)
    }

    /// Push queued requests to the compositor now.
    ///
    /// Ordinarily the run loop does this. The clipboard cannot wait for it: a
    /// paste asks the *other* client to write into a pipe and then blocks
    /// reading it, so a request still sitting in libwayland's buffer is a
    /// deadlock with nothing in any log.
    public func flush() { wl_display_flush(display) }

    /// Send everything queued and wait for the compositor to answer it.
    ///
    /// The constructor already does two of these — globals, then the follow-ups
    /// they issue. A clipboard reader needs a third: the data device's own
    /// events, including the selection we may already have been handed, arrive
    /// only after the device object exists, which is after the second.
    public func roundtrip() { wl_display_roundtrip(display) }

    // MARK: - Which window is where (P15.6)

    /// One answer to `window_at`: a window's box (the compositor's frame
    /// included) and what it calls itself.
    public struct WindowAt: Equatable, Sendable {
        public let x: Int32, y: Int32, width: Int32, height: Int32
        public let appID: String, title: String
    }

    private final class WindowAtAnswer { var answered = false; var window: WindowAt? }
    /// One listener for every query, made once: `addListener` keeps what it is
    /// given, and Grab asks on every pointer motion.
    private var windowQueryListener: UnsafeMutablePointer<abyss_window_query_v1_listener>?

    /// Which window is topmost at (x, y) in the layout's coordinates, asked of
    /// the compositor (`abyss_window_manager_v1` v2) — Grab's Window mode. nil
    /// when nothing is there, or the compositor cannot say.
    public func windowAt(x: Int32, y: Int32) -> WindowAt? {
        guard let manager = windowManager, windowManagerVersion >= 2,
              let q = abyss_window_manager_v1_window_at(manager, x, y) else { return nil }
        if windowQueryListener == nil {
            var l = abyss_window_query_v1_listener()
            l.window = { data, _, x, y, w, h, app, title in
                guard let data else { return }
                let a = Unmanaged<WindowAtAnswer>.fromOpaque(data).takeUnretainedValue()
                a.window = WindowAt(x: x, y: y, width: w, height: h,
                                    appID: app.map { String(cString: $0) } ?? "",
                                    title: title.map { String(cString: $0) } ?? "")
                a.answered = true
            }
            l.none = { data, _ in
                guard let data else { return }
                Unmanaged<WindowAtAnswer>.fromOpaque(data).takeUnretainedValue().answered = true
            }
            let p = UnsafeMutablePointer<abyss_window_query_v1_listener>.allocate(capacity: 1)
            p.initialize(to: l)
            windowQueryListener = p
        }
        let answer = WindowAtAnswer()
        let data = Unmanaged.passUnretained(answer).toOpaque()
        _ = UnsafeMutableRawPointer(windowQueryListener!).withMemoryRebound(
            to: (@convention(c) () -> Void)?.self, capacity: 1) { wl_proxy_add_listener(q, $0, data) }
        // The compositor answers at once; a round trip is enough.
        var tries = 0
        while !answer.answered && tries < 3 { wl_display_roundtrip(display); tries += 1 }
        abyss_window_query_v1_destroy(q)
        return withExtendedLifetime(answer) { answer.window }
    }
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
        guard let reg = wl_display_get_registry(d) else {
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

    // MARK: window registry

    /// Called by Window.init. The first window becomes the primary one.
    func register(window w: Window) {
        windowRegistry.removeAll { $0.window == nil }
        windowRegistry.append(WeakWindow(w))
        if window == nil { window = w }
    }

    /// Called by Window.close/deinit; promotes another window to primary.
    func unregister(window w: Window) {
        windowRegistry.removeAll { $0.window == nil || $0.window === w }
        if pointerWindow === w { pointerWindow = nil }
        if keyboardWindow === w { keyboardWindow = nil }
        if window === w { window = windowRegistry.first?.window }
    }

    /// The window owning `surface`, if it's one of ours.
    func window(forSurface surface: OpaquePointer?) -> Window? {
        guard let surface else { return nil }
        for box in windowRegistry where box.window?.surface == surface {
            return box.window
        }
        return nil
    }

    /// The surface an activation request should claim to come from: whatever
    /// currently holds keyboard focus (else the primary window's).
    var activationSourceSurface: OpaquePointer? {
        (keyboardWindow ?? window)?.surface
    }

    // Store a copy of `listener` on the heap and register it on `proxy`.
    func addListener<L>(to proxy: OpaquePointer, listener: L,
                        data: UnsafeMutableRawPointer) {
        let p = UnsafeMutablePointer<L>.allocate(capacity: 1)
        p.initialize(to: listener)
        listenerStorage.append(UnsafeMutableRawPointer(p))
        // The generic form every generated `*_add_listener` forwards to.
        _ = UnsafeMutableRawPointer(p).withMemoryRebound(
            to: (@convention(c) () -> Void)?.self, capacity: 1) {
            wl_proxy_add_listener(proxy, $0, data)
        }
    }

    private func handleGlobal(name: UInt32, interface: String, version: UInt32) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        switch interface {
        case "wl_compositor":
            compositor = wlBind(registry, name, wl_compositor_iface, min(version, 4))
        case "wl_shm":
            shm = wlBind(registry, name, wl_shm_iface, 1)
        case "wl_data_device_manager":
            // v3 is where drag actions live (P9.3); the selection half works at
            // any version, and asking for more than the compositor has is an
            // error rather than a downgrade.
            dataDeviceManager = wlBind(registry, name, wl_data_device_manager_iface, min(version, 3))
            attachClipboardIfReady()
        case "wl_seat":
            guard let s = wlBind(registry, name, wl_seat_iface, min(version, 5))
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
            // **Either global may arrive first.** The registry advertises in
            // whatever order the compositor chose, so the clipboard is built
            // when the second of the two lands rather than from one of them.
            attachClipboardIfReady()
        case "xdg_wm_base":
            // v6 (T.3): `suspended` (don't draw for nobody), `wm_capabilities`
            // (don't ask for what is not served) and `configure_bounds` (the
            // most room there is). Every one of their listener slots is
            // filled in Window — libwayland aborts on an event with none.
            guard let b = wlBind(registry, name, xdg_wm_base_iface, min(version, 6))
            else { return }
            wmBase = b
            var bl = xdg_wm_base_listener()
            bl.ping = { data, _, serial in
                guard let data else { return }
                let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
                xdg_wm_base_pong(d.wmBase!, serial)
            }
            addListener(to: b, listener: bl, data: me)
        case "zwlr_layer_shell_v1":
            // v4 brings keyboard on_demand + since-4 configure semantics; the
            // menu bar/Dock will want it. It has no events, so no listener.
            layerShell = wlBind(registry, name, zwlr_layer_shell_v1_iface, min(version, 4))
        case "zwlr_foreign_toplevel_manager_v1":
            foreignToplevelManager = (name, min(version, 3))
        case "abyss_menu_manager_v1":
            menuManager = wlBind(registry, name, abyss_menu_manager_v1_iface, Display.ourVersions["abyss_menu_manager_v1"]!)
        case "abyss_window_manager_v1":
            windowManagerVersion = min(version, Display.ourVersions["abyss_window_manager_v1"]!)
            windowManager = wlBind(registry, name, abyss_window_manager_v1_iface, windowManagerVersion)
        case "abyss_menubar_v1":
            menubarGlobal = (name, min(version, Display.ourVersions["abyss_menubar_v1"]!))
        case "xdg_activation_v1":
            // No events on the manager itself, so it binds with no listener;
            // the per-request token object is the thing that reports back.
            activation = wlBind(registry, name, xdg_activation_v1_iface, min(version, 1))
        case "ext_idle_notifier_v1":
            // v1's notifications honour idle inhibitors — the one idea of
            // idle (HANDOFF §2.86) the session's policy must share (P16.3).
            idleNotifier = wlBind(registry, name, ext_idle_notifier_v1_iface, 1)
        case "ext_session_lock_manager_v1":
            // No events on the manager; the lock object reports back.
            sessionLockManager = wlBind(registry, name, ext_session_lock_manager_v1_iface, 1)
        case "zwlr_screencopy_manager_v1":
            // v3 adds buffer_done, which is what says "I've told you every
            // buffer type I take — now send copy". Below it, the wl_shm buffer
            // event is guaranteed and stands alone (Screencopy.swift). The
            // manager has no events, so it binds with no listener.
            screencopyVersion = min(version, 3)
            screencopy = wlBind(registry, name, zwlr_screencopy_manager_v1_iface, screencopyVersion)
        case "wl_output":
            // v2 is where the `scale` event lands (and `done` batches props).
            guard let o = wlBind(registry, name, wl_output_iface, min(version, 2))
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
            outputAdded?(outputs.count - 1)
        default:
            break
        }
    }

    private func handleGlobalRemove(name: UInt32) {
        guard let i = outputs.firstIndex(where: { $0.name == name }) else { return }
        outputRemoved?(outputs[i].proxy)
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

    /// How many `wl_output` globals we've bound. A screenshot needs to name one.
    public var outputCount: Int { outputs.count }

    /// A bound output by index, in the order the registry advertised them.
    func output(at index: Int) -> OpaquePointer? {
        guard index >= 0, index < outputs.count else { return nil }
        return outputs[index].proxy
    }

    private func seatCapabilities(_ caps: UInt32) {
        guard let seat else { return }
        if caps & kSeatCapabilityKeyboard != 0, keyboard == nil {
            bindKeyboard(seat)
        }
        if caps & kSeatCapabilityPointer != 0, pointer == nil {
            guard let p = wl_seat_get_pointer(seat) else { return }
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
                d.lastInputSerial = serial
                d.updatePointerTarget(surfaceRaw)
                d.routePointerMotion(sx, sy)
            }
            pl.leave = { data, _, _, _ in
                guard let data else { return }
                let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
                // If the pointer left the primary layer surface (not into a
                // popup), let it reset hover state (e.g. Dock magnification).
                if let l = d.pointerLock { l.pointerLeft(); d.pointerLock = nil }
                else if !d.pointerOnPopup { d.layerSurface?.pointerLeft() }
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
                d.lastInputSerial = serial
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
    // grab); otherwise it names one of our windows (or the layer surface).
    private func updatePointerTarget(_ surface: OpaquePointer?) {
        pointerOnPopup = false
        pointerOnLayer = false
        pointerLock = lockSurface(for: surface)
        guard let surface, pointerLock == nil else { return }
        if let popup = openPopups.lazy.compactMap({ $0.popup }).first(where: { $0.surface == surface }) {
            pointerOnPopup = true
            pointerPopup = popup
        } else if let w = window(forSurface: surface) {
            pointerWindow = w
        } else if let ls = layerSurface, surface == ls.surface {
            pointerOnLayer = true
            pointerWindow = nil
        }
    }

    private func routePointerMotion(_ sx: Int32, _ sy: Int32) {
        if let l = pointerLock { l.pointerMoved(fx: sx, fy: sy); return }
        if pointerOnPopup, let popup = pointerPopup {
            popup.pointerMoved(fx: sx, fy: sy)
        } else if pointerOnLayer {
            layerSurface?.pointerMoved(fx: sx, fy: sy)
        } else if let w = pointerWindow ?? window {
            w.pointerMoved(fx: sx, fy: sy)
        } else {
            layerSurface?.pointerMoved(fx: sx, fy: sy)
        }
    }

    private func routePointerButton(_ button: UInt32, pressed: Bool) {
        if let l = pointerLock { l.pointerButton(button, pressed: pressed); return }
        if pointerOnPopup, let popup = pointerPopup {
            if button == 0x110 { popup.pointerButton(pressed: pressed) }  // BTN_LEFT
        } else if pointerOnLayer {
            layerSurface?.pointerButton(button, pressed: pressed)
        } else if let w = pointerWindow ?? window {
            w.pointerButton(button, pressed: pressed)
        } else {
            layerSurface?.pointerButton(button, pressed: pressed)
        }
    }

    private func routePointerAxis(_ axis: UInt32, value: Double) {
        // The primary surface scrolls; an open menu just stays put.
        guard !pointerOnPopup, pointerLock == nil else { return }
        if pointerOnLayer { layerSurface?.pointerAxis(axis, value: value) }
        else if let w = pointerWindow ?? window { w.pointerAxis(axis, value: value) }
        else { layerSurface?.pointerAxis(axis, value: value) }
    }

    // Keyboard goes to the focused window (from wl_keyboard.enter) or the shell
    // layer surface. A grabbing popup does not steal keyboard from our client
    // (see HANDOFF §2.12), so the window/layer surface forwards to its open menu.
    private func routeKeyEvent(_ ev: KeyEvent) {
        if let l = keyboardLock { l.keyEvent(ev); return }
        if keyboardOnLayer { layerSurface?.keyEvent(ev) }
        else if let w = keyboardWindow ?? window { w.keyEvent(ev) }
        else { layerSurface?.keyEvent(ev) }
    }

    private func keyboardFocus(_ surface: OpaquePointer?) {
        if let l = lockSurface(for: surface) {
            keyboardLock = l
            return
        }
        keyboardLock = nil
        if let w = window(forSurface: surface) {
            keyboardWindow = w
            keyboardOnLayer = false
        } else if let ls = layerSurface, surface == ls.surface {
            keyboardWindow = nil
            keyboardOnLayer = true
        }
    }

    private func keyboardBlur(_ surface: OpaquePointer?) {
        if let l = keyboardLock, l.surface == surface {
            keyboardLock = nil
            repeatKey = nil
            return
        }
        if let w = window(forSurface: surface), keyboardWindow === w {
            keyboardWindow = nil
            repeatKey = nil        // don't keep repeating into an unfocused window
        } else if let ls = layerSurface, surface == ls.surface {
            keyboardOnLayer = false
            repeatKey = nil
        }
    }

    private func bindKeyboard(_ seat: OpaquePointer) {
        guard let k = wl_seat_get_keyboard(seat) else { return }
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
        // enter/leave carry the focused surface: in a multi-window app that is
        // what decides where typing goes. (Imported as OpaquePointer?, like
        // wl_pointer.enter's surface — see HANDOFF §2.10.)
        kl.enter = { data, _, _, surface, _ in
            guard let data else { return }
            let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
            d.keyboardFocus(surface)
        }
        kl.leave = { data, _, _, surface in
            guard let data else { return }
            let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
            d.keyboardBlur(surface)
        }
        kl.key = { data, _, serial, _, key, state in
            guard let data else { return }
            let d = Unmanaged<Display>.fromOpaque(data).takeUnretainedValue()
            // **The serial a copy is allowed to quote.** ⌘C is a key press, and
            // the clipboard may only be taken with the serial of an input event
            // the client actually received (P9.1). This one was being discarded,
            // which would have left every keyboard-driven copy quoting a stale
            // pointer serial — or none at all on a desktop nobody had clicked.
            d.lastInputSerial = serial
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

    func nowMs() -> Int64 {
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
            // **The set is snapshotted HERE, where it is polled** — not after
            // the Wayland dispatch below. A handler run by that dispatch may
            // register a descriptor (the menu bar subscribes to an application
            // when a focus event arrives, P10.4), and a snapshot taken after it
            // is one entry longer than `pfds`: an index out of range, and a
            // crash, the first time anything registered from inside a Wayland
            // event rather than from a descriptor handler.
            let polled = extraFds
            var pfds = [pollfd(fd: wlfd, events: Int16(POLLIN), revents: 0)]
            for e in polled {
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
                // `extraFds` is a value, so this iterates a snapshot and a
                // handler may safely unregister things — but a handler that has
                // just been removed must not still run: it would read a
                // descriptor it already closed, and close it a second time. In
                // a process that opens sockets, a double close can shut
                // somebody else's connection that inherited the number.
                for (i, e) in polled.enumerated() {
                    let revents = pfds[i + 1].revents
                    guard revents != 0 else { continue }
                    guard extraFds.contains(where: { $0.fd == e.fd }) else { continue }
                    if (revents & Int16(POLLNVAL)) != 0 {
                        // A closed descriptor left in the set would make poll()
                        // return immediately, for ever. Drop it rather than spin.
                        removeFileDescriptor(e.fd)
                        continue
                    }
                    if (revents & Int16(POLLIN | POLLHUP)) != 0 { e.handler() }
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

    /// Stop polling an fd. The caller still owns it and must close it — and
    /// should unregister *before* closing, so no handler can run against a
    /// descriptor that is already gone.
    public func removeFileDescriptor(_ fd: Int32) {
        extraFds.removeAll { $0.fd == fd }
    }

    public func stop() { running = false }

    /// Ask every surface this connection draws to draw again: each window,
    /// the shell's layer surface, the open menu. For a change that alters how
    /// *everything* looks and nothing about what it says — the theme (P14.2).
    /// Each redraws on its own next frame, as any other change would.
    public func setEverythingNeedsDisplay() {
        for w in windowRegistry { w.window?.setNeedsDisplay() }
        layerSurface?.setNeedsDisplay()
        for p in openPopups { p.popup?.setNeedsDisplay() }
        for l in lockSurfaces { l.surface?.setNeedsDisplay() }
    }
}

/// A weak reference to a lock surface.
final class WeakLockSurface {
    weak var surface: LockSurface?
    init(_ s: LockSurface) { surface = s }
}

/// A weak reference to a popup, for the open-popup stack.
final class WeakPopup {
    weak var popup: Popup?
    init(_ p: Popup) { popup = p }
}
