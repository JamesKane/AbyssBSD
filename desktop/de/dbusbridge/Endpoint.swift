// BridgeEndpoint — the bridge's sockets (BACKLOG D.1).
//
// Two listening sockets: the address applications are given
// (`DBUS_SESSION_BUS_ADDRESS`, or a jail's), and a private one in the
// session's runtime directory for ADE's own services. Both are 0600, and both
// admit only a peer whose uid is this process's — the kernel says so
// (`getpeereid`), and SASL `EXTERNAL` must say the same. Then each connection
// is framed into messages and handed to `BridgeRouter`, which decides.
//
// Non-blocking throughout, with a queue per connection: an application that
// stops reading fills its own queue, and is dropped when that passes a limit,
// rather than stalling the bridge for everyone else.

import CPlatform
import CurrentIPC
import DBus

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class BridgeEndpoint {
    final class Conn {
        let fd: Int32
        let kind: PeerKind
        var authed = false
        var buf: [UInt8] = []
        var pendingFDs: [Int32] = []
        var out: [(bytes: [UInt8], fds: [Int32], at: Int)] = []
        var queued = 0
        var sawNul = false
        init(fd: Int32, kind: PeerKind) { self.fd = fd; self.kind = kind }
    }

    public private(set) var router: BridgeRouter
    private var listeners: [(server: Current.Server, kind: PeerKind)] = []
    private var conns: [Int: Conn] = [:]
    private var nextID = 1
    private let say: (String) -> Void
    /// A connection whose unsent bytes pass this is dropped (it stopped reading).
    public var queueLimit = 16 << 20
    public static let maxMessage = 64 << 20

    public init(log: @escaping (String) -> Void) {
        var g = ""
        var r = [UInt8](repeating: 0, count: 16)
        let fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC)
        if fd >= 0 { _ = read(fd, &r, 16); close(fd) }
        for b in r { g += String(b, radix: 16).count == 1 ? "0" + String(b, radix: 16) : String(b, radix: 16) }
        router = BridgeRouter(guid: g)
        say = log
    }

    /// Listen at `path` for peers of `kind`.
    public func listen(_ path: String, kind: PeerKind) throws {
        let s = try Current.Server(path: path, mode: 0o600)
        try s.setNonBlocking(true)
        listeners.append((s, kind))
    }

    public func shutdown() {
        for l in listeners { l.server.shutdownAndUnlink() }
        for c in conns.values { close(c.fd) }
        conns = [:]
    }

    public var connectionCount: Int { conns.count }

    // MARK: - the loop

    /// Serve for ever (or until `stop` says).
    public func run(while keepGoing: () -> Bool = { true }) {
        while keepGoing() { step(timeoutMs: 1000) }
    }

    public func step(timeoutMs: Int32) {
        var fds: [pollfd] = listeners.map { pollfd(fd: $0.server.fd, events: Int16(POLLIN), revents: 0) }
        let ids = conns.keys.sorted()
        for id in ids {
            let c = conns[id]!
            fds.append(pollfd(fd: c.fd, events: Int16(POLLIN | (c.out.isEmpty ? 0 : POLLOUT)), revents: 0))
        }
        let n = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), timeoutMs) }
        if n <= 0 { return }
        for (i, l) in listeners.enumerated() where fds[i].revents != 0 { accept(l.server, l.kind) }
        for (j, id) in ids.enumerated() {
            let ev = fds[listeners.count + j].revents
            guard ev != 0, let c = conns[id] else { continue }
            if ev & Int16(POLLOUT) != 0 { flush(id, c) }
            if ev & Int16(POLLIN | POLLHUP | POLLERR) != 0 { readable(id, c) }
        }
    }

    private func accept(_ s: Current.Server, _ kind: PeerKind) {
        while let fd = try? s.accept() {
            var uid: UInt32 = 0
            guard ap_peer_uid(fd, &uid) == 0, uid == UInt32(getuid()) else {
                say("bridge: refused a \(kind) whose uid is not ours")
                close(fd); continue
            }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let id = nextID; nextID += 1
            conns[id] = Conn(fd: fd, kind: kind)
            router.attach(id, kind: kind, uid: uid, pid: 0)
        }
    }

    private func drop(_ id: Int, _ why: String) {
        guard let c = conns.removeValue(forKey: id) else { return }
        for f in c.pendingFDs { close(f) }
        for o in c.out { for f in o.fds { close(f) } }
        close(c.fd)
        if !why.isEmpty { say("bridge: dropped \(router.peers[id]?.unique ?? "a connection") (\(c.kind)): \(why)") }
        apply(router.detach(id))
    }

    // MARK: - reading

    private func readable(_ id: Int, _ c: Conn) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        var got = [Int32](repeating: -1, count: 16)
        var nfds: Int32 = 0
        let n = chunk.withUnsafeMutableBufferPointer { b in
            got.withUnsafeMutableBufferPointer { f in ap_recvmsg_fds(c.fd, b.baseAddress, b.count, f.baseAddress, 16, &nfds) }
        }
        if n == 0 { drop(id, ""); return }
        if n < 0 { if errno != EAGAIN && errno != EINTR { drop(id, "read: \(String(cString: strerror(errno)))") }; return }
        c.buf += chunk[0..<n]
        if nfds > 0 { c.pendingFDs += got[0..<Int(nfds)] }
        if !c.authed { authenticate(id, c) }
        if c.authed { frames(id, c) }
    }

    /// SASL, as D-Bus uses it: a NUL, then lines. EXTERNAL only, and the uid it
    /// names must be ours (the kernel already said whose the socket is).
    private func authenticate(_ id: Int, _ c: Conn) {
        if !c.sawNul {
            guard let first = c.buf.first else { return }
            guard first == 0 else { drop(id, "no credentials byte"); return }
            c.buf.removeFirst(); c.sawNul = true
        }
        while !c.authed, let nl = c.buf.firstIndex(of: 0x0a) {
            var line = String(decoding: c.buf[..<nl], as: UTF8.self)
            c.buf.removeFirst(nl + 1)
            if line.hasSuffix("\r") { line.removeLast() }
            let words = line.split(separator: " ").map(String.init)
            switch words.first ?? "" {
            case "AUTH":
                if words.count >= 2, words[1] == "EXTERNAL" {
                    if words.count == 2 { send(id, c, "DATA\r\n") } else { external(id, c, words[2]) }
                } else { send(id, c, "REJECTED EXTERNAL\r\n") }
            case "DATA": external(id, c, words.count > 1 ? words[1] : "")
            case "NEGOTIATE_UNIX_FD": send(id, c, "AGREE_UNIX_FD\r\n")
            case "BEGIN": c.authed = true
            case "CANCEL", "ERROR": send(id, c, "REJECTED EXTERNAL\r\n")
            default: send(id, c, "ERROR \"unknown command\"\r\n")
            }
            if c.buf.count > 16384 && !c.authed { drop(id, "too much before BEGIN"); return }
        }
    }

    private func external(_ id: Int, _ c: Conn, _ hex: String) {
        // Empty data means "the uid the socket already proved".
        var claimed = ""
        var h = Array(hex.utf8)
        while h.count >= 2 {
            guard let b = UInt8(String(decoding: h[0..<2], as: UTF8.self), radix: 16) else { break }
            claimed.append(Character(UnicodeScalar(b))); h.removeFirst(2)
        }
        if hex.isEmpty || claimed == String(getuid()) {
            send(id, c, "OK \(router.guid)\r\n")
        } else {
            send(id, c, "REJECTED EXTERNAL\r\n")
        }
    }

    private func frames(_ id: Int, _ c: Conn) {
        while let total = DBusMessage.framedLength(c.buf) {
            guard total <= Self.maxMessage else { drop(id, "a message of \(total) bytes"); return }
            guard c.buf.count >= total else { return }
            let frame = Array(c.buf[0..<total])
            c.buf.removeFirst(total)
            var msg: DBusMessage
            do { msg = try DBusMessage.decode(frame, fds: c.pendingFDs) } catch {
                drop(id, "a message that does not parse (\(error))"); return
            }
            // Exactly the descriptors this message declared are its own; the
            // body holds them as values, so the message forwards with those
            // and no copy beside them.
            guard msg.declaredFDs <= c.pendingFDs.count else { drop(id, "a message declaring descriptors that did not arrive"); return }
            let mine = Array(c.pendingFDs.prefix(msg.declaredFDs))
            c.pendingFDs.removeFirst(msg.declaredFDs)
            msg.fds = []
            apply(router.route(from: id, msg))
            for f in mine { close(f) }
            guard conns[id] != nil else { return }
        }
    }

    // MARK: - writing

    private func apply(_ actions: [BridgeRouter.Action]) {
        for a in actions {
            switch a {
            case .deliver(let to, let m):
                guard let c = conns[to] else { continue }
                let (bytes, fds) = m.encode()
                // Our copies of the descriptors are the router's message's; each
                // delivery sends its own duplicates.
                enqueue(to, c, bytes, fds.map { dup($0) })
            case .close(let id, let why):
                drop(id, why)
            }
        }
    }

    private func send(_ id: Int, _ c: Conn, _ text: String) { enqueue(id, c, Array(text.utf8), []) }

    private func enqueue(_ id: Int, _ c: Conn, _ bytes: [UInt8], _ fds: [Int32]) {
        c.out.append((bytes, fds, 0))
        c.queued += bytes.count
        if c.queued > queueLimit { drop(id, "stopped reading (\(c.queued) bytes queued)"); return }
        flush(id, c)
    }

    private func flush(_ id: Int, _ c: Conn) {
        while var head = c.out.first {
            let rest = head.bytes.count - head.at
            let n: Int
            if head.at == 0 && !head.fds.isEmpty {
                let rc = head.bytes.withUnsafeBufferPointer { b in
                    head.fds.withUnsafeBufferPointer { f in ap_sendmsg_fds(c.fd, b.baseAddress, b.count, f.baseAddress, Int32(f.count)) }
                }
                n = rc == 0 ? head.bytes.count : -1
                if rc == 0 { for f in head.fds { close(f) }; head.fds = [] }
            } else {
                n = head.bytes.withUnsafeBufferPointer { write(c.fd, $0.baseAddress! + head.at, rest) }
            }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { return }
                drop(id, "write: \(String(cString: strerror(errno)))"); return
            }
            head.at += n
            c.queued -= n
            if head.at >= head.bytes.count {
                c.out.removeFirst()
            } else {
                c.out[0] = head
                return
            }
        }
    }
}
