// PoolConfig — a Swift port of the sibling's `pool` config library, reading and
// writing the same `~/.config/abyss/*.ini` files so Swift and Rust components
// stay config-compatible.
//
// The discipline (from the Rust original): reads mmap the file MAP_PRIVATE and
// parse in place — lock-free, and an atomic rename() underneath can never hand a
// reader a torn file. Writes go to a temp file, fsync, then atomic rename over
// the target under an exclusive lock, so a reader always maps either the whole
// old file or the whole new one. Types are string / uint64 / int64 / bool with
// the same coercions. See docs/PHASE2.md (P2.3) and the pool briefing.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum PoolError: Error, Sendable {
    case io(String)
    case noConfigDir
}

/// A parsed, owned snapshot of one config domain: sections of key/value strings,
/// with typed accessors. The default (unnamed) section is the empty string "".
public struct Config: Sendable, Equatable {
    // Section name -> (key -> raw string value). Sorted on serialize for stable,
    // Rust-BTreeMap-compatible output.
    private var sections: [String: [String: String]] = [:]

    public init() {}

    // MARK: Typed reads

    public func string(_ section: String, _ key: String) -> String? {
        sections[section]?[key]
    }

    public func uint64(_ section: String, _ key: String) -> UInt64? {
        string(section, key).flatMap { UInt64($0) }
    }

    public func int64(_ section: String, _ key: String) -> Int64? {
        string(section, key).flatMap { Int64($0) }
    }

    /// Booleans accept true/1/yes/on and false/0/no/off (case-insensitive), the
    /// same set the Rust `pool` accepts. Anything else is nil (absent/invalid).
    public func bool(_ section: String, _ key: String) -> Bool? {
        guard let v = string(section, key)?.lowercased() else { return nil }
        switch v {
        case "true", "1", "yes", "on":  return true
        case "false", "0", "no", "off": return false
        default:                        return nil
        }
    }

    /// Every key/value in a section, sorted by key.
    ///
    /// Every reader until now knew the key it wanted. A *table* does not — the
    /// keybind file's keys are the shortcuts themselves (P9.5) — so it needs to
    /// ask what is there. Sorted, because a table read in hash order would
    /// resolve two rows that collide differently on different runs.
    public func pairs(_ section: String) -> [(String, String)] {
        (sections[section] ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The schema version from the default section (0 if unset), for migrations.
    public var schemaVersion: UInt64 { uint64("", "schema_version") ?? 0 }

    /// Every section present, sorted — for a reader that must refuse the ones
    /// it does not know rather than skip them (a theme, PHASE11 P11.2).
    public var sectionNames: [String] { sections.keys.sorted() }

    // MARK: Typed writes (chainable)

    @discardableResult
    public mutating func set(_ section: String, _ key: String, _ value: String) -> Config {
        sections[section, default: [:]][key] = value
        return self
    }

    @discardableResult
    public mutating func set(_ section: String, _ key: String, uint64 value: UInt64) -> Config {
        set(section, key, String(value))
    }

    @discardableResult
    public mutating func set(_ section: String, _ key: String, bool value: Bool) -> Config {
        set(section, key, value ? "true" : "false")
    }

    // MARK: Parse / serialize

    /// Parse INI text: `[section]` headers, `key = value` pairs, `#`/`;` full-line
    /// comments, blank lines ignored. Keys before any header land in the default
    /// section. Lenient (matches the Rust parser): unparseable lines are skipped.
    public static func parse(_ text: String) -> Config {
        var config = Config()
        var current = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmedPool()
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast().trimmedPool())
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmedPool()
            if key.isEmpty { continue }
            let value = line[line.index(after: eq)...].trimmedPool()
            config.sections[current, default: [:]][String(key)] = String(value)
        }
        return config
    }

    /// Serialize to INI text. Deterministic: the default section's keys first,
    /// then named sections, sections and keys sorted (matching Rust's BTreeMap).
    public func toINI() -> String {
        var out = ""
        for name in sections.keys.sorted() {
            guard let kv = sections[name], !kv.isEmpty else { continue }
            if !name.isEmpty {
                if !out.isEmpty { out += "\n" }
                out += "[\(name)]\n"
            }
            for key in kv.keys.sorted() {
                out += "\(key) = \(kv[key]!)\n"
            }
        }
        return out
    }

    // MARK: Persist

    /// Atomically write this config as `<domain>.ini`. `dir` defaults to the
    /// resolved config directory. temp file + fsync + rename under a `.lock`.
    public func store(_ domain: String, in dir: String? = nil) throws {
        let d = try dir ?? Pool.configDir()
        try Pool.atomicWrite(dir: d, domain: domain, bytes: Array(toINI().utf8))
    }
}

private extension Substring {
    /// Trim ASCII whitespace (space/tab/CR/NL) from both ends.
    func trimmedPool() -> Substring {
        func ws(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\r" || c == "\n" }
        var s = self
        while let f = s.first, ws(f) { s = s.dropFirst() }
        while let l = s.last, ws(l) { s = s.dropLast() }
        return s
    }
}
