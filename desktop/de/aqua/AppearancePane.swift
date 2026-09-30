// AppearancePane — System Preferences' General pane: the theme, its scheme,
// and its settings (PHASE14 P14.2).
//
// Jaguar called it General, and it chose the appearance; this chooses the
// theme. A click writes appearance.ini at once — a Mac's General pane applies
// as you choose, with no OK button — and every process that draws follows it
// through its own watch (P14.2a–c): this pane never tells anybody anything,
// which is what lets `abyss-theme set` from a terminal be exactly as good.
//
// What it shows is **read, not remembered**: the themes installed (every
// `theme.ini` on the search path that parses) and the choice as appearance.ini
// has it now. So a change made elsewhere is shown here as soon as this window
// draws again — which the reload that change causes makes it do.

import AquaDraw
import PoolConfig

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A theme a person can choose.
public struct InstalledTheme: Equatable, Sendable {
    /// The directory name — what appearance.ini says.
    public let id: String
    /// What the theme calls itself (`[theme] name`).
    public let name: String
    /// Its schemes, sorted; empty for a theme with one look.
    public let schemes: [String]
    /// The scheme it wears when none is chosen.
    public let defaultScheme: String?
    /// Its settings, with their defaults and bounds.
    public let parameters: [ThemeParameter]
}

public enum AppearanceCatalogue {
    /// Every theme on `dirs` whose `theme.ini` parses — the first of a name
    /// wins, as it does when loading — Aqua first, then by name. A theme that
    /// does not parse is not offered: choosing it would put every process on
    /// the desktop back on Jaguar at once.
    public static func installed(dirs: [String] = ThemeLoader.searchPath()) -> [InstalledTheme] {
        var seen = Set<String>(), out: [InstalledTheme] = []
        for d in dirs {
            guard let dir = opendir(d) else { continue }
            var names: [String] = []
            while let e = readdir(dir) {
                let n = withUnsafeBytes(of: e.pointee.d_name) {
                    String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                }
                if !n.hasPrefix(".") { names.append(n) }
            }
            closedir(dir)
            for id in names.sorted() where !seen.contains(id) {
                guard let text = ThemeLoader.readFile("\(d)/\(id)/theme.ini"),
                      let t = try? ThemeLoader.parse(text) else { continue }
                seen.insert(id)
                out.append(InstalledTheme(id: id, name: t.name, schemes: t.schemes.sorted(),
                                          defaultScheme: t.scheme, parameters: t.parameters))
            }
        }
        return out.sorted { a, b in a.id == "aqua" ? b.id != "aqua" : (b.id == "aqua" ? false : a.name < b.name) }
    }
}

/// What the pane shows as chosen: appearance.ini, as every process reads it.
public struct AppearanceChoice: Equatable, Sendable {
    public var theme: String
    public var scheme: String?
    public var parameters: [String: Double]

    public static func current(configDir: String? = nil) -> AppearanceChoice {
        let c = ThemeLoader.choice(configDir: configDir)
        return AppearanceChoice(theme: c.name, scheme: c.scheme, parameters: c.overrides)
    }
}

// MARK: - Layout (paint and hit-test read this, §2.9)

public struct AppearanceLayout: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let value: String     // a theme id, a scheme, or a parameter name
        public let label: String
        public let hit: Rect
        public let control: Rect     // the radio's circle, or the slider's track
    }
    public var themes: [Row] = []
    public var schemes: [Row] = []
    public var parameters: [Row] = []
    public var headings: [(String, Double, Double)] = []   // text, right edge, baseline

    public static func == (a: AppearanceLayout, b: AppearanceLayout) -> Bool {
        a.themes == b.themes && a.schemes == b.schemes && a.parameters == b.parameters
    }
}
extension AppearanceLayout: @unchecked Sendable {}

/// Where the pane's controls go inside `body`, for these themes and this
/// choice: a column of labels on the left, right-aligned as a Mac pane's are,
/// and the controls beside them.
public func appearanceLayout(body: Rect, themes: [InstalledTheme],
                             choice: AppearanceChoice) -> AppearanceLayout {
    var l = AppearanceLayout()
    let labelRight = body.x + 170, x = labelRight + 12, rowH = 22.0
    var y = body.y + 34

    func radioRows(_ items: [(String, String)]) -> [AppearanceLayout.Row] {
        var rows: [AppearanceLayout.Row] = []
        for (value, label) in items {
            rows.append(.init(value: value, label: label, hit: Rect(x, y, 260, rowH),
                              control: Rect(x, y + 3, 16, 16)))
            y += rowH
        }
        return rows
    }

    l.headings.append(("Theme:", labelRight, y + 15))
    l.themes = radioRows(themes.map { ($0.id, $0.name) })
    y += 14

    let theme = themes.first { $0.id == choice.theme }
    l.headings.append(("Scheme:", labelRight, y + 15))
    if let t = theme, !t.schemes.isEmpty {
        l.schemes = radioRows(t.schemes.map { ($0, $0.prefix(1).uppercased() + $0.dropFirst()) })
    } else {
        y += rowH                      // "Standard", said, not offered
    }
    y += 14

    if let t = theme, !t.parameters.isEmpty {
        l.headings.append(("Settings:", labelRight, y + 15))
        for p in t.parameters {
            l.parameters.append(.init(value: p.name, label: p.name, hit: Rect(x, y, 260, rowH),
                                      control: Rect(x + 70, y + 1, 150, 20)))
            y += rowH + 4
        }
    }
    return l
}

public enum AppearanceHit: Equatable, Sendable {
    case theme(String)
    case scheme(String)
    /// A parameter, and the value the pointer's x means on its track.
    case parameter(String, Double)
}

/// What a press at (x, y) means, from the layout the painter drew.
public func appearanceHit(_ l: AppearanceLayout, themes: [InstalledTheme],
                          choice: AppearanceChoice, x: Double, y: Double) -> AppearanceHit? {
    if let r = l.themes.first(where: { $0.hit.contains(x, y) }) { return .theme(r.value) }
    if let r = l.schemes.first(where: { $0.hit.contains(x, y) }) { return .scheme(r.value) }
    if let r = l.parameters.first(where: { $0.hit.contains(x, y) }),
       let p = themes.first(where: { $0.id == choice.theme })?.parameters.first(where: { $0.name == r.value }) {
        return .parameter(r.value, appearanceValue(p, track: r.control, x: x))
    }
    return nil
}

/// The value a pointer at `x` means on a parameter's track, within its bounds.
public func appearanceValue(_ p: ThemeParameter, track: Rect, x: Double) -> Double {
    let t = max(0, min(1, (x - track.x) / max(1, track.w)))
    return p.min + t * (p.max - p.min)
}

// MARK: - Paint

public func paintAppearancePane(_ cr: OpaquePointer, _ l: AppearanceLayout, body: Rect,
                                themes: [InstalledTheme], choice: AppearanceChoice,
                                dragging: (String, Double)? = nil) {
    for (text, right, baseline) in l.headings {
        let w = Draw.textWidth(cr, text, size: 13)
        Draw.textLeft(cr, text, x: right - w, baselineY: baseline, color: Theme.bodyText, size: 13)
    }
    for r in l.themes {
        Draw.radioButton(cr, cx: r.control.x + 8, cy: r.control.y + 8, radius: 7,
                         selected: r.value == choice.theme)
        Draw.textLeft(cr, r.label, x: r.control.x + 24, baselineY: r.control.y + 12,
                      color: Theme.bodyText, size: 13)
    }
    let theme = themes.first { $0.id == choice.theme }
    let scheme = choice.scheme ?? theme?.defaultScheme
    for r in l.schemes {
        Draw.radioButton(cr, cx: r.control.x + 8, cy: r.control.y + 8, radius: 7,
                         selected: r.value == scheme)
        Draw.textLeft(cr, r.label, x: r.control.x + 24, baselineY: r.control.y + 12,
                      color: Theme.bodyText, size: 13)
    }
    if l.schemes.isEmpty, let h = l.headings.first(where: { $0.0 == "Scheme:" }) {
        Draw.textLeft(cr, "Standard — this theme has one look", x: h.1 + 12, baselineY: h.2,
                      color: Theme.secondaryText, size: 13)
    }
    for r in l.parameters {
        guard let p = theme?.parameters.first(where: { $0.name == r.value }) else { continue }
        let v = dragging.flatMap { $0.0 == r.value ? $0.1 : nil } ?? choice.parameters[r.value] ?? p.value
        Draw.textLeft(cr, r.label, x: r.hit.x, baselineY: r.hit.y + 15, color: Theme.bodyText, size: 13)
        Draw.slider(cr, r.control, value: (v - p.min) / max(1e-9, p.max - p.min))
        Draw.textLeft(cr, twoPlaces(v), x: r.control.x + r.control.w + 10,
                      baselineY: r.hit.y + 15, color: Theme.secondaryText, size: 11)
    }
}

/// "0.60" — a setting's value as the pane shows it, without Foundation.
func twoPlaces(_ v: Double) -> String {
    let c = Int((abs(v) * 100).rounded())
    return (v < 0 ? "-" : "") + "\(c / 100)." + (c % 100 < 10 ? "0" : "") + "\(c % 100)"
}

// MARK: - The write

public enum AppearanceWrite {
    /// What choosing `hit` writes: a new theme starts from its own defaults;
    /// a scheme or a setting keeps everything else as it was.
    public static func next(_ hit: AppearanceHit, from c: AppearanceChoice) -> AppearanceChoice {
        switch hit {
        case .theme(let id):
            return id == c.theme ? c : AppearanceChoice(theme: id, scheme: nil, parameters: [:])
        case .scheme(let s):
            var n = c; n.scheme = s; return n
        case .parameter(let name, let v):
            var n = c; n.parameters[name] = (v * 100).rounded() / 100; return n
        }
    }

    public static func store(_ c: AppearanceChoice, configDir: String? = nil) throws {
        try ThemeLoader.store(theme: c.theme, scheme: c.scheme, parameters: c.parameters,
                              configDir: configDir)
    }
}
