// ThemeLoader — a theme is a file, not a build (PHASE11.md P11.2).
//
// A theme is a directory, `themes/<name>/`, and its tokens are
// `themes/<name>/theme.ini`, read through `PoolConfig`'s parser:
//
//   [theme]         name = Aqua            human name
//                   default_scheme = …     optional
//   [colors]        titleBarTop = #f4f4f4  a token: #rrggbb, #rrggbb/alpha,
//                   pinstripe = #eef2f7/0.6        "r g b [a]" as fractions,
//                   separator = 0 0 0 0.12         or mix(a, b, t) in OKLCH
//                   raisedTop = mix(raised, #ffffff, 0.14)
//   [metrics]       titleBarHeight = 22    a number, or "number * parameter"
//   [fonts]         fontFamily = Lucida Grande
//   [chrome]        left = close minimize zoom    the frame's gadgets, per side
//                   right = pill  title = center  titleWeight = regular
//   [parameters]    glow = 0.6 0 1         default, min, max — a person may
//                                          change these, within the bounds
//   [colors.<scheme>], [metrics.<scheme>]  a scheme overrides the base
//
// **Strict where PoolConfig is lenient.** PoolConfig skips what it cannot read,
// which is right for a preferences file and wrong for a theme: a misspelt token
// would silently draw Jaguar's value and the theme would look *almost* right.
// Here an unknown key, a malformed value, an unknown reference or a cycle is an
// error naming the section, the key and why — and the theme is refused whole,
// with the compiled Jaguar used instead **and said so** (§2.45).
//
// **Not a language** (PHASE11 §6.5): the only operations are a colour mix and
// multiplying a metric by a bounded parameter. Nothing loops, branches or runs.

import PoolConfig

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct ThemeError: Error, Equatable, Sendable, CustomStringConvertible {
    public let problems: [String]
    public var description: String { problems.joined(separator: "; ") }
}

/// A bounded setting a person may change (glow strength, bevel width, …).
public struct ThemeParameter: Equatable, Sendable {
    public let name: String
    public let value: Double
    public let min: Double
    public let max: Double
}

/// A theme file, read.
public struct LoadedTheme: Equatable, Sendable {
    public let name: String
    public let scheme: String?
    public let schemes: [String]
    public let parameters: [ThemeParameter]
    public let tokens: ThemeTokens
    /// Things that were not wrong enough to refuse the theme: a parameter
    /// clamped to its bounds, say. Shown, never swallowed.
    public internal(set) var warnings: [String]
    /// The draw lists the theme's own `draw/*.dl` files define (P11.4), sorted.
    /// Empty when it ships none — then every widget draws Jaguar's.
    public internal(set) var drawLists: [String] = []
}

public enum ThemeLoader {
    // MARK: parsing

    /// Read a theme from its `theme.ini` text. `scheme` picks a variant (nil for
    /// the theme's default); `overrides` are a person's parameter settings.
    public static func parse(_ text: String, scheme wanted: String? = nil,
                             overrides: [String: Double] = [:]) throws -> LoadedTheme {
        let c = Config.parse(text)
        var problems: [String] = []
        var warnings: [String] = []

        let known: Set<String> = ["", "theme", "colors", "metrics", "fonts", "parameters", "chrome"]
        let sectionNames = c.sectionNames
        let schemes = sectionNames.compactMap { s -> String? in
            for base in ["colors.", "metrics."] where s.hasPrefix(base) { return String(s.dropFirst(base.count)) }
            return nil
        }
        let schemeSet = Array(Set(schemes)).sorted()
        for s in sectionNames where !known.contains(s) && !s.hasPrefix("colors.") && !s.hasPrefix("metrics.") {
            problems.append("[\(s)] is not a section a theme has")
        }
        let scheme = wanted ?? c.string("theme", "default_scheme")
        if let scheme, !schemeSet.contains(scheme), scheme != "default" {
            problems.append("there is no scheme \(scheme) (the theme has: "
                            + (schemeSet.isEmpty ? "none" : schemeSet.joined(separator: ", ")) + ")")
        }

        // Parameters first: metrics may use them.
        var params: [ThemeParameter] = []
        for (k, v) in c.pairs("parameters") {
            let f = v.split(separator: " ").compactMap { Double($0) }
            guard f.count == 3, f[1] <= f[2] else {
                problems.append("[parameters] \(k) = \(v): want \"default min max\""); continue
            }
            var value = overrides[k] ?? f[0]
            if value < f[1] || value > f[2] {
                warnings.append("\(k) = \(value) is outside \(f[1])…\(f[2]); clamped")
                value = Swift.min(Swift.max(value, f[1]), f[2])
            }
            params.append(ThemeParameter(name: k, value: value, min: f[1], max: f[2]))
        }
        for k in overrides.keys.sorted() where !params.contains(where: { $0.name == k }) {
            warnings.append("this theme has no parameter \(k); ignored")
        }
        let paramValue = Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.value) })

        func merged(_ base: String) -> [(String, String)] {
            var d = Dictionary(c.pairs(base), uniquingKeysWith: { $1 })
            if let scheme { for (k, v) in c.pairs("\(base).\(scheme)") { d[k] = v } }
            return d.sorted { $0.key < $1.key }
        }

        var t = ThemeTokens.jaguar
        // Colours: literals, then mixes — which may name other tokens.
        let colorKey = Dictionary(uniqueKeysWithValues: ThemeTokens.colorKeys)
        var raw = Dictionary(uniqueKeysWithValues: merged("colors"))
        for k in raw.keys.sorted() where colorKey[k] == nil {
            problems.append("[colors] \(k) is not a token (misspelt?)"); raw[k] = nil
        }
        var resolved: [String: Color] = [:]
        func resolve(_ name: String, _ stack: [String]) -> Color? {
            if let c = resolved[name] { return c }
            guard let v = raw[name] else {
                // A token the file does not set keeps its Jaguar value, and may
                // still be mixed from.
                if let kp = colorKey[name] { return t[keyPath: kp] }
                return nil
            }
            if stack.contains(name) {
                problems.append("[colors] \(name): a mix that refers to itself (\((stack + [name]).joined(separator: " → ")))")
                return nil
            }
            guard let col = color(v, lookup: { resolve($0, stack + [name]) }) else {
                problems.append("[colors] \(name) = \(v): not a colour"); return nil
            }
            resolved[name] = col
            return col
        }
        for k in raw.keys.sorted() {
            if let col = resolve(k, []), let kp = colorKey[k] { t[keyPath: kp] = col }
        }

        let metricKey = Dictionary(uniqueKeysWithValues: ThemeTokens.metricKeys)
        for (k, v) in merged("metrics") {
            guard let kp = metricKey[k] else { problems.append("[metrics] \(k) is not a token"); continue }
            guard let n = metric(v, params: paramValue) else {
                problems.append("[metrics] \(k) = \(v): want a number, or \"number * parameter\""); continue
            }
            t[keyPath: kp] = n
        }
        let fontKey = Dictionary(uniqueKeysWithValues: ThemeTokens.fontKeys)
        for (k, v) in c.pairs("fonts") {
            // role.upper / role.tracking (P11.9)
            let parts = k.split(separator: ".").map(String.init)
            if parts.count == 2, ["interface", "chrome", "readout", "mono"].contains(parts[0]) {
                switch parts[1] {
                case "upper":
                    guard v == "true" || v == "false" else { problems.append("[fonts] \(k) = \(v): want true or false"); continue }
                    if v == "true" { t.roleUpper.insert(parts[0]) } else { t.roleUpper.remove(parts[0]) }
                case "tracking":
                    guard let n = Double(v), n >= -0.2, n <= 1 else { problems.append("[fonts] \(k) = \(v): want a tracking in em, -0.2…1"); continue }
                    t.roleTracking[parts[0]] = n
                default:
                    problems.append("[fonts] \(k) is not a token")
                }
                continue
            }
            if let kp = fontKey[k] { t[keyPath: kp] = v }
            else if let kp = metricKey[k] {   // fontSize is a metric that lives with the fonts
                guard let n = metric(v, params: paramValue) else {
                    problems.append("[fonts] \(k) = \(v): not a number"); continue
                }
                t[keyPath: kp] = n
            } else {
                problems.append("[fonts] \(k) is not a token")
            }
        }

        // The frame's shape: named gadgets, each on one side at most once.
        var placed: [Gadget: String] = [:]
        for (k, v) in c.pairs("chrome") {
            switch k {
            case "left", "right":
                var gs: [Gadget] = []
                for w in v.split(separator: " ") {
                    guard let g = Gadget(rawValue: String(w)) else {
                        problems.append("[chrome] \(k) = \(v): \(w) is not a gadget (close minimize zoom depth pill)"); continue
                    }
                    if let other = placed[g] { problems.append("[chrome] \(w) is on the \(other) already"); continue }
                    placed[g] = k; gs.append(g)
                }
                if k == "left" { t.chromeLeft = gs } else { t.chromeRight = gs }
            case "title":
                guard let a = TitleAlign(rawValue: v) else { problems.append("[chrome] title = \(v): want left or center"); continue }
                t.titleAlign = a
            case "titleWeight":
                guard v == "regular" || v == "bold" else { problems.append("[chrome] titleWeight = \(v): want regular or bold"); continue }
                t.titleBold = v == "bold"
            default:
                problems.append("[chrome] \(k) is not a token")
            }
        }

        // The floor (P11.10): checked on what this theme, in this scheme, will
        // actually show — refused when body text cannot be read.
        if problems.isEmpty {
            let (p, w) = Legibility.check(t)
            problems += p
            warnings += w
        }

        guard problems.isEmpty else { throw ThemeError(problems: problems) }
        return LoadedTheme(name: c.string("theme", "name") ?? "unnamed",
                           scheme: scheme, schemes: schemeSet, parameters: params,
                           tokens: t, warnings: warnings)
    }

    /// `#rrggbb`, `#rrggbb/alpha`, `r g b [a]`, or `mix(a, b, t)`.
    static func color(_ s: String, lookup: (String) -> Color?) -> Color? {
        let v = s.trimmingSpaces
        if v.hasPrefix("mix("), v.hasSuffix(")") {
            let args = v.dropFirst(4).dropLast().split(separator: ",").map { String($0).trimmingSpaces }
            guard args.count == 3, let f = Double(args[2]), f >= 0, f <= 1,
                  let a = color(args[0], lookup: lookup) ?? lookup(args[0]),
                  let b = color(args[1], lookup: lookup) ?? lookup(args[1]) else { return nil }
            return mixOKLCH(a, b, f)
        }
        if v.hasPrefix("#") {
            let parts = v.dropFirst().split(separator: "/").map { String($0).trimmingSpaces }
            guard let hexs = parts.first, hexs.count == 6, let hex = UInt32(hexs, radix: 16) else { return nil }
            if parts.count == 1 { return Color(hex: hex) }
            guard parts.count == 2, let a = Double(parts[1]), a >= 0, a <= 1 else { return nil }
            return Color(hex: hex, a: a)
        }
        let f = v.split(separator: " ").compactMap { Double($0) }
        guard f.count == 3 || f.count == 4, f.allSatisfy({ $0 >= 0 && $0 <= 1 }),
              v.split(separator: " ").count == f.count else { return nil }
        return Color(f[0], f[1], f[2], f.count == 4 ? f[3] : 1)
    }

    /// A number, or `number * parameter`.
    static func metric(_ s: String, params: [String: Double]) -> Double? {
        let parts = s.split(separator: "*").map { String($0).trimmingSpaces }
        guard let n = Double(parts[0]) else { return nil }
        if parts.count == 1 { return n }
        guard parts.count == 2, let p = params[parts[1]] else { return nil }
        return n * p
    }

    // MARK: OKLCH

    /// `color-mix(in oklch, a (1-t), b t)`, as the Plan Neo study writes its
    /// derived colours. Lightness and chroma linear, hue the short way round;
    /// an achromatic end takes the other end's hue, as CSS does.
    public static func mixOKLCH(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let (la, ca, ha) = oklch(a), (lb, cb, hb) = oklch(b)
        var h1 = ha, h2 = hb
        if ca < 1e-4 { h1 = hb }
        if cb < 1e-4 { h2 = h1 }
        var dh = h2 - h1
        if dh > .pi { dh -= 2 * .pi } else if dh < -.pi { dh += 2 * .pi }
        let l = la + (lb - la) * t, c = ca + (cb - ca) * t, h = h1 + dh * t
        let (r, g, bl) = srgb(fromOKLab: l, c * cos(h), c * sin(h))
        return Color(r, g, bl, a.a + (b.a - a.a) * t)
    }

    static func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    static func gam(_ x: Double) -> Double {
        let y = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return Swift.min(Swift.max(y, 0), 1)
    }

    static func oklch(_ c: Color) -> (Double, Double, Double) {
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (L, (A * A + B * B).squareRoot(), atan2(B, A))
    }

    static func srgb(fromOKLab L: Double, _ A: Double, _ B: Double) -> (Double, Double, Double) {
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
        return (gam(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    // MARK: finding and choosing

    /// Where themes live, in order: `$ABYSS_THEME_DIR`, the person's config
    /// dir (`<config>/themes`), the install (`<exe>/../share/abyss/themes`),
    /// and — for a build tree — the repository's `themes/`.
    public static func searchPath() -> [String] {
        var dirs: [String] = []
        if let d = getenv("ABYSS_THEME_DIR").map({ String(cString: $0) }), !d.isEmpty { dirs.append(d) }
        if let c = try? Pool.configDir() { dirs.append(c + "/themes") }
        if let exe = executableDirectory() {
            // <prefix>/bin → <prefix>/share/abyss/themes, said without a `..`:
            // the path a process announces is the path a test and a person read.
            if let slash = exe.lastIndex(of: "/"), slash != exe.startIndex {
                dirs.append(String(exe[..<slash]) + "/share/abyss/themes")
            } else {
                dirs.append(exe + "/../share/abyss/themes")
            }
            // A build tree: the binary is under .build/<triple>/debug — how
            // deep depends on the toolchain — so walk up to the directory that
            // holds Package.swift rather than guessing a number of `..`s.
            var d = exe
            for _ in 0..<5 {
                guard let slash = d.lastIndex(of: "/"), slash != d.startIndex else { break }
                d = String(d[..<slash])
                if access(d + "/Package.swift", F_OK) == 0 { dirs.append(d + "/themes"); break }
            }
        }
        return dirs
    }

    /// The theme a person chose: `appearance.ini` `[appearance] theme` and
    /// `scheme`, and `[parameters]`. Aqua when nothing says otherwise.
    /// `$ABYSS_THEME` overrides the file's choice, for one process — a test, or
    /// a person trying a theme without committing to it (as `GTK_THEME` does).
    public static func choice() -> (name: String, scheme: String?, overrides: [String: Double]) {
        let a = (try? Pool.load("appearance")) ?? Config()
        var o: [String: Double] = [:]
        for (k, v) in a.pairs("parameters") { if let d = Double(v) { o[k] = d } }
        func env(_ n: String) -> String? { getenv(n).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 } }
        return (env("ABYSS_THEME") ?? a.string("appearance", "theme") ?? "aqua",
                env("ABYSS_THEME_SCHEME") ?? a.string("appearance", "scheme"), o)
    }

    public enum Outcome: Equatable, Sendable {
        case loaded(LoadedTheme, path: String)
        case notFound(name: String, looked: [String])
        case refused(name: String, path: String, ThemeError)
    }

    /// A theme's draw lists: every `draw/*.dl` in `dir`, in name order. Strict
    /// as `parse` is — a list that does not parse, or a name two files both
    /// define, refuses the theme, naming the file and line. A list the toolkit
    /// never asks for is only a warning: a theme may carry lists for a later
    /// toolkit.
    public static func loadLists(_ dir: String) throws -> (DrawListFile?, warnings: [String]) {
        // draw/ for widgets and chrome, icons/ for the icon set (P11.8) — one
        // namespace, so a list name is unique across both.
        var names: [String] = []
        for sub in ["draw", "icons"] {
            guard let d = opendir(dir + "/" + sub) else { continue }
            while let e = readdir(d) {
                let n = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if n.hasSuffix(".dl") && !n.hasPrefix(".") { names.append(sub + "/" + n) }
            }
            closedir(d)
        }
        guard !names.isEmpty else { return (nil, []) }
        var merged = DrawListFile(lists: [:]), problems: [String] = [], seen: [String: String] = [:]
        for n in names.sorted() {
            guard let text = readFile("\(dir)/\(n)") else { problems.append("\(n): cannot be read"); continue }
            do {
                let f = try DrawListFile(parsing: text)
                for k in f.lists.keys.sorted() {
                    if let other = seen[k] { problems.append("\(n): list \(k) is also in \(other)") }
                    seen[k] = n
                }
                merged = merged.merging(f)
            } catch let e as DrawListError {
                problems.append("\(n) line \(e.line): \(e.message)")
            }
        }
        if !problems.isEmpty { throw ThemeError(problems: problems) }
        let warnings = merged.lists.keys.sorted().filter { JaguarLists.file[$0] == nil }
            .map { "list \($0) (\(seen[$0]!)) is not one the toolkit draws" }
        return (merged, warnings)
    }

    /// Find, read and **use** the chosen theme; fall back to the compiled
    /// Jaguar when it cannot be — and return which, so it can be said.
    @discardableResult
    public static func loadCurrent() -> Outcome {
        let ch = choice()
        let dirs = searchPath()
        // Fonts live beside the themes (P11.7): <config>/fonts, the install's
        // share/abyss/fonts, the repository's fonts/ — and a theme's own. Known
        // to fontconfig before any role is matched.
        Text.addFontDirs(fontDirs(themeDirs: dirs, theme: ch.name))
        for d in dirs {
            let path = "\(d)/\(ch.name)/theme.ini"
            guard let text = readFile(path) else { continue }
            do {
                var t = try parse(text, scheme: ch.scheme, overrides: ch.overrides)
                let (lists, w) = try loadLists("\(d)/\(ch.name)")
                t.drawLists = lists.map { $0.lists.keys.sorted() } ?? []
                t.warnings += w
                Theme.use(t.tokens, lists: lists,
                          parameters: Dictionary(uniqueKeysWithValues: t.parameters.map { ($0.name, $0.value) }))
                return .loaded(t, path: path)
            } catch let e as ThemeError {
                Theme.use(.jaguar)
                return .refused(name: ch.name, path: path, e)
            } catch {
                Theme.use(.jaguar)
                return .refused(name: ch.name, path: path, ThemeError(problems: ["\(error)"]))
            }
        }
        Theme.use(.jaguar)
        return .notFound(name: ch.name, looked: dirs)
    }

    /// Where font files may be, for a theme chosen from `themeDirs`: each
    /// `…/themes` directory's sibling `…/fonts`, and `<themes>/<theme>/fonts`.
    public static func fontDirs(themeDirs: [String], theme: String) -> [String] {
        var out: [String] = []
        for d in themeDirs {
            if d.hasSuffix("/themes") { out.append(String(d.dropLast("themes".count)) + "fonts") }
            out.append("\(d)/\(theme)/fonts")
        }
        return out.filter { access($0, F_OK) == 0 }
    }

    /// One line on stderr saying what is being drawn with — a silent fallback
    /// is invisible to every test downstream (§2.45).
    public static func announce(_ o: Outcome) {
        let line: String
        switch o {
        case .loaded(let t, let path):
            line = "Theme: \(t.name)" + (t.scheme.map { " (\($0))" } ?? "") + " from \(path)"
                + ", \(t.drawLists.count) draw lists from draw/ and icons/"
                + (t.warnings.isEmpty ? "" : " — " + t.warnings.joined(separator: "; "))
        case .notFound(let name, let looked):
            line = "Theme: NO THEME \(name) — drawing with the compiled Jaguar (looked in "
                + looked.joined(separator: ", ") + ")"
        case .refused(let name, let path, let e):
            line = "Theme: \(name) REFUSED (\(path)): \(e) — drawing with the compiled Jaguar"
        }
        (line + "\n").withCString { _ = write(2, $0, strlen($0)) }
        Text.announceRoles()
    }

    // MARK: small things

    public static func readFile(_ path: String) -> String? {
        guard let f = fopen(path, "rb") else { return nil }
        defer { fclose(f) }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = fread(&buf, 1, buf.count, f)
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func executableDirectory() -> String? {
        #if os(Linux)
        var buf = [CChar](repeating: 0, count: 4096)
        let n = readlink("/proc/self/exe", &buf, buf.count - 1)
        guard n > 0 else { return nil }
        let path = String(cString: buf)
        #else
        guard let a0 = CommandLine.arguments.first, a0.contains("/"),
              let rp = realpath(a0, nil) else { return nil }
        let path = String(cString: rp); free(rp)
        #endif
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }
}

extension String {
    var trimmingSpaces: String {
        var s = Substring(self)
        while s.first == " " || s.first == "\t" { s.removeFirst() }
        while s.last == " " || s.last == "\t" { s.removeLast() }
        return String(s)
    }
}
