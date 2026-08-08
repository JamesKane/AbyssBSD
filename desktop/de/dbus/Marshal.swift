// DBus — marshalling and unmarshalling (PHASE8.md P8.1).
//
// The rule that governs everything here: **every value is aligned to its own
// natural boundary, measured from the start of the message body** — not from
// the start of whatever buffer we happen to be filling. A header's fields and a
// body are marshalled into separate buffers but share one alignment origin, so
// both `Marshaller` and `Unmarshaller` carry an explicit `origin` rather than
// trusting `bytes.count`. Getting that wrong produces output that round-trips
// perfectly through our own reader and is rejected by every real bus.
//
// Little-endian only on the write side (we declare 'l' in the header, which the
// spec allows); the read side honours whatever the peer declared, because a bus
// is entitled to send big-endian and some do.

public struct DBusError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

// MARK: - Writing

public struct Marshaller {
    public private(set) var bytes: [UInt8] = []
    /// How many bytes precede this buffer in the message, for alignment.
    private let origin: Int
    /// Descriptors collected while marshalling, to travel over SCM_RIGHTS.
    public private(set) var fds: [Int32] = []

    public init(origin: Int = 0) { self.origin = origin }

    public mutating func align(_ n: Int) {
        while (origin + bytes.count) % n != 0 { bytes.append(0) }
    }

    public mutating func byte(_ v: UInt8) { bytes.append(v) }

    public mutating func uint16(_ v: UInt16) {
        align(2); bytes += [UInt8(v & 0xff), UInt8(v >> 8)]
    }

    public mutating func uint32(_ v: UInt32) {
        align(4)
        bytes += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                  UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    public mutating func uint64(_ v: UInt64) {
        align(8)
        for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) }
    }

    /// A string: u32 length, the UTF-8, then a NUL that is *not* counted.
    public mutating func string(_ s: String) {
        let b = Array(s.utf8)
        uint32(UInt32(b.count))
        bytes += b
        bytes.append(0)
    }

    /// A signature: a *byte* length (signatures are short by construction), the
    /// text, then a NUL. Note the different length width from `string` — a
    /// mistake here is invisible until a signature happens to exceed 255.
    public mutating func signature(_ s: String) {
        let b = Array(s.utf8)
        bytes.append(UInt8(b.count))
        bytes += b
        bytes.append(0)
    }

    public mutating func value(_ v: DBusValue) {
        switch v {
        case .byte(let b): byte(b)
        case .bool(let b): uint32(b ? 1 : 0)
        case .uint16(let n): uint16(n)
        case .int32(let n): uint32(UInt32(bitPattern: n))
        case .uint32(let n): uint32(n)
        case .uint64(let n): uint64(n)
        case .string(let s), .objectPath(let s): string(s)
        case .signature(let s): signature(s)
        case .unixFD(let fd):
            // The wire carries an INDEX; the descriptor rides out of band.
            uint32(UInt32(fds.count))
            fds.append(fd)
        case .array(let elem, let items):
            // u32 byte-length, then the elements — and the length does NOT
            // include the padding between the length and the first element, so
            // the alignment has to happen before measuring.
            align(4)
            let lengthAt = bytes.count
            bytes += [0, 0, 0, 0]
            align(dbusAlignment(ofSignature: Substring(elem)))
            let contentStart = bytes.count
            for item in items { value(item) }
            let length = UInt32(bytes.count - contentStart)
            bytes[lengthAt] = UInt8(length & 0xff)
            bytes[lengthAt + 1] = UInt8((length >> 8) & 0xff)
            bytes[lengthAt + 2] = UInt8((length >> 16) & 0xff)
            bytes[lengthAt + 3] = UInt8((length >> 24) & 0xff)
        case .structure(let items):
            align(8)
            for item in items { value(item) }
        case .dictEntry(let k, let v2):
            align(8)
            value(k); value(v2)
        case .variant(let inner):
            signature(inner.signature)
            value(inner)
        }
    }
}

// MARK: - Reading

public struct Unmarshaller {
    private let bytes: [UInt8]
    private var pos: Int
    private let origin: Int
    public let littleEndian: Bool
    /// Descriptors that arrived with the message; `.unixFD` indexes into this.
    public var fds: [Int32]

    public init(_ bytes: [UInt8], origin: Int = 0, littleEndian: Bool = true,
                fds: [Int32] = []) {
        self.bytes = bytes
        self.pos = 0
        self.origin = origin
        self.littleEndian = littleEndian
        self.fds = fds
    }

    public var offset: Int { pos }
    public var remaining: Int { bytes.count - pos }

    public mutating func align(_ n: Int) throws {
        while (origin + pos) % n != 0 {
            guard pos < bytes.count else { throw DBusError("truncated padding") }
            pos += 1
        }
    }

    public mutating func byte() throws -> UInt8 {
        guard pos < bytes.count else { throw DBusError("truncated byte") }
        defer { pos += 1 }
        return bytes[pos]
    }

    public mutating func uint16() throws -> UInt16 {
        try align(2)
        guard pos + 2 <= bytes.count else { throw DBusError("truncated uint16") }
        defer { pos += 2 }
        return littleEndian
            ? UInt16(bytes[pos]) | UInt16(bytes[pos + 1]) << 8
            : UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1])
    }

    public mutating func uint32() throws -> UInt32 {
        try align(4)
        guard pos + 4 <= bytes.count else { throw DBusError("truncated uint32") }
        defer { pos += 4 }
        var v: UInt32 = 0
        if littleEndian {
            for i in (0..<4).reversed() { v = v << 8 | UInt32(bytes[pos + i]) }
        } else {
            for i in 0..<4 { v = v << 8 | UInt32(bytes[pos + i]) }
        }
        return v
    }

    public mutating func uint64() throws -> UInt64 {
        try align(8)
        guard pos + 8 <= bytes.count else { throw DBusError("truncated uint64") }
        defer { pos += 8 }
        var v: UInt64 = 0
        if littleEndian {
            for i in (0..<8).reversed() { v = v << 8 | UInt64(bytes[pos + i]) }
        } else {
            for i in 0..<8 { v = v << 8 | UInt64(bytes[pos + i]) }
        }
        return v
    }

    public mutating func string() throws -> String {
        let n = Int(try uint32())
        guard pos + n + 1 <= bytes.count else { throw DBusError("truncated string") }
        let s = String(decoding: bytes[pos..<(pos + n)], as: UTF8.self)
        pos += n + 1                                     // skip the NUL
        return s
    }

    public mutating func signature() throws -> String {
        let n = Int(try byte())
        guard pos + n + 1 <= bytes.count else { throw DBusError("truncated signature") }
        let s = String(decoding: bytes[pos..<(pos + n)], as: UTF8.self)
        pos += n + 1
        return s
    }

    /// Read one complete type named by `sig`.
    public mutating func value(_ sig: String) throws -> DBusValue {
        guard let c = sig.first else { throw DBusError("empty signature") }
        switch c {
        case "y": return .byte(try byte())
        case "b": return .bool(try uint32() != 0)
        case "q": return .uint16(try uint16())
        case "i": return .int32(Int32(bitPattern: try uint32()))
        case "u": return .uint32(try uint32())
        case "t": return .uint64(try uint64())
        case "s": return .string(try string())
        case "o": return .objectPath(try string())
        case "g": return .signature(try signature())
        case "h":
            let idx = Int(try uint32())
            guard idx < fds.count else { throw DBusError("fd index \(idx) out of range") }
            return .unixFD(fds[idx])
        case "v":
            let inner = try signature()
            return .variant(try value(inner))
        case "a":
            let elem = String(sig.dropFirst())
            guard !elem.isEmpty else { throw DBusError("array with no element type") }
            let byteLength = Int(try uint32())
            try align(dbusAlignment(ofSignature: Substring(elem)))
            let end = pos + byteLength
            guard end <= bytes.count else { throw DBusError("array runs past the message") }
            var items: [DBusValue] = []
            while pos < end { items.append(try value(elem)) }
            guard pos == end else { throw DBusError("array overran its declared length") }
            return .array(elem, items)
        case "(":
            try align(8)
            let inner = String(sig.dropFirst().dropLast())
            var items: [DBusValue] = []
            for part in dbusSplitSignature(inner) { items.append(try value(part)) }
            return .structure(items)
        case "{":
            try align(8)
            let inner = String(sig.dropFirst().dropLast())
            let parts = dbusSplitSignature(inner)
            guard parts.count == 2 else { throw DBusError("dict entry needs exactly two types") }
            return .dictEntry(try value(parts[0]), try value(parts[1]))
        default:
            throw DBusError("unsupported type '\(c)'")
        }
    }
}
