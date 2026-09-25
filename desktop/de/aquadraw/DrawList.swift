// DrawList — a widget's drawing as data (PHASE11.md P11.3).
//
// PRODUCT §8.3: a theme is data, not code. Layer 2 — *how* a control is painted
// — is a **draw list**: a short sequence of declarative ops over a widget's
// rectangle, parameterised by the theme's tokens, its bounded parameters and
// the widget's state. The interpreter here is the only thing that turns one
// into pixels, and it cannot execute anything: no loops, no calls, no
// conditions beyond picking a state.
//
// A file holds any number of lists:
//
//   list button
//     rect 0 0 w h 4                       the current shape: x y w h [radius [top|bottom]]
//     glow menuHighlight 8                  a blurred halo of the shape (cached)
//     fill linear 0 0 0 h stops 0 buttonWhiteTop 1 buttonWhiteBottom
//     when pressed fill #000000/0.1         an op for some states only
//     bevel 1 #ffffff/0.4 #000000/0.6       top-left light, bottom-right shade
//     stroke controlBorder 1
//     text $label w/2 h/2 center bold upper tracking=1.5 color=buttonTextOnWhite
//   end
//
// **Operands** are a number, `w` or `h` (the widget's size), `@metric` (a theme
// metric), `$param` (a theme parameter), or one of those combined once with
// + - * / — `w-1`, `h/2`, `4*$bevel`. That is the whole arithmetic, on purpose
// (PHASE11 §6.5).
//
// **Colours** are anything `theme.ini` accepts: a token name, `#rrggbb[/a]`,
// `r g b a` is NOT accepted here (spaces separate operands) — use `#rrggbb/a` or
// `mix(a, b, t)`.
//
// **Paints:** a colour; `linear x0 y0 x1 y1 stops …`; `radial cx cy r stops …`;
// `conic cx cy r stops …` (cairo mesh patches, PHASE11 §4.1); `stripes angle w1
// c1 w2 c2` (a repeating two-colour pattern — brushed metal is two of these
// over a gradient); `noise seed alpha` (a deterministic white-noise tile —
// anodized panels). `stops` is followed by offset/colour pairs.
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

/// One operand: a number, the widget's size, a metric or a parameter — once
/// combined, at most.
indirect enum Operand: Equatable, Sendable {
    case number(Double)
    case width, height
    case metric(String)
    case parameter(String)
    case binary(Operand, Character, Operand)
}

/// A colour, resolved when the list runs so a theme reload reaches it.
indirect enum ColorRef: Equatable, Sendable {
    case literal(Color)
    case token(String)
    case mix(ColorRef, ColorRef, Double)
}

enum Paint: Sendable {
    case solid(ColorRef)
    case linear(Operand, Operand, Operand, Operand, [(Double, ColorRef)])
    case radial(Operand, Operand, Operand, [(Double, ColorRef)])
    case conic(Operand, Operand, Operand, [(Double, ColorRef)])
    case stripes(Double, Operand, ColorRef, Operand, ColorRef)
    case noise(UInt32, Double)
}

enum Shape: Equatable, Sendable {
    enum Corners: Equatable, Sendable { case all, top, bottom }
    case rect(Operand, Operand, Operand, Operand, Operand?, Corners)
    case ellipse(Operand, Operand, Operand, Operand)
}

enum TextAlign: Equatable, Sendable { case left, center, right }

enum Op: Sendable {
    case shape(Shape)
    case fill(Paint)
    case stroke(Paint, Operand)
    case bevel(Operand, ColorRef, ColorRef)
    case innerShadow(ColorRef, Operand)
    case glow(ColorRef, Operand, Double)
    case text(content: String, x: Operand, y: Operand, align: TextAlign, bold: Bool,
              upper: Bool, tracking: Double, size: Operand?, color: ColorRef, ghost: String?,
              ghostAlpha: Double)
    case push, pop, clip
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
    public let lists: [String: DrawList]

    public init(parsing text: String) throws {
        lists = try DrawListParser.parse(text)
    }

    public subscript(_ name: String) -> DrawList? { lists[name] }
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

    static func operand(_ s: String, line: Int) throws -> Operand {
        func term(_ t: Substring) throws -> Operand {
            if t == "w" { return .width }
            if t == "h" { return .height }
            if t.hasPrefix("@"), t.count > 1 { return .metric(String(t.dropFirst())) }
            if t.hasPrefix("$"), t.count > 1 { return .parameter(String(t.dropFirst())) }
            if let d = Double(t) { return .number(d) }
            throw DrawListError(line: line, message: "\(t) is not an operand (a number, w, h, @metric or $parameter)")
        }
        if let d = Double(s) { return .number(d) }
        // One binary operator at most, not at position 0 (a leading minus is a
        // number) and not straight after another (`w*-2` is w times -2).
        let ops = "+-*/"
        let chars = Array(s)
        let at = chars.indices.dropFirst().filter { ops.contains(chars[$0]) && !ops.contains(chars[$0 - 1]) }
        if at.count > 1 { throw DrawListError(line: line, message: "\(s): one operator at most") }
        if let i = at.first {
            let idx = s.index(s.startIndex, offsetBy: i)
            return .binary(try term(s[..<idx]), chars[i], try term(s[s.index(after: idx)...]))
        }
        return try term(Substring(s))
    }

    static func color(_ s: String, line: Int) throws -> ColorRef {
        if s.hasPrefix("mix("), s.hasSuffix(")") {
            let args = s.dropFirst(4).dropLast().split(separator: ",").map { String($0).trimmingSpaces }
            guard args.count == 3, let t = Double(args[2]), t >= 0, t <= 1 else {
                throw DrawListError(line: line, message: "\(s): want mix(colour, colour, 0…1)")
            }
            return .mix(try color(args[0], line: line), try color(args[1], line: line), t)
        }
        if s.hasPrefix("#") {
            guard let c = ThemeLoader.color(s, lookup: { _ in nil }) else {
                throw DrawListError(line: line, message: "\(s) is not a colour")
            }
            return .literal(c)
        }
        guard ThemeTokens.colorKeys.contains(where: { $0.0 == s }) else {
            throw DrawListError(line: line, message: "\(s) is not a colour token")
        }
        return .token(s)
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

    static func paint(_ w: ArraySlice<String>, line: Int) throws -> (Paint, Int) {
        guard let head = w.first else { throw DrawListError(line: line, message: "want a paint") }
        let a = Array(w)
        func need(_ k: Int) throws { if a.count < k { throw DrawListError(line: line, message: "\(head) wants \(k - 1) arguments") } }
        switch head {
        case "linear":
            try need(6)
            let st = try stops(w.dropFirst(5), line: line)
            return (.linear(try operand(a[1], line: line), try operand(a[2], line: line),
                            try operand(a[3], line: line), try operand(a[4], line: line), st), a.count)
        case "radial", "conic":
            try need(5)
            let st = try stops(w.dropFirst(4), line: line)
            let args = (try operand(a[1], line: line), try operand(a[2], line: line), try operand(a[3], line: line))
            return (head == "radial" ? .radial(args.0, args.1, args.2, st) : .conic(args.0, args.1, args.2, st), a.count)
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

    static func parseOp(_ w: [String], line: Int) throws -> Op {
        let name = w[0]
        let args = Array(w.dropFirst())
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
            return .shape(.rect(try operand(args[0], line: line), try operand(args[1], line: line),
                                try operand(args[2], line: line), try operand(args[3], line: line),
                                args.count >= 5 ? try operand(args[4], line: line) : nil, corners))
        case "ellipse":
            guard args.count == 4 else { throw DrawListError(line: line, message: "want: ellipse x y w h") }
            return .shape(.ellipse(try operand(args[0], line: line), try operand(args[1], line: line),
                                   try operand(args[2], line: line), try operand(args[3], line: line)))
        case "fill":
            let (p, used) = try paint(args[...], line: line)
            guard used == args.count else { throw DrawListError(line: line, message: "fill: unexpected \(args[used...].joined(separator: " "))") }
            return .fill(p)
        case "stroke":
            guard args.count >= 2 else { throw DrawListError(line: line, message: "want: stroke <paint> <width>") }
            let (p, used) = try paint(args.dropLast(), line: line)
            guard used == args.count - 1 else { throw DrawListError(line: line, message: "stroke: unexpected arguments") }
            return .stroke(p, try operand(args.last!, line: line))
        case "bevel":
            guard args.count == 3 else { throw DrawListError(line: line, message: "want: bevel <width> <light> <shade>") }
            return .bevel(try operand(args[0], line: line), try color(args[1], line: line), try color(args[2], line: line))
        case "innershadow":
            guard args.count == 2 else { throw DrawListError(line: line, message: "want: innershadow <colour> <size>") }
            return .innerShadow(try color(args[0], line: line), try operand(args[1], line: line))
        case "glow":
            guard args.count == 2 || args.count == 3 else { throw DrawListError(line: line, message: "want: glow <colour> <radius> [strength]") }
            var strength = 1.0
            if args.count == 3 {
                guard let s = Double(args[2]), s >= 0, s <= 4 else { throw DrawListError(line: line, message: "glow strength wants 0…4") }
                strength = s
            }
            return .glow(try color(args[0], line: line), try operand(args[1], line: line), strength)
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
            var align = TextAlign.left, bold = false, upper = false, tracking = 0.0
            var size: Operand?, color = ColorRef.token("bodyText"), ghost: String?, ghostAlpha = 0.13
            for opt in args.dropFirst(3) {
                switch opt {
                case "left": align = .left
                case "center": align = .center
                case "right": align = .right
                case "bold": bold = true
                case "upper": upper = true
                default:
                    guard let eq = opt.firstIndex(of: "=") else { throw DrawListError(line: line, message: "\(opt) is not a text option") }
                    let k = String(opt[..<eq]), v = String(opt[opt.index(after: eq)...])
                    switch k {
                    case "tracking": guard let t = Double(v) else { throw DrawListError(line: line, message: "tracking wants a number") }; tracking = t
                    case "size": size = try operand(v, line: line)
                    case "color": color = try self.color(v, line: line)
                    case "ghost":
                        guard v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 else { throw DrawListError(line: line, message: "ghost wants a \"quoted string\"") }
                        ghost = String(v.dropFirst().dropLast())
                    case "ghostalpha": guard let a = Double(v), a >= 0, a <= 1 else { throw DrawListError(line: line, message: "ghostalpha wants 0…1") }; ghostAlpha = a
                    default: throw DrawListError(line: line, message: "\(k) is not a text option")
                    }
                }
            }
            return .text(content: content, x: try operand(args[1], line: line), y: try operand(args[2], line: line),
                         align: align, bold: bold, upper: upper, tracking: tracking, size: size,
                         color: color, ghost: ghost, ghostAlpha: ghostAlpha)
        case "push": return .push
        case "pop": return .pop
        case "clip": return .clip
        default:
            throw DrawListError(line: line, message: "\(name) is not an op (rect ellipse fill stroke bevel innershadow glow text push pop clip)")
        }
    }
}

// MARK: - Running

public struct DrawContext {
    public var rect: Rect
    public var state: DrawState
    public var label: String
    public var parameters: [String: Double]
    public init(rect: Rect, state: DrawState = .normal, label: String = "",
                parameters: [String: Double] = [:]) {
        self.rect = rect; self.state = state; self.label = label; self.parameters = parameters
    }
}

public enum DrawListRunner {
    /// Run `list` into `cr` for one widget. A missing token or parameter at run
    /// time draws nothing for that op and is reported once — the loader will
    /// have checked the names already, so this is a backstop, not a path.
    public static func run(_ list: DrawList, _ cr: OpaquePointer, _ ctx: DrawContext) {
        var shape: Shape?
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
            case .shape(let s): shape = s
            case .fill(let p):
                guard let s = shape else { continue }
                path(s, cr, ctx); setPaint(p, cr, ctx); cairo_fill(cr); clearPaint(cr)
            case .stroke(let p, let width):
                guard let s = shape else { continue }
                path(s, cr, ctx); setPaint(p, cr, ctx)
                cairo_set_line_width(cr, eval(width, ctx)); cairo_stroke(cr); clearPaint(cr)
            case .bevel(let width, let hi, let lo):
                guard case .rect(let x, let y, let w, let h, _, _)? = shape else { continue }
                bevel(cr, Rect(eval(x, ctx), eval(y, ctx), eval(w, ctx), eval(h, ctx)),
                      eval(width, ctx), resolve(hi), resolve(lo))
            case .innerShadow(let c, let size):
                guard let s = shape, case .rect(let x, let y, let w, _, _, _) = s else { continue }
                cairo_save(cr); path(s, cr, ctx); cairo_clip(cr)
                let col = resolve(c), sz = eval(size, ctx), top = eval(y, ctx)
                let g = cairo_pattern_create_linear(0, top, 0, top + sz)
                cairo_pattern_add_color_stop_rgba(g, 0, col.r, col.g, col.b, col.a)
                cairo_pattern_add_color_stop_rgba(g, 1, col.r, col.g, col.b, 0)
                cairo_set_source(cr, g)
                cairo_rectangle(cr, eval(x, ctx), top, eval(w, ctx), sz); cairo_fill(cr)
                cairo_pattern_destroy(g); cairo_restore(cr)
            case .glow(let c, let radius, let strength):
                guard let s = shape else { continue }
                glow(s, cr, ctx, resolve(c), eval(radius, ctx), strength)
            case .text(let content, let x, let y, let align, let bold, let upper, let tracking,
                       let size, let color, let ghost, let ghostAlpha):
                var str = content == "\u{0}label" ? ctx.label : content
                if upper { str = str.uppercased() }
                let sz = size.map { eval($0, ctx) } ?? Theme.fontSize
                let col = resolve(color)
                if let ghost {
                    let gs = upper ? ghost.uppercased() : ghost
                    text(cr, gs, eval(x, ctx), eval(y, ctx), align, bold, tracking, sz, col.with(a: col.a * ghostAlpha))
                }
                text(cr, str, eval(x, ctx), eval(y, ctx), align, bold, tracking, sz, col)
            case .push: cairo_save(cr); depth += 1
            case .pop: if depth > 0 { cairo_restore(cr); depth -= 1 }
            case .clip:
                guard let s = shape else { continue }
                path(s, cr, ctx); cairo_clip(cr)
            }
        }
        while depth > 0 { cairo_restore(cr); depth -= 1 }
        cairo_restore(cr)
    }

    // MARK: operands and colours

    static func eval(_ o: Operand, _ ctx: DrawContext) -> Double {
        switch o {
        case .number(let d): return d
        case .width: return ctx.rect.w
        case .height: return ctx.rect.h
        case .metric(let m):
            return ThemeTokens.metricKeys.first(where: { $0.0 == m }).map { Theme.current[keyPath: $0.1] } ?? 0
        case .parameter(let p): return ctx.parameters[p] ?? 0
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

    static func resolve(_ c: ColorRef) -> Color {
        switch c {
        case .literal(let col): return col
        case .token(let t):
            return ThemeTokens.colorKeys.first(where: { $0.0 == t }).map { Theme.current[keyPath: $0.1] } ?? Color(0, 0, 0, 0)
        case .mix(let a, let b, let t): return ThemeLoader.mixOKLCH(resolve(a), resolve(b), t)
        }
    }

    // MARK: shapes and paints

    static func path(_ s: Shape, _ cr: OpaquePointer, _ ctx: DrawContext) {
        cairo_new_path(cr)
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
        }
    }

    /// Set the source for `p`. Patterns are owned by the cairo context after
    /// this, and released by `clearPaint`.
    static func setPaint(_ p: Paint, _ cr: OpaquePointer, _ ctx: DrawContext) {
        func addStops(_ pat: OpaquePointer?, _ st: [(Double, ColorRef)]) {
            for (o, c) in st { let col = resolve(c); cairo_pattern_add_color_stop_rgba(pat, o, col.r, col.g, col.b, col.a) }
        }
        switch p {
        case .solid(let c): Draw.setColor(cr, resolve(c))
        case .linear(let x0, let y0, let x1, let y1, let st):
            let pat = cairo_pattern_create_linear(eval(x0, ctx), eval(y0, ctx), eval(x1, ctx), eval(y1, ctx))
            addStops(pat, st); cairo_set_source(cr, pat); cairo_pattern_destroy(pat)
        case .radial(let cx, let cy, let r, let st):
            let x = eval(cx, ctx), y = eval(cy, ctx)
            let pat = cairo_pattern_create_radial(x, y, 0, x, y, eval(r, ctx))
            addStops(pat, st); cairo_set_source(cr, pat); cairo_pattern_destroy(pat)
        case .conic(let cx, let cy, let r, let st):
            let pat = conicMesh(eval(cx, ctx), eval(cy, ctx), eval(r, ctx), st.map { ($0.0, resolve($0.1)) })
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
            Draw.setColor(tc, resolve(c1))
            if across { cairo_rectangle(tc, 0, 0, 1, a) } else { cairo_rectangle(tc, 0, 0, a, 1) }
            cairo_fill(tc)
            Draw.setColor(tc, resolve(c2))
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
                     _ radius: Double, _ strength: Double) {
        guard radius > 0 else { return }
        var bx = 0.0, by = 0.0, bw = 0.0, bh = 0.0
        switch s {
        case .rect(let x, let y, let w, let h, _, _), .ellipse(let x, let y, let w, let h):
            bx = eval(x, ctx); by = eval(y, ctx); bw = eval(w, ctx); bh = eval(h, ctx)
        }
        let scale = Int32(Text.renderScale)
        let pad = radius * 2
        let key = GlowKey(shape: "\(s)", w: Int32(bw), h: Int32(bh), radius: Int32(radius), scale: scale)
        if glowCache[key] == nil {
            let sw = Int32(((bw + 2 * pad) * Double(scale)).rounded(.up))
            let sh = Int32(((bh + 2 * pad) * Double(scale)).rounded(.up))
            guard let mask = cairo_image_surface_create(CAIRO_FORMAT_A8, sw, sh),
                  let mc = cairo_create(mask) else { return }
            cairo_scale(mc, Double(scale), Double(scale))
            cairo_translate(mc, pad - bx, pad - by)
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
        cairo_matrix_translate(&m, pad - bx, pad - by)
        cairo_pattern_set_matrix(pat, &m)
        Draw.setColor(cr, c.with(a: min(1, c.a * strength)))
        cairo_mask(cr, pat)
        cairo_pattern_destroy(pat)
        cairo_restore(cr)
    }

    static func text(_ cr: OpaquePointer, _ s: String, _ x: Double, _ y: Double,
                     _ align: TextAlign, _ bold: Bool, _ tracking: Double, _ size: Double, _ c: Color) {
        let px = Text.px(size)
        var glyphs = Text.shape(s, px: px, style: bold ? .bold : .regular)
        if tracking != 0 {
            let t = tracking * Double(Text.renderScale)
            for i in glyphs.indices { glyphs[i].x_advance += t }
        }
        let width = Text.width(glyphs) / Double(Text.renderScale)
        let m = Text.metrics(px: px)
        let baseline = y + (m.ascent - m.descent) / 2 / Double(Text.renderScale)
        let left: Double
        switch align {
        case .left: left = x
        case .center: left = x - width / 2
        case .right: left = x - width
        }
        Draw.setColor(cr, c)
        Text.drawShaped(cr, glyphs, x: left, baselineY: baseline, px: px)
    }
}
