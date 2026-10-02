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
        // 3 was Qt's dbusmenu, retired with Qt support (one toolkit); never reused.
        case none = 0, abyss = 1, gtk = 2
    }

    /// What the bar is told: which kind, where, and whose.
    public struct Focus: Equatable, Sendable {
        public var kind: Kind
        public var address: String
        public var appID: String
        /// The focused window's jail class, or "" (v5, PHASE18 P18.6).
        public var jail: String = ""
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
            tw_menubar_send_focused(resource, f.kind.rawValue, f.address, f.appID, f.jail)
            // And what every display shows (P13.4): the bar's island item.
            for d in m.compositor.layout.displays { m.sendIsland(of: d.name, to: resource) }
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
        hooks.force_quit = { ctx, appID in
            guard let ctx, let appID else { return }
            let m = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue()
            m.compositor.forceQuit(appID: String(cString: appID))
        }
        hooks.lower = { ctx, surface in
            // abyss_window_manager_v1.lower (P11.6): a toolkit window's own
            // depth gadget. Served here because this C already holds the
            // project's globals; the operation is the compositor's.
            guard let ctx, let surface else { return }
            let m = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue()
            guard let t = m.compositor.toplevels.first(where: { $0.surface == surface }) else { return }
            m.compositor.lower(t)
        }
        hooks.window_at = { ctx, x, y, box, appID, title in
            // abyss_window_manager_v1.window_at (P15.6): Grab's Window mode.
            guard let ctx, let box else { return 0 }
            let m = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue()
            guard let w = m.compositor.windowBox(at: Double(x), Double(y)) else { return 0 }
            box[0] = w.x; box[1] = w.y; box[2] = w.width; box[3] = w.height
            appID?.pointee = strdup(w.toplevel.appID ?? "")
            title?.pointee = strdup(w.toplevel.title ?? "")
            return 1
        }
        // Islands (abyss_menubar_v1 v3, PHASE13 P13.4): the bar's island
        // menu lists every island's windows, and does two things.
        hooks.list_islands = { ctx, resource in
            guard let ctx, let resource else { return }
            let c = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue().compositor
            for t in c.toplevels where t.mapped && !t.minimized {
                tw_menubar_send_window(resource, t.id, t.islandDisplay, UInt32(t.island),
                                       t.appID ?? "", t.title ?? "")
                // Whose it is: the client's pid, as Force Quit finds it (P10.8).
                tw_menubar_send_window_pid(resource, t.id, tw_client_pid_of(t.xdgToplevel.pointee.resource))
            }
            for (i, s) in c.shoalBook.shoals.enumerated() {
                let open = s.members.filter { k in c.toplevels.contains { $0.mapped && $0.placeKey == k } }.count
                tw_menubar_send_shoal(resource, s.display, UInt32(s.island), UInt32(i), s.name, UInt32(open))
            }
            tw_menubar_send_islands_done(resource,
                (1...c.islands.count).map { c.islands.name($0) }.joined(separator: "\t"))
        }
        hooks.switch_island = { ctx, display, island in
            guard let ctx else { return }
            let c = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue().compositor
            let d = display.map { String(cString: $0) } ?? ""
            c.switchIsland(Int(island), on: d.isEmpty ? (c.layout.main?.name ?? "") : d)
        }
        hooks.activate_window = { ctx, id in
            guard let ctx else { return }
            let c = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue().compositor
            guard let t = c.toplevels.first(where: { $0.id == id && $0.mapped }) else { return }
            c.bringToFront(t)
        }
        hooks.shoal_command = { ctx, verb, arg in
            guard let ctx, let verb else { return }
            let c = Unmanaged<Menus>.fromOpaque(ctx).takeUnretainedValue().compositor
            switch String(cString: verb) {
            case "recall": c.recallShoal(Int(arg))
            case "new":    c.newShoal()
            case "add":    c.addFocusedToShoal(Int(arg))
            case "remove": c.removeFocusedFromShoal()
            case "strip":  c.toggleShoalStrip()
            default:       break
            }
        }
        guard let r = tw_menus_create(display, &hooks) else { return nil }
        raw = r
        // Jailed clients (PHASE18 P18.3): the session registers each jail's
        // socket with this, and what comes in through it sees an allowlist.
        if tw_menus_enable_jails(r) == nil { Compositor.log("no security-context manager: jails cannot be told apart") }
    }

    /// The security context `surface`'s client came in through, if it is
    /// jailed (P18.3): engine, app id and instance, any of them "-" if unset.
    public func jail(of surface: UnsafeMutablePointer<wlr_surface>) -> (engine: String, appID: String, instance: String)? {
        guard let raw, let res = surface.pointee.resource, let client = wl_resource_get_client(res) else { return nil }
        var e: UnsafePointer<CChar>?, a: UnsafePointer<CChar>?, i: UnsafePointer<CChar>?
        guard tw_client_jail(raw, client, &e, &a, &i) else { return nil }
        func s(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "-" }
        return (s(e), s(a), s(i))
    }

    /// Display `d`'s island, to one bar or (nil) to every bar.
    func sendIsland(of d: String, to resource: UnsafeMutablePointer<wl_resource>? = nil) {
        let c = compositor, n = c.activeIsland(on: d)
        let isMain: UInt32 = d == c.layout.main?.name ? 1 : 0
        if let resource {
            tw_menubar_send_island(resource, d, UInt32(n), c.islands.name(n), UInt32(c.islands.count), isMain)
        } else {
            tw_menubar_send_island_all(raw, d, UInt32(n), c.islands.name(n), UInt32(c.islands.count), isMain)
        }
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

    /// Offer `global` to the privileged socket's clients only (P16.2c).
    func restrictToPrivileged(_ global: OpaquePointer?) {
        tw_menus_add_privileged_global(raw, global)
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
        // Ours names the class as the context's app id; another engine is
        // named for itself (P18.6).
        let jail = t.jail.map { $0.engine == "org.abyssbsd.jail" ? $0.appID : $0.engine } ?? ""
        guard let e = addresses[t.surface] else {
            return Focus(kind: .none, address: "", appID: app, jail: jail)
        }
        return Focus(kind: e.kind, address: e.address, appID: app, jail: jail)
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
        tw_menubar_send_focused_all(raw, f.kind.rawValue, f.address, f.appID, f.jail)
        Menus.log("focused \(f.describe) (\(menubarCount) bar\(menubarCount == 1 ? "" : "s"))")
    }

    static func log(_ s: String) {
        let line = "undertow: menus: \(s)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }
}

extension Menus.Focus {
    var describe: String { base + (jail.isEmpty ? "" : " (confined in \(jail))") }
    private var base: String {
        switch kind {
        case .none: return appID.isEmpty ? "nothing" : "\(appID), which publishes no menus"
        case .gtk:  return "\(appID) at \(address.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: " ")) [\(kind)]"
        default:    return "\(appID) at \(address) [\(kind)]"
        }
    }
}
