// DBus — the message (PHASE8.md P8.1).
//
// A message is a fixed 12-byte prologue, an array of header fields, padding to
// 8, then the body. The two subtleties worth stating, because both are silent
// when wrong:
//
//   1. The body's declared length does NOT include the header or its padding,
//      but the body is marshalled at an offset that DOES — so the body's own
//      alignment origin is the padded header length, not zero. Marshalling the
//      body into a fresh buffer with `origin: 0` produces a message that our
//      own reader accepts and a real bus rejects.
//
//   2. `UNIX_FDS` (field 9) must be present and correct whenever descriptors
//      ride along, or the peer will not look for them.

public enum MessageType: UInt8, Sendable {
    case methodCall = 1
    case methodReturn = 2
    case error = 3
    case signal = 4
}

public struct MessageFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let noReplyExpected = MessageFlags(rawValue: 1)
    public static let noAutoStart = MessageFlags(rawValue: 2)
}

/// Header field codes, from the specification.
enum HeaderField: UInt8 {
    case path = 1, interface = 2, member = 3, errorName = 4
    case replySerial = 5, destination = 6, sender = 7, signature = 8, unixFDs = 9
}

public struct DBusMessage: Equatable, Sendable {
    public var type: MessageType
    public var flags: MessageFlags = []
    public var serial: UInt32 = 0

    public var path: String?
    public var interface: String?
    public var member: String?
    public var errorName: String?
    public var replySerial: UInt32?
    public var destination: String?
    public var sender: String?

    public var body: [DBusValue] = []
    /// Descriptors accompanying this message.
    public var fds: [Int32] = []
    /// On a decoded message, its `UNIX_FDS` header: how many of the
    /// descriptors that arrived are this message's (the rest are the next
    /// one's). A forwarder consumes exactly this many (BACKLOG D.1).
    public var declaredFDs = 0

    public init(type: MessageType) { self.type = type }

    public var signature: String { body.map(\.signature).joined() }

    // MARK: Convenience constructors

    public static func methodCall(destination: String, path: String,
                                  interface: String, member: String,
                                  body: [DBusValue] = []) -> DBusMessage {
        var m = DBusMessage(type: .methodCall)
        m.destination = destination
        m.path = path
        m.interface = interface
        m.member = member
        m.body = body
        return m
    }

    public static func methodReturn(to call: DBusMessage,
                                    body: [DBusValue] = []) -> DBusMessage {
        var m = DBusMessage(type: .methodReturn)
        m.replySerial = call.serial
        m.destination = call.sender
        m.body = body
        return m
    }

    public static func error(to call: DBusMessage, name: String,
                             message: String) -> DBusMessage {
        var m = DBusMessage(type: .error)
        m.errorName = name
        m.replySerial = call.serial
        m.destination = call.sender
        m.body = [.string(message)]
        return m
    }

    /// A signal.
    ///
    /// `to:` is the difference between a signal every client on the bus may
    /// receive and one addressed to a single caller. **Pass it whenever the
    /// signal answers a particular client**, because a broadcast is only
    /// delivered to clients that added a match rule for it, and a client that
    /// expects to be addressed adds none — it simply never hears the answer,
    /// with no error anywhere (HANDOFF §2.40).
    public static func signal(path: String, interface: String, member: String,
                              to destination: String? = nil,
                              body: [DBusValue] = []) -> DBusMessage {
        var m = DBusMessage(type: .signal)
        m.path = path
        m.interface = interface
        m.member = member
        m.destination = destination
        m.body = body
        return m
    }

    // MARK: Encoding

    /// Serialise, returning the bytes and the descriptors to send with them.
    public func encode() -> (bytes: [UInt8], fds: [Int32]) {
        // The body is marshalled first, to learn its length and its fds — but at
        // the offset it will actually occupy, which is not known until the
        // header is sized. So: marshal the body twice is wasteful and marshal it
        // at origin 0 is wrong. Instead marshal the fields, compute the padded
        // header length, then marshal the body at that origin.
        var fieldsProbe = Marshaller(origin: 16)   // fields start after the 12-byte
        encodeFields(into: &fieldsProbe, fdCount: 0)  // prologue + the u32 array length
        let headerEnd = 16 + fieldsProbe.bytes.count
        let bodyOrigin = (headerEnd + 7) & ~7

        var bodyM = Marshaller(origin: bodyOrigin)
        for v in body { bodyM.value(v) }
        let bodyBytes = bodyM.bytes
        let allFDs = fds + bodyM.fds

        // Now the real fields, which may gain a UNIX_FDS entry and so change
        // length — recompute the body only if the padded header length moved.
        var fieldsM = Marshaller(origin: 16)
        encodeFields(into: &fieldsM, fdCount: UInt32(allFDs.count))
        let realHeaderEnd = 16 + fieldsM.bytes.count
        let realBodyOrigin = (realHeaderEnd + 7) & ~7
        var finalBody = bodyBytes
        if realBodyOrigin != bodyOrigin {
            var m = Marshaller(origin: realBodyOrigin)
            for v in body { m.value(v) }
            finalBody = m.bytes
        }

        var out = Marshaller()
        out.byte(UInt8(ascii: "l"))          // little-endian
        out.byte(type.rawValue)
        out.byte(flags.rawValue)
        out.byte(1)                          // protocol version
        out.uint32(UInt32(finalBody.count))
        out.uint32(serial)
        out.uint32(UInt32(fieldsM.bytes.count))
        var bytes = out.bytes
        bytes += fieldsM.bytes
        while bytes.count % 8 != 0 { bytes.append(0) }
        bytes += finalBody
        return (bytes, allFDs)
    }

    private func encodeFields(into m: inout Marshaller, fdCount: UInt32) {
        func field(_ code: HeaderField, _ v: DBusValue) {
            m.align(8)
            m.byte(code.rawValue)
            m.value(.variant(v))
        }
        if let path { field(.path, .objectPath(path)) }
        if let interface { field(.interface, .string(interface)) }
        if let member { field(.member, .string(member)) }
        if let errorName { field(.errorName, .string(errorName)) }
        if let replySerial { field(.replySerial, .uint32(replySerial)) }
        if let destination { field(.destination, .string(destination)) }
        if let sender { field(.sender, .string(sender)) }
        if !body.isEmpty { field(.signature, .signature(signature)) }
        if fdCount > 0 { field(.unixFDs, .uint32(fdCount)) }
    }

    // MARK: Decoding

    /// How many bytes the message starting at `bytes` needs in total, or nil if
    /// the 16-byte prologue has not arrived yet.
    public static func framedLength(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 16 else { return nil }
        let le = bytes[0] == UInt8(ascii: "l")
        func u32(_ at: Int) -> UInt32 {
            var v: UInt32 = 0
            if le { for i in (0..<4).reversed() { v = v << 8 | UInt32(bytes[at + i]) } }
            else { for i in 0..<4 { v = v << 8 | UInt32(bytes[at + i]) } }
            return v
        }
        let bodyLen = Int(u32(4))
        let fieldsLen = Int(u32(12))
        let headerEnd = 16 + fieldsLen
        return ((headerEnd + 7) & ~7) + bodyLen
    }

    public static func decode(_ bytes: [UInt8], fds: [Int32] = []) throws -> DBusMessage {
        guard bytes.count >= 16 else { throw DBusError("message shorter than its prologue") }
        let le = bytes[0] == UInt8(ascii: "l")
        guard le || bytes[0] == UInt8(ascii: "B") else {
            throw DBusError("bad endianness byte")
        }
        guard let type = MessageType(rawValue: bytes[1]) else {
            throw DBusError("unknown message type \(bytes[1])")
        }
        var m = DBusMessage(type: type)
        m.flags = MessageFlags(rawValue: bytes[2])

        var head = Unmarshaller(Array(bytes[4...]), origin: 4, littleEndian: le, fds: fds)
        let bodyLen = Int(try head.uint32())
        m.serial = try head.uint32()
        let fieldsLen = Int(try head.uint32())

        let fieldsStart = 16
        guard fieldsStart + fieldsLen <= bytes.count else {
            throw DBusError("header fields run past the message")
        }
        var fieldsU = Unmarshaller(Array(bytes[fieldsStart..<(fieldsStart + fieldsLen)]),
                                   origin: fieldsStart, littleEndian: le, fds: fds)
        var bodySignature = ""
        while fieldsU.remaining > 0 {
            try fieldsU.align(8)
            if fieldsU.remaining == 0 { break }
            let code = try fieldsU.byte()
            let v = try fieldsU.value("v")
            guard case .variant(let inner) = v else { continue }
            switch HeaderField(rawValue: code) {
            case .path: if case .objectPath(let s) = inner { m.path = s }
            case .interface: if case .string(let s) = inner { m.interface = s }
            case .member: if case .string(let s) = inner { m.member = s }
            case .errorName: if case .string(let s) = inner { m.errorName = s }
            case .replySerial: if case .uint32(let n) = inner { m.replySerial = n }
            case .destination: if case .string(let s) = inner { m.destination = s }
            case .sender: if case .string(let s) = inner { m.sender = s }
            case .signature: if case .signature(let s) = inner { bodySignature = s }
            case .unixFDs: if case .uint32(let n) = inner { m.declaredFDs = Int(n) }
            case nil: break                    // unknown fields are ignored, per spec
            }
        }

        let bodyStart = ((fieldsStart + fieldsLen) + 7) & ~7
        guard bodyStart + bodyLen <= bytes.count else {
            throw DBusError("body runs past the message")
        }
        if bodyLen > 0, !bodySignature.isEmpty {
            var bodyU = Unmarshaller(Array(bytes[bodyStart..<(bodyStart + bodyLen)]),
                                     origin: bodyStart, littleEndian: le, fds: fds)
            for part in dbusSplitSignature(bodySignature) {
                m.body.append(try bodyU.value(part))
            }
        }
        m.fds = fds
        return m
    }
}
