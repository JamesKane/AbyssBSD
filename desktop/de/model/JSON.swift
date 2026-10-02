// JSON — the one wire format's values (PHASE18 P18.7).
//
// The model wire is OpenAI-compatible chat completions, which is JSON, and the
// tree has no Foundation (and wants none): this is the whole of it. Objects
// keep their keys in order, so what is written to a transcript reads in the
// order it was sent. Numbers are Doubles, written without a fraction when
// they are whole (token counts stay `42`, not `42.0`).

public indirect enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    // MARK: - reading a value

    public subscript(key: String) -> JSON? {
        guard case .object(let o) = self else { return nil }
        return o.last { $0.0 == key }?.1
    }
    public subscript(index: Int) -> JSON? {
        guard case .array(let a) = self, index >= 0, index < a.count else { return nil }
        return a[index]
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { number.flatMap { $0 == $0.rounded() && abs($0) < 9e15 ? Int($0) : nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }

    /// A copy with `key` set (replaced in place if present, appended if not).
    public func setting(_ key: String, _ value: JSON) -> JSON {
        guard case .object(var o) = self else { return self }
        if let i = o.firstIndex(where: { $0.0 == key }) { o[i].1 = value } else { o.append((key, value)) }
        return .object(o)
    }

    // MARK: - writing

    public var text: String {
        var out = ""
        write(into: &out)
        return out
    }

    func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n):
            if n == n.rounded(), abs(n) < 9e15 { out += String(Int(n)) }
            else if n.isFinite { out += "\(n)" }
            else { out += "null" }   // JSON has no NaN or infinity
        case .string(let s): JSON.quote(s, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() { if i > 0 { out += "," }; v.write(into: &out) }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, (k, v)) in o.enumerated() {
                if i > 0 { out += "," }
                JSON.quote(k, into: &out); out += ":"; v.write(into: &out)
            }
            out += "}"
        }
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    let h = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - h.count) + h
                } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }

    // MARK: - parsing

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let offset: Int
        public let why: String
        public var description: String { "JSON at byte \(offset): \(why)" }
    }

    /// Parse exactly one value (surrounding whitespace allowed). Nesting is
    /// limited, so a hostile body cannot exhaust the stack.
    public static func parse(_ bytes: [UInt8]) throws -> JSON {
        var p = Parser(b: bytes)
        p.ws()
        let v = try p.value(depth: 0)
        p.ws()
        guard p.i == bytes.count else { throw ParseError(offset: p.i, why: "text after the value") }
        return v
    }
    public static func parse(_ text: String) throws -> JSON { try parse(Array(text.utf8)) }

    struct Parser {
        let b: [UInt8]
        var i = 0
        static let maxDepth = 128

        mutating func ws() { while i < b.count, b[i] == 0x20 || b[i] == 0x0a || b[i] == 0x0d || b[i] == 0x09 { i += 1 } }
        func fail(_ why: String) -> ParseError { ParseError(offset: i, why: why) }

        mutating func value(depth: Int) throws -> JSON {
            guard depth < Parser.maxDepth else { throw fail("nested too deep") }
            guard i < b.count else { throw fail("unexpected end") }
            switch b[i] {
            case UInt8(ascii: "{"): return try object(depth)
            case UInt8(ascii: "["): return try array(depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try word("true"); return .bool(true)
            case UInt8(ascii: "f"): try word("false"); return .bool(false)
            case UInt8(ascii: "n"): try word("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func word(_ w: String) throws {
            let u = Array(w.utf8)
            guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { throw fail("expected \(w)") }
            i += u.count
        }

        mutating func object(_ depth: Int) throws -> JSON {
            i += 1; ws()
            var out: [(String, JSON)] = []
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
            while true {
                ws()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                let k = try string()
                ws()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                i += 1; ws()
                out.append((k, try value(depth: depth + 1)))
                ws()
                guard i < b.count else { throw fail("unexpected end in an object") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
                throw fail("expected ',' or '}'")
            }
        }

        mutating func array(_ depth: Int) throws -> JSON {
            i += 1; ws()
            var out: [JSON] = []
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
            while true {
                ws()
                out.append(try value(depth: depth + 1))
                ws()
                guard i < b.count else { throw fail("unexpected end in an array") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
                throw fail("expected ',' or ']'")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else {
                throw fail("bad \\u escape")
            }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            i += 1
            var out: [UInt8] = []
            while true {
                guard i < b.count else { throw fail("unterminated string") }
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c < 0x20 { throw fail("a control character in a string") }
                if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
                i += 1
                guard i < b.count else { throw fail("unterminated escape") }
                let e = b[i]; i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5c)
                case UInt8(ascii: "/"): out.append(0x2f)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0c)
                case UInt8(ascii: "n"): out.append(0x0a)
                case UInt8(ascii: "r"): out.append(0x0d)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var v = try hex4()
                    if v >= 0xd800 && v < 0xdc00 {   // a surrogate pair
                        guard i + 6 <= b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") else {
                            throw fail("a lone high surrogate")
                        }
                        i += 2
                        let lo = try hex4()
                        guard lo >= 0xdc00 && lo < 0xe000 else { throw fail("a bad low surrogate") }
                        v = 0x10000 + ((v - 0xd800) << 10) + (lo - 0xdc00)
                    }
                    guard let s = Unicode.Scalar(v) else { throw fail("not a character") }
                    out += Array(String(Character(s)).utf8)
                default: throw fail("unknown escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func number() throws -> Double {
            let start = i
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            while i < b.count, (b[i] >= 0x30 && b[i] <= 0x39) || b[i] == UInt8(ascii: ".")
                    || b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E")
                    || b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            guard i > start, let d = Double(String(decoding: b[start..<i], as: UTF8.self)) else {
                i = start
                throw fail("expected a value")
            }
            return d
        }
    }
}
