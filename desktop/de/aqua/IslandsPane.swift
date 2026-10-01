// IslandsPane — System Preferences' Islands pane (PHASE13 P13.7).
//
// How many islands each display has and whether a switch slides, written to
// islands.ini at once — a Mac pane applies as you choose — and undertow follows
// the file itself (`watchIslands`): this pane tells nobody anything, so an
// editor is exactly as good. The keys are shown as they are bound: the
// defaults, with keys.ini's rows over them.
//
// Read, not remembered: what it shows is the file as it is now.

import AquaDraw
import PoolConfig

// MARK: - Layout (paint and hit-test read this, §2.9)

public struct IslandsLayout: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let value: Int
        public let hit: Rect
        public let control: Rect
    }
    public var counts: [Row] = []
    public var slide = Row(value: 0, hit: Rect(0, 0, 0, 0), control: Rect(0, 0, 0, 0))
    /// Label, right edge, baseline.
    public var headings: [(String, Double, Double)] = []
    /// Where the names and the key table start.
    public var namesTop = 0.0
    public var keysTop = 0.0
    public var x = 0.0

    public static func == (a: IslandsLayout, b: IslandsLayout) -> Bool {
        a.counts == b.counts && a.slide == b.slide && a.namesTop == b.namesTop && a.keysTop == b.keysTop
    }
}
extension IslandsLayout: @unchecked Sendable {}

public func islandsLayout(body: Rect, _ c: IslandsConfig) -> IslandsLayout {
    var l = IslandsLayout()
    let labelRight = body.x + 170, x = labelRight + 12
    l.x = x
    var y = body.y + 30
    l.headings.append(("Islands:", labelRight, y + 15))
    for n in 1...IslandsConfig.maxCount {
        let cx = x + Double(n - 1) * 34
        l.counts.append(.init(value: n, hit: Rect(cx, y, 32, 22), control: Rect(cx, y + 3, 16, 16)))
    }
    y += 36
    l.headings.append(("Switching:", labelRight, y + 15))
    l.slide = .init(value: 0, hit: Rect(x, y, 260, 22), control: Rect(x, y + 3, 16, 16))
    y += 36
    l.headings.append(("Names:", labelRight, y + 15))
    l.namesTop = y
    y += 22 * Double((c.count - 1) / 5 + 1) + 30
    l.headings.append(("Keys:", labelRight, y + 15))
    l.keysTop = y
    return l
}

public enum IslandsHit: Equatable, Sendable {
    case count(Int)
    case slide
}

public func islandsHit(_ l: IslandsLayout, x: Double, y: Double) -> IslandsHit? {
    if let r = l.counts.first(where: { $0.hit.contains(x, y) }) { return .count(r.value) }
    if l.slide.hit.contains(x, y) { return .slide }
    return nil
}

// MARK: - The keys, as bound

public enum IslandsKeys {
    /// What each of the phase's actions is called, and the action it is in
    /// keys.ini. An action with an island number is shown with N.
    public static let rows: [(String, String)] = [
        ("Show island N", "island 1"),
        ("Next / previous island", "island next"),
        ("Send window to island N", "move-to-island 1"),
        ("…and go with it", "move-to-island 1 follow"),
        ("Ebb: this island", "ebb island"),
        ("Ebb: every island", "ebb archipelago"),
        ("Ebb: this application", "ebb app"),
        ("New shoal from window", "shoal new"),
        ("Add window to shoal", "shoal add"),
        ("Take window out", "shoal remove"),
        ("Recall shoal N", "shoal recall 1"),
        ("Show the shoals strip", "shoal strip"),
    ]

    /// A key spec as a Mac menu shows one: "Ctrl+Alt+Shift+1" → "⌃⌥⇧1".
    public static func pretty(_ spec: String) -> String {
        var out = ""
        for part in spec.split(separator: "+") {
            switch part.lowercased() {
            case "ctrl", "control": out += "⌃"
            case "alt", "option", "opt": out += "⌥"
            case "shift": out += "⇧"
            case "cmd", "command", "super", "logo", "meta": out += "⌘"
            case "left": out += "←"
            case "right": out += "→"
            case "up": out += "↑"
            case "down": out += "↓"
            case "equal": out += "="
            case "minus": out += "−"
            default: out += part.count == 1 ? part.uppercased() : String(part)
            }
        }
        return out
    }

    /// Each row's key, from `table` (the defaults with keys.ini over them):
    /// an island number shown as the digits it can be, "1…9" — not "N", which
    /// is also a key (⌃⌥N makes a shoal); unbound said so.
    public static func shown(_ table: [(String, String)]) -> [(String, String)] {
        rows.map { (label, action) in
            guard let spec = table.first(where: { $0.1.lowercased() == action })?.0 else { return (label, "none") }
            var keys = pretty(spec)
            if action.contains(" 1") || action.hasSuffix(" 1 follow") {
                keys = String(keys.dropLast()) + "1…9"
            }
            if action == "island next", let prev = table.first(where: { $0.1.lowercased() == "island previous" })?.0 {
                keys = pretty(prev) + " / " + keys
            }
            return (label, keys)
        }
    }
}

// MARK: - Paint

public func paintIslandsPane(_ cr: OpaquePointer, _ l: IslandsLayout, _ c: IslandsConfig,
                             keys: [(String, String)]) {
    for (text, right, baseline) in l.headings {
        let w = Draw.textWidth(cr, text, size: 13)
        Draw.textLeft(cr, text, x: right - w, baselineY: baseline, color: Theme.bodyText, size: 13)
    }
    for r in l.counts {
        Draw.radioButton(cr, cx: r.control.x + 8, cy: r.control.y + 8, radius: 7, selected: r.value == c.count)
        Draw.textLeft(cr, "\(r.value)", x: r.control.x + 19, baselineY: r.control.y + 12,
                      color: Theme.bodyText, size: 12)
    }
    Draw.checkbox(cr, l.slide.control, checked: c.animate)
    Draw.textLeft(cr, "Slide from one island to the next", x: l.slide.control.x + 24,
                  baselineY: l.slide.control.y + 12, color: Theme.bodyText, size: 13)
    for n in 1...c.count {
        let col = (n - 1) % 5, row = (n - 1) / 5
        let name = c.name(n) == "\(n)" ? "Island \(n)" : c.name(n)
        Draw.textLeft(cr, name, x: l.x + Double(col) * 80, baselineY: l.namesTop + 15 + Double(row) * 22,
                      color: Theme.bodyText, size: 12)
    }
    Draw.textLeft(cr, "Named in islands.ini (name.1 = …).", x: l.x,
                  baselineY: l.namesTop + 15 + Double((c.count - 1) / 5 + 1) * 22,
                  color: Theme.secondaryText, size: 11)
    for (i, (label, key)) in keys.enumerated() {
        let y = l.keysTop + 15 + Double(i) * 18
        Draw.textLeft(cr, label, x: l.x, baselineY: y, color: Theme.bodyText, size: 12)
        Draw.textLeft(cr, key, x: l.x + 200, baselineY: y, color: Theme.secondaryText, size: 12)
    }
}

// MARK: - The write

public enum IslandsWrite {
    /// What a click makes of the file: the count chosen, or the slide turned
    /// over — everything else (names, the slide's length) kept as it was.
    public static func next(_ hit: IslandsHit, from c: IslandsConfig) -> IslandsConfig {
        var n = c
        switch hit {
        case .count(let k): n.count = min(max(k, 1), IslandsConfig.maxCount)
        case .slide: n.animate.toggle()
        }
        return n
    }

    public static func store(_ c: IslandsConfig, configDir: String? = nil) throws {
        var f = (try? Pool.load("islands", in: configDir)) ?? Config()
        f = f.set("islands", "count", String(c.count))
        f = f.set("islands", "animate", bool: c.animate)
        f = f.set("islands", "slide_ms", String(c.slideMs))
        for (i, name) in c.names.enumerated() where !name.isEmpty { f = f.set("islands", "name.\(i + 1)", name) }
        try f.store("islands", in: configDir)
    }
}
