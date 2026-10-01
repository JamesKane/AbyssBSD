// MenuBarFocus — the menu bar's view of focus (PHASE10.md P10.3).
//
// `abyss_menubar_v1` is offered only to clients that connected through
// undertow's privileged socket, so constructing one succeeds only on that
// connection. It says, whenever focus moves, which application is frontmost and
// where its menus are published — sent once on bind, so a bar that starts after
// the windows it serves is not left blank until somebody clicks.

import CWayland

public final class MenuBarFocus {
    /// `abyss_menubar_v1.kind`, as the compositor sends it.
    public enum Kind: UInt32, Sendable {
        // 3 was Qt's dbusmenu, retired with Qt support (one toolkit); never reused.
        case none = 0, abyss = 1, gtk = 2
    }

    public struct Focus: Equatable, Sendable {
        public let kind: Kind
        public let address: String
        public let appID: String
    }

    /// What a display shows (v3, PHASE13 P13.4).
    public struct Island: Equatable, Sendable {
        public let display: String
        public let island: Int
        public let name: String
        public let count: Int
        public let isMain: Bool
    }
    /// A window, wherever it is, for the island menu.
    public struct IslandWindow: Equatable, Sendable {
        public let id: UInt32
        public let display: String
        public let island: Int
        public let appID: String
        public let title: String
        public init(id: UInt32, display: String, island: Int, appID: String, title: String) {
            self.id = id; self.display = display; self.island = island
            self.appID = appID; self.title = title
        }
    }

    /// A shoal, as the island list tells it (v4, PHASE13 P13.6).
    public struct ShoalInfo: Equatable, Sendable {
        public let display: String
        public let island: Int
        public let index: UInt32
        public let name: String
        public let open: Int
        public init(display: String, island: Int, index: UInt32, name: String, open: Int) {
            self.display = display; self.island = island; self.index = index; self.name = name; self.open = open
        }
    }
    /// Everything one `list_islands` answer carries.
    public struct IslandList: Sendable {
        public let windows: [IslandWindow]
        public let names: [String]
        public let shoals: [ShoalInfo]
    }

    private let display: Display
    private var proxy: OpaquePointer?
    public private(set) var current: Focus?
    /// Called on every `focused` event, including the one sent on bind.
    public var onFocus: (Focus) -> Void = { _ in }
    /// Every display's island, as last told; and a call on each change.
    public private(set) var islands: [String: Island] = [:]
    public var onIsland: (Island) -> Void = { _ in }
    private var listing: [IslandWindow] = []
    private var shoalListing: [ShoalInfo] = []
    private var listWaiters: [(IslandList) -> Void] = []

    /// Nil when this connection was not offered the global — which is to say,
    /// when this process is not the menu bar's.
    public init?(display: Display) {
        guard let g = display.menubarGlobal,
              let p = wlBind(display.registry, g.name, abyss_menubar_v1_iface, g.version)
        else { return nil }
        self.display = display
        proxy = p
        version = g.version
        var l = abyss_menubar_v1_listener()
        l.focused = { data, _, kind, address, appID in
            guard let data else { return }
            let me = Unmanaged<MenuBarFocus>.fromOpaque(data).takeUnretainedValue()
            let f = Focus(kind: Kind(rawValue: kind) ?? .none,
                          address: address.map { String(cString: $0) } ?? "",
                          appID: appID.map { String(cString: $0) } ?? "")
            me.current = f
            me.onFocus(f)
        }
        // Islands (v3). Every event a v3 compositor may send has a handler:
        // libwayland calls the listener's slot, and an empty one is a crash.
        l.island = { data, _, d, island, name, count, isMain in
            guard let data else { return }
            let me = Unmanaged<MenuBarFocus>.fromOpaque(data).takeUnretainedValue()
            let i = Island(display: d.map { String(cString: $0) } ?? "", island: Int(island),
                           name: name.map { String(cString: $0) } ?? "", count: Int(count),
                           isMain: isMain != 0)
            me.islands[i.display] = i
            me.onIsland(i)
        }
        l.window = { data, _, id, d, island, appID, title in
            guard let data else { return }
            let me = Unmanaged<MenuBarFocus>.fromOpaque(data).takeUnretainedValue()
            me.listing.append(IslandWindow(id: id, display: d.map { String(cString: $0) } ?? "",
                                           island: Int(island),
                                           appID: appID.map { String(cString: $0) } ?? "",
                                           title: title.map { String(cString: $0) } ?? ""))
        }
        l.shoal = { data, _, d, island, index, name, open in
            guard let data else { return }
            let me = Unmanaged<MenuBarFocus>.fromOpaque(data).takeUnretainedValue()
            me.shoalListing.append(ShoalInfo(display: d.map { String(cString: $0) } ?? "", island: Int(island),
                                             index: index, name: name.map { String(cString: $0) } ?? "",
                                             open: Int(open)))
        }
        l.islands_done = { data, _, names in
            guard let data else { return }
            let me = Unmanaged<MenuBarFocus>.fromOpaque(data).takeUnretainedValue()
            let n = (names.map { String(cString: $0) } ?? "").split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let got = IslandList(windows: me.listing, names: n, shoals: me.shoalListing)
            let waiters = me.listWaiters
            me.listing = []; me.shoalListing = []; me.listWaiters = []
            for w in waiters { w(got) }
        }
        display.addListener(to: p, listener: l, data: Unmanaged.passUnretained(self).toOpaque())
        display.flush()
    }

    private var version: UInt32 = 1

    /// Ask the compositor to kill `appID` (P10.8). False when the compositor
    /// is too old to be asked.
    @discardableResult
    public func forceQuit(appID: String) -> Bool {
        guard version >= 2, let p = proxy else { return false }
        abyss_menubar_v1_force_quit(p, appID)
        display.flush()
        return true
    }

    /// The main display's island, if the compositor says.
    public var mainIsland: Island? { islands.values.first { $0.isMain } }

    /// Every island's windows and every island's name, answered later (when
    /// `islands_done` arrives). False when the compositor is too old to ask.
    @discardableResult
    public func listIslands(_ done: @escaping (IslandList) -> Void) -> Bool {
        guard version >= 3, let p = proxy else { return false }
        listWaiters.append(done)
        if listWaiters.count == 1 { abyss_menubar_v1_list_islands(p) }
        display.flush()
        return true
    }

    @discardableResult
    public func switchIsland(display d: String, island: Int) -> Bool {
        guard version >= 3, let p = proxy, island >= 1 else { return false }
        abyss_menubar_v1_switch_island(p, d, UInt32(island))
        display.flush()
        return true
    }

    /// A shoal command (v4): recall, new, add, remove, strip.
    @discardableResult
    public func shoalCommand(_ verb: String, _ arg: UInt32 = 0) -> Bool {
        guard version >= 4, let p = proxy else { return false }
        abyss_menubar_v1_shoal_command(p, verb, arg)
        display.flush()
        return true
    }

    @discardableResult
    public func activateWindow(id: UInt32) -> Bool {
        guard version >= 3, let p = proxy else { return false }
        abyss_menubar_v1_activate_window(p, id)
        display.flush()
        return true
    }

    deinit {
        if let p = proxy { abyss_menubar_v1_destroy(p) }
    }
}
