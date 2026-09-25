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
        case none = 0, abyss = 1, gtk = 2, dbusmenu = 3
    }

    public struct Focus: Equatable, Sendable {
        public let kind: Kind
        public let address: String
        public let appID: String
    }

    private let display: Display
    private var proxy: OpaquePointer?
    public private(set) var current: Focus?
    /// Called on every `focused` event, including the one sent on bind.
    public var onFocus: (Focus) -> Void = { _ in }

    /// Nil when this connection was not offered the global — which is to say,
    /// when this process is not the menu bar's.
    public init?(display: Display) {
        guard let g = display.menubarGlobal,
              let p = opt(aw_bind_menubar(raw(display.registry), g.name, g.version))
        else { return nil }
        self.display = display
        proxy = p
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
        display.addListener(to: p, listener: l, data: Unmanaged.passUnretained(self).toOpaque())
        display.flush()
    }

    deinit {
        if let p = proxy { aw_menubar_destroy(raw(p)) }
    }
}
