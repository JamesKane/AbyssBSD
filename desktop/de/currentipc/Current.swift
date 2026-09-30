// CurrentIPC — the transport: where sockets live, how a frame is framed, and
// the service/client pair.
//
// Brokerless by design (docs/PLAN.md goal #3): there is no bus daemon. A client
// connects straight to `<runtime_dir>/<service>.sock`, and the control plane
// *is* the bus. A Swift rewrite of the sibling's `current` — same layout on
// disk, same call shape, none of its code.
//
// Framing: one message goes out in a single `sendmsg`, as a 4-byte big-endian
// length followed by the packed body, with any descriptors attached to that same
// call. The receiver reads the 4-byte length with `recvmsg` — which is where the
// SCM_RIGHTS ancillary data arrives, since the kernel delivers it with the first
// byte of the transfer it accompanied — then reads the body with plain reads.
// Doing it the other way round (body first, length later) would lose the
// association between a message and its descriptors.

import CPlatform

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The control plane's namespace: where things live, and how to talk to them.
public enum Current {
    /// The per-user runtime directory holding service sockets, created 0700.
    ///
    /// `$ABYSS_RUNTIME_DIR`, else `$XDG_RUNTIME_DIR/abyss`, else
    /// `/var/run/user/<uid>/abyss` — the same precedence as the sibling, so a
    /// session that sets `ABYSS_RUNTIME_DIR` (as the supervisor will) puts every
    /// component's sockets in one namespace.
    public static func runtimeDir() throws -> String {
        let dir: String
        if let d = getenv("ABYSS_RUNTIME_DIR"), d.pointee != 0 {
            dir = String(cString: d)
        } else if let x = getenv("XDG_RUNTIME_DIR"), x.pointee != 0 {
            dir = String(cString: x) + "/abyss"
        } else {
            dir = "/var/run/user/\(geteuid())/abyss"
        }
        // mkdir failing because it already exists is success for our purposes.
        if mkdir(dir, 0o700) != 0 && errno != EEXIST {
            throw CurrentError.system(errno, "mkdir \(dir)")
        }
        if chmod(dir, 0o700) != 0 {
            throw CurrentError.system(errno, "chmod 0700 \(dir)")
        }
        return dir
    }

    /// The socket path for a named service.
    public static func socketPath(_ service: String) throws -> String {
        try runtimeDir() + "/" + service + ".sock"
    }

    // MARK: - Client

    /// Connect to a service, returning the connected socket. The caller owns it
    /// and must `close` it.
    public static func connect(_ service: String) throws -> Int32 {
        let path = try socketPath(service)
        let sock = socket(AF_UNIX, sockStream, 0)
        guard sock >= 0 else { throw CurrentError.system(errno, "socket") }
        var addr = sockaddr_un()
        addr.sun_family = sunFamily
        try setSunPath(&addr, path)
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(sock)
            throw CurrentError.system(e, "connect \(path)")
        }
        _ = ap_socket_nosigpipe(sock)   // belt and braces beside MSG_NOSIGNAL
        return sock
    }

    /// One-shot request → reply against a service. Opens a connection, sends,
    /// reads one reply, closes.
    public static func call(_ service: String, _ request: Msg) throws -> Msg {
        let sock = try connect(service)
        defer { close(sock) }
        try send(request, on: sock)
        return try receive(on: sock)
    }

    // MARK: - Framing

    /// Send one message (and its descriptors) on a connected socket.
    public static func send(_ msg: Msg, on sock: Int32) throws {
        let body = msg.pack()
        guard body.count + 4 <= Msg.maxFrame else { throw CurrentError.tooLarge(body.count) }
        let fds = msg.attachedFDs
        guard fds.count <= Msg.maxFDs else {
            throw CurrentError.malformed("\(fds.count) descriptors exceeds the \(Msg.maxFDs) cap")
        }

        // The length prefix goes in its own sendmsg, carrying the descriptors,
        // so the receiver's single recvmsg is guaranteed to collect them.
        let header = beBytes(UInt32(body.count))
        let sent = header.withUnsafeBufferPointer { hp -> Int in
            fds.withUnsafeBufferPointer { fp in
                Int(ap_sendmsg_fds(sock, hp.baseAddress, 4,
                                   fds.isEmpty ? nil : fp.baseAddress, Int32(fds.count)))
            }
        }
        guard sent == 4 else {
            throw sent < 0 ? CurrentError.system(errno, "sendmsg") : CurrentError.closed
        }
        try writeAll(sock, body)
    }

    /// Receive one message from a connected socket. Any descriptors that arrive
    /// are owned by the returned message (see `Msg.takeFD`).
    public static func receive(on sock: Int32) throws -> Msg {
        var header = [UInt8](repeating: 0, count: 4)
        var fds = [Int32](repeating: -1, count: Msg.maxFDs)
        var nfds: Int32 = 0
        let n = header.withUnsafeMutableBufferPointer { hp -> Int in
            fds.withUnsafeMutableBufferPointer { fp in
                Int(ap_recvmsg_fds(sock, hp.baseAddress, 4,
                                   fp.baseAddress, Int32(Msg.maxFDs), &nfds))
            }
        }
        if n < 0 { throw CurrentError.system(errno, "recvmsg") }
        if n == 0 { throw CurrentError.closed }
        let received = Array(fds[0..<Int(nfds)])
        // From here on we own `received`: close them on any failure, or they
        // leak on every malformed message a peer sends.
        func abandon() { for f in received { close(f) } }

        guard n == 4 else {
            abandon()
            throw CurrentError.malformed("short length prefix (\(n) bytes)")
        }
        let length = Int(beUInt32(header))
        guard length >= 0, length + 4 <= Msg.maxFrame else {
            abandon()
            throw CurrentError.tooLarge(length)
        }
        do {
            let body = try readAll(sock, length)
            return try Msg.unpack(body, fds: received)
        } catch {
            abandon()
            throw error
        }
    }

    // MARK: - Server

    /// A service listening on `<runtime_dir>/<service>.sock`.
    ///
    /// The listening `fd` is exposed on purpose: it goes straight into
    /// `Display.addFileDescriptor` (HANDOFF §2.18), the same run-loop hook the
    /// config watcher and the menu-bar clock use — so a shell component hosts a
    /// service without a thread or a second loop.
    public final class Server {
        public let fd: Int32
        public let path: String
        private var closed = false

        /// Bind the service socket, replacing a stale one left by a crash.
        public init(service: String, backlog: Int32 = 16) throws {
            let p = try Current.socketPath(service)
            self.path = p
            let s = socket(AF_UNIX, sockStream, 0)
            guard s >= 0 else { throw CurrentError.system(errno, "socket") }
            unlink(p)      // a leftover socket file would make bind fail with EADDRINUSE
            var addr = sockaddr_un()
            addr.sun_family = sunFamily
            do {
                try setSunPath(&addr, p)
            } catch {
                close(s)
                throw error
            }
            let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0 else {
                let e = errno
                close(s)
                throw CurrentError.system(e, "bind \(p)")
            }
            // Only this user may talk to the service.
            _ = chmod(p, 0o600)
            guard listen(s, backlog) == 0 else {
                let e = errno
                close(s)
                unlink(p)
                throw CurrentError.system(e, "listen \(p)")
            }
            self.fd = s
        }

        /// Accept one client. The returned socket is the caller's to close.
        /// How long to wait for a request on an accepted connection before
        /// giving up on it. A client that connects and then says nothing must
        /// not be able to stall a service that is also supervising a session.
        public var requestTimeout: Double = 2.0

        public func accept() throws -> Int32 {
            let c = Glibc.accept(fd, nil, nil)
            guard c >= 0 else { throw CurrentError.system(errno, "accept") }
            _ = ap_socket_nosigpipe(c)

            // **A connection accepted from a non-blocking listener inherits
            // O_NONBLOCK on the BSDs, but not on Linux.** Leaving it inherited
            // means `recvmsg` returns EAGAIN whenever the request hasn't landed
            // in the microsecond since accept — the service then drops a
            // perfectly good client, which on FreeBSD failed about half of all
            // `abyssctl quit` calls (HANDOFF §2.33). Force blocking explicitly.
            let flags = fcntl(c, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(c, F_SETFL, flags & ~O_NONBLOCK) }

            // Bound the wait instead of trusting the peer.
            if requestTimeout > 0 {
                var tv = timeval(tv_sec: Int(requestTimeout),
                                 tv_usec: Int((requestTimeout - Double(Int(requestTimeout))) * 1_000_000))
                _ = setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            }
            return c
        }

        /// Non-blocking mode, so a component can poll `accept` from its own
        /// event loop and get `EAGAIN` when idle instead of blocking.
        public func setNonBlocking(_ nb: Bool) throws {
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0 else { throw CurrentError.system(errno, "fcntl F_GETFL") }
            let want = nb ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK)
            guard fcntl(fd, F_SETFL, want) >= 0 else {
                throw CurrentError.system(errno, "fcntl F_SETFL")
            }
        }

        /// Accept one connection, read one request, reply with `handler`'s result.
        ///
        /// A malformed request or a peer that hangs up mid-message costs that one
        /// connection and nothing else — "a helper can't take down the session"
        /// is the whole point of a brokerless plane.
        @discardableResult
        public func serveOne(_ handler: (Msg) -> Msg) throws -> Bool {
            let c = try accept()
            defer { close(c) }
            guard var request = try? Current.receive(on: c) else { return false }
            let reply = handler(request)
            request.closeFDs()      // whatever the handler didn't take
            try? Current.send(reply, on: c)
            return true
        }

        /// Serve request→reply until `stop` returns true (checked between
        /// connections).
        public func serve(while stop: () -> Bool = { false }, _ handler: (Msg) -> Msg) throws {
            while !stop() {
                _ = try serveOne(handler)
            }
        }

        public func shutdownAndUnlink() {
            guard !closed else { return }
            closed = true
            close(fd)
            unlink(path)
        }

        deinit { shutdownAndUnlink() }
    }
}

// MARK: - Small helpers

// SOCK_STREAM and AF_UNIX arrive with different Swift types per platform: on
// Linux SOCK_STREAM is imported as `__socket_type`, on the BSDs as a plain
// Int32, and sun_family is UInt16 vs UInt8. Normalise once here so the code
// above reads the same on both.
#if canImport(Glibc) && os(Linux)
private let sockStream = Int32(SOCK_STREAM.rawValue)
private let sunFamily = sa_family_t(AF_UNIX)
#else
private let sockStream = Int32(SOCK_STREAM)
private let sunFamily = sa_family_t(AF_UNIX)
#endif

/// Copy `path` into a `sockaddr_un`, refusing one that wouldn't fit rather than
/// silently truncating to a different socket.
private func setSunPath(_ addr: inout sockaddr_un, _ path: String) throws {
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else {
        throw CurrentError.malformed("socket path too long (\(bytes.count) >= \(capacity)): \(path)")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
}

private func beBytes(_ v: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
     UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
}

private func beUInt32(_ b: [UInt8]) -> UInt32 {
    b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
}

/// Write every byte, resuming on a short write or EINTR.
///
/// Goes through `ap_send_all` rather than `write(2)` so a peer that has hung up
/// yields EPIPE instead of **SIGPIPE killing the process** — MSG_NOSIGNAL is a
/// macro Swift cannot see, so it has to happen in C. Losing a peer mid-message
/// is an ordinary error a caller should report.
private func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
    let rc = bytes.withUnsafeBufferPointer {
        ap_send_all(fd, $0.baseAddress, bytes.count)
    }
    if rc != 0 {
        throw errno == EPIPE ? CurrentError.closed : CurrentError.system(errno, "send")
    }
}

/// Read exactly `count` bytes, or throw. A short read is normal on a stream
/// socket; a zero read means the peer hung up mid-message.
private func readAll(_ fd: Int32, _ count: Int) throws -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: count)
    var off = 0
    while off < count {
        let n = buf.withUnsafeMutableBufferPointer {
            read(fd, $0.baseAddress! + off, count - off)
        }
        if n < 0 {
            if errno == EINTR { continue }
            throw CurrentError.system(errno, "read")
        }
        if n == 0 { throw CurrentError.closed }
        off += n
    }
    return buf
}
