// AppBundles — a port's `.desktop` entry, as a Mac-shaped application bundle
// (PHASE15 P15.1).
//
// Ports install freedesktop Desktop Entries and icon themes; the Finder and the
// Dock understand `Foo.app` bundles (P2.11: `Contents/MacOS/Foo` is run, the
// first icon in `Contents/Resources` is drawn). This is the translation, as
// values: parse an entry, decide whether it is an application a person should
// see, turn its `Exec` into a launcher script, and choose its icon from the
// files a theme offers. It does no I/O — `abyss-appgen` walks the directories,
// rasterises, and writes — so every rule here is tested with no filesystem.
//
// Rules taken from the Desktop Entry Specification 1.5 and from what the 16
// guest actually has (PHASE15 §4.1): half its entries are `NoDisplay` URL
// handlers and daemons, `Exec` carries field codes, and the best icon is often
// an SVG in a theme that is not hicolor.

// MARK: - The entry

public struct DesktopEntry: Equatable, Sendable {
    public var type = ""
    public var name = ""
    public var exec = ""
    public var icon = ""
    public var comment = ""
    public var noDisplay = false
    public var hidden = false
    public var terminal = false
    public var tryExec = ""
    public var onlyShowIn: [String] = []
    public var notShowIn: [String] = []

    public init() {}

    /// Parse the `[Desktop Entry]` group. Localised keys (`Name[fr]`) are
    /// skipped: the bundle takes the default. Unknown keys are ignored, as the
    /// spec asks; a line that is not `key=value` is ignored rather than fatal.
    public static func parse(_ text: String) -> DesktopEntry? {
        var e = DesktopEntry()
        var inGroup = false, sawGroup = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingWhitespace()
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inGroup = line == "[Desktop Entry]"
                if inGroup { sawGroup = true }
                continue
            }
            guard inGroup, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingWhitespace()
            if key.contains("[") { continue }
            let value = unescape(String(line[line.index(after: eq)...]).trimmingWhitespace())
            switch key {
            case "Type": e.type = value
            case "Name": e.name = value
            case "Exec": e.exec = value
            case "Icon": e.icon = value
            case "Comment": e.comment = value
            case "NoDisplay": e.noDisplay = value == "true"
            case "Hidden": e.hidden = value == "true"
            case "Terminal": e.terminal = value == "true"
            case "TryExec": e.tryExec = value
            case "OnlyShowIn": e.onlyShowIn = list(value)
            case "NotShowIn": e.notShowIn = list(value)
            default: break
            }
        }
        return sawGroup ? e : nil
    }

    /// Why this entry does not become an application a person sees, or nil when
    /// it does. `desktop` is `XDG_CURRENT_DESKTOP`'s name for us.
    public func skipReason(desktop: String = "AbyssBSD", haveTerminal: Bool = false) -> String? {
        if type != "Application" { return type.isEmpty ? "no Type" : "a \(type), not an application" }
        if hidden { return "Hidden" }
        if noDisplay { return "NoDisplay (a handler or a service, not an application)" }
        if name.isEmpty { return "no Name" }
        if exec.isEmpty { return "no Exec" }
        if !onlyShowIn.isEmpty && !onlyShowIn.contains(desktop) { return "only for \(onlyShowIn.joined(separator: ", "))" }
        if notShowIn.contains(desktop) { return "not for \(desktop)" }
        if terminal && !haveTerminal { return "needs a terminal, and there is none yet (P15.4)" }
        return nil
    }

    // MARK: Exec

    /// `Exec` as the words to run and where the files go: the spec's quoting
    /// (double quotes, with `\"`, `` \` ``, `\$` and `\\` inside them), and its
    /// field codes — `%f %F %u %U` are the files a person opens with it (at most
    /// one of them), `%%` is a percent sign, and the rest are dropped.
    public func command() -> (argv: [String], takesFiles: Bool)? {
        guard var words = DesktopEntry.split(exec), !words.isEmpty else { return nil }
        var takesFiles = false
        words = words.compactMap { w -> String? in
            switch w {
            case "%f", "%F", "%u", "%U":
                if takesFiles { return nil }
                takesFiles = true
                return DesktopEntry.filesMarker
            case "%i", "%c", "%k", "%d", "%D", "%n", "%N", "%v", "%m":
                return nil
            default:
                return w.replacingPercentPercent()
            }
        }
        return words.first == DesktopEntry.filesMarker ? nil : (words, takesFiles)
    }

    /// Where the files go in `command().argv`.
    public static let filesMarker = "\u{0}files\u{0}"

    /// The spec's argument splitting.
    static func split(_ s: String) -> [String]? {
        var out: [String] = [], cur = "", quoted = false, inWord = false
        var it = s.makeIterator()
        while let c = it.next() {
            if quoted {
                if c == "\"" { quoted = false; continue }
                if c == "\\", let n = it.next() { cur.append(n); continue }
                cur.append(c)
            } else if c == "\"" {
                quoted = true; inWord = true
            } else if c == " " || c == "\t" {
                if inWord { out.append(cur); cur = ""; inWord = false }
            } else {
                cur.append(c); inWord = true
            }
        }
        if quoted { return nil }
        if inWord { out.append(cur) }
        return out
    }

    /// The string escapes every value may carry: `\s \n \t \r \\`.
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = "", it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            switch n {
            case "s": out.append(" ")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            default: out.append("\\"); out.append(n)
            }
        }
        return out
    }

    static func list(_ v: String) -> [String] { v.split(separator: ";").map(String.init).filter { !$0.isEmpty } }
}

// MARK: - The bundle

public enum AppBundle {
    /// A bundle's directory name for an application called `name`: what the
    /// Finder shows, so the entry's own name, minus what a path cannot hold.
    public static func directoryName(_ name: String) -> String {
        var n = name.replacingOccurrences("/", with: "-")
        while n.hasPrefix(".") { n.removeFirst() }
        return (n.isEmpty ? "Application" : n) + ".app"
    }

    /// The launcher `Contents/MacOS/<Name>`: `exec` the entry's command, with
    /// the files the Finder hands it where the entry asked for them.
    public static func launcher(argv: [String], source: String) -> String {
        let words = argv.map { $0 == DesktopEntry.filesMarker ? "\"$@\"" : shellQuote($0) }
        return "#!/bin/sh\n# Generated by abyss-appgen from \(source) — regenerated, do not edit.\n"
            + "exec " + words.joined(separator: " ") + "\n"
    }

    /// The marker that says a bundle is ours to replace or remove: the entry it
    /// came from. A bundle without one was put there by somebody else.
    public static let marker = "Contents/abyss-appgen"

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:,+@%".contains($0) }) { return s }
        return "'" + s.replacingOccurrences("'", with: "'\\''") + "'"
    }
}

// MARK: - The icon

public enum AppIconChoice: Equatable, Sendable {
    /// Copy this PNG as it is.
    case png(String)
    /// Rasterise this SVG to `size` pixels square.
    case svg(String, size: Int)
}

public enum IconLookup {
    /// The size a bundle icon wants: the Dock magnifies to 128, and 2× that is
    /// what a HiDPI display draws.
    public static let wanted = 256

    /// Choose from every file a theme offers under an icon's name. A PNG at
    /// least `wanted`/2 pixels is taken as it is (the largest); failing that an
    /// SVG, rasterised; failing that the largest PNG there is. Sizes come from
    /// the theme's directory names (`48x48`, `256x256`, `scalable`); a
    /// `-symbolic` icon is a monochrome glyph, never an application's face.
    /// `hicolor`, the fallback theme every application installs into, wins a tie.
    public static func choose(from paths: [String]) -> AppIconChoice? {
        let usable = paths.filter { !$0.contains("-symbolic") }
        let pngs = usable.filter { $0.hasSuffix(".png") }.map { ($0, size(of: $0)) }
            .sorted { ($0.1, hicolor($0.0) ? 1 : 0) > ($1.1, hicolor($1.0) ? 1 : 0) }
        let svgs = usable.filter { $0.hasSuffix(".svg") || $0.hasSuffix(".svgz") }
            .sorted { hicolor($0) && !hicolor($1) }
        if let best = pngs.first, best.1 >= wanted / 2 { return .png(best.0) }
        if let svg = svgs.first { return .svg(svg, size: wanted) }
        return pngs.first.map { .png($0.0) }
    }

    /// A theme directory's pixel size: the first `NxN` path component (and
    /// `@2x` doubling it); 0 when there is none (pixmaps, `scalable`).
    static func size(of path: String) -> Int {
        for comp in path.split(separator: "/") {
            let parts = comp.split(separator: "@")
            let dims = parts[0].split(separator: "x")
            if dims.count == 2, let w = Int(dims[0]), Int(dims[1]) != nil {
                let scale = parts.count > 1 ? Int(parts[1].dropLast()) ?? 1 : 1
                return w * scale
            }
        }
        return 0
    }

    static func hicolor(_ p: String) -> Bool { p.contains("/hicolor/") }
}

// MARK: - Small string helpers, no Foundation

extension StringProtocol {
    func trimmingWhitespace() -> String {
        String(drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" })
            .reversed().drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" }).reversed())
    }
}

extension String {
    func replacingOccurrences(_ a: String, with b: String) -> String {
        guard !a.isEmpty, contains(a) else { return self }
        var out = "", rest = Substring(self)
        while let r = rest.range(of: a) {
            out += rest[..<r.lowerBound] + b
            rest = rest[r.upperBound...]
        }
        return out + rest
    }

    func replacingPercentPercent() -> String { replacingOccurrences("%%", with: "%") }
}

extension Substring {
    func range(of s: String) -> Range<Index>? {
        guard !s.isEmpty else { return nil }
        var i = startIndex
        while i < endIndex {
            if self[i...].hasPrefix(s) { return i..<index(i, offsetBy: s.count) }
            i = index(after: i)
        }
        return nil
    }
}
