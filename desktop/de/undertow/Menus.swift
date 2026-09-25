// Menus — whose menus belong to which window (PHASE10.md P10.3).
//
// A global menu bar shows the focused application's menus, and only the
// compositor knows which surface is focused. So applications tell undertow,
// per surface, where their menus are published (`abyss_menu_manager_v1`), and
// undertow tells the menu bar — only the menu bar — where the focused
// surface's menus are whenever that changes (`abyss_menubar_v1`).
//
// The binding is surface → address, set by the client that owns the surface on
// the connection that proves it. Nothing trusts an app_id: GTK does not even
// set its app_id to its bus name (PHASE10 §4.2), and any client may claim any
// app_id it likes.
//
// The libwayland plumbing is C (`de/cwlroots/menus.c`, and the header's
// "Menus" section for why); the policy is here.

import CWlroots
import MenuModel

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class Menus {
    /// `abyss_menubar_v1.kind`.
    public enum Kind: UInt32, Sendable {
        case none = 0, abyss = 1, gtk = 2, dbusmenu = 3
    }

    /// What the bar is told: which kind, where, and whose.
    public struct Focus: Equatable, Sendable {
        public var kind: Kind
        public var address: String
        public var appID: String
        public static let nothing = Focus(kind: .none, address: "", appID: "")
    }

    private var raw: OpaquePointer?
    private unowned let compositor: Compositor
    /// Surface → the address its client published.
    private var addresses: [UnsafeMutablePointer<wlr_surface>: Entry] = [:]
    /// What every bound bar was last told, so a focus change that changes
    /// nothing sends nothing.
    public private(set) var lastSent = Focus.nothing
    /// Every `focused` sent, in order — for tests and the log.
    public private(set) var sentCount = 0

    private final class Entry {
        var address: String
        var kind: Kind
        var destroyListener: UnsafeMutablePointer<tw_listener>?
        init(address: String, kind: Kind) { self.address = address; self.kind = kind }
    }

    init?(compositor: Compositor, display: OpaquePointer) {
        self.compositor = compositor
        var hooks = tw_menu_hooks()
        hooks.ctx = Unmanaged.passUnretained(self).toOpaque()
        hooks.set_address = { ctx, surface, address in
            guard let ctx, let surface else { return }
            let m = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue()
            m.setAddress(address.map { String(cString: $0) } ?? "", for: surface, kind: .abyss)
        }
        hooks.menubar_bound = { ctx, resource in
            guard let ctx, let resource else { return }
            let m = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue()
            let f = m.current
            tw_menubar_send_focused(resource, f.kind.rawValue, f.address, f.appID)
            Menus.log("a menu bar bound; told it \(f.describe)")
        }
        hooks.set_gtk_properties = { ctx, surface, appID, appMenu, menubar, window, appPath, bus in
            guard let ctx, let surface else { return }
            let m = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue()
            func s(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
            let a = GtkMenuAddress(applicationID: s(appID), busName: s(bus),
                                   applicationPath: s(appPath), menubarPath: s(menubar),
                                   appMenuPath: s(appMenu), windowPath: s(window))
            // GTK says this for every window, menus or not; only one with
            // something to read is worth pointing the bar at.
            m.setAddress(a.hasMenus ? a.encoded : "", for: surface, kind: .gtk)
        }
        hooks.set_dbusmenu_address = { ctx, surface, service, path in
            guard let ctx, let surface else { return }
            let m = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue()
            let svc = service.map { String(cString: $0) } ?? ""
            let p = path.map { String(cString: $0) } ?? ""
            // "service\npath" — the dbusmenu kind's address (P10.7).
            m.setAddress(svc.isEmpty || p.isEmpty ? "" : svc + "\n" + p, for: surface, kind: .dbusmenu)
        }
        guard let r = tw_menus_create(display, &hooks) else { return nil }
        raw = r
    }

    deinit { teardown() }

    func teardown() {
        for (_, e) in addresses { tw_listener_free(e.destroyListener) }
        addresses.removeAll()
        tw_menus_destroy(raw)
        raw = nil
    }

    /// Accept privileged clients on `path`. They, and only they, can see
    /// `abyss_menubar_v1`.
    func addPrivilegedSocket(_ path: String) throws {
        let rc = tw_privileged_socket_add(raw, path)
        guard rc == 0 else { throw BackendError.privilegedSocket(path, -rc) }
    }

    public var menubarCount: Int { Int(tw_menubar_count(raw)) }

    /// The address a surface published, if any.
    public func address(of surface: UnsafeMutablePointer<wlr_surface>) -> String? {
        addresses[surface]?.address
    }

    /// GTK's windows lose their own menubar only when this is on (§6.5).
    func advertiseGlobalMenusToGTK(_ on: Bool) { tw_gtk_set_global_menus(raw, on) }

    private func setAddress(_ address: String, for surface: UnsafeMutablePointer<wlr_surface>,
                            kind: Kind) {
        if address.isEmpty {
            if let e = addresses.removeValue(forKey: surface) { tw_listener_free(e.destroyListener) }
        } else if let e = addresses[surface] {
            e.address = address
            e.kind = kind
        } else {
            let e = Entry(address: address, kind: kind)
            // Forgotten with the surface: an address outliving its window would
            // point the bar at a menu for something no longer on screen.
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            e.destroyListener = tw_listen(&surface.pointee.events.destroy, { ctx, data in
                guard let ctx, let data else { return }
                let m = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue()
                let s = data.assumingMemoryBound(to: wlr_surface.self)
                if let e = m.addresses.removeValue(forKey: s) { tw_listener_free(e.destroyListener) }
                m.focusChanged()
            }, ctx)
            addresses[surface] = e
        }
        Menus.log(address.isEmpty ? "a surface withdrew its menus"
                  : "a surface published its menus at "
                    + (kind != .abyss ? "\(address.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: " ")) [\(kind)]"
                                    : address))
        focusChanged()
    }

    /// What the bar should be showing now.
    public var current: Focus {
        guard let t = compositor.seat?.focused else { return desktop }
        let app = t.appID ?? ""
        guard let e = addresses[t.surface] else {
            return Focus(kind: .none, address: "", appID: app)
        }
        return Focus(kind: e.kind, address: e.address, appID: app)
    }

    /// With no window focused, the desktop is frontmost — and in Jaguar the
    /// desktop *is* the Finder, whose menus the bar shows (PHASE10 P10.4). So
    /// the fallback is whatever a BACKGROUND layer surface published, and
    /// nothing only when no desktop has published anything.
    private var desktop: Focus {
        for l in compositor.layers
        where l.layer == ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND.rawValue {
            if let e = addresses[l.surface] {
                return Focus(kind: e.kind, address: e.address, appID: l.namespace)
            }
        }
        return .nothing
    }

    /// Focus moved, or the focused surface's address changed: tell the bars,
    /// unless nothing they would show is different.
    public func focusChanged() {
        let f = current
        guard f != lastSent else { return }
        lastSent = f
        sentCount += 1
        tw_menubar_send_focused_all(raw, f.kind.rawValue, f.address, f.appID)
        Menus.log("focused \(f.describe) (\(menubarCount) bar\(menubarCount == 1 ? "" : "s"))")
    }

    static func log(_ s: String) {
        let line = "undertow: menus: \(s)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }
}

extension Menus.Focus {
    var describe: String {
        switch kind {
        case .none: return appID.isEmpty ? "nothing" : "\(appID), which publishes no menus"
        case .gtk, .dbusmenu:  return "\(appID) at \(address.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: " ")) [\(kind)]"
        default:    return "\(appID) at \(address) [\(kind)]"
        }
    }
}
