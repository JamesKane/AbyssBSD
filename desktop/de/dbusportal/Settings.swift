// DBusPortal — org.freedesktop.portal.Settings, the second interface (P8.3).
//
// PHASE8 §6.4 predicted this one and declined to guess at it: *"a real GTK app
// may probe org.freedesktop.portal.Settings … the mitigation is to find out with
// a real app in P8.3 rather than guess now."* A real GTK 3 app was pointed at the
// bridge, and the first thing it did — before it asked for a file, before it drew
// a window — was:
//
//     Settings.ReadAll(["org.gnome.*"])  →  no such method
//     Gdk-WARNING: Failed to read portal settings
//
// So the interface list grew by exactly one, as budgeted.
//
// Read off disk, not remembered (/usr/share/dbus-1/interfaces/
// org.freedesktop.portal.Settings.xml), and three things in it govern this file:
//
//  1. **`Read` returns the value inside TWO layers of variant, and that is not a
//     typo.** Its own documentation says the single layer *was intended* and the
//     double layer is what shipped, so the bug is the contract. `ReadOne` (added
//     in version 2) is the one with one layer. We implement both, because
//     answering the deprecated method with the shape its callers do not expect is
//     worse than not answering it.
//
//  2. **Only `org.freedesktop.appearance` is standardised.** Everything else —
//     `org.gnome.*` included — the spec calls "entirely implementation details
//     that are undocumented". So that is the one namespace we publish, and a
//     request for any other gets an empty dictionary rather than an invention.
//     GTK asking for `org.gnome.*` gets a successful, empty answer and falls back
//     to its own defaults, which is both true and quiet.
//
//  3. **Globbing is trailing-only.** `org.example.*` matches by prefix on
//     everything before the `*`; an empty array, or any empty string in it,
//     matches everything.

import PoolConfig

/// `org.freedesktop.portal.Settings` — what the desktop will tell a foreign
/// toolkit about how it looks.
///
/// Pure: a table and three lookups over it, so the matching rules are unit-tested
/// without a bus. Nothing here reads a file or a socket.
public struct PortalSettings: Sendable {
    public static let interface = "org.freedesktop.portal.Settings"

    /// **2, because we implement 2.** Version 2 is the one that added `ReadOne`,
    /// and `ReadOne` is the only way a client gets a single-variant answer. The
    /// same reasoning as `fileChooserVersion`, reaching the opposite number:
    /// claim what you serve.
    public static let version: UInt32 = 2

    public static let appearance = "org.freedesktop.appearance"

    /// Namespace → keys, in the order they are published.
    public let namespaces: [(String, [(String, DBusValue)])]

    /// The desktop's own answer.
    ///
    /// `color-scheme` is **2, prefer light**, and not because nothing better was
    /// available: Aqua is a light theme and has no dark variant to offer. A
    /// desktop that reports "no preference" gets GTK's default, which on some
    /// distributions is dark — a dark GTK dialog on a Jaguar desktop.
    ///
    /// `accent-color` is the Aqua menu-selection blue. It is repeated here as
    /// three literals rather than imported, because `DBusPortal` linking the
    /// whole toolkit (and through it cairo, FreeType and HarfBuzz) to name one
    /// colour would be a bad trade — `testAccentColourMatchesTheAquaTheme` is
    /// what keeps the two from drifting apart.
    public static let aqua = PortalSettings(namespaces: [
        (appearance, [
            ("color-scheme", .uint32(2)),
            ("accent-color", .structure([.double(0x3f / 255.0),
                                         .double(0x6f / 255.0),
                                         .double(0xdf / 255.0)])),
            ("contrast", .uint32(0)),
            ("reduced-motion", .uint32(0)),
        ]),
    ])

    /// The palette namespace (P11.10): the loaded theme's colours, for a
    /// toolkit or a bridge that asks. Not standard — the spec leaves every
    /// namespace but appearance to the implementation.
    public static let palette = "org.abyssbsd.palette"

    /// The answer made from a theme's palette (`abyss-theme palette`): its
    /// color-scheme, accent and contrast in the standard namespace, and the
    /// colours beside it. Nil when the text is not a palette.
    public static func from(palette text: String) -> PortalSettings? {
        let c = Config.parse(text)
        func rgb(_ v: String?) -> DBusValue? {
            guard let v else { return nil }
            let n = v.split(separator: " ").compactMap { Double($0) }
            guard n.count == 3, n.allSatisfy({ $0 >= 0 && $0 <= 1 }) else { return nil }
            return .structure(n.map { .double($0) })
        }
        guard let scheme = c.string("appearance", "color-scheme").flatMap(UInt32.init), scheme <= 2,
              let accent = rgb(c.string("appearance", "accent-color")) else { return nil }
        let contrast = c.string("appearance", "contrast").flatMap(UInt32.init) ?? 0
        var colours: [(String, DBusValue)] = []
        for (k, v) in c.pairs("palette") { if let d = rgb(v) { colours.append((k, d)) } }
        return PortalSettings(namespaces: [
            (appearance, [("color-scheme", .uint32(scheme)), ("accent-color", accent),
                          ("contrast", .uint32(min(1, contrast))), ("reduced-motion", .uint32(0))]),
            (palette, colours),
        ])
    }

    public init(namespaces: [(String, [(String, DBusValue)])]) {
        self.namespaces = namespaces
    }

    /// Every key whose value in `new` differs from this one — including keys
    /// `new` adds — in `new`'s order: exactly what `SettingChanged` must say
    /// when the theme changes (P14.2). A key `new` drops is not reported; the
    /// spec has no signal for a setting that went away, and a client asking
    /// for it is answered NotFound from then on.
    public func changes(to new: PortalSettings) -> [(namespace: String, key: String, value: DBusValue)] {
        var out: [(namespace: String, key: String, value: DBusValue)] = []
        for (ns, keys) in new.namespaces {
            for (k, v) in keys where value(namespace: ns, key: k) != v {
                out.append((ns, k, v))
            }
        }
        return out
    }

    // MARK: - Matching

    /// Does `namespace` match one of `patterns`?
    ///
    /// The spec's rule exactly: an empty list matches everything, so does any
    /// empty string in it, a trailing `*` is a prefix match on the text before
    /// it, and anything else is equality. Note that `org.gnome.*` therefore does
    /// **not** match the bare namespace `org.gnome` — the `.` before the star is
    /// part of the prefix, and inventing a looser rule here would have us
    /// answering for namespaces the client did not ask about.
    public static func matches(namespace: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        for pattern in patterns {
            if pattern.isEmpty { return true }
            if pattern.hasSuffix("*") {
                if namespace.hasPrefix(String(pattern.dropLast())) { return true }
            } else if pattern == namespace {
                return true
            }
        }
        return false
    }

    // MARK: - The three readers

    /// `ReadAll(as namespaces) -> a{sa{sv}}`.
    public func readAll(patterns: [String]) -> DBusValue {
        var entries: [DBusValue] = []
        for (name, keys) in namespaces where PortalSettings.matches(namespace: name,
                                                                   patterns: patterns) {
            entries.append(.dictEntry(.string(name),
                                      .options(keys.map { ($0.0, $0.1) })))
        }
        return .array("{sa{sv}}", entries)
    }

    /// The raw value of one key, or nil if the namespace or the key is unknown.
    ///
    /// Nil is the caller's cue to send an error: the spec says both `Read` and
    /// `ReadOne` "return an error on any unknown namespace or key", and answering
    /// an unknown key with a plausible default is how a toolkit ends up rendering
    /// a setting the desktop never made.
    public func value(namespace: String, key: String) -> DBusValue? {
        for (name, keys) in namespaces where name == namespace {
            for (k, v) in keys where k == key { return v }
        }
        return nil
    }

    /// `ReadOne(s, s) -> v` — the value in **one** variant. Version 2's method,
    /// and the one to use.
    public func readOne(namespace: String, key: String) -> DBusValue? {
        value(namespace: namespace, key: key).map { .variant($0) }
    }

    /// `Read(s, s) -> v` — the value in **two** variants.
    ///
    /// Deprecated upstream and wrong on purpose. Its documentation is explicit
    /// that the extra layer was unintended and is now what callers parse, so a
    /// correct implementation reproduces the mistake. This is the whole reason
    /// both methods exist, and a single-variant `Read` would fail in exactly the
    /// silent way P8.2 spent its pass on: the client decodes a variant, finds a
    /// variant where it expected a `u`, and gives up without a diagnostic.
    public func read(namespace: String, key: String) -> DBusValue? {
        readOne(namespace: namespace, key: key).map { .variant($0) }
    }
}
