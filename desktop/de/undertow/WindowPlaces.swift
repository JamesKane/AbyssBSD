// Undertow — remembered window positions (PHASE6.md P6.7; HANDOFF §2.22).
//
// The debt this pays, recorded in Phase 2 when the spatial Finder was built:
//
//   *"A Wayland client cannot position its own windows. Real spatial Finder
//    remembers each folder's window position; xdg-shell has no set-position, so
//    placement is the compositor's. What we can persist is size, view and mode
//    — position waits for Phase 6. Not a bug to hunt."*
//
// It waited. Placement is ours now, so remembering it is ours too — a client
// literally cannot do this, which is what makes it the right thing for the last
// pass of the compositor phase.
//
// **Stored through `PoolConfig`**, the same mmap-read / atomic-rename-write
// `~/.config/abyss/*.ini` store every other component uses, so a window's place
// is inspectable with `cat` and survives a session the way the Finder's view
// mode already does.

import PoolConfig

/// Where a window was last seen.
public struct WindowPlace: Equatable, Sendable {
    public var x: Int32
    public var y: Int32
    public init(x: Int32, y: Int32) { self.x = x; self.y = y }
}

/// Remembered positions, keyed by what identifies a window across sessions.
public final class WindowPlaces {
    private var config: Config
    private let dir: String?
    private let domain = "windows"
    private let section = "windows"

    public init(configDir: String? = nil) {
        dir = configDir
        config = (try? Pool.load("windows", in: configDir)) ?? Config()
    }

    /// The key for a window.
    ///
    /// `app_id` alone is wrong — the spatial Finder opens one window per folder
    /// from one application, and they must not all share a position. `title` is
    /// what distinguishes them (it is the folder's name), so the key is both.
    /// A window with no title falls back to its app_id, which at least keeps
    /// single-window apps working.
    ///
    /// Pure and `static` so the key rule can be tested without a compositor —
    /// and because a key that changes meaning between write and read would
    /// silently lose every position.
    public static func key(appID: String?, title: String?) -> String? {
        let app = (appID ?? "").trimmed()
        let name = (title ?? "").trimmed()
        guard !app.isEmpty || !name.isEmpty else { return nil }
        // Neither half may contain the separator, or two different windows
        // could collide on one key.
        let safeApp = app.replacingSeparator()
        let safeName = name.replacingSeparator()
        return safeName.isEmpty ? safeApp : "\(safeApp)/\(safeName)"
    }

    public func place(forKey key: String) -> WindowPlace? {
        guard let raw = config.string(section, key) else { return nil }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = Int32(parts[0]), let y = Int32(parts[1])
        else { return nil }
        return WindowPlace(x: x, y: y)
    }

    public func remember(_ place: WindowPlace, forKey key: String) {
        config = config.set(section, key, "\(place.x),\(place.y)")
        // Written straight through: a session that ends in a crash should still
        // have remembered where its windows were, and the write is a temp file
        // plus an atomic rename, so a reader never sees a torn file.
        try? config.store(domain, in: dir)
    }

    /// Re-read from disk — for tests, and for a session that shares the file.
    public func reload() { config = (try? Pool.load(domain, in: dir)) ?? Config() }
}

private extension String {
    func trimmed() -> String {
        var s = Substring(self)
        while let f = s.first, f == " " || f == "\t" || f == "\n" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" || l == "\n" { s = s.dropLast() }
        return String(s)
    }
    /// `/` separates the two halves of a key and `=` would break the INI line.
    func replacingSeparator() -> String {
        var out = ""
        for ch in self { out.append(ch == "/" || ch == "=" ? "_" : ch) }
        return out
    }
}
