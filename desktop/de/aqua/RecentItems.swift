// RecentItems — the applications last opened, for the Apple menu's Recent
// Items (PHASE15 P15.2c).
//
// Three processes open applications — the Finder, the Dock and the menu bar —
// and a fourth shows them, so the list lives where they can all reach it: the
// `recent` domain of the config pool (`recent.ini`), one key per entry, most
// recent first. The last writer wins a race between two launches in the same
// instant; losing one of those from the list is harmless, a torn file is not,
// and the pool's atomic write rules that out.

import MenuModel
import PoolConfig

public enum RecentItems {
    /// Jaguar's default for Recent Items.
    public static let limit = 10
    static let domain = "recent"
    static let section = "applications"

    /// `list` with `bundle` first, once, and no longer than `limit`.
    public static func adding(_ bundle: String, to list: [String], limit: Int = RecentItems.limit) -> [String] {
        Array(([bundle] + list.filter { $0 != bundle }).prefix(limit))
    }

    /// The applications, most recent first. Keys are `0`…`9`, so reading them
    /// in sorted order is reading them in order.
    public static func load(configDir: String? = nil) -> [String] {
        let config = (try? Pool.load(domain, in: configDir)) ?? Config()
        return config.pairs(section).map(\.1).filter { !$0.isEmpty }
    }

    public static func save(_ list: [String], configDir: String? = nil) {
        var config = Config()
        for (i, path) in list.prefix(limit).enumerated() { _ = config.set(section, String(i), path) }
        try? config.store(domain, in: configDir)
    }

    /// Note that `bundle` was just opened.
    public static func record(_ bundle: String) {
        save(adding(bundle, to: load()))
    }

    /// The submenu: each application by its bundle's name, then Clear Menu.
    /// The verbs carry the entry's place in `list`, which is what the bar
    /// chooses from — so the bar keeps the list it built the menu from.
    public static func submenu(_ list: [String]) -> Menu {
        var items: [MenuItem] = list.enumerated().map { i, path in
            let base = String(path.split(separator: "/").last ?? Substring(path))
            let name = base.hasSuffix(".app") ? String(base.dropLast(4)) : base
            return .command(Command("system.recent.\(i)", name, summary: "Open \(name) again."))
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(.command(Command("system.recent.clear", "Clear Menu",
                                      summary: "Forget the recent applications.")))
        return Menu("Recent Items", items)
    }
}
