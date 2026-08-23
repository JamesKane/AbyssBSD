// DBus — the type system, and the marshalling rules (PHASE8.md P8.1).
//
// D-Bus' wire format is a fixed set of alignment rules over a little- or
// big-endian byte stream. There is no library here — no libdbus (its own docs
// discourage it for new code), no GDBus (that means GLib, and through it the GTK
// stack this project rejects), no sd-bus (systemd). The spike proved a
// hand-written client authenticates and calls `Hello` on both platforms in about
// a hundred lines; this is that, done properly.
//
// **Everything is aligned to its own natural boundary, from the start of the
// message body** — not from the start of the buffer you happen to be writing
// into. That single rule is where hand-rolled D-Bus implementations go wrong,
// and it is why `Marshaller` carries an explicit origin rather than trusting
// `count`.

/// A D-Bus value. Only the types the portal API actually uses — this is a
/// bridge, not a general-purpose binding, and every type here has a caller.
public indirect enum DBusValue: Equatable, Sendable {
    case byte(UInt8)               // y
    case bool(Bool)                // b
    case uint16(UInt16)            // q
    case int32(Int32)              // i
    case uint32(UInt32)            // u
    case uint64(UInt64)            // t
    /// IEEE 754 double. Added in P8.3 for one caller: `org.freedesktop.appearance`
    /// publishes its accent colour as `(ddd)`, and there is no other way to say it.
    case double(Double)            // d
    case string(String)            // s
    case objectPath(String)        // o
    case signature(String)         // g
    /// A file descriptor. On the wire this is a *32-bit index* into the
    /// message's fd array — the descriptor itself travels out of band over
    /// SCM_RIGHTS, exactly as it does in `CurrentIPC` (HANDOFF §2.32).
    case unixFD(Int32)             // h
    case array(String, [DBusValue])          // a<sig> — element signature + items
    case structure([DBusValue])              // (...)
    case variant(DBusValue)                  // v
    case dictEntry(DBusValue, DBusValue)     // {kv}

    /// The signature of this value, as the wire spells it.
    public var signature: String {
        switch self {
        case .byte: return "y"
        case .bool: return "b"
        case .uint16: return "q"
        case .int32: return "i"
        case .uint32: return "u"
        case .uint64: return "t"
        case .double: return "d"
        case .string: return "s"
        case .objectPath: return "o"
        case .signature: return "g"
        case .unixFD: return "h"
        case .array(let elem, _): return "a" + elem
        case .structure(let items): return "(" + items.map(\.signature).joined() + ")"
        case .variant: return "v"
        case .dictEntry(let k, let v): return "{" + k.signature + v.signature + "}"
        }
    }

    /// Alignment of this type's *start*, in bytes.
    public var alignment: Int {
        switch self {
        case .byte, .signature, .variant: return 1
        case .uint16: return 2
        case .bool, .int32, .uint32, .string, .objectPath, .unixFD, .array: return 4
        case .uint64, .double, .structure, .dictEntry: return 8
        }
    }

    /// Convenience: a dictionary of string→variant, the `a{sv}` that every
    /// portal method takes as its options argument.
    public static func options(_ pairs: [(String, DBusValue)]) -> DBusValue {
        .array("{sv}", pairs.map { .dictEntry(.string($0.0), .variant($0.1)) })
    }
}

/// Alignment for a type named by its signature character. Needed when *reading*,
/// where the value's own type is not yet known.
public func dbusAlignment(ofSignature sig: Substring) -> Int {
    guard let c = sig.first else { return 1 }
    switch c {
    case "y", "g", "v": return 1
    case "q", "n": return 2
    case "b", "i", "u", "s", "o", "h": return 4
    case "x", "t", "d", "(", "{": return 8
    case "a": return 4                       // an array starts with its u32 length
    default: return 1
    }
}

/// Split a signature into its top-level complete types.
///
/// `"sa{sv}u"` → `["s", "a{sv}", "u"]`. Needed because a struct's or an array's
/// element signature is a *single* complete type that may itself be nested, and
/// scanning naively splits `a{sv}` into pieces that mean nothing.
public func dbusSplitSignature(_ sig: String) -> [String] {
    var out: [String] = []
    var chars = Array(sig)
    var i = 0
    while i < chars.count {
        let start = i
        var depth = 0
        repeat {
            let c = chars[i]
            if c == "(" || c == "{" { depth += 1 }
            if c == ")" || c == "}" { depth -= 1 }
            i += 1
            // `a` is a prefix: it binds to whatever complete type follows.
            if c == "a" && depth == 0 { continue }
        } while i < chars.count && (depth > 0 || chars[start] == "a" && isPrefixOnly(chars, start, i))
        out.append(String(chars[start..<i]))
    }
    return out
}

/// Whether the run `chars[start..<i]` is still only array prefixes (`a`, `aa`,
/// …) and therefore not yet a complete type.
private func isPrefixOnly(_ chars: [Character], _ start: Int, _ end: Int) -> Bool {
    for k in start..<end where chars[k] != "a" { return false }
    return true
}
