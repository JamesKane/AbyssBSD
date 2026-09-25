// SVGImport — vector artwork into a draw list, at build time (PHASE11 P11.8).
//
// A theme's icons are draw lists; an artist's are SVG. This turns the second
// into the first **once, when the theme is made**, so no process on the
// desktop ever parses SVG (PHASE11 §6.3, §4.4: an SVG renderer is a large
// parser of theme-supplied files living in the process that holds your
// windows — the surface PRODUCT §8.3 rejects).
//
// A deliberately small subset, and strict about it: anything outside it is
// refused by name rather than approximated, because an icon that imported
// "mostly" looks right in the file and wrong on the desktop.
//
//   elements   svg (viewBox), g, path, rect (rx), circle, ellipse, line,
//              polyline, polygon, defs, linearGradient, stop; title, desc and
//              metadata are skipped
//   path d     M L H V C S Q T A Z, absolute and relative — Q, T and A are
//              converted to cubic curves
//   paint      fill, stroke, stroke-width, fill-opacity, stroke-opacity,
//              opacity (attributes or style="…"), #rgb, #rrggbb, rgb(), none,
//              url(#gradient) for a linearGradient (userSpaceOnUse or the
//              object's bounding box)
//   transform  translate() scale() rotate() skewX() skewY() matrix() — all
//              affine, applied to the points (curves transform exactly)
//   gradients  linearGradient and radialGradient (centre and radius; a focal
//              point is not read)
//
// Coordinates come out as fractions of the list's rect — `w*0.25 h*0.5` — so
// the icon draws at any size.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct SVGImportError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public enum SVGImport {
    /// Convert `svg` into a draw list called `name`.
    public static func drawList(named name: String, svg: String) throws -> String {
        var p = XMLReader(Array(svg.utf8))
        let root = try p.document()
        guard root.name == "svg" else { throw SVGImportError(message: "the document is <\(root.name)>, not <svg>") }
        var c = Converter()
        try c.run(root)
        return "list \(name)\n" + c.lines.map { "  " + $0 }.joined(separator: "\n") + "\nend\n"
    }
}

// MARK: - XML, enough of it

struct Element {
    var name: String
    var attrs: [String: String]
    var children: [Element]
}

struct XMLReader {
    let b: [UInt8]
    var i = 0
    init(_ b: [UInt8]) { self.b = b }

    func fail(_ m: String) -> SVGImportError { SVGImportError(message: "XML: \(m) (at byte \(i))") }
    func at(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return i + u.count <= b.count && Array(b[i..<(i + u.count)]) == u
    }
    mutating func skip(until s: String) throws {
        while i < b.count && !at(s) { i += 1 }
        guard at(s) else { throw fail("unterminated \(s)") }
        i += s.utf8.count
    }
    mutating func space() { while i < b.count, b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13 { i += 1 } }
    mutating func misc() throws {
        while true {
            space()
            if at("<?") { try skip(until: "?>") }
            else if at("<!--") { try skip(until: "-->") }
            else if at("<!") { try skip(until: ">") }
            else { return }
        }
    }
    mutating func name() -> String {
        let s = i
        while i < b.count, !(b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13 || b[i] == 47 || b[i] == 62 || b[i] == 61) { i += 1 }
        return String(decoding: b[s..<i], as: UTF8.self)
    }
    mutating func document() throws -> Element {
        try misc()
        let e = try element()
        return e
    }
    mutating func element() throws -> Element {
        guard at("<") else { throw fail("expected <") }
        i += 1
        var e = Element(name: name(), attrs: [:], children: [])
        while true {
            space()
            if at("/>") { i += 2; return e }
            if at(">") { i += 1; break }
            let k = name()
            guard !k.isEmpty else { throw fail("bad attribute in <\(e.name)>") }
            space()
            guard at("=") else { throw fail("attribute \(k) has no value") }
            i += 1; space()
            guard i < b.count, b[i] == 34 || b[i] == 39 else { throw fail("attribute \(k) is not quoted") }
            let q = b[i]; i += 1
            let s = i
            while i < b.count && b[i] != q { i += 1 }
            guard i < b.count else { throw fail("unterminated attribute \(k)") }
            e.attrs[k] = XMLReader.unescape(String(decoding: b[s..<i], as: UTF8.self))
            i += 1
        }
        while true {
            while i < b.count && b[i] != 60 { i += 1 }        // text content is ignored
            if at("<!--") { try skip(until: "-->"); continue }
            if at("<![CDATA[") { try skip(until: "]]>"); continue }
            if at("</") {
                i += 2
                let n = name()
                guard n == e.name else { throw fail("</\(n)> closes <\(e.name)>") }
                space()
                guard at(">") else { throw fail("bad </\(n)>") }
                i += 1
                return e
            }
            guard i < b.count else { throw fail("<\(e.name)> is not closed") }
            e.children.append(try element())
        }
    }
    static func unescape(_ s: String) -> String {
        s.replacingAll("&lt;", "<").replacingAll("&gt;", ">").replacingAll("&quot;", "\"")
            .replacingAll("&apos;", "'").replacingAll("&amp;", "&")
    }
}

extension String {
    func replacingAll(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return self }
        var out = "", rest = Substring(self)
        while let r = rest.range(of: a) { out += rest[..<r.lowerBound]; out += b; rest = rest[r.upperBound...] }
        return out + rest
    }
}

extension Substring {
    func range(of s: String) -> Range<Substring.Index>? {
        guard !s.isEmpty, count >= s.count else { return nil }
        var i = startIndex
        while i < endIndex {
            if self[i...].hasPrefix(s) { return i..<index(i, offsetBy: s.count) }
            i = index(after: i)
        }
        return nil
    }
}

// MARK: - Conversion

struct RGBA { var r, g, b, a: Double }

enum PaintSpec { case none, color(RGBA), gradient(String) }

struct Style {
    var fill: PaintSpec = .color(RGBA(r: 0, g: 0, b: 0, a: 1))   // SVG's default fill is black
    var stroke: PaintSpec = .none
    var strokeWidth = 1.0
    var fillOpacity = 1.0, strokeOpacity = 1.0, opacity = 1.0
    var round = false                // stroke-linejoin / -linecap round
    var dash: [Double] = []
}

/// A 2-D affine transform, as SVG writes it: x' = a x + c y + e, y' = b x + d y + f.
struct Affine {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0
    func apply(_ x: Double, _ y: Double) -> (Double, Double) { (a * x + c * y + e, b * x + d * y + f) }
    func then(_ m: Affine) -> Affine {   // self applied first, then m
        Affine(a: m.a * a + m.c * b, b: m.b * a + m.d * b, c: m.a * c + m.c * d, d: m.b * c + m.d * d,
               e: m.a * e + m.c * f + m.e, f: m.b * e + m.d * f + m.f)
    }
    var scale: Double { (abs(a * d - b * c)).squareRoot() }
}

struct Gradient {
    var x1 = 0.0, y1 = 0.0, x2 = 1.0, y2 = 0.0
    var radial = false
    var cx = 0.5, cy = 0.5, r = 0.5
    var userSpace = false
    var stops: [(Double, RGBA)] = []
}

enum Seg { case move(Double, Double), line(Double, Double), curve(Double, Double, Double, Double, Double, Double), close }

struct Converter {
    var lines: [String] = []
    var vb = (x: 0.0, y: 0.0, w: 1.0, h: 1.0)
    var gradients: [String: Gradient] = [:]

    func fail(_ m: String) -> SVGImportError { SVGImportError(message: m) }

    mutating func run(_ root: Element) throws {
        if let v = root.attrs["viewBox"] {
            let n = numbers(v)
            guard n.count == 4, n[2] > 0, n[3] > 0 else { throw fail("viewBox=\"\(v)\" is not four numbers with a size") }
            vb = (n[0], n[1], n[2], n[3])
        } else if let w = root.attrs["width"].flatMap(length), let h = root.attrs["height"].flatMap(length), w > 0, h > 0 {
            vb = (0, 0, w, h)
        } else {
            throw fail("<svg> has neither a viewBox nor a width and height")
        }
        collectGradients(root)
        try walk(root.children, style: Style(), m: Affine())
    }

    mutating func collectGradients(_ e: Element) {
        for c in e.children {
            if c.name == "linearGradient" || c.name == "radialGradient", let id = c.attrs["id"] {
                var g = Gradient()
                g.radial = c.name == "radialGradient"
                g.userSpace = c.attrs["gradientUnits"] == "userSpaceOnUse"
                func coord(_ k: String, _ d: Double) -> Double {
                    guard let v = c.attrs[k] else { return d }
                    return v.hasSuffix("%") ? (Double(v.dropLast()) ?? d * 100) / 100 : (Double(v) ?? d)
                }
                g.x1 = coord("x1", 0); g.y1 = coord("y1", 0); g.x2 = coord("x2", 1); g.y2 = coord("y2", 0)
                g.cx = coord("cx", 0.5); g.cy = coord("cy", 0.5); g.r = coord("r", 0.5)
                for s in c.children where s.name == "stop" {
                    var st = styleAttrs(s)
                    let off = s.attrs["offset"].map { $0.hasSuffix("%") ? (Double($0.dropLast()) ?? 0) / 100 : (Double($0) ?? 0) } ?? 0
                    let col = (st["stop-color"].flatMap(Converter.color)) ?? RGBA(r: 0, g: 0, b: 0, a: 1)
                    let op = st.removeValue(forKey: "stop-opacity").flatMap(Double.init) ?? 1
                    g.stops.append((min(1, max(0, off)), RGBA(r: col.r, g: col.g, b: col.b, a: col.a * op)))
                }
                gradients[id] = g
            }
            collectGradients(c)
        }
    }

    /// Presentation attributes and `style="k: v; …"`, merged (style wins).
    func styleAttrs(_ e: Element) -> [String: String] {
        var out = e.attrs
        if let s = e.attrs["style"] {
            for decl in s.split(separator: ";") {
                let kv = decl.split(separator: ":", maxSplits: 1).map { String($0).trimmed }
                if kv.count == 2 { out[kv[0]] = kv[1] }
            }
        }
        return out
    }

    mutating func walk(_ els: [Element], style parent: Style, m parentM: Affine) throws {
        for e in els {
            switch e.name {
            case "title", "desc", "metadata", "defs", "linearGradient", "radialGradient": continue
            default: break
            }
            var st = parent
            let a = styleAttrs(e)
            if let v = a["fill-rule"], v == "evenodd" {
                throw fail("<\(e.name)> fill-rule=evenodd: the draw-list format fills nonzero only")
            }
            if let v = a["fill"] { st.fill = try paint(v) }
            if let v = a["stroke"] { st.stroke = try paint(v) }
            if let v = a["stroke-width"] { st.strokeWidth = length(v) ?? st.strokeWidth }
            if let v = a["fill-opacity"].flatMap(Double.init) { st.fillOpacity = v }
            if let v = a["stroke-opacity"].flatMap(Double.init) { st.strokeOpacity = v }
            if let v = a["opacity"].flatMap(Double.init) { st.opacity *= v }
            if let v = a["stroke-linejoin"] { st.round = v == "round" || st.round }
            if let v = a["stroke-linecap"] { st.round = v == "round" || st.round }
            if let v = a["stroke-dasharray"] { st.dash = numbers(v) }
            var m = parentM
            if let t = e.attrs["transform"] { m = try transform(t).then(parentM) }
            switch e.name {
            case "g", "svg":
                try walk(e.children, style: st, m: m)
            case "path":
                guard let d = e.attrs["d"] else { throw fail("<path> with no d") }
                var pp = PathParser(d)
                try emit(try pp.parse(), st, m)
            case "rect":
                let x = num(e, "x"), y = num(e, "y"), w = num(e, "width"), h = num(e, "height")
                var rx = e.attrs["rx"].flatMap(length) ?? e.attrs["ry"].flatMap(length) ?? 0
                rx = min(rx, w / 2, h / 2)
                if rx > 0 {
                    // A rounded rect as four arcs' worth of curves, so a transform
                    // applies to it like any other path.
                    let k = 0.5522847498 * rx
                    let s: [Seg] = [.move(x + rx, y), .line(x + w - rx, y),
                                    .curve(x + w - rx + k, y, x + w, y + rx - k, x + w, y + rx), .line(x + w, y + h - rx),
                                    .curve(x + w, y + h - rx + k, x + w - rx + k, y + h, x + w - rx, y + h), .line(x + rx, y + h),
                                    .curve(x + rx - k, y + h, x, y + h - rx + k, x, y + h - rx), .line(x, y + rx),
                                    .curve(x, y + rx - k, x + rx - k, y, x + rx, y), .close]
                    try emit(s, st, m)
                } else {
                    try emit([.move(x, y), .line(x + w, y), .line(x + w, y + h), .line(x, y + h), .close], st, m)
                }
            case "circle", "ellipse":
                let cx = num(e, "cx"), cy = num(e, "cy")
                let rx = e.name == "circle" ? num(e, "r") : num(e, "rx")
                let ry = e.name == "circle" ? rx : num(e, "ry")
                let k = 0.5522847498
                let s: [Seg] = [.move(cx + rx, cy),
                                .curve(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry),
                                .curve(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy),
                                .curve(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry),
                                .curve(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy), .close]
                try emit(s, st, m)
            case "line":
                try emit([.move(num(e, "x1"), num(e, "y1")), .line(num(e, "x2"), num(e, "y2"))], st, m, fill: false)
            case "polyline", "polygon":
                let n = numbers(e.attrs["points"] ?? "")
                guard n.count >= 4, n.count % 2 == 0 else { throw fail("<\(e.name)> points is not pairs") }
                var s: [Seg] = [.move(n[0], n[1])]
                for i in stride(from: 2, to: n.count, by: 2) { s.append(.line(n[i], n[i + 1])) }
                if e.name == "polygon" { s.append(.close) }
                try emit(s, st, m, fill: e.name == "polygon")
            default:
                throw fail("<\(e.name)> is not in the subset svg2dl imports (svg g path rect circle ellipse line polyline polygon linearGradient)")
            }
        }
    }

    func num(_ e: Element, _ k: String) -> Double { e.attrs[k].flatMap(length) ?? 0 }

    // MARK: output

    /// Five decimals, trailing zeros dropped, never exponent notation (the
    /// draw-list grammar reads plain decimals).
    func fmt(_ v: Double) -> String {
        let scaled = Int64((abs(v) * 100_000).rounded())
        if scaled == 0 { return "0" }
        let ip = scaled / 100_000, fp = scaled % 100_000
        var frac = String(fp)
        while frac.count < 5 { frac = "0" + frac }
        while frac.hasSuffix("0") { frac.removeLast() }
        return (v < 0 ? "-" : "") + String(ip) + (frac.isEmpty ? "" : "." + frac)
    }
    func px(_ x: Double) -> String { "w*" + fmt((x - vb.x) / vb.w) }
    func py(_ y: Double) -> String { "h*" + fmt((y - vb.y) / vb.h) }
    func colour(_ c: RGBA, _ alpha: Double) -> String {
        "rgba(\(fmt(c.r)), \(fmt(c.g)), \(fmt(c.b)), \(fmt(min(1, max(0, c.a * alpha)))))"
    }

    mutating func emit(_ segs: [Seg], _ st: Style, _ m: Affine, fill: Bool = true) throws {
        // Transform, and split into subpaths.
        var subs: [[Seg]] = []
        var xs: [Double] = [], ys: [Double] = []
        for s in segs {
            switch s {
            case .move(let x, let y):
                let (a, b) = m.apply(x, y); xs.append(a); ys.append(b)
                subs.append([.move(a, b)])
            case .line(let x, let y):
                let (a, b) = m.apply(x, y); xs.append(a); ys.append(b)
                if subs.isEmpty { subs.append([]) }
                subs[subs.count - 1].append(.line(a, b))
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                let p1 = m.apply(x1, y1), p2 = m.apply(x2, y2), p = m.apply(x, y)
                xs += [p1.0, p2.0, p.0]; ys += [p1.1, p2.1, p.1]
                if subs.isEmpty { subs.append([]) }
                subs[subs.count - 1].append(.curve(p1.0, p1.1, p2.0, p2.1, p.0, p.1))
            case .close:
                if !subs.isEmpty { subs[subs.count - 1].append(.close) }
            }
        }
        subs = subs.filter { $0.count >= 2 }
        guard !subs.isEmpty else { return }
        for (i, sub) in subs.enumerated() {
            var words: [String] = [i == 0 ? "path" : "and path"]
            var closed = false
            for s in sub {
                switch s {
                case .move(let x, let y), .line(let x, let y): words += [px(x), py(y)]
                case .curve(let x1, let y1, let x2, let y2, let x, let y):
                    words += ["curve", px(x1), py(y1), px(x2), py(y2), px(x), py(y)]
                case .close: closed = true
                }
            }
            if closed { words.append("close") }
            lines.append(words.joined(separator: " "))
        }
        let bbox = (x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!)
        if fill, let f = try paintWords(st.fill, st.fillOpacity * st.opacity, bbox, m) { lines.append("fill " + f) }
        if let s = try paintWords(st.stroke, st.strokeOpacity * st.opacity, bbox, m) {
            var line = "stroke \(s) w*\(fmt(st.strokeWidth * m.scale / vb.w))"
            if st.round { line += " round" }
            if !st.dash.isEmpty {
                // Dashes are in the SVG's units; the list's are points at the
                // drawn size, which svg2dl cannot know — so they are written at
                // the viewBox's own scale (a 64-unit icon drawn at 64 pt).
                line += " dash=" + st.dash.map { fmt($0 * m.scale) }.joined(separator: ",")
            }
            lines.append(line)
        }
    }

    func paintWords(_ p: PaintSpec, _ alpha: Double, _ bbox: (x: Double, y: Double, w: Double, h: Double),
                    _ m: Affine) throws -> String? {
        switch p {
        case .none: return nil
        case .color(let c): return colour(c, alpha)
        case .gradient(let id):
            guard let g = gradients[id] else { throw fail("url(#\(id)): no linearGradient with that id") }
            guard g.stops.count >= 2 else { throw fail("url(#\(id)): a gradient wants two stops") }
            let stopsText = g.stops.map { "\(fmt($0.0)) \(colour($0.1, alpha))" }.joined(separator: " ")
            if g.radial {
                var (cx, cy, r) = (g.cx, g.cy, g.r)
                if g.userSpace { (cx, cy) = m.apply(cx, cy); r *= m.scale }
                else { cx = bbox.x + cx * bbox.w; cy = bbox.y + cy * bbox.h; r *= max(bbox.w, bbox.h) }
                return "radial \(px(cx)) \(py(cy)) w*\(fmt(r / vb.w)) stops \(stopsText)"
            }
            var (x1, y1, x2, y2) = (g.x1, g.y1, g.x2, g.y2)
            if g.userSpace {
                (x1, y1) = m.apply(x1, y1); (x2, y2) = m.apply(x2, y2)
            } else {
                (x1, y1) = (bbox.x + x1 * bbox.w, bbox.y + y1 * bbox.h)
                (x2, y2) = (bbox.x + x2 * bbox.w, bbox.y + y2 * bbox.h)
            }
            let stops = g.stops.map { "\(fmt($0.0)) \(colour($0.1, alpha))" }.joined(separator: " ")
            return "linear \(px(x1)) \(py(y1)) \(px(x2)) \(py(y2)) stops \(stops)"
        }
    }

    // MARK: values

    func paint(_ v: String) throws -> PaintSpec {
        let s = v.trimmed
        if s == "none" { return .none }
        if s.hasPrefix("url(#"), s.hasSuffix(")") { return .gradient(String(s.dropFirst(5).dropLast())) }
        guard let c = Converter.color(s) else { throw fail("\(s) is not a colour svg2dl reads (#rgb #rrggbb rgb() none url(#id))") }
        return .color(c)
    }

    static func color(_ v: String) -> RGBA? {
        let s = v.trimmed
        if s.hasPrefix("#") {
            let h = Array(s.dropFirst())
            let hex = h.count == 3 ? h.flatMap { [$0, $0] } : h
            guard hex.count == 6, let n = UInt32(String(hex), radix: 16) else { return nil }
            return RGBA(r: Double(n >> 16 & 0xff) / 255, g: Double(n >> 8 & 0xff) / 255, b: Double(n & 0xff) / 255, a: 1)
        }
        if s.hasPrefix("rgb("), s.hasSuffix(")") {
            let n = s.dropFirst(4).dropLast().split(separator: ",").compactMap { Double(String($0).trimmed) }
            guard n.count == 3 else { return nil }
            return RGBA(r: n[0] / 255, g: n[1] / 255, b: n[2] / 255, a: 1)
        }
        switch s {
        case "black": return RGBA(r: 0, g: 0, b: 0, a: 1)
        case "white": return RGBA(r: 1, g: 1, b: 1, a: 1)
        default: return nil
        }
    }

    func transform(_ t: String) throws -> Affine {
        var m = Affine()
        var rest = Substring(t.trimmed)
        while !rest.isEmpty {
            guard let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")") else {
                throw fail("transform=\"\(t)\" is not understood")
            }
            let fnName = rest[..<open].trimmingCharacters()
            let n = numbers(String(rest[rest.index(after: open)..<close]))
            let step: Affine
            switch fnName {
            case "translate": step = Affine(e: n.first ?? 0, f: n.count > 1 ? n[1] : 0)
            case "scale": step = Affine(a: n.first ?? 1, d: n.count > 1 ? n[1] : (n.first ?? 1))
            case "rotate":
                let a = (n.first ?? 0) * .pi / 180, c = cos(a), sn = sin(a)
                let r = Affine(a: c, b: sn, c: -sn, d: c)
                if n.count == 3 {   // about (cx, cy)
                    step = Affine(e: -n[1], f: -n[2]).then(r).then(Affine(e: n[1], f: n[2]))
                } else { step = r }
            case "skewX": step = Affine(c: tan((n.first ?? 0) * .pi / 180))
            case "skewY": step = Affine(b: tan((n.first ?? 0) * .pi / 180))
            case "matrix":
                guard n.count == 6 else { throw fail("matrix() wants six numbers") }
                step = Affine(a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5])
            default: throw fail("transform \(fnName)() is not in the subset (translate, scale, rotate, skewX, skewY, matrix)")
            }
            m = step.then(m)            // listed left to right, applied right to left
            rest = rest[rest.index(after: close)...].drop { $0 == " " || $0 == "," }
        }
        return m
    }

    func length(_ v: String) -> Double? {
        var s = v.trimmed
        if s.hasSuffix("px") { s.removeLast(2) }
        return Double(s)
    }
}

func numbers(_ s: String) -> [Double] {
    var out: [Double] = []
    var cur = ""
    func flush() { if let d = Double(cur) { out.append(d) }; cur = "" }
    for ch in s {
        if ch == "-" && !cur.isEmpty && !cur.hasSuffix("e") { flush() }
        if ch.isNumber || ch == "." || ch == "-" || ch == "e" || ch == "+" {
            if ch == "." && cur.contains(".") && !cur.contains("e") { flush() }
            cur.append(ch)
        } else { flush() }
    }
    flush()
    return out
}

extension String {
    var trimmed: String {
        var s = Substring(self)
        while let f = s.first, f == " " || f == "\t" || f == "\n" || f == "\r" { s.removeFirst() }
        while let l = s.last, l == " " || l == "\t" || l == "\n" || l == "\r" { s.removeLast() }
        return String(s)
    }
}
extension Substring {
    func trimmingCharacters() -> String { String(self).trimmed }
}

// MARK: - Path data

struct PathParser {
    let c: [Character]
    var i = 0
    init(_ d: String) { c = Array(d) }

    func fail(_ m: String) -> SVGImportError { SVGImportError(message: "path d: \(m)") }

    mutating func skip() { while i < c.count, c[i] == " " || c[i] == "," || c[i] == "\n" || c[i] == "\t" || c[i] == "\r" { i += 1 } }
    mutating func number() throws -> Double {
        skip()
        let s = i
        if i < c.count, c[i] == "-" || c[i] == "+" { i += 1 }
        var dot = false, exp = false
        while i < c.count {
            let ch = c[i]
            if ch.isNumber { i += 1 }
            else if ch == ".", !dot, !exp { dot = true; i += 1 }
            else if ch == "e" || ch == "E", !exp { exp = true; i += 1; if i < c.count, c[i] == "-" || c[i] == "+" { i += 1 } }
            else { break }
        }
        guard i > s, let d = Double(String(c[s..<i])) else { throw fail("expected a number at \(s)") }
        return d
    }
    mutating func flag() throws -> Bool {
        skip()
        guard i < c.count, c[i] == "0" || c[i] == "1" else { throw fail("expected an arc flag at \(i)") }
        i += 1
        return c[i - 1] == "1"
    }
    mutating func moreNumbers() -> Bool {
        skip()
        return i < c.count && (c[i].isNumber || c[i] == "-" || c[i] == "+" || c[i] == ".")
    }

    mutating func parse() throws -> [Seg] {
        var out: [Seg] = []
        var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0
        var lastCtrl: (Double, Double)?, lastQ: (Double, Double)?
        var cmd: Character = " "
        while true {
            skip()
            guard i < c.count else { break }
            if c[i].isLetter { cmd = c[i]; i += 1 }
            else if cmd == " " { throw fail("expected a command at \(i)") }
            let rel = cmd.isLowercase
            let up = Character(cmd.uppercased())
            func pt() throws -> (Double, Double) {
                let a = try number(), b = try number()
                return rel ? (x + a, y + b) : (a, b)
            }
            switch up {
            case "M":
                let p = try pt(); x = p.0; y = p.1; sx = x; sy = y
                out.append(.move(x, y))
                cmd = rel ? "l" : "L"      // further pairs are line-tos
                lastCtrl = nil; lastQ = nil
                continue
            case "L":
                let p = try pt(); x = p.0; y = p.1; out.append(.line(x, y)); lastCtrl = nil; lastQ = nil
            case "H":
                let a = try number(); x = rel ? x + a : a; out.append(.line(x, y)); lastCtrl = nil; lastQ = nil
            case "V":
                let a = try number(); y = rel ? y + a : a; out.append(.line(x, y)); lastCtrl = nil; lastQ = nil
            case "C":
                let p1 = try pt(), p2 = try pt(), p = try pt()
                out.append(.curve(p1.0, p1.1, p2.0, p2.1, p.0, p.1))
                lastCtrl = p2; lastQ = nil; x = p.0; y = p.1
            case "S":
                let p1 = lastCtrl.map { (2 * x - $0.0, 2 * y - $0.1) } ?? (x, y)
                let p2 = try pt(), p = try pt()
                out.append(.curve(p1.0, p1.1, p2.0, p2.1, p.0, p.1))
                lastCtrl = p2; lastQ = nil; x = p.0; y = p.1
            case "Q", "T":
                let q: (Double, Double)
                if up == "Q" { q = try pt() } else { q = lastQ.map { (2 * x - $0.0, 2 * y - $0.1) } ?? (x, y) }
                let p = try pt()
                // A quadratic is a cubic with its controls two thirds of the way.
                out.append(.curve(x + 2 / 3 * (q.0 - x), y + 2 / 3 * (q.1 - y),
                                  p.0 + 2 / 3 * (q.0 - p.0), p.1 + 2 / 3 * (q.1 - p.1), p.0, p.1))
                lastQ = q; lastCtrl = nil; x = p.0; y = p.1
            case "A":
                let rx = abs(try number()), ry = abs(try number()), rot = try number()
                let large = try flag(), sweep = try flag()
                let p = try pt()
                out += arc(x, y, rx, ry, rot, large, sweep, p.0, p.1)
                lastCtrl = nil; lastQ = nil; x = p.0; y = p.1
            case "Z":
                out.append(.close); x = sx; y = sy; lastCtrl = nil; lastQ = nil
                continue
            default:
                throw fail("\(cmd) is not a path command")
            }
            if !moreNumbers() { continue }
        }
        return out
    }

    /// An elliptical arc as cubic curves (SVG 1.1 §F.6.5: endpoint to centre
    /// parameterisation, then quarter-turn-or-less pieces).
    func arc(_ x1: Double, _ y1: Double, _ rxIn: Double, _ ryIn: Double, _ rotDeg: Double,
             _ large: Bool, _ sweep: Bool, _ x2: Double, _ y2: Double) -> [Seg] {
        if rxIn == 0 || ryIn == 0 || (x1 == x2 && y1 == y2) { return [.line(x2, y2)] }
        var rx = rxIn, ry = ryIn
        let phi = rotDeg * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (x1 - x2) / 2, dy = (y1 - y2) / 2
        let x1p = cp * dx + sp * dy, y1p = -sp * dx + cp * dy
        let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lam > 1 { rx *= lam.squareRoot(); ry *= lam.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var co = (max(0, num) / den).squareRoot()
        if large == sweep { co = -co }
        let cxp = co * rx * y1p / ry, cyp = -co * ry * x1p / rx
        let cx = cp * cxp - sp * cyp + (x1 + x2) / 2, cy = sp * cxp + cp * cyp + (y1 + y2) / 2
        func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
        let n = max(1, Int((abs(dt) / (.pi / 2)).rounded(.up)))
        let step = dt / Double(n), k = 4.0 / 3.0 * tan(step / 4)
        var out: [Seg] = []
        var t = t1
        func point(_ t: Double) -> (Double, Double) {
            (cx + rx * cos(t) * cp - ry * sin(t) * sp, cy + rx * cos(t) * sp + ry * sin(t) * cp)
        }
        func deriv(_ t: Double) -> (Double, Double) {
            (-rx * sin(t) * cp - ry * cos(t) * sp, -rx * sin(t) * sp + ry * cos(t) * cp)
        }
        for _ in 0..<n {
            let a = point(t), da = deriv(t), b = point(t + step), db = deriv(t + step)
            out.append(.curve(a.0 + k * da.0, a.1 + k * da.1, b.0 - k * db.0, b.1 - k * db.1, b.0, b.1))
            t += step
        }
        return out
    }
}
