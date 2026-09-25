// DrawList — a widget's drawing as data (PHASE11.md P11.3, P11.4).
//
// PRODUCT §8.3: a theme is data, not code. Layer 2 — *how* a control is painted
// — is a **draw list**: a short sequence of declarative ops over a widget's
// rectangle, parameterised by the theme's tokens, its bounded parameters and
// the widget's state. The interpreter here is the only thing that turns one
// into pixels, and it cannot execute anything: no variables, no loops, no
// calls, no conditions beyond picking a state.
//
// A file holds any number of lists:
//
//   list button
//     rect 0 0 w h h/2                     the current shape: x y w h [radius [top|bottom]]
//     glow menuHighlight 8                  a blurred halo of the shape (cached)
//     fill vertical stops 0 buttonWhiteTop 1 buttonWhiteBottom
//     when pressed fill #000000/0.1         an op for some states only
//     bevel 1 #ffffff/0.4 #000000/0.6       top-left light, bottom-right shade
//     stroke controlBorder 1
//     text $label w/2 h/2 center color=buttonTextOnWhite
//   end
//
// Coordinates are the widget's own: 0 0 is its top-left, `w` and `h` its size.
//
// **Operands** are arithmetic in the manner of CSS `calc()`: numbers, `w`, `h`,
// `@metric` (a theme metric), `$param` (a theme parameter, or one the widget
// passes — a slider's thumb position), `textw(size)` (the label's width at a
// size), `min(a, b)`, `max(a, b)`, + - * / and parentheses — `w-h/2-3`,
// `(w-h)/2`, `min(w,h)*0.26`. That is the whole of it: there are no names a
// list can define, so a list is a formula, never a program (PHASE11 §6.5).
//
// **Colours** are a token name, `#rrggbb[/a]`, `rgb(r, g, b)` / `rgba(r, g, b, a)`
// in fractions, `$param` (a colour the widget
// passes — a traffic light's base), any of those with `/a` (alpha replaced),
// `mix(a, b, t)` (OKLCH, as theme.ini's), or `shift(c, d)` (d added to each of
// r g b, clamped — Aqua's "a touch darker when pressed"), or `fade(c, $p)`
// (alpha times a parameter — a sheet's dimming as it slides out).
//
// **Shapes:** `rect x y w h [radius [top|bottom|all]]`, `ellipse x y w h`,
// `circle cx cy r`, `arc cx cy r from to` (radians, clockwise from 3 o'clock),
// `path x y  x y | curve x1 y1 x2 y2 x y  … [close]`; `and SHAPE` adds a subpath to
// the current shape, so one fill or stroke covers both.
//
// **Paints:** a colour; `vertical stops …` (top to bottom of the current
// shape); `linear x0 y0 x1 y1 stops …`; `radial cx cy r stops …` or `radial
// x0 y0 r0 x1 y1 r1 stops …`; `conic cx cy r stops …` (cairo mesh patches,
// PHASE11 §4.1); `stripes angle w1 c1 w2 c2`; `noise seed alpha`. `stops` is
// followed by offset/colour pairs.
//
// **Ops:** `fill PAINT`; `stroke PAINT WIDTH [round] [dash=on,off…]`; `bevel W LIGHT SHADE`;
// `innershadow COLOUR SIZE [EXTENT]`; `glow COLOUR RADIUS [STRENGTH]`;
// `shadow COLOUR DX DY BLUR` (the shape's cast shadow — an icon's, P11.8);
// `rules across FROM EVERY PAINT WIDTH` (hairlines across the shape, FROM
// its top, EVERY apart — a pinstripe); `rules slant FROM EVERY UNTIL PAINT
// WIDTH` (45° lines rising left to right — a progress bar's candy stripe);
// `text "…"|$label X Y [left|center|right] [baseline] [bold] [upper]
// [tracking=N] [size=S] [color=C] [placeholder=C] [ghost="…"] [ghostalpha=A]
// [role=interface|chrome|readout|mono]`;
// `push`, `pop`, `clip`; `move dx dy`, `rotate radians`, `scale sx sy` (for
// what follows, until the `pop` of an enclosing `push`). `pi` is an operand.
//
// **States:** `when a,b op…` runs the op when the widget has any of those
// states; `unless a op…` when it has none. The states are normal, hover,
// pressed, disabled, focused, selected, active.

import CCairo
import CDraw

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - The model

public struct DrawListError: Error, Equatable, Sendable, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

/// A widget's state, as a set.
public struct DrawState: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let hover    = DrawState(rawValue: 1 << 0)
    public static let pressed  = DrawState(rawValue: 1 << 1)
    public static let disabled = DrawState(rawValue: 1 << 2)
    public static let focused  = DrawState(rawValue: 1 << 3)
    public static let selected = DrawState(rawValue: 1 << 4)
    public static let active   = DrawState(rawValue: 1 << 5)
    public static let normal: DrawState = []

    static let names: [(String, DrawState)] = [
        ("normal", []), ("hover", .hover), ("pressed", .pressed), ("disabled", .disabled),
        ("focused", .focused), ("selected", .selected), ("active", .active),
    ]
}

/// An operand: arithmetic over numbers, the widget's size, metrics,
/// parameters and the label's width.
indirect enum Operand: Equatable, Sendable {
    case number(Double)
    case width, height
    case metric(Int)                 // index into ThemeTokens.metricKeys
    case parameter(String)
    case textWidth(Operand)
    case negate(Operand)
    case binary(Operand, Character, Operand)
    case minimum(Operand, Operand)
    case maximum(Operand, Operand)
}

/// A colour, resolved when the list runs so a theme reload reaches it.
indirect enum ColorRef: Equatable, Sendable {
    case literal(Color)
    case token(Int)                  // index into ThemeTokens.colorKeys
    case parameter(String)
    case alpha(ColorRef, Double)
    case shift(ColorRef, Double)
    case fade(ColorRef, String)      // alpha times a parameter — a sheet's dimming as it slides
    case mix(ColorRef, ColorRef, Double)
}

enum Paint: Sendable {
    case solid(ColorRef)
    case vertical([(Double, ColorRef)])
    case linear(Operand, Operand, Operand, Operand, [(Double, ColorRef)])
    case radial(Operand, Operand, Operand, Operand, Operand, Operand, [(Double, ColorRef)])
    case conic(Operand, Operand, Operand, [(Double, ColorRef)])
    case stripes(Double, Operand, ColorRef, Operand, ColorRef)
    case noise(UInt32, Double)
}

enum Shape: Equatable, Sendable {
    enum Corners: Equatable, Sendable { case all, top, bottom }
    case rect(Operand, Operand, Operand, Operand, Operand?, Corners)
    case ellipse(Operand, Operand, Operand, Operand)
    case circle(Operand, Operand, Operand)
    case arc(Operand, Operand, Operand, Operand, Operand)   // cx cy r from to (radians, clockwise)
    case path([PathSegment], closed: Bool)
}

enum PathSegment: Equatable, Sendable {
    case move(Operand, Operand)
    case line(Operand, Operand)
    case curve(Operand, Operand, Operand, Operand, Operand, Operand)
    case arc(Operand, Operand, Operand, Operand, Operand)   // cx cy r from to: a line to its start, then the arc
}

enum TextAlign: Equatable, Sendable { case left, center, right }
enum RuleKind: Equatable, Sendable { case across, slant }

struct TextOp: Sendable {
    var content: String              // "\u{0}label" for $label
    var x: Operand, y: Operand
    var align = TextAlign.left
    var baseline = false
    var bold = false, upper = false
    var tracking = 0.0
    var size: Operand?
    var color = ColorRef.token(ThemeTokens.colorKeys.firstIndex { $0.0 == "bodyText" } ?? 0)
    var placeholder: ColorRef?
    var ghost: String?
    var ghostAlpha = 0.13
    var role = Text.Role.interface
}

enum Op: Sendable {
    case shape(Shape)
    case andShape(Shape)             // one more subpath in the current shape
    case fill(Paint)
    case stroke(Paint, Operand, round: Bool, dash: [Double])
    case bevel(Operand, ColorRef, ColorRef)
    case innerShadow(ColorRef, Operand, Operand?)
    case glow(ColorRef, Operand, Double)
    case shadow(ColorRef, Operand, Operand, Operand)   // colour dx dy blur
    case rules(RuleKind, Operand, Operand, Operand?, Paint, Operand)
    case text(TextOp)
    case push, pop, clip
    case move(Operand, Operand)      // translate what follows
    case rotate(Operand)             // radians, clockwise
    case scale(Operand, Operand)
}

struct Step: Sendable {
    let line: Int
    let when: DrawState?     // any of these
    let unless: DrawState?   // none of these
    let op: Op
}

public struct DrawList: Sendable {
    public let name: String
    let steps: [Step]
}

/// A parsed draw-list file.
public struct DrawListFile: Sendable {
    public private(set) var lists: [String: DrawList]

    public init(parsing text: String) throws {
        lists = try DrawListParser.parse(text)
    }
    init(lists: [String: DrawList]) { self.lists = lists }

    public subscript(_ name: String) -> DrawList? { lists[name] }

    /// These lists, with `other`'s replacing any of the same name.
    public func merging(_ other: DrawListFile) -> DrawListFile {
        DrawListFile(lists: lists.merging(other.lists) { _, new in new })
    }
}

// MARK: - Parsing

enum DrawListParser {
    /// Split a line into words, keeping `"quoted strings"` and `(…)` groups
    /// whole, and dropping a trailing `# comment`.
    static func words(_ line: Substring) -> [String] {
        var out: [String] = []
        var cur = ""
        var depth = 0
        var quote = false
        for ch in line {
            if quote {
                cur.append(ch)
                if ch == "\"" { quote = false }
                continue
            }
            switch ch {
            case "\"": quote = true; cur.append(ch)
            case "(": depth += 1; cur.append(ch)
            case ")": depth -= 1; cur.append(ch)
            case " ", "\t":
                if depth > 0 { cur.append(ch) } else if !cur.isEmpty { out.append(cur); cur = "" }
            default: cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        // A comment is a word that begins with '#' and is not a colour.
        if let i = out.firstIndex(where: { $0.hasPrefix("#") && !isHexColor($0) }) {
            out.removeSubrange(i...)
        }
        return out
    }

    static func isHexColor(_ s: String) -> Bool {
        let body = s.dropFirst().split(separator: "/", maxSplits: 1)
        guard let h = body.first, h.count == 6, UInt32(h, radix: 16) != nil else { return false }
        return true
    }

    static func parse(_ text: String) throws -> [String: DrawList] {
        var lists: [String: DrawList] = [:]
        var current: (name: String, line: Int, steps: [Step])?
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let n = i + 1
            var w = words(raw)
            if w.isEmpty { continue }
            // words() keeps a (…) group whole, so an unclosed one has swallowed
            // the rest of the line — say that, not whatever it looks like now.
            if let open = w.first(where: { $0.filter { $0 == "(" }.count != $0.filter { $0 == ")" }.count }) {
                throw DrawListError(line: n, message: "\(open): a ( is not closed")
            }
            if w[0] == "list" {
                guard current == nil else { throw DrawListError(line: n, message: "list inside list \(current!.name) (missing end?)") }
                guard w.count == 2 else { throw DrawListError(line: n, message: "want: list <name>") }
                guard lists[w[1]] == nil else { throw DrawListError(line: n, message: "a second list called \(w[1])") }
                current = (w[1], n, [])
                continue
            }
            if w[0] == "end" {
                guard let c = current else { throw DrawListError(line: n, message: "end with no list") }
                lists[c.name] = DrawList(name: c.name, steps: c.steps)
                current = nil
                continue
            }
            guard current != nil else { throw DrawListError(line: n, message: "\(w[0]) outside a list") }
            var when: DrawState?, unless: DrawState?
            if w[0] == "when" || w[0] == "unless" {
                guard w.count >= 3 else { throw DrawListError(line: n, message: "\(w[0]) wants states and an op") }
                let st = try states(w[1], line: n)
                if w[0] == "when" { when = st } else { unless = st }
                w.removeFirst(2)
            }
            let op = try parseOp(w, line: n)
            current!.steps.append(Step(line: n, when: when, unless: unless, op: op))
        }
        if let c = current { throw DrawListError(line: c.line, message: "list \(c.name) has no end") }
        return lists
    }

    static func states(_ s: String, line: Int) throws -> DrawState {
        var out: DrawState = []
        for name in s.split(separator: ",") {
            guard let st = DrawState.names.first(where: { $0.0 == name })?.1 else {
                throw DrawListError(line: line, message: "\(name) is not a state (normal hover pressed disabled focused selected active)")
            }
            out.formUnion(st)
        }
        return out
    }

    // MARK: operands

    /// `calc()`-style arithmetic, recursive descent: + - bind looser than * /,
    /// both left to right — the order Swift evaluates the same expression in,
    /// which is what lets a list reproduce a Swift recipe to the bit.
    static func operand(_ s: String, line: Int) throws -> Operand {
        var p = ExprParser(chars: Array(s), line: line, source: s)
        let e = try p.expression()
        guard p.i == p.chars.count else { throw p.fail("unexpected \(String(p.chars[p.i...]))") }
        return e
    }

    struct ExprParser {
        let chars: [Character]
        var i = 0
        let line: Int
        let source: String
        init(chars: [Character], line: Int, source: String) { self.chars = chars; self.line = line; self.source = source }

        func fail(_ why: String) -> DrawListError {
            DrawListError(line: line, message: "\(source): \(why)")
        }
        var peek: Character? { i < chars.count ? chars[i] : nil }

        mutating func expression() throws -> Operand {
            var l = try term()
            while let c = peek, c == "+" || c == "-" { i += 1; l = .binary(l, c, try term()) }
            return l
        }
        mutating func term() throws -> Operand {
            var l = try factor()
            while let c = peek, c == "*" || c == "/" { i += 1; l = .binary(l, c, try factor()) }
            return l
        }
        mutating func factor() throws -> Operand {
            guard let c = peek else { throw fail("an operand is missing") }
            if c == "-" { i += 1; return .negate(try factor()) }
            if c == "(" {
                i += 1
                let e = try expression()
                guard peek == ")" else { throw fail("a ( is not closed") }
                i += 1
                return e
            }
            if c.isNumber || c == "." {
                let start = i
                while let d = peek, d.isNumber || d == "." { i += 1 }
                guard let v = Double(String(chars[start..<i])) else { throw fail("\(String(chars[start..<i])) is not a number") }
                return .number(v)
            }
            if c == "@" || c == "$" {
                i += 1
                let name = identifier(dotted: c == "@")   // @finder.rowHeight
                guard !name.isEmpty else { throw fail("\(c) wants a name") }
                if c == "$" { return .parameter(name) }
                guard let k = ThemeTokens.metricKeys.firstIndex(where: { $0.0 == name }) else {
                    throw fail("@\(name) is not a metric (\(ThemeTokens.metricKeys.map { $0.0 }.joined(separator: " ")))")
                }
                return .metric(k)
            }
            let name = identifier()
            switch name {
            case "w": return .width
            case "h": return .height
            case "pi": return .number(Double.pi)
            case "min", "max", "textw":
                guard peek == "(" else { throw fail("\(name) wants (…)") }
                i += 1
                let a = try expression()
                if name == "textw" {
                    guard peek == ")" else { throw fail("textw wants one size") }
                    i += 1
                    return .textWidth(a)
                }
                guard peek == "," else { throw fail("\(name) wants two operands") }
                i += 1
                while peek == " " { i += 1 }
                let b = try expression()
                guard peek == ")" else { throw fail("\(name) wants two operands") }
                i += 1
                return name == "min" ? .minimum(a, b) : .maximum(a, b)
            case "": throw fail("\(c) is not an operand (a number, w, h, @metric, $parameter, textw, min or max)")
            default: throw fail("\(name) is not an operand (a number, w, h, @metric, $parameter, textw, min or max)")
            }
        }
        mutating func identifier(dotted: Bool = false) -> String {
            let start = i
            while let d = peek, d.isLetter || d.isNumber || d == "_" || (dotted && d == ".") { i += 1 }
            return String(chars[start..<i])
        }
    }

    // MARK: colours

    static func color(_ s: String, line: Int) throws -> ColorRef {
        func fn(_ name: String) -> [String]? {
            guard s.hasPrefix(name + "("), s.hasSuffix(")") else { return nil }
            return s.dropFirst(name.count + 1).dropLast().split(separator: ",").map { String($0).trimmingSpaces }
        }
        if let args = fn("mix") {
            guard args.count == 3, let t = Double(args[2]), t >= 0, t <= 1 else {
                throw DrawListError(line: line, message: "\(s): want mix(colour, colour, 0…1)")
            }
            return .mix(try color(args[0], line: line), try color(args[1], line: line), t)
        }
        if let args = fn("shift") {
            guard args.count == 2, let d = Double(args[1]), d >= -1, d <= 1 else {
                throw DrawListError(line: line, message: "\(s): want shift(colour, -1…1)")
            }
            return .shift(try color(args[0], line: line), d)
        }
        if let args = fn("rgb") ?? fn("rgba") {
            let f = args.compactMap { Double($0) }
            guard f.count == args.count, f.count == (s.hasPrefix("rgba(") ? 4 : 3),
                  f.allSatisfy({ $0 >= 0 && $0 <= 1 }) else {
                throw DrawListError(line: line, message: "\(s): want rgb(r, g, b) or rgba(r, g, b, a), each 0…1")
            }
            return .literal(Color(f[0], f[1], f[2], f.count == 4 ? f[3] : 1))
        }
        if let args = fn("fade") {
            guard args.count == 2, args[1].hasPrefix("$"), args[1].count > 1 else {
                throw DrawListError(line: line, message: "\(s): want fade(colour, $parameter)")
            }
            return .fade(try color(args[0], line: line), String(args[1].dropFirst()))
        }
        if s.hasPrefix("#") {
            guard let c = ThemeLoader.color(s, lookup: { _ in nil }) else {
                throw DrawListError(line: line, message: "\(s) is not a colour")
            }
            return .literal(c)
        }
        // name or $name, optionally /alpha
        var name = Substring(s), alpha: Double?
        if let slash = s.firstIndex(of: "/") {
            name = s[..<slash]
            guard let a = Double(s[s.index(after: slash)...]), a >= 0, a <= 1 else {
                throw DrawListError(line: line, message: "\(s): the alpha after / wants 0…1")
            }
            alpha = a
        }
        let base: ColorRef
        if name.hasPrefix("$"), name.count > 1 {
            base = .parameter(String(name.dropFirst()))
        } else if let k = ThemeTokens.colorKeys.firstIndex(where: { $0.0 == name }) {
            base = .token(k)
        } else {
            throw DrawListError(line: line, message: "\(name) is not a colour token")
        }
        return alpha.map { .alpha(base, $0) } ?? base
    }

    static func stops(_ w: ArraySlice<String>, line: Int) throws -> [(Double, ColorRef)] {
        guard w.first == "stops" else { throw DrawListError(line: line, message: "want: stops <offset> <colour> …") }
        let pairs = Array(w.dropFirst())
        guard pairs.count >= 4, pairs.count % 2 == 0 else {
            throw DrawListError(line: line, message: "stops wants at least two offset/colour pairs")
        }
        return try stride(from: 0, to: pairs.count, by: 2).map { i in
            guard let off = Double(pairs[i]), off >= 0, off <= 1 else {
                throw DrawListError(line: line, message: "\(pairs[i]) is not a stop offset (0…1)")
            }
            return (off, try color(pairs[i + 1], line: line))
        }
    }

    // MARK: paints

    /// A paint at the head of `w`, and how many words it took. A gradient's
    /// stops run to the end of `w`, so a caller with words after a paint hands
    /// over only the paint's.
    static func paint(_ w: ArraySlice<String>, line: Int) throws -> (Paint, Int) {
        guard let head = w.first else { throw DrawListError(line: line, message: "want a paint") }
        let a = Array(w)
        func need(_ k: Int) throws { if a.count < k { throw DrawListError(line: line, message: "\(head) wants \(k - 1) arguments") } }
        let stopsAt = a.firstIndex(of: "stops")
        switch head {
        case "vertical":
            guard stopsAt == 1 else { throw DrawListError(line: line, message: "want: vertical stops …") }
            return (.vertical(try stops(w.dropFirst(1), line: line)), a.count)
        case "linear":
            guard stopsAt == 5 else { throw DrawListError(line: line, message: "want: linear x0 y0 x1 y1 stops …") }
            let st = try stops(w.dropFirst(5), line: line)
            return (.linear(try operand(a[1], line: line), try operand(a[2], line: line),
                            try operand(a[3], line: line), try operand(a[4], line: line), st), a.count)
        case "radial":
            if stopsAt == 4 {
                let st = try stops(w.dropFirst(4), line: line)
                let cx = try operand(a[1], line: line), cy = try operand(a[2], line: line)
                return (.radial(cx, cy, .number(0), cx, cy, try operand(a[3], line: line), st), a.count)
            }
            guard stopsAt == 7 else { throw DrawListError(line: line, message: "want: radial cx cy r stops … or radial x0 y0 r0 x1 y1 r1 stops …") }
            let o = try (1...6).map { try operand(a[$0], line: line) }
            return (.radial(o[0], o[1], o[2], o[3], o[4], o[5], try stops(w.dropFirst(7), line: line)), a.count)
        case "conic":
            guard stopsAt == 4 else { throw DrawListError(line: line, message: "want: conic cx cy r stops …") }
            let st = try stops(w.dropFirst(4), line: line)
            return (.conic(try operand(a[1], line: line), try operand(a[2], line: line), try operand(a[3], line: line), st), a.count)
        case "stripes":
            try need(6)
            guard let ang = Double(a[1]) else { throw DrawListError(line: line, message: "stripes wants an angle in degrees") }
            return (.stripes(ang, try operand(a[2], line: line), try color(a[3], line: line),
                             try operand(a[4], line: line), try color(a[5], line: line)), 6)
        case "noise":
            try need(3)
            guard let seed = UInt32(a[1]), let al = Double(a[2]), al >= 0, al <= 1 else {
                throw DrawListError(line: line, message: "noise wants a seed and an alpha 0…1")
            }
            return (.noise(seed, al), 3)
        default:
            return (.solid(try color(head, line: line)), 1)
        }
    }

    // MARK: ops

    static func parseOp(_ w: [String], line: Int) throws -> Op {
        if w[0] == "and" {
            guard w.count >= 2, case .shape(let sh) = try parseOp(Array(w.dropFirst()), line: line) else {
                throw DrawListError(line: line, message: "and wants a shape (rect ellipse circle path)")
            }
            return .andShape(sh)
        }
        let name = w[0]
        let args = Array(w.dropFirst())
        func o(_ i: Int) throws -> Operand { try operand(args[i], line: line) }
        switch name {
        case "rect":
            guard args.count >= 4, args.count <= 6 else { throw DrawListError(line: line, message: "want: rect x y w h [radius [top|bottom]]") }
            var corners = Shape.Corners.all
            if args.count == 6 {
                switch args[5] {
                case "top": corners = .top
                case "bottom": corners = .bottom
                case "all": corners = .all
                default: throw DrawListError(line: line, message: "\(args[5]) is not top, bottom or all")
                }
            }
            return .shape(.rect(try o(0), try o(1), try o(2), try o(3), args.count >= 5 ? try o(4) : nil, corners))
        case "ellipse":
            guard args.count == 4 else { throw DrawListError(line: line, message: "want: ellipse x y w h") }
            return .shape(.ellipse(try o(0), try o(1), try o(2), try o(3)))
        case "circle":
            guard args.count == 3 else { throw DrawListError(line: line, message: "want: circle cx cy r") }
            return .shape(.circle(try o(0), try o(1), try o(2)))
        case "arc":
            guard args.count == 5 else { throw DrawListError(line: line, message: "want: arc cx cy r from to") }
            return .shape(.arc(try o(0), try o(1), try o(2), try o(3), try o(4)))
        case "path":
            let closed = args.last == "close"
            let a = closed ? Array(args.dropLast()) : args
            let usage = "want: path x y, then x y, curve x1 y1 x2 y2 x y or arc cx cy r from to …, [close]"
            var segs: [PathSegment] = [], i = 0
            while i < a.count {
                if a[i] == "arc" {
                    guard i + 6 <= a.count else { throw DrawListError(line: line, message: usage) }
                    let o = try (1...5).map { try operand(a[i + $0], line: line) }
                    segs.append(.arc(o[0], o[1], o[2], o[3], o[4])); i += 6
                } else if a[i] == "curve" {
                    guard !segs.isEmpty, i + 7 <= a.count else {
                        throw DrawListError(line: line, message: usage)
                    }
                    let o = try (1...6).map { try operand(a[i + $0], line: line) }
                    segs.append(.curve(o[0], o[1], o[2], o[3], o[4], o[5])); i += 7
                } else {
                    guard i + 1 < a.count else { throw DrawListError(line: line, message: usage) }
                    let x = try operand(a[i], line: line), y = try operand(a[i + 1], line: line)
                    segs.append(segs.isEmpty ? .move(x, y) : .line(x, y)); i += 2
                }
            }
            guard segs.count >= 2 || segs.contains(where: { if case .arc = $0 { return true }; return false })
            else { throw DrawListError(line: line, message: usage) }
            return .shape(.path(segs, closed: closed))
        case "fill":
            let (p, used) = try paint(args[...], line: line)
            guard used == args.count else { throw DrawListError(line: line, message: "fill: unexpected \(args[used...].joined(separator: " "))") }
            return .fill(p)
        case "stroke":
            var a = args, round = false, dash: [Double] = []
            while let last = a.last, last == "round" || last.hasPrefix("dash=") {
                if last == "round" { round = true } else {
                    let d = last.dropFirst(5).split(separator: ",").compactMap { Double($0) }
                    guard !d.isEmpty, d.allSatisfy({ $0 >= 0 }), d.contains(where: { $0 > 0 }) else {
                        throw DrawListError(line: line, message: "\(last): want dash=on,off,… in pixels")
                    }
                    dash = d
                }
                a.removeLast()
            }
            guard a.count >= 2 else { throw DrawListError(line: line, message: "want: stroke <paint> <width> [round] [dash=on,off]") }
            let (p, used) = try paint(a.dropLast(), line: line)
            guard used == a.count - 1 else { throw DrawListError(line: line, message: "stroke: unexpected arguments") }
            return .stroke(p, try operand(a.last!, line: line), round: round, dash: dash)
        case "bevel":
            guard args.count == 3 else { throw DrawListError(line: line, message: "want: bevel <width> <light> <shade>") }
            return .bevel(try o(0), try color(args[1], line: line), try color(args[2], line: line))
        case "innershadow":
            guard args.count == 2 || args.count == 3 else { throw DrawListError(line: line, message: "want: innershadow <colour> <size> [extent]") }
            return .innerShadow(try color(args[0], line: line), try o(1), args.count == 3 ? try o(2) : nil)
        case "glow":
            guard args.count == 2 || args.count == 3 else { throw DrawListError(line: line, message: "want: glow <colour> <radius> [strength]") }
            var strength = 1.0
            if args.count == 3 {
                guard let s = Double(args[2]), s >= 0, s <= 4 else { throw DrawListError(line: line, message: "glow strength wants 0…4") }
                strength = s
            }
            return .glow(try color(args[0], line: line), try o(1), strength)
        case "shadow":
            guard args.count == 4 else { throw DrawListError(line: line, message: "want: shadow <colour> <dx> <dy> <blur>") }
            return .shadow(try color(args[0], line: line), try o(1), try o(2), try o(3))
        case "rules":
            guard let kind = args.first, kind == "across" || kind == "slant" else {
                throw DrawListError(line: line, message: "want: rules across FROM EVERY PAINT WIDTH, or rules slant FROM EVERY UNTIL PAINT WIDTH")
            }
            let fixed = kind == "across" ? 3 : 4       // kind + operands before the paint
            guard args.count >= fixed + 2 else { throw DrawListError(line: line, message: "rules \(kind) wants a paint and a width") }
            let (p, used) = try paint(args[fixed..<(args.count - 1)], line: line)
            guard fixed + used == args.count - 1 else { throw DrawListError(line: line, message: "rules: unexpected arguments") }
            return .rules(kind == "across" ? .across : .slant, try o(1), try o(2),
                          kind == "slant" ? try o(3) : nil, p, try operand(args.last!, line: line))
        case "text":
            guard args.count >= 3 else { throw DrawListError(line: line, message: "want: text <\"string\"|$label> x y [options]") }
            let content: String
            if args[0].hasPrefix("\""), args[0].hasSuffix("\""), args[0].count >= 2 {
                content = String(args[0].dropFirst().dropLast())
            } else if args[0] == "$label" {
                content = "\u{0}label"
            } else {
                throw DrawListError(line: line, message: "text wants a \"quoted string\" or $label")
            }
            var t = TextOp(content: content, x: try o(1), y: try o(2))
            for opt in args.dropFirst(3) {
                switch opt {
                case "left": t.align = .left
                case "center": t.align = .center
                case "right": t.align = .right
                case "baseline": t.baseline = true
                case "bold": t.bold = true
                case "upper": t.upper = true
                default:
                    guard let eq = opt.firstIndex(of: "=") else { throw DrawListError(line: line, message: "\(opt) is not a text option") }
                    let k = String(opt[..<eq]), v = String(opt[opt.index(after: eq)...])
                    switch k {
                    case "tracking": guard let n = Double(v) else { throw DrawListError(line: line, message: "tracking wants a number") }; t.tracking = n
                    case "size": t.size = try operand(v, line: line)
                    case "color": t.color = try color(v, line: line)
                    case "placeholder": t.placeholder = try color(v, line: line)
                    case "ghost":
                        guard v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 else { throw DrawListError(line: line, message: "ghost wants a \"quoted string\"") }
                        t.ghost = String(v.dropFirst().dropLast())
                    case "ghostalpha": guard let a = Double(v), a >= 0, a <= 1 else { throw DrawListError(line: line, message: "ghostalpha wants 0…1") }; t.ghostAlpha = a
                    case "role":
                        guard let r = Text.Role.allCases.first(where: { $0.name == v }) else {
                            throw DrawListError(line: line, message: "\(v) is not a role (interface chrome readout mono)")
                        }
                        t.role = r
                    default: throw DrawListError(line: line, message: "\(k) is not a text option")
                    }
                }
            }
            return .text(t)
        case "move":
            guard args.count == 2 else { throw DrawListError(line: line, message: "want: move dx dy") }
            return .move(try o(0), try o(1))
        case "rotate":
            guard args.count == 1 else { throw DrawListError(line: line, message: "want: rotate radians") }
            return .rotate(try o(0))
        case "scale":
            guard args.count == 2 else { throw DrawListError(line: line, message: "want: scale sx sy") }
            return .scale(try o(0), try o(1))
        case "push": return .push
        case "pop": return .pop
        case "clip": return .clip
        default:
            throw DrawListError(line: line, message: "\(name) is not an op (rect ellipse circle arc path fill stroke bevel innershadow glow shadow rules text push pop clip move rotate scale)")
        }
    }
}

// MARK: - Running

public struct DrawContext {
    public var rect: Rect
    public var state: DrawState
    public var label: String
    /// Shown by a `text … placeholder=` op when the label is empty.
    public var placeholder: String
    public var parameters: [String: Double]
    public var colors: [String: Color]
    public init(rect: Rect, state: DrawState = .normal, label: String = "",
                placeholder: String = "", parameters: [String: Double] = [:],
                colors: [String: Color] = [:]) {
        self.rect = rect; self.state = state; self.label = label
        self.placeholder = placeholder; self.parameters = parameters; self.colors = colors
    }
}

public enum DrawListRunner {
    /// Run `list` into `cr` for one widget. A missing parameter at run time
    /// reads as 0 (or a clear colour): the loader has checked the names that
    /// can be checked, so this is a backstop, not a path.
    public static func run(_ list: DrawList, _ cr: OpaquePointer, _ ctx: DrawContext) {
        var shape: Shape?            // the first subpath: what bounds, bevels and glows use
        var more: [Shape] = []       // `and` subpaths, filled and stroked with it
        var depth = 0
        cairo_save(cr)
        cairo_translate(cr, ctx.rect.x, ctx.rect.y)
        for step in list.steps {
            if let w = step.when {
                // `when normal` matches the empty state set.
                let matches = w.isEmpty ? ctx.state.isEmpty : !w.intersection(ctx.state).isEmpty
                if !matches { continue }
            }
            if let u = step.unless, !u.intersection(ctx.state).isEmpty { continue }
            switch step.op {
            case .shape(let s): shape = s; more = []
            case .andShape(let s): if shape == nil { shape = s } else { more.append(s) }
            case .fill(let p):
                guard let s = shape else { continue }
                path(s, cr, ctx, more); setPaint(p, s, cr, ctx); cairo_fill(cr); clearPaint(cr)
            case .stroke(let p, let width, let round, let dash):
                guard let s = shape else { continue }
                path(s, cr, ctx, more); setPaint(p, s, cr, ctx)
                cairo_set_line_width(cr, eval(width, ctx))
                if !dash.isEmpty { cairo_set_dash(cr, dash, Int32(dash.count), 0) }
                if round {
                    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
                }
                cairo_stroke(cr); clearPaint(cr)
                if !dash.isEmpty { cairo_set_dash(cr, [], 0, 0) }
                if round {
                    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT); cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER)
                }
            case .bevel(let width, let hi, let lo):
                guard case .rect(let x, let y, let w, let h, _, _)? = shape else { continue }
                bevel(cr, Rect(eval(x, ctx), eval(y, ctx), eval(w, ctx), eval(h, ctx)),
                      eval(width, ctx), resolve(hi, ctx), resolve(lo, ctx))
            case .innerShadow(let c, let size, let extent):
                guard let s = shape else { continue }
                let b = bounds(s, ctx)
                cairo_save(cr); path(s, cr, ctx); cairo_clip(cr)
                let col = resolve(c, ctx), sz = eval(size, ctx)
                let g = cairo_pattern_create_linear(0, b.y, 0, b.y + sz)
                cairo_pattern_add_color_stop_rgba(g, 0, col.r, col.g, col.b, col.a)
                cairo_pattern_add_color_stop_rgba(g, 1, col.r, col.g, col.b, 0)
                cairo_rectangle(cr, b.x, b.y, b.w, extent.map { eval($0, ctx) } ?? sz)
                cairo_set_source(cr, g)
                cairo_fill(cr)
                cairo_pattern_destroy(g); cairo_restore(cr)
            case .glow(let c, let radius, let strength):
                guard let s = shape else { continue }
                glow(s, cr, ctx, resolve(c, ctx), eval(radius, ctx), strength)
            case .shadow(let c, let dx, let dy, let blur):
                guard let s = shape else { continue }
                glow(s, cr, ctx, resolve(c, ctx), eval(blur, ctx), 1, dx: eval(dx, ctx), dy: eval(dy, ctx))
            case .rules(let kind, let from, let every, let until, let p, let width):
                guard let s = shape else { continue }
                rules(kind, bounds(s, ctx), eval(from, ctx), eval(every, ctx),
                      until.map { eval($0, ctx) }, p, s, eval(width, ctx), cr, ctx)
            case .text(let t):
                text(t, cr, ctx)
            case .move(let dx, let dy): cairo_translate(cr, eval(dx, ctx), eval(dy, ctx))
            case .rotate(let a): cairo_rotate(cr, eval(a, ctx))
            case .scale(let sx, let sy): cairo_scale(cr, eval(sx, ctx), eval(sy, ctx))
            case .push: cairo_save(cr); depth += 1
            case .pop: if depth > 0 { cairo_restore(cr); depth -= 1 }
            case .clip:
                guard let s = shape else { continue }
                path(s, cr, ctx, more); cairo_clip(cr)
            }
        }
        while depth > 0 { cairo_restore(cr); depth -= 1 }
        cairo_restore(cr)
    }

    /// Clip `cr` to the shape `list` describes (its shapes, the `and`s
    /// included) and **leave the clip set** — for a caller that draws more
    /// inside it (a window's gadgets and title inside its frame). The caller
    /// saves and restores around it.
    public static func clip(_ list: DrawList, _ cr: OpaquePointer, _ ctx: DrawContext) {
        var shape: Shape?, more: [Shape] = []
        for step in list.steps {
            switch step.op {
            case .shape(let s): shape = s; more = []
            case .andShape(let s): if shape == nil { shape = s } else { more.append(s) }
            default: continue
            }
        }
        guard let s = shape else { return }
        cairo_save(cr)
        cairo_translate(cr, ctx.rect.x, ctx.rect.y)
        path(s, cr, ctx, more)      // the path is in device space: it outlives the restore
        cairo_restore(cr)
        cairo_clip(cr)
    }

    // MARK: operands and colours

    static func eval(_ o: Operand, _ ctx: DrawContext) -> Double {
        switch o {
        case .number(let d): return d
        case .width: return ctx.rect.w
        case .height: return ctx.rect.h
        case .metric(let k): return Theme.metricTable[k]
        case .parameter(let p): return ctx.parameters[p] ?? 0
        case .textWidth(let size):
            guard let cr = measuring else { return 0 }
            return Draw.textWidth(cr, ctx.label, size: eval(size, ctx))
        case .negate(let a): return -eval(a, ctx)
        case .minimum(let a, let b): return min(eval(a, ctx), eval(b, ctx))
        case .maximum(let a, let b): return max(eval(a, ctx), eval(b, ctx))
        case .binary(let a, let op, let b):
            let l = eval(a, ctx), r = eval(b, ctx)
            switch op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            default: return r == 0 ? 0 : l / r
            }
        }
    }

    /// A context `textw` measures with (only the toy-text fallback needs one).
    nonisolated(unsafe) static var measuring: OpaquePointer? = {
        guard let s = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1) else { return nil }
        defer { cairo_surface_destroy(s) }
        return cairo_create(s)
    }()

    static func resolve(_ c: ColorRef, _ ctx: DrawContext) -> Color {
        switch c {
        case .literal(let col): return col
        case .token(let k): return Theme.colorTable[k]
        case .parameter(let p): return ctx.colors[p] ?? Color(0, 0, 0, 0)
        case .alpha(let base, let a): return resolve(base, ctx).with(a: a)
        case .shift(let base, let d):
            // Clamped per channel, alpha kept — Aqua's pressed and lit-from-
            // above arithmetic, exactly as the Swift recipes did it.
            let b = resolve(base, ctx)
            return d < 0
                ? Color(max(0, b.r + d), max(0, b.g + d), max(0, b.b + d), b.a)
                : Color(min(1, b.r + d), min(1, b.g + d), min(1, b.b + d), b.a)
        case .fade(let base, let p):
            let b = resolve(base, ctx)
            return b.with(a: b.a * (ctx.parameters[p] ?? 0))
        case .mix(let a, let b, let t): return ThemeLoader.mixOKLCH(resolve(a, ctx), resolve(b, ctx), t)
        }
    }

    // MARK: shapes and paints

    static func path(_ s: Shape, _ cr: OpaquePointer, _ ctx: DrawContext, _ more: [Shape] = []) {
        cairo_new_path(cr)
        for sub in [s] + more { subpath(sub, cr, ctx) }
    }

    static func subpath(_ s: Shape, _ cr: OpaquePointer, _ ctx: DrawContext) {
        cairo_new_sub_path(cr)
        switch s {
        case .rect(let x, let y, let w, let h, let r, let corners):
            let rect = Rect(eval(x, ctx), eval(y, ctx), eval(w, ctx), eval(h, ctx))
            let rad = r.map { eval($0, ctx) } ?? 0
            if rad <= 0 { cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h) }
            else {
                switch corners {
                case .all: Draw.roundedRect(cr, rect, radius: rad)
                case .top: Draw.roundedRectTop(cr, rect, radius: rad)
                case .bottom: Draw.roundedRectBottom(cr, rect, radius: rad)
                }
            }
        case .ellipse(let x, let y, let w, let h):
            let ew = eval(w, ctx), eh = eval(h, ctx)
            guard ew > 0, eh > 0 else { return }
            cairo_save(cr)
            cairo_translate(cr, eval(x, ctx) + ew / 2, eval(y, ctx) + eh / 2)
            cairo_scale(cr, ew / 2, eh / 2)
            cairo_arc(cr, 0, 0, 1, 0, 2 * .pi)
            cairo_restore(cr)
        case .circle(let cx, let cy, let r):
            cairo_arc(cr, eval(cx, ctx), eval(cy, ctx), eval(r, ctx), 0, 2 * .pi)
        case .arc(let cx, let cy, let r, let a0, let a1):
            cairo_arc(cr, eval(cx, ctx), eval(cy, ctx), eval(r, ctx), eval(a0, ctx), eval(a1, ctx))
        case .path(let segs, let closed):
            for seg in segs {
                switch seg {
                case .move(let x, let y): cairo_move_to(cr, eval(x, ctx), eval(y, ctx))
                case .line(let x, let y): cairo_line_to(cr, eval(x, ctx), eval(y, ctx))
                case .curve(let x1, let y1, let x2, let y2, let x, let y):
                    cairo_curve_to(cr, eval(x1, ctx), eval(y1, ctx), eval(x2, ctx), eval(y2, ctx),
                                   eval(x, ctx), eval(y, ctx))
                case .arc(let cx, let cy, let r, let a0, let a1):
                    cairo_arc(cr, eval(cx, ctx), eval(cy, ctx), eval(r, ctx), eval(a0, ctx), eval(a1, ctx))
                }
            }
            if closed { cairo_close_path(cr) }
        }
    }

    /// A shape's bounding box, computed the way the Swift recipes computed the
    /// band a vertical gradient spans (a circle's is `cy - r` for `r * 2`).
    static func bounds(_ s: Shape, _ ctx: DrawContext) -> Rect {
        switch s {
        case .rect(let x, let y, let w, let h, _, _), .ellipse(let x, let y, let w, let h):
            return Rect(eval(x, ctx), eval(y, ctx), eval(w, ctx), eval(h, ctx))
        case .circle(let cx, let cy, let r), .arc(let cx, let cy, let r, _, _):
            let rr = eval(r, ctx)
            return Rect(eval(cx, ctx) - rr, eval(cy, ctx) - rr, rr * 2, rr * 2)
        case .path(let segs, _):
            var xs: [Double] = [], ys: [Double] = []
            for seg in segs {
                switch seg {
                case .move(let x, let y), .line(let x, let y):
                    xs.append(eval(x, ctx)); ys.append(eval(y, ctx))
                case .curve(let x1, let y1, let x2, let y2, let x, let y):
                    xs += [eval(x1, ctx), eval(x2, ctx), eval(x, ctx)]; ys += [eval(y1, ctx), eval(y2, ctx), eval(y, ctx)]
                case .arc(let cx, let cy, let r, _, _):
                    let x = eval(cx, ctx), y = eval(cy, ctx), rr = eval(r, ctx)
                    xs += [x - rr, x + rr]; ys += [y - rr, y + rr]
                }
            }
            let x0 = xs.min() ?? 0, y0 = ys.min() ?? 0
            return Rect(x0, y0, (xs.max() ?? 0) - x0, (ys.max() ?? 0) - y0)
        }
    }

    /// Set the source for `p`, for filling or stroking `s`.
    static func setPaint(_ p: Paint, _ s: Shape, _ cr: OpaquePointer, _ ctx: DrawContext) {
        func addStops(_ pat: OpaquePointer?, _ st: [(Double, ColorRef)]) {
            for (o, c) in st { let col = resolve(c, ctx); cairo_pattern_add_color_stop_rgba(pat, o, col.r, col.g, col.b, col.a) }
        }
        switch p {
        case .solid(let c): Draw.setColor(cr, resolve(c, ctx))
        case .vertical(let st):
            let b = bounds(s, ctx)
            let pat = cairo_pattern_create_linear(0, b.y, 0, b.y + b.h)
            addStops(pat, st); cairo_set_source(cr, pat); cairo_pattern_destroy(pat)
        case .linear(let x0, let y0, let x1, let y1, let st):
            let pat = cairo_pattern_create_linear(eval(x0, ctx), eval(y0, ctx), eval(x1, ctx), eval(y1, ctx))
            addStops(pat, st); cairo_set_source(cr, pat); cairo_pattern_destroy(pat)
        case .radial(let x0, let y0, let r0, let x1, let y1, let r1, let st):
            let pat = cairo_pattern_create_radial(eval(x0, ctx), eval(y0, ctx), eval(r0, ctx),
                                                  eval(x1, ctx), eval(y1, ctx), eval(r1, ctx))
            addStops(pat, st); cairo_set_source(cr, pat); cairo_pattern_destroy(pat)
        case .conic(let cx, let cy, let r, let st):
            let pat = conicMesh(eval(cx, ctx), eval(cy, ctx), eval(r, ctx), st.map { ($0.0, resolve($0.1, ctx)) })
            cairo_set_source(cr, pat); cairo_pattern_destroy(pat)
        case .stripes(let angle, let w1, let c1, let w2, let c2):
            let a = max(1, eval(w1, ctx)), b = max(1, eval(w2, ctx))
            // 0° and 90° (brushed metal's hairlines) get a tile already lying the
            // right way; any other angle rotates the pattern, which pixman does
            // per pixel — ~400 µs for a 260×26 strip against ~4 (the P11.3 bench).
            let across = angle.truncatingRemainder(dividingBy: 360) == 90
            let upright = across || angle.truncatingRemainder(dividingBy: 360) == 0
            let n = Int32((a + b).rounded(.up))
            guard let tile = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, across ? 1 : n, across ? n : 1),
                  let tc = cairo_create(tile) else { return }
            Draw.setColor(tc, resolve(c1, ctx))
            if across { cairo_rectangle(tc, 0, 0, 1, a) } else { cairo_rectangle(tc, 0, 0, a, 1) }
            cairo_fill(tc)
            Draw.setColor(tc, resolve(c2, ctx))
            if across { cairo_rectangle(tc, 0, a, 1, b) } else { cairo_rectangle(tc, a, 0, b, 1) }
            cairo_fill(tc)
            cairo_destroy(tc)
            let pat = cairo_pattern_create_for_surface(tile)
            cairo_pattern_set_extend(pat, CAIRO_EXTEND_REPEAT)
            if !upright {
                var m = cairo_matrix_t()
                cairo_matrix_init_rotate(&m, -angle * .pi / 180)
                cairo_pattern_set_matrix(pat, &m)
            }
            cairo_set_source(cr, pat)
            cairo_pattern_destroy(pat); cairo_surface_destroy(tile)
        case .noise(let seed, let alpha):
            let pat = noisePattern(seed, alpha)
            cairo_set_source(cr, pat); cairo_pattern_destroy(pat)
        }
    }

    static func clearPaint(_ cr: OpaquePointer) { cairo_set_source_rgba(cr, 0, 0, 0, 1) }

    /// Parallel hairlines over `b`, each stroked on its own (so where two
    /// overlap they composite twice, as a hand-drawn set would). Bounded: a
    /// step that is not positive draws nothing, and no set passes 10 000.
    static func rules(_ kind: RuleKind, _ b: Rect, _ from: Double, _ every: Double, _ until: Double?,
                      _ p: Paint, _ s: Shape, _ width: Double, _ cr: OpaquePointer, _ ctx: DrawContext) {
        guard every > 0 else { return }
        setPaint(p, s, cr, ctx)
        cairo_set_line_width(cr, width)
        var n = 0
        switch kind {
        case .across:
            var y = b.y + from
            while y < b.y + b.h, n < 10_000 {
                cairo_move_to(cr, b.x, y); cairo_line_to(cr, b.x + b.w, y); cairo_stroke(cr)
                y += every; n += 1
            }
        case .slant:
            var x = from
            let limit = until ?? (b.x + b.w)
            while x < limit, n < 10_000 {
                cairo_move_to(cr, x, b.y + b.h); cairo_line_to(cr, x + b.h, b.y); cairo_stroke(cr)
                x += every; n += 1
            }
        }
        clearPaint(cr)
    }

    /// A conic sweep as quarter-or-smaller Coons patches around the centre
    /// (PHASE11 §4.1: cairo has no conic pattern, and this is how to have one).
    /// Offsets are fractions of a turn from 3 o'clock, clockwise.
    static func conicMesh(_ cx: Double, _ cy: Double, _ r: Double,
                          _ stops: [(Double, Color)]) -> OpaquePointer? {
        let pat = cairo_pattern_create_mesh()
        var st = stops.sorted { $0.0 < $1.0 }
        if st.first!.0 > 0 { st.insert((0, st.first!.1), at: 0) }
        if st.last!.0 < 1 { st.append((1, st.last!.1)) }
        func lerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
            Color(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
        }
        for i in 0..<(st.count - 1) {
            let (o0, c0) = st[i], (o1, c1) = st[i + 1]
            guard o1 > o0 else { continue }
            let pieces = Int(((o1 - o0) * 4).rounded(.up))   // ≤ a quarter turn each
            for k in 0..<pieces {
                let f0 = Double(k) / Double(pieces), f1 = Double(k + 1) / Double(pieces)
                let a0 = (o0 + (o1 - o0) * f0) * 2 * .pi, a1 = (o0 + (o1 - o0) * f1) * 2 * .pi
                let col0 = lerp(c0, c1, f0), col1 = lerp(c0, c1, f1)
                let kk = 4.0 / 3.0 * tan((a1 - a0) / 4)
                let x0 = cx + r * cos(a0), y0 = cy + r * sin(a0)
                let x3 = cx + r * cos(a1), y3 = cy + r * sin(a1)
                cairo_mesh_pattern_begin_patch(pat)
                cairo_mesh_pattern_move_to(pat, cx, cy)
                cairo_mesh_pattern_line_to(pat, x0, y0)
                cairo_mesh_pattern_curve_to(pat, x0 - kk * r * sin(a0), y0 + kk * r * cos(a0),
                                            x3 + kk * r * sin(a1), y3 - kk * r * cos(a1), x3, y3)
                cairo_mesh_pattern_line_to(pat, cx, cy)
                for (corner, c) in [(0, col0), (1, col0), (2, col1), (3, col1)] {
                    cairo_mesh_pattern_set_corner_color_rgba(pat, UInt32(corner), c.r, c.g, c.b, c.a)
                }
                cairo_mesh_pattern_end_patch(pat)
            }
        }
        return pat
    }

    nonisolated(unsafe) static var noiseTiles: [UInt64: OpaquePointer] = [:]

    /// A repeating white-noise tile, made once per seed and strength.
    static func noisePattern(_ seed: UInt32, _ alpha: Double) -> OpaquePointer? {
        let key = UInt64(seed) << 16 | UInt64(alpha * 255)
        if noiseTiles[key] == nil,
           let s = cairo_image_surface_create(CAIRO_FORMAT_A8, 128, 128) {
            cairo_surface_flush(s)
            cd_noise_a8(cairo_image_surface_get_data(s), 128, 128,
                        cairo_image_surface_get_stride(s), seed, Int32(alpha * 255))
            cairo_surface_mark_dirty(s)
            noiseTiles[key] = s
        }
        // White through the tile's alpha, repeating.
        guard let tile = noiseTiles[key],
              let rgba = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 128, 128),
              let tc = cairo_create(rgba) else { return nil }
        cairo_set_source_rgba(tc, 1, 1, 1, 1)
        cairo_mask_surface(tc, tile, 0, 0)
        cairo_destroy(tc)
        let pat = cairo_pattern_create_for_surface(rgba)
        cairo_pattern_set_extend(pat, CAIRO_EXTEND_REPEAT)
        cairo_surface_destroy(rgba)
        return pat
    }

    /// The bevel that is the whole of MUI: a light edge top and left, a shade
    /// bottom and right, `width` pixels, inside the rect.
    static func bevel(_ cr: OpaquePointer, _ r: Rect, _ width: Double, _ hi: Color, _ lo: Color) {
        guard width > 0 else { return }
        Draw.setColor(cr, hi)
        cairo_rectangle(cr, r.x, r.y, r.w, width); cairo_fill(cr)
        cairo_rectangle(cr, r.x, r.y + width, width, r.h - width); cairo_fill(cr)
        Draw.setColor(cr, lo)
        cairo_rectangle(cr, r.x + width, r.y + r.h - width, r.w - width, width); cairo_fill(cr)
        cairo_rectangle(cr, r.x + r.w - width, r.y + width, width, r.h - 2 * width); cairo_fill(cr)
    }

    struct GlowKey: Hashable {
        let shape: String, w: Int32, h: Int32, radius: Int32, scale: Int32
    }
    nonisolated(unsafe) static var glowCache: [GlowKey: OpaquePointer] = [:]
    public nonisolated(unsafe) static var glowsComputed = 0

    /// A halo: the shape's mask, blurred (in C, PHASE11 §4.2) and tinted.
    /// **Cached** by shape, size, radius and scale — a title bar's glow is made
    /// on resize, not per frame.
    static func glow(_ s: Shape, _ cr: OpaquePointer, _ ctx: DrawContext, _ c: Color,
                     _ radius: Double, _ strength: Double, dx: Double = 0, dy: Double = 0) {
        guard radius > 0 else { return }
        let b = bounds(s, ctx)
        let scale = Int32(Text.renderScale)
        let pad = radius * 2
        let key = GlowKey(shape: "\(s)", w: Int32(b.w), h: Int32(b.h), radius: Int32(radius), scale: scale)
        if glowCache[key] == nil {
            let sw = Int32(((b.w + 2 * pad) * Double(scale)).rounded(.up))
            let sh = Int32(((b.h + 2 * pad) * Double(scale)).rounded(.up))
            guard let mask = cairo_image_surface_create(CAIRO_FORMAT_A8, sw, sh),
                  let mc = cairo_create(mask) else { return }
            cairo_scale(mc, Double(scale), Double(scale))
            cairo_translate(mc, pad - b.x, pad - b.y)
            path(s, mc, ctx)
            cairo_set_source_rgba(mc, 0, 0, 0, 1)
            cairo_fill(mc)
            cairo_destroy(mc)
            cairo_surface_flush(mask)
            let stride = cairo_image_surface_get_stride(mask)
            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(sw) * Int(sh))
            cd_blur_a8(cairo_image_surface_get_data(mask), scratch, sw, sh, stride,
                       Int32(radius * Double(scale)))
            scratch.deallocate()
            cairo_surface_mark_dirty(mask)
            glowCache[key] = mask
            glowsComputed += 1
        }
        guard let mask = glowCache[key] else { return }
        cairo_save(cr)
        let pat = cairo_pattern_create_for_surface(mask)
        var m = cairo_matrix_t()
        cairo_matrix_init_scale(&m, Double(scale), Double(scale))
        // A cast shadow (P11.8) is the same blurred mask, moved by (dx, dy).
        cairo_matrix_translate(&m, pad - b.x - dx, pad - b.y - dy)
        cairo_pattern_set_matrix(pat, &m)
        Draw.setColor(cr, c.with(a: min(1, c.a * strength)))
        cairo_mask(cr, pat)
        cairo_pattern_destroy(pat)
        cairo_restore(cr)
    }

    static func text(_ t: TextOp, _ cr: OpaquePointer, _ ctx: DrawContext) {
        var str = t.content == "\u{0}label" ? ctx.label : t.content
        var col = resolve(t.color, ctx)
        if str.isEmpty, let ph = t.placeholder, !ctx.placeholder.isEmpty {
            str = ctx.placeholder; col = resolve(ph, ctx)
        }
        if t.upper { str = str.uppercased() }
        let size = t.size.map { eval($0, ctx) } ?? Theme.fontSize
        let x = eval(t.x, ctx), y = eval(t.y, ctx)
        let style: Text.Style = t.bold ? .bold : .regular
        if let ghost = t.ghost {
            run(t.upper ? ghost.uppercased() : ghost, col.with(a: col.a * t.ghostAlpha))
        }
        run(str, col)

        func run(_ s: String, _ c: Color) {
            // The plain cases are Draw's own text calls, so a list draws a label
            // exactly where the Swift recipe it replaced did (P11.4's gate).
            if t.tracking == 0 && t.align == .center && !t.baseline {
                Draw.text(cr, s, centerX: x, centerY: y, color: c, size: size, style: style, role: t.role); return
            }
            if t.tracking == 0 && t.align == .left && t.baseline {
                Draw.textLeft(cr, s, x: x, baselineY: y, color: c, size: size, style: style, role: t.role); return
            }
            let px = Text.px(size)
            var glyphs = Text.shape(s, px: px, style: style, role: t.role)
            if t.tracking != 0 {
                let tr = t.tracking * Double(Text.renderScale)
                for i in glyphs.indices { glyphs[i].x_advance += tr }
            }
            let width = Text.width(glyphs) / Double(Text.renderScale)
            let baseline: Double
            if t.baseline { baseline = y } else {
                let m = Text.metrics(px: px, role: t.role)
                baseline = y + (m.ascent - m.descent) / 2 / Double(Text.renderScale)
            }
            let left: Double
            switch t.align {
            case .left: left = x
            case .center: left = x - width / 2
            case .right: left = x - width
            }
            Draw.setColor(cr, c)
            Text.drawShaped(cr, glyphs, x: left, baselineY: baseline, px: px)
        }
    }
}
