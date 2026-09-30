// KeyboardPrefs — the keyboard layout this session types with (BACKLOG T.2).
//
// rc.conf's `keymap=` is the machine's layout, and the console's: written once
// by the installer, read by undertow when a keyboard appears. This is the
// session's — a person's choice while they are logged in, and the one the
// installer makes on the live medium before there is any rc.conf to write to,
// so that the password they type is typed in the layout they chose. undertow
// watches it and gives every keyboard that has no keymap of its own the new
// one, at once.
//
//     [keyboard]
//     kbdmap = uk.kbd
//
// A `kbdmap` name, like rc.conf's, so one table (`Install.Keymaps`) turns both
// into XKB.

public struct KeyboardPrefs: Equatable, Sendable {
    /// A `kbdmap` name (`uk.kbd`), or empty for none: rc.conf's then.
    public var kbdmap: String

    public init(kbdmap: String = "") { self.kbdmap = kbdmap }

    static let domain = "keyboard", section = "keyboard"

    public static func load(configDir: String? = nil) -> KeyboardPrefs {
        guard let c = try? Pool.load(domain, in: configDir) else { return KeyboardPrefs() }
        return KeyboardPrefs(kbdmap: c.string(section, "kbdmap") ?? "")
    }

    /// Written by atomic rename, so a watcher sees one change, never half.
    public func store(configDir: String? = nil) throws {
        var c = (try? Pool.load(KeyboardPrefs.domain, in: configDir)) ?? Config()
        c = c.set(KeyboardPrefs.section, "kbdmap", kbdmap)
        try c.store(KeyboardPrefs.domain, in: configDir)
    }
}
