// The keyboard layouts, in both of FreeBSD's vocabularies.
//
// The console reads `keymap=` from rc.conf and wants a `kbdmap` file name
// (`/usr/share/vt/keymaps/uk.kbd`); the desktop compiles an XKB keymap and wants
// a layout and a variant (`gb`). The installer writes one, and until this table
// nothing turned it into the other, so every installation typed US in the
// desktop whatever it typed on the console (HANDOFF §2.70). rc.conf stays the one
// place the choice is written; this is how it is read twice.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One layout, named the way each half of the system names it.
public struct Keymap: Equatable, Sendable {
    /// The file in `/usr/share/vt/keymaps`, as rc.conf's `keymap=` takes it.
    public let kbdmap: String
    /// XKB's layout and variant (`us`, `dvorak`); an empty variant is the default.
    public let layout: String
    public let variant: String

    public init(kbdmap: String, layout: String, variant: String = "") {
        self.kbdmap = kbdmap
        self.layout = layout
        self.variant = variant
    }
}

public enum Keymaps {
    /// What the installer offers — a short, honest list rather than every
    /// layout either vocabulary knows. **Each `kbdmap` must be a file FreeBSD
    /// ships**: the list once offered `dvorak.kbd` and `colemak.kbd`, which do
    /// not exist, so choosing either wrote a console keymap that could not load.
    public static let offered: [Keymap] = [
        Keymap(kbdmap: "us.kbd", layout: "us"),
        Keymap(kbdmap: "uk.kbd", layout: "gb"),
        Keymap(kbdmap: "de.kbd", layout: "de"),
        Keymap(kbdmap: "fr.kbd", layout: "fr"),
        Keymap(kbdmap: "es.kbd", layout: "es"),
        Keymap(kbdmap: "it.kbd", layout: "it"),
        Keymap(kbdmap: "us.dvorak.kbd", layout: "us", variant: "dvorak"),
        Keymap(kbdmap: "colemak.acc.kbd", layout: "us", variant: "colemak"),
    ]

    /// The XKB layout for a `kbdmap` name.
    ///
    /// A name the installer offers is translated exactly. Any other — somebody
    /// edited rc.conf by hand — is guessed from its prefix, because most of
    /// FreeBSD's keymaps are named for a country whose XKB layout has the same
    /// code (`de.acc.kbd` → `de`); `uk` is the exception worth knowing. A guess
    /// can be wrong, so the caller must be ready for XKB to refuse it.
    public static func xkb(forKbdmap name: String) -> (keymap: Keymap, exact: Bool)? {
        if let k = offered.first(where: { $0.kbdmap == name }) { return (k, true) }
        guard name.hasSuffix(".kbd"),
              let prefix = name.split(separator: ".").first, !prefix.isEmpty
        else { return nil }
        let layout = prefix == "uk" ? "gb" : String(prefix)
        return (Keymap(kbdmap: name, layout: layout), false)
    }

    /// The `keymap=` a system is configured with, or nil for none.
    ///
    /// rc.conf is shell, and this is not a shell: it reads plain assignments,
    /// quoted or not, and the last one wins — which is what the installer writes
    /// and what `sysrc` edits. `rc.conf.local` is read after `rc.conf`, as rc(8)
    /// does. `NO`, the default in `/etc/defaults/rc.conf`, means none.
    public static func configured(rcConf: [String] = ["/etc/rc.conf", "/etc/rc.conf.local"])
        -> String? {
        var value: String?
        for path in rcConf {
            guard let text = readText(path) else { continue }
            if let v = lastAssignment("keymap", in: text) { value = v }
        }
        guard let v = value, !v.isEmpty, v != "NO" else { return nil }
        return v
    }

    /// The last `name=value` in shell-assignment text, with quotes removed.
    static func lastAssignment(_ name: String, in text: String) -> String? {
        var found: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            guard line.hasPrefix(name + "=") else { continue }
            var v = line.dropFirst(name.count + 1)
            if let q = v.first, q == "\"" || q == "'" {
                v = v.dropFirst()
                v = v.prefix(while: { $0 != q })
            } else {
                v = v.prefix(while: { $0 != " " && $0 != "\t" && $0 != "#" })
            }
            found = String(v)
        }
        return found
    }

    private static func readText(_ path: String) -> String? {
        guard let f = fopen(path, "r") else { return nil }
        defer { fclose(f) }
        var bytes: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = fread(&buf, 1, buf.count, f)
            if n <= 0 { break }
            bytes.append(contentsOf: buf[0..<n])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
