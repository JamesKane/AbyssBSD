// DisplayConfigurator — wlr-output-management-v1, client side (PHASE14 P14.7b).
//
// What every display is (its name, modes, current mode, position and scale),
// and a way to ask the compositor to test or apply a new arrangement. The
// Displays pane speaks this (P14.7c), and so does `abyss-displays`, which is
// how the protocol is tested on both platforms — `wlr-randr` would do, where
// it installs, and it is not ours.
//
// The protocol in one breath: the manager announces a *head* per output, each
// head its *modes*; `done(serial)` closes a batch. A configuration is made
// against a serial — if the outputs change meanwhile, the compositor cancels it
// rather than apply something stale — and is answered succeeded, failed or
// cancelled. Every listener slot is filled: a NULL one aborts the client the
// moment its event arrives (HANDOFF §2.3).
//
// **Its own connection.** A request pumps a bounded loop until the answer, so
// a CLI is a straight-line program and a compositor that never answers is a
// timeout. On an application's own connection that pump would dispatch the
// application's other events from inside its own handlers; on a connection of
// its own it dispatches nothing but this. An application watches
// `fileDescriptor` in its run loop and calls `dispatch()`, and hears through
// `onChange` when someone else — wlr-randr, kanshi — rearranged the displays.

import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class DisplayConfigurator {
    public struct Mode: Equatable, Sendable {
        public var width: Int32, height: Int32
        /// mHz, as the protocol gives it; 0 when the output did not say.
        public var refreshMilliHz: Int32
        public var preferred: Bool
        public init(width: Int32, height: Int32, refreshMilliHz: Int32, preferred: Bool = false) {
            self.width = width; self.height = height; self.refreshMilliHz = refreshMilliHz; self.preferred = preferred
        }
    }

    public struct Head: Equatable, Sendable {
        public var name: String
        public var description: String
        public var enabled: Bool
        public var modes: [Mode]
        public var current: Mode?
        public var x: Int32, y: Int32
        public var scale: Double
        public init(name: String, description: String = "", enabled: Bool = true, modes: [Mode], current: Mode?,
                    x: Int32, y: Int32, scale: Double = 1) {
            self.name = name; self.description = description; self.enabled = enabled; self.modes = modes
            self.current = current; self.x = x; self.y = y; self.scale = scale
        }
        /// Its size in the layout: its mode over its scale.
        public var layoutWidth: Int32 { Int32((Double(current?.width ?? 0) / scale).rounded()) }
        public var layoutHeight: Int32 { Int32((Double(current?.height ?? 0) / scale).rounded()) }
    }

    /// What to ask for, per display.
    public struct Setting: Equatable, Sendable {
        public var name: String
        public var width: Int32, height: Int32
        /// 0: any refresh at that size (the output's current, if it matches).
        public var refreshMilliHz: Int32
        public var x: Int32, y: Int32
        public var scale: Double
        public init(name: String, width: Int32, height: Int32, refreshMilliHz: Int32 = 0,
                    x: Int32, y: Int32, scale: Double = 1) {
            self.name = name; self.width = width; self.height = height; self.refreshMilliHz = refreshMilliHz
            self.x = x; self.y = y; self.scale = scale
        }
    }

    public enum Outcome: Equatable, Sendable { case succeeded, failed, cancelled, timedOut }

    // MARK: - State, as the events leave it

    private final class HeadState {
        let proxy: OpaquePointer
        var name = "", description = "", enabled = false
        var modes: [OpaquePointer] = []
        var current: OpaquePointer?
        var x: Int32 = 0, y: Int32 = 0, scale = 1.0
        init(_ p: OpaquePointer) { proxy = p }
    }
    private struct ModeState { var width: Int32 = 0, height: Int32 = 0, refresh: Int32 = 0, preferred = false }

    private let wl: OpaquePointer
    private var registry: OpaquePointer?
    private var manager: OpaquePointer?
    private var heads: [HeadState] = []
    private var modes: [OpaquePointer: ModeState] = [:]
    private(set) var serial: UInt32 = 0
    private var batches = 0
    private var outcome: Outcome?

    // Listener tables live as long as this object: a proxy's listener pointer
    // is read on every event (HANDOFF §2.2).
    private let registryListener = UnsafeMutablePointer<wl_registry_listener>.allocate(capacity: 1)
    private let managerListener = UnsafeMutablePointer<zwlr_output_manager_v1_listener>.allocate(capacity: 1)
    private let headListener = UnsafeMutablePointer<zwlr_output_head_v1_listener>.allocate(capacity: 1)
    private let modeListener = UnsafeMutablePointer<zwlr_output_mode_v1_listener>.allocate(capacity: 1)
    private let configListener = UnsafeMutablePointer<zwlr_output_configuration_v1_listener>.allocate(capacity: 1)

    /// Every display, as of the last `done`.
    public var displays: [Head] {
        heads.map { h in
            func mode(_ p: OpaquePointer) -> Mode? {
                modes[p].map { Mode(width: $0.width, height: $0.height, refreshMilliHz: $0.refresh, preferred: $0.preferred) }
            }
            return Head(name: h.name, description: h.description, enabled: h.enabled,
                        modes: h.modes.compactMap(mode), current: h.current.flatMap(mode),
                        x: h.x, y: h.y, scale: h.scale)
        }
    }

    /// Bind the manager and wait for the first complete description. Nil when
    /// the compositor does not offer the protocol, or never finishes saying.
    /// Called after each complete description (`done`) — an apply of ours,
    /// or anyone's.
    public var onChange: () -> Void = {}

    /// Connect (to `$WAYLAND_DISPLAY`, as every client does), bind the manager
    /// and wait for the first complete description. Nil when there is no
    /// compositor, it does not offer the protocol, or it never finishes saying.
    public init?(timeoutMs: Int = 2000) {
        guard let d = wl_display_connect(nil) else { return nil }
        wl = d
        installListeners()
        guard let reg = wl_display_get_registry(d) else { wl_display_disconnect(d); return nil }
        registry = reg
        _ = wl_registry_add_listener(reg, registryListener,
                                     Unmanaged.passUnretained(self).toOpaque())
        _ = wl_display_roundtrip(d)
        guard manager != nil,
              pumpWayland(d, until: { batches > 0 }, timeoutMs: timeoutMs) else {
            teardown()
            return nil
        }
    }

    /// For an application's run loop: readable when the compositor said something.
    public var fileDescriptor: Int32 { wl_display_get_fd(wl) }

    /// Read and dispatch what arrived (non-blocking), then flush.
    public func dispatch() {
        if wl_display_prepare_read(wl) == 0 {
            var pfd = pollfd(fd: wl_display_get_fd(wl), events: Int16(POLLIN), revents: 0)
            if withUnsafeMutablePointer(to: &pfd, { poll($0, 1, 0) }) > 0 { _ = wl_display_read_events(wl) }
            else { wl_display_cancel_read(wl) }
        }
        _ = wl_display_dispatch_pending(wl)
        wl_display_flush(wl)
    }

    deinit { teardown() }

    private var tornDown = false
    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        for h in heads { zwlr_output_head_v1_destroy(h.proxy) }
        for m in modes.keys { zwlr_output_mode_v1_destroy(m) }
        heads = []; modes = [:]
        if let manager { zwlr_output_manager_v1_destroy(manager) }
        if let registry { wl_registry_destroy(registry) }
        wl_display_flush(wl)
        wl_display_disconnect(wl)
        registryListener.deallocate(); managerListener.deallocate(); headListener.deallocate()
        modeListener.deallocate(); configListener.deallocate()
    }

    /// Wait until the compositor has described the displays again (after an
    /// apply, it does). False on a timeout.
    @discardableResult
    public func awaitUpdate(timeoutMs: Int = 2000) -> Bool {
        let before = batches
        return pumpWayland(wl, until: { batches > before }, timeoutMs: timeoutMs)
    }

    /// Ask for `settings` to be tested (nothing changes) or applied. Every
    /// display must be named: one left out is one the protocol turns off.
    public func request(_ settings: [Setting], testOnly: Bool, timeoutMs: Int = 3000) -> Outcome {
        guard let manager else { return .failed }
        guard let config = zwlr_output_manager_v1_create_configuration(manager, serial) else { return .failed }
        defer { zwlr_output_configuration_v1_destroy(config); wl_display_flush(wl) }
        outcome = nil
        _ = zwlr_output_configuration_v1_add_listener(config, configListener,
                                                     Unmanaged.passUnretained(self).toOpaque())
        for s in settings {
            guard let h = heads.first(where: { $0.name == s.name }),
                  let ch = zwlr_output_configuration_v1_enable_head(config, h.proxy) else { continue }
            // A named mode when the output has one of that size (and rate);
            // a custom one otherwise — which a headless output always takes.
            let match = h.modes.first { p in
                guard let m = modes[p] else { return false }
                return m.width == s.width && m.height == s.height
                    && (s.refreshMilliHz == 0 || m.refresh == s.refreshMilliHz)
            }
            if let m = match { zwlr_output_configuration_head_v1_set_mode(ch, m) }
            else { zwlr_output_configuration_head_v1_set_custom_mode(ch, s.width, s.height, s.refreshMilliHz) }
            zwlr_output_configuration_head_v1_set_position(ch, s.x, s.y)
            zwlr_output_configuration_head_v1_set_scale(ch, wl_fixed_from_double(s.scale))
        }
        if testOnly { zwlr_output_configuration_v1_test(config) } else { zwlr_output_configuration_v1_apply(config) }
        guard pumpWayland(wl, until: { outcome != nil }, timeoutMs: timeoutMs) else { return .timedOut }
        return outcome ?? .timedOut
    }

    // MARK: - Listeners

    private static func me(_ data: UnsafeMutableRawPointer?) -> DisplayConfigurator {
        Unmanaged<DisplayConfigurator>.fromOpaque(data!).takeUnretainedValue()
    }
    private func head(_ p: OpaquePointer?) -> HeadState? { heads.first { $0.proxy == p } }

    private func installListeners() {
        registryListener.initialize(to: wl_registry_listener(
            global: { data, reg, name, iface, version in
                guard let iface, String(cString: iface) == "zwlr_output_manager_v1" else { return }
                let c = DisplayConfigurator.me(data)
                guard c.manager == nil, let reg,
                      let m = wlBind(reg, name, zwlr_output_manager_v1_iface, min(version, 4))
                else { return }
                c.manager = m
                _ = zwlr_output_manager_v1_add_listener(m, c.managerListener, data)
            },
            global_remove: { _, _, _ in }))

        managerListener.initialize(to: zwlr_output_manager_v1_listener(
            head: { data, _, h in
                guard let h else { return }
                let c = DisplayConfigurator.me(data)
                c.heads.append(HeadState(h))
                _ = zwlr_output_head_v1_add_listener(h, c.headListener, data)
            },
            done: { data, _, serial in
                let c = DisplayConfigurator.me(data)
                c.serial = serial
                c.batches += 1
                c.onChange()
            },
            finished: { _, _ in }))

        headListener.initialize(to: zwlr_output_head_v1_listener(
            name: { data, h, s in DisplayConfigurator.me(data).head(h)?.name = s.map { String(cString: $0) } ?? "" },
            description: { data, h, s in
                DisplayConfigurator.me(data).head(h)?.description = s.map { String(cString: $0) } ?? "" },
            physical_size: { _, _, _, _ in },
            mode: { data, h, m in
                guard let m else { return }
                let c = DisplayConfigurator.me(data)
                c.head(h)?.modes.append(m)
                c.modes[m] = ModeState()
                _ = zwlr_output_mode_v1_add_listener(m, c.modeListener, data)
            },
            enabled: { data, h, on in DisplayConfigurator.me(data).head(h)?.enabled = on != 0 },
            current_mode: { data, h, m in DisplayConfigurator.me(data).head(h)?.current = m },
            position: { data, h, x, y in
                let s = DisplayConfigurator.me(data).head(h); s?.x = x; s?.y = y },
            transform: { _, _, _ in },
            scale: { data, h, f in DisplayConfigurator.me(data).head(h)?.scale = wl_fixed_to_double(f) },
            finished: { data, h in
                let c = DisplayConfigurator.me(data)
                guard let i = c.heads.firstIndex(where: { $0.proxy == h }) else { return }
                zwlr_output_head_v1_release(c.heads[i].proxy)
                c.heads.remove(at: i)
            },
            make: { _, _, _ in }, model: { _, _, _ in }, serial_number: { _, _, _ in },
            adaptive_sync: { _, _, _ in }))

        modeListener.initialize(to: zwlr_output_mode_v1_listener(
            size: { data, m, w, h in
                guard let m else { return }
                DisplayConfigurator.me(data).modes[m]?.width = w
                DisplayConfigurator.me(data).modes[m]?.height = h
            },
            refresh: { data, m, r in guard let m else { return }; DisplayConfigurator.me(data).modes[m]?.refresh = r },
            preferred: { data, m in guard let m else { return }; DisplayConfigurator.me(data).modes[m]?.preferred = true },
            finished: { data, m in
                guard let m else { return }
                let c = DisplayConfigurator.me(data)
                c.modes[m] = nil
                for h in c.heads { h.modes.removeAll { $0 == m }; if h.current == m { h.current = nil } }
                zwlr_output_mode_v1_release(m)
            }))

        configListener.initialize(to: zwlr_output_configuration_v1_listener(
            succeeded: { data, _ in DisplayConfigurator.me(data).outcome = .succeeded },
            failed: { data, _ in DisplayConfigurator.me(data).outcome = .failed },
            cancelled: { data, _ in DisplayConfigurator.me(data).outcome = .cancelled }))
    }
}
