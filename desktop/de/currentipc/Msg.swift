// CurrentIPC — a typed control-plane message, and its wire format.
//
// A Swift rewrite of the sibling's `current` (read as the spec, not linked —
// docs/PLAN.md). Same shape: a message is a small set of named, typed fields,
// one of which may be a **file descriptor**, because handing over an shm or
// dmabuf handle with no pixel copies is the whole reason the desktop wants a
// control plane of its own (PHASE2.md P2.9).
//
// The encoding is ours rather than FreeBSD's nvlist: with every peer being a
// Swift component we write, nvlist's wire format stopped being a compatibility
// requirement and became just one option — and a codec this small is plainly
// feasible in Swift, which is the standing rule (PLAN.md). Descriptors do NOT
// appear in the byte stream; they travel as SCM_RIGHTS ancillary data and the
// field records their *index* in that array, so several fds stay unambiguous.
//
//   msg    := magic "ABYM" | version u8 | count u16 | field*
//   field  := nameLen u16 | name UTF-8 | kind u8 | payload
//   payload: .string  len u32 | UTF-8
//            .uint64  u64
//            .bool    u8 (0/1)
//            .bytes   len u32 | raw
//            .fd      index u8            (the fd itself rides in SCM_RIGHTS)
//
// Integers are big-endian: this is a documented format, not a memory dump, and
// a fixed order means the bytes a test asserts on are the bytes on the wire.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What went wrong in the control plane. Deliberately small — a caller either
/// retries, or reports, or gives up.
public enum CurrentError: Error, Equatable, Sendable {
    case malformed(String)          // the bytes are not a message we can read
    case tooLarge(Int)              // a frame bigger than `Msg.maxFrame`
    case closed                     // the peer hung up mid-message
    case system(Int32, String)      // a syscall failed (errno, what we tried)
}

/// A typed IPC message: named fields, insertion-ordered so packing is
/// deterministic.
///
/// **Descriptor ownership is explicit.** `set(_:fd:)` *borrows* — the caller
/// must keep the fd open until `send` returns. A received message *owns* the
/// descriptors that arrived with it: take them with `takeFD(_:)` (you then own
/// and must close them), or drop them with `closeFDs()`. Nothing here closes a
/// descriptor behind your back, because a control plane that silently invalidates
/// a buffer handle is worse than one that leaks.
public struct Msg: Sendable {
    /// A field's value. `.fd` holds a raw descriptor, not an index — the index
    /// only exists on the wire.
    public enum Value: Equatable, Sendable {
        case string(String)
        case uint64(UInt64)
        case bool(Bool)
        case bytes([UInt8])
        case fd(Int32)
    }

    /// Refuse to allocate for a frame larger than this. A control message is a
    /// method name and a few scalars; anything approaching a megabyte is a bug
    /// or a hostile peer.
    public static let maxFrame = 1 << 20

    /// At most this many descriptors per message (matches `AP_MAX_FDS`).
    public static let maxFDs = 16

    private static let magic: [UInt8] = Array("ABYM".utf8)
    private static let version: UInt8 = 1

    /// Insertion-ordered fields. Messages hold a handful of entries, so a linear
    /// scan beats a dictionary and keeps the order deterministic.
    public private(set) var fields: [(name: String, value: Value)] = []

    public init() {}

    // MARK: - Building

    /// Set a field, replacing any existing field of the same name (which keeps
    /// its position, so packing stays stable).
    public mutating func set(_ name: String, _ value: Value) {
        if let i = fields.firstIndex(where: { $0.name == name }) {
            fields[i] = (name, value)
        } else {
            fields.append((name, value))
        }
    }

    public mutating func set(_ name: String, _ value: String) { set(name, .string(value)) }
    public mutating func set(_ name: String, _ value: UInt64) { set(name, .uint64(value)) }
    public mutating func set(_ name: String, _ value: Bool)   { set(name, .bool(value)) }
    public mutating func set(_ name: String, bytes: [UInt8])  { set(name, .bytes(bytes)) }

    /// Attach a descriptor. Borrowed, not duplicated — keep it open until the
    /// message is sent.
    public mutating func set(_ name: String, fd: Int32) { set(name, .fd(fd)) }

    // MARK: - Reading
    //
    // A getter returns nil when the field is absent *or* holds another type,
    // matching the sibling: a caller that wanted a number and got a string has
    // the same problem either way.

    public func has(_ name: String) -> Bool { value(name) != nil }

    public func value(_ name: String) -> Value? {
        fields.first(where: { $0.name == name })?.value
    }

    public func string(_ name: String) -> String? {
        if case .string(let s) = value(name) { return s }
        return nil
    }

    public func uint64(_ name: String) -> UInt64? {
        if case .uint64(let n) = value(name) { return n }
        return nil
    }

    public func bool(_ name: String) -> Bool? {
        if case .bool(let b) = value(name) { return b }
        return nil
    }

    public func bytes(_ name: String) -> [UInt8]? {
        if case .bytes(let b) = value(name) { return b }
        return nil
    }

    /// Borrow an attached descriptor. Still owned by the message.
    public func fd(_ name: String) -> Int32? {
        if case .fd(let f) = value(name) { return f }
        return nil
    }

    /// Take a descriptor out of the message: the field is removed and the caller
    /// becomes responsible for closing it.
    public mutating func takeFD(_ name: String) -> Int32? {
        guard let i = fields.firstIndex(where: { $0.name == name }),
              case .fd(let f) = fields[i].value else { return nil }
        fields.remove(at: i)
        return f
    }

    /// Close every descriptor still attached, and drop those fields. For a
    /// receiver that decided it doesn't want them.
    public mutating func closeFDs() {
        for f in fields {
            if case .fd(let raw) = f.value { close(raw) }
        }
        fields.removeAll(where: { if case .fd = $0.value { return true } else { return false } })
    }

    /// The descriptors attached, in field order — the order they go into
    /// SCM_RIGHTS and therefore the order the indices on the wire refer to.
    public var attachedFDs: [Int32] {
        fields.compactMap { if case .fd(let f) = $0.value { return f } else { return nil } }
    }

    // MARK: - Wire format

    /// Serialize to bytes. Descriptors become indices; the fds themselves are
    /// `attachedFDs`, to be sent alongside.
    public func pack() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        out += Msg.magic
        out.append(Msg.version)
        out += be16(UInt16(truncatingIfNeeded: fields.count))
        var fdIndex: UInt8 = 0
        for f in fields {
            let name = Array(f.name.utf8)
            out += be16(UInt16(truncatingIfNeeded: name.count))
            out += name
            switch f.value {
            case .string(let s):
                out.append(Kind.string.rawValue)
                let b = Array(s.utf8)
                out += be32(UInt32(truncatingIfNeeded: b.count))
                out += b
            case .uint64(let n):
                out.append(Kind.uint64.rawValue)
                out += be64(n)
            case .bool(let b):
                out.append(Kind.bool.rawValue)
                out.append(b ? 1 : 0)
            case .bytes(let b):
                out.append(Kind.bytes.rawValue)
                out += be32(UInt32(truncatingIfNeeded: b.count))
                out += b
            case .fd:
                out.append(Kind.fd.rawValue)
                out.append(fdIndex)
                fdIndex += 1
            }
        }
        return out
    }

    /// Parse bytes produced by `pack`. `fds` supplies the descriptors that
    /// arrived over SCM_RIGHTS; an index with no matching fd is malformed.
    public static func unpack(_ buf: [UInt8], fds: [Int32] = []) throws -> Msg {
        var r = Reader(buf)
        guard try r.take(4) == magic else {
            throw CurrentError.malformed("bad magic")
        }
        let v = try r.u8()
        guard v == version else {
            throw CurrentError.malformed("unsupported version \(v)")
        }
        let count = try r.u16()
        var m = Msg()
        for _ in 0..<count {
            let nameLen = Int(try r.u16())
            // As in PoolConfig, decode leniently (this module is Foundation-free
            // by project convention): invalid UTF-8 becomes replacement
            // characters rather than an error. A mojibake key simply won't match
            // what a reader asks for, which is a better failure than refusing
            // the whole message.
            let name = String(decoding: try r.take(nameLen), as: UTF8.self)
            guard let kind = Kind(rawValue: try r.u8()) else {
                throw CurrentError.malformed("unknown field kind for '\(name)'")
            }
            switch kind {
            case .string:
                let n = Int(try r.u32())
                m.set(name, .string(String(decoding: try r.take(n), as: UTF8.self)))
            case .uint64:
                m.set(name, .uint64(try r.u64()))
            case .bool:
                m.set(name, .bool(try r.u8() != 0))
            case .bytes:
                let n = Int(try r.u32())
                m.set(name, .bytes(try r.take(n)))
            case .fd:
                let idx = Int(try r.u8())
                guard idx < fds.count else {
                    throw CurrentError.malformed("field '\(name)' names fd #\(idx), only \(fds.count) arrived")
                }
                m.set(name, .fd(fds[idx]))
            }
        }
        return m
    }

    private enum Kind: UInt8 {
        case string = 1, uint64 = 2, bool = 3, bytes = 4, fd = 5
    }

    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
         UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }
    private func be64(_ v: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8(truncatingIfNeeded: v >> UInt64($0 * 8)) }
    }

    /// A bounds-checked cursor. Every read either succeeds or throws, so a
    /// truncated or hostile frame can't walk off the end of the buffer.
    private struct Reader {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, i + n <= b.count else {
                throw CurrentError.malformed("truncated: wanted \(n) bytes at \(i) of \(b.count)")
            }
            defer { i += n }
            return Array(b[i..<(i + n)])
        }
        mutating func u8() throws -> UInt8 { try take(1)[0] }
        mutating func u16() throws -> UInt16 {
            let x = try take(2); return UInt16(x[0]) << 8 | UInt16(x[1])
        }
        mutating func u32() throws -> UInt32 {
            let x = try take(4)
            return x.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        mutating func u64() throws -> UInt64 {
            let x = try take(8)
            return x.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
    }
}
