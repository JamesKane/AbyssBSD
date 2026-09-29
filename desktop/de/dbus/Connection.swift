// DBus — the connection: address, authentication, dispatch (PHASE8.md P8.1).
//
// Descriptor passing reuses `CPlatform`'s `ap_sendmsg_fds`/`ap_recvmsg_fds` —
// the same SCM_RIGHTS helpers `CurrentIPC` has used since P3.5, because cmsg(3)
// is entirely macros and Swift cannot see macros (HANDOFF §2.32). D-Bus wraps
// them in its own `h` type and a UNIX_FDS header field, but the descriptor that
// crosses is the same descriptor.

import CPlatform

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// SOCK_STREAM imports as `__socket_type` on Linux and a plain Int32 on the BSDs
// (HANDOFF §2.32) — the spike hit this on its first FreeBSD run.
#if canImport(Glibc) && os(Linux)
private let sockStream = Int32(SOCK_STREAM.rawValue)
#else
private let sockStream = Int32(SOCK_STREAM)
#endif

/// A connection to a message bus.
public final class DBusConnection {
    public private(set) var fd: Int32 = -1
    /// The unique name the bus assigned us (`:1.4`), after `Hello`.
    public private(set) var uniqueName: String = ""
    private var nextSerial: UInt32 = 1
    private var inbox: [UInt8] = []
    private var pendingFDs: [Int32] = []

    /// Method calls we are waiting for replies to.
    private var pendingReplies: [UInt32: (DBusMessage) -> Void] = [:]
    /// Incoming method calls, by "interface.member".
    private var handlers: [String: (DBusMessage) -> DBusMessage?] = [:]
    /// Called for any message we did not otherwise consume.
    public var onMessage: ((DBusMessage) -> Void)?

    public init() {}

    deinit { if fd >= 0 { close(fd) } }

    // MARK: - Connecting

    /// Parse a bus address of the form `unix:path=…` or `unix:abstract=…`,
    /// possibly with more key=value pairs after a comma.
    public static func parseAddress(_ address: String) -> (path: String, abstract: Bool)? {
        func after(_ hay: String, _ needle: String) -> String? {
            let h = Array(hay.utf8), n = Array(needle.utf8)
            guard n.count <= h.count, !n.isEmpty else { return nil }
            for i in 0...(h.count - n.count) where Array(h[i..<(i + n.count)]) == n {
                return String(decoding: h[(i + n.count)...], as: UTF8.self)
            }
            return nil
        }
        // Abstract first: an address can contain both words only if a path
        // happens to spell one, and abstract is the more specific match.
        if var p = after(address, "unix:abstract=") {
            if let c = p.firstIndex(of: ",") { p = String(p[..<c]) }
            return (p, true)
        }
        if var p = after(address, "unix:path=") {
            if let c = p.firstIndex(of: ",") { p = String(p[..<c]) }
            return (p, false)
        }
        return nil
    }

    /// Connect, authenticate, and say `Hello`.
    public func connect(address: String? = nil) throws {
        let addr: String
        if let address { addr = address }
        else if let env = getenv("DBUS_SESSION_BUS_ADDRESS") { addr = String(cString: env) }
        else { throw DBusError("no DBUS_SESSION_BUS_ADDRESS and no address given") }

        guard let (path, abstract) = DBusConnection.parseAddress(addr) else {
            throw DBusError("unsupported bus address: \(addr)")
        }

        let s = socket(AF_UNIX, sockStream, 0)
        guard s >= 0 else { throw DBusError("socket: \(errnoText())") }
        var sa = sockaddr_un()
        sa.sun_family = sa_family_t(AF_UNIX)
        let pb = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: sa.sun_path)
        guard pb.count + (abstract ? 1 : 1) <= capacity else {
            close(s)
            throw DBusError("bus socket path too long (\(pb.count) >= \(capacity))")
        }
        withUnsafeMutableBytes(of: &sa.sun_path) { raw in
            // An abstract socket's name begins with a NUL byte and is NOT
            // NUL-terminated; a filesystem one is an ordinary path.
            var off = 0
            if abstract { raw[0] = 0; off = 1 }
            for (i, b) in pb.enumerated() { raw[off + i] = b }
        }
        let len = socklen_t(MemoryLayout<sa_family_t>.size + (abstract ? 1 : 0)
                            + pb.count + (abstract ? 0 : 1))
        let rc = withUnsafePointer(to: &sa) {
            // Qualified: our own method is also called `connect`, and Swift
            // resolves to it here rather than to libc's.
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemConnect(s, $0, len)
            }
        }
        guard rc == 0 else {
            close(s)
            throw DBusError("connect \(path): \(errnoText())")
        }
        fd = s
        try authenticate()
        try hello()
    }

    /// SASL EXTERNAL: a leading NUL byte, then a small line protocol. The NUL is
    /// not part of SASL — it is there so the kernel delivers credentials with
    /// the first byte, which is how the bus learns our uid.
    private func authenticate() throws {
        writeAll([0])
        let hex = Array(String(getuid()).utf8).map(hexByte).joined()
        writeAll(Array("AUTH EXTERNAL \(hex)\r\n".utf8))
        let reply = try readLine()
        guard reply.hasPrefix("OK") else {
            throw DBusError("authentication refused: \(reply)")
        }
        // Ask for descriptor passing before BEGIN. A bus that says anything but
        // AGREE_UNIX_FD cannot carry the file chooser's answer, so this is not
        // optional for us — but the error should say that plainly.
        writeAll(Array("NEGOTIATE_UNIX_FD\r\n".utf8))
        let fdReply = try readLine()
        guard fdReply.hasPrefix("AGREE_UNIX_FD") else {
            throw DBusError("the bus will not pass descriptors (\(fdReply));"
                            + " a portal cannot work without them")
        }
        writeAll(Array("BEGIN\r\n".utf8))
    }

    private func hello() throws {
        let reply = try call(.methodCall(destination: "org.freedesktop.DBus",
                                         path: "/org/freedesktop/DBus",
                                         interface: "org.freedesktop.DBus",
                                         member: "Hello"))
        guard case .string(let name)? = reply.body.first else {
            throw DBusError("Hello returned no name")
        }
        uniqueName = name
    }

    /// Ask the bus for a well-known name. Returns the reply code (1 = primary
    /// owner, which is the only one a portal should accept).
    @discardableResult
    public func requestName(_ name: String, flags: UInt32 = 0) throws -> UInt32 {
        let reply = try call(.methodCall(destination: "org.freedesktop.DBus",
                                         path: "/org/freedesktop/DBus",
                                         interface: "org.freedesktop.DBus",
                                         member: "RequestName",
                                         body: [.string(name), .uint32(flags)]))
        guard case .uint32(let code)? = reply.body.first else {
            throw DBusError("RequestName returned nothing")
        }
        return code
    }

    /// Subscribe to signals matching a rule.
    ///
    /// A bus delivers a broadcast signal only to connections that asked for it,
    /// so **this must happen before the call that provokes the signal**. The
    /// portal API is built around that ordering: a client derives the Request's
    /// object path from its own name and its own token precisely so it can match
    /// on the path first and call second (PHASE8.md §6.1).
    public func addMatch(_ rule: String) throws {
        _ = try call(.methodCall(destination: "org.freedesktop.DBus",
                                 path: "/org/freedesktop/DBus",
                                 interface: "org.freedesktop.DBus",
                                 member: "AddMatch",
                                 body: [.string(rule)]))
    }

    /// Stop receiving what `addMatch` asked for — the same rule, word for word.
    public func removeMatch(_ rule: String) throws {
        _ = try call(.methodCall(destination: "org.freedesktop.DBus",
                                 path: "/org/freedesktop/DBus",
                                 interface: "org.freedesktop.DBus",
                                 member: "RemoveMatch",
                                 body: [.string(rule)]))
    }

    // MARK: - Sending

    public func send(_ message: DBusMessage) throws {
        var m = message
        if m.serial == 0 { m.serial = nextSerial; nextSerial &+= 1 }
        let (bytes, fds) = m.encode()
        if fds.isEmpty {
            writeAll(bytes)
        } else {
            let rc = bytes.withUnsafeBufferPointer { b in
                fds.withUnsafeBufferPointer { f in
                    ap_sendmsg_fds(fd, b.baseAddress, bytes.count, f.baseAddress, Int32(f.count))
                }
            }
            guard rc == 0 else { throw DBusError("sendmsg with fds: \(errnoText())") }
        }
    }

    /// Send a method call and block until its reply arrives.
    ///
    /// Blocking is fine here: this is a legacy adapter, and nothing on the frame
    /// path talks to it (PHASE8 §6.3).
    public func call(_ message: DBusMessage, timeoutMs: Int32 = 25_000) throws -> DBusMessage {
        var m = message
        m.serial = nextSerial; nextSerial &+= 1
        var reply: DBusMessage?
        pendingReplies[m.serial] = { reply = $0 }
        try send(m)
        let deadline = nowMs() + Int64(timeoutMs)
        while reply == nil {
            guard nowMs() < deadline else {
                pendingReplies[m.serial] = nil
                throw DBusError("timed out waiting for a reply to \(m.member ?? "?")")
            }
            try readAndDispatch(timeoutMs: 100)
        }
        if reply!.type == .error {
            let text: String
            if case .string(let s)? = reply!.body.first { text = s } else { text = "" }
            throw DBusError("\(reply!.errorName ?? "error"): \(text)")
        }
        return reply!
    }

    // MARK: - Serving

    /// Handle `interface.member`; the closure's return value is sent as the
    /// reply (return nil for a call that is answered later, or not at all).
    public func handle(_ interface: String, _ member: String,
                       _ body: @escaping (DBusMessage) -> DBusMessage?) {
        handlers["\(interface).\(member)"] = body
    }

    /// Read whatever is available and dispatch it. `timeoutMs` < 0 blocks.
    public func readAndDispatch(timeoutMs: Int32) throws {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pr = withUnsafeMutablePointer(to: &p) { poll($0, 1, timeoutMs) }
        if pr <= 0 { return }

        var buf = [UInt8](repeating: 0, count: 8192)
        var gotFDs = [Int32](repeating: -1, count: 16)
        var fdCount: Int32 = 0
        let n = buf.withUnsafeMutableBufferPointer { b in
            gotFDs.withUnsafeMutableBufferPointer { f in
                ap_recvmsg_fds(fd, b.baseAddress, 8192, f.baseAddress, 16, &fdCount)
            }
        }
        guard n > 0 else {
            if n == 0 { throw DBusError("the bus closed the connection") }
            return
        }
        inbox += buf[0..<n]
        if fdCount > 0 { pendingFDs += gotFDs[0..<Int(fdCount)] }

        while let total = DBusMessage.framedLength(inbox), inbox.count >= total {
            let frame = Array(inbox[0..<total])
            inbox.removeFirst(total)
            let msg = try DBusMessage.decode(frame, fds: pendingFDs)
            pendingFDs = []
            dispatch(msg)
        }
    }

    private func dispatch(_ msg: DBusMessage) {
        if let serial = msg.replySerial, let waiter = pendingReplies[serial] {
            pendingReplies[serial] = nil
            waiter(msg)
            return
        }
        if msg.type == .methodCall, let i = msg.interface, let m = msg.member,
           let handler = handlers["\(i).\(m)"] {
            if var reply = handler(msg) {
                reply.serial = nextSerial; nextSerial &+= 1
                try? send(reply)
            }
            return
        }
        if msg.type == .methodCall {
            // An unknown method must be answered, or the caller waits for ever.
            var err = DBusMessage.error(to: msg,
                                        name: "org.freedesktop.DBus.Error.UnknownMethod",
                                        message: "no such method: "
                                            + "\(msg.interface ?? "?").\(msg.member ?? "?")")
            err.serial = nextSerial; nextSerial &+= 1
            try? send(err)
            return
        }
        onMessage?(msg)
    }

    // MARK: - Plumbing

    private func writeAll(_ bytes: [UInt8]) {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBufferPointer {
                write(fd, $0.baseAddress! + off, bytes.count - off)
            }
            if n <= 0 { return }
            off += n
        }
    }

    private func readLine() throws -> String {
        var out: [UInt8] = []
        var c: UInt8 = 0
        while read(fd, &c, 1) == 1 {
            out.append(c)
            if out.count >= 2, out[out.count - 2] == 13, c == 10 { break }
        }
        while let l = out.last, l == 10 || l == 13 { out.removeLast() }
        return String(decoding: out, as: UTF8.self)
    }

    private func nowMs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }
}

/// libc's `connect(2)`, named apart from `DBusConnection.connect`.
@inline(__always)
private func systemConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>,
                           _ len: socklen_t) -> Int32 {
#if canImport(Glibc)
    return Glibc.connect(fd, addr, len)
#else
    return Darwin.connect(fd, addr, len)
#endif
}

private func hexByte(_ b: UInt8) -> String {
    let d = Array("0123456789abcdef".utf8)
    return String(decoding: [d[Int(b >> 4)], d[Int(b & 0xf)]], as: UTF8.self)
}

private func errnoText() -> String { String(cString: strerror(errno)) }
