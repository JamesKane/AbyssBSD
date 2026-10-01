// IslandsConfig — `islands.ini` (PHASE13 P13.1), shared by undertow, which
// keeps the islands, and the Islands pane, which writes the file (P13.7).

/// `islands.ini`: how many islands each display has, and what they are called.
/// §6.1: a fixed count, so Ctrl-3 always means the same place.
public struct IslandsConfig: Equatable, Sendable {
    public static let defaultCount = 4
    public static let maxCount = 9          // one per digit key

    public var count: Int
    /// Index 0 is island 1. A missing name is the number.
    public var names: [String]
    /// The slide (P13.3, §6.5): on by default, 150 ms, skippable. Decoration
    /// only — the switch is committed before the first frame of it (C6).
    public var animate: Bool
    /// Its length. PRODUCT §7.2 budgets ~150 ms; up to 2 s is allowed so a
    /// test (or a person who wants to watch) can slow it down.
    public var slideMs: Int

    public init(count: Int = IslandsConfig.defaultCount, names: [String] = [],
                animate: Bool = true, slideMs: Int = 150) {
        self.count = min(max(count, 1), IslandsConfig.maxCount)
        self.names = names
        self.animate = animate
        self.slideMs = min(max(slideMs, 0), 2000)
    }

    public func name(_ n: Int) -> String {
        n >= 1 && n <= names.count && !names[n - 1].isEmpty ? names[n - 1] : "\(n)"
    }

    public static func from(_ c: Config) -> IslandsConfig {
        let count = c.int64("islands", "count").map(Int.init) ?? defaultCount
        var names: [String] = []
        for n in 1...maxCount { names.append(c.string("islands", "name.\(n)") ?? "") }
        while let last = names.last, last.isEmpty { names.removeLast() }
        return IslandsConfig(count: count, names: names,
                             animate: c.bool("islands", "animate") ?? true,
                             slideMs: c.int64("islands", "slide_ms").map(Int.init) ?? 150)
    }

    public static func load(configDir: String?) -> IslandsConfig {
        (try? Pool.load("islands", in: configDir)).map(from) ?? IslandsConfig()
    }

    /// The island one step from `n`, wrapping — Ctrl-→ from the last is the first.
    public func step(_ n: Int, by d: Int) -> Int {
        ((n - 1 + d) % count + count) % count + 1
    }
}

