// HTTP — just enough HTTP/1.1 for the model wire (PHASE18 P18.7).
//
// `abyss-model` speaks OpenAI-compatible chat completions **over a unix
// socket**, so any OpenAI client — and `curl --unix-socket` — can use it, and
// calls llama.cpp's `llama-server` over loopback TCP. One request per
// connection, `Content-Length` bodies, no chunking, no keep-alive: the agent is
// one client asking one thing at a time, and a parser this small is one that
// can be read.

import CPlatform
import CTLS

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [(String, String)]
    public var body: [UInt8]

    public static func == (a: HTTPRequest, b: HTTPRequest) -> Bool {
        a.method == b.method && a.path == b.path && a.body == b.body
            && a.headers.map { $0.0 + ":" + $0.1 } == b.headers.map { $0.0 + ":" + $0.1 }
    }

    public func header(_ name: String) -> String? {
        headers.last { $0.0.lowercased() == name.lowercased() }?.1
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var reason: String
    public var headers: [(String, String)]
    public var body: [UInt8]

    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.body == b.body
    }

    public init(status: Int, reason: String, json: JSON) {
        self.status = status
        self.reason = reason
        self.body = Array(json.text.utf8)
        self.headers = [("Content-Type", "application/json")]
    }
    public init(status: Int, reason: String, headers: [(String, String)], body: [UInt8]) {
        self.status = status; self.reason = reason; self.headers = headers; self.body = body
    }

    public var bytes: [UInt8] {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in headers where k.lowercased() != "content-length" && k.lowercased() != "connection" {
            head += "\(k): \(v)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Array(head.utf8) + body
    }
}

public enum HTTP {
    public static let maxHead = 64 << 10
    public static let maxBody = 32 << 20

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// Where the head ends (the index just past "\r\n\r\n"), if it has.
    static func headEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4) where b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 { return i + 4 }
        return nil
    }

    /// Parse a head's lines: the start line, and the headers.
    static func lines(_ head: [UInt8]) -> (String, [(String, String)]) {
        let text = String(decoding: head, as: UTF8.self)
        var rows = text.split(separator: "\r\n", omittingEmptySubsequences: true).map(String.init)
        let start = rows.isEmpty ? "" : rows.removeFirst()
        let headers = rows.compactMap { r -> (String, String)? in
            guard let c = r.firstIndex(of: ":") else { return nil }
            var v = r[r.index(after: c)...]
            while v.first == " " { v.removeFirst() }
            return (String(r[..<c]), String(v))
        }
        return (start, headers)
    }

    /// A complete request from `bytes`, or nil if more are needed.
    public static func request(_ bytes: [UInt8]) throws -> HTTPRequest? {
        guard let end = headEnd(bytes) else {
            if bytes.count > maxHead { throw Failure("a request head over \(maxHead) bytes") }
            return nil
        }
        let (start, headers) = lines(Array(bytes[0..<end]))
        let parts = start.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw Failure("not an HTTP/1 request line: \(start)") }
        if headers.contains(where: { $0.0.lowercased() == "transfer-encoding" }) { throw Failure("chunked bodies are not accepted") }
        let length = headers.last { $0.0.lowercased() == "content-length" }.flatMap { Int($0.1) } ?? 0
        guard length >= 0, length <= maxBody else { throw Failure("a body of \(length) bytes") }
        guard bytes.count >= end + length else { return nil }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers,
                           body: Array(bytes[end..<(end + length)]))
    }

    /// A complete response from `bytes` (read to EOF: `Connection: close`).
    public static func response(_ bytes: [UInt8]) throws -> HTTPResponse {
        guard let end = headEnd(bytes) else { throw Failure("no response head") }
        let (start, headers) = lines(Array(bytes[0..<end]))
        let parts = start.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            throw Failure("not an HTTP/1 status line: \(start)")
        }
        var body = Array(bytes[end...])
        if let l = headers.last(where: { $0.0.lowercased() == "content-length" }).flatMap({ Int($0.1) }), l <= body.count {
            body = Array(body[0..<l])
        }
        return HTTPResponse(status: status, reason: parts.count > 2 ? String(parts[2]) : "", headers: headers, body: body)
    }

    // MARK: - sockets

    static func readAll(_ fd: Int32, until done: ([UInt8]) throws -> Bool) throws -> [UInt8] {
        var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536)
        while try !done(out) {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; throw Failure("read: \(String(cString: strerror(errno)))") }
            if n == 0 { break }
            out += buf[0..<n]
            if out.count > maxHead + maxBody { throw Failure("more than \(maxHead + maxBody) bytes") }
        }
        return out
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; throw Failure("write: \(String(cString: strerror(errno)))") }
            off += n
        }
    }

    /// Read one request from a connection.
    public static func readRequest(_ fd: Int32) throws -> HTTPRequest? {
        var got: HTTPRequest?
        _ = try readAll(fd) { b in got = try request(b); return got != nil }
        return got
    }

    public static func send(_ r: HTTPResponse, on fd: Int32) throws { try writeAll(fd, r.bytes) }

    /// Where a server is: loopback TCP, or a unix socket (how `abyss-model`
    /// runs `llama-server` itself, so a local model has no port at all).
    public enum Endpoint: Equatable, Sendable {
        case tcp(host: String, port: UInt16)
        case unix(path: String)
        /// TLS over TCP (P18.12a): the certificate must chain to a trusted CA
        /// (the system's, or `cafile`) and name `host`.
        case tls(host: String, port: UInt16, cafile: String?)
        var hostHeader: String {
            switch self {
            case let .tcp(h, p): return "\(h):\(p)"
            case let .tls(h, p, _): return p == 443 ? h : "\(h):\(p)"
            case .unix: return "localhost"
            }
        }
    }

    /// Reading and writing one connection, whether plain or TLS.
    final class Connection {
        let fd: Int32
        var tls: OpaquePointer?
        init(fd: Int32, tls: OpaquePointer?) { self.fd = fd; self.tls = tls }
        func readAll(_ limit: Int) throws -> [UInt8] {
            var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n: Int = buf.withUnsafeMutableBytes { b in
                    if let t = tls { return ap_tls_read(t, b.baseAddress, b.count) }
                    return read(fd, b.baseAddress, b.count)
                }
                if n < 0 {
                    if tls == nil, errno == EINTR { continue }
                    throw Failure(tls == nil ? "read: \(String(cString: strerror(errno)))" : "read: the TLS connection failed")
                }
                if n == 0 { break }
                out += buf[0..<n]
                if out.count > limit { throw Failure("more than \(limit) bytes") }
            }
            return out
        }
        func writeAll(_ bytes: [UInt8]) throws {
            if let t = tls {
                var off = 0
                while off < bytes.count {
                    let n = bytes[off...].withUnsafeBytes { ap_tls_write(t, $0.baseAddress, $0.count) }
                    if n <= 0 { throw Failure("write: the TLS connection failed") }
                    off += Int(n)
                }
            } else { try HTTP.writeAll(fd, bytes) }
        }
        deinit { if let t = tls { ap_tls_close(t) }; close(fd) }
    }

    /// `address`: connect to this numeric address rather than resolving the
    /// host again — the one a caller already checked (the fetch bridge, so a
    /// DNS answer that changes between the check and the connection cannot
    /// slip in a local address). The host still names the server for TLS and
    /// `Host:`.
    static func connect(_ to: Endpoint, timeoutSeconds: Int, address: String? = nil) throws -> Int32 {
        let fd: Int32
        switch to {
        case let .tcp(host, port), let .tls(host, port, _):
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            if address != nil { hints.ai_flags = AI_NUMERICHOST }
            #if os(Linux)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            #else
            hints.ai_socktype = SOCK_STREAM
            #endif
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(address ?? host, String(port), &hints, &res) == 0, let ai = res else {
                throw Failure(address == nil ? "cannot resolve \(host)" : "not an address: \(address!)")
            }
            defer { freeaddrinfo(res) }
            fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard fd >= 0 else { throw Failure("socket: \(String(cString: strerror(errno)))") }
            guard Glibc_connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else {
                let e = errno; close(fd)
                throw Failure("connect \(host):\(port): \(String(cString: strerror(e)))")
            }
        case let .unix(path):
            #if os(Linux)
            fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
            #else
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            #endif
            guard fd >= 0 else { throw Failure("socket: \(String(cString: strerror(errno)))") }
            var sa = sockaddr_un()
            sa.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: sa.sun_path) else { close(fd); throw Failure("socket path too long: \(path)") }
            withUnsafeMutableBytes(of: &sa.sun_path) { dst in for (i, b) in bytes.enumerated() { dst[i] = b } }
            let ok = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc_connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard ok == 0 else { let e = errno; close(fd); throw Failure("connect \(path): \(String(cString: strerror(e)))") }
        }
        _ = ap_socket_nosigpipe(fd)
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func open(_ to: Endpoint, timeoutSeconds: Int, address: String? = nil) throws -> Connection {
        let fd = try connect(to, timeoutSeconds: timeoutSeconds, address: address)
        guard case let .tls(host, _, cafile) = to else { return Connection(fd: fd, tls: nil) }
        var err = [CChar](repeating: 0, count: 512)
        guard let t = ap_tls_open(fd, host, cafile, &err, err.count) else {
            close(fd)
            throw Failure(String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return Connection(fd: fd, tls: t)
    }

    /// One request to `to`, read to EOF. `version` "1.0" asks a web server
    /// for a body it ends by closing, never chunked (P18.12's fetch).
    public static func call(_ to: Endpoint, method: String, path: String, json: JSON? = nil,
                            headers: [(String, String)] = [], version: String = "1.1",
                            timeoutSeconds: Int = 600, address: String? = nil) throws -> HTTPResponse {
        let c = try open(to, timeoutSeconds: timeoutSeconds, address: address)
        let body = json.map { Array($0.text.utf8) } ?? []
        var head = "\(method) \(path) HTTP/\(version)\r\nHost: \(to.hostHeader)\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try c.writeAll(Array(head.utf8) + body)
        return try response(try c.readAll(maxHead + maxBody))
    }

    /// POST a JSON body to http://HOST:PORT/PATH over TCP and read the reply.
    public static func post(host: String, port: UInt16, path: String, json: JSON,
                            timeoutSeconds: Int = 600) throws -> HTTPResponse {
        try call(.tcp(host: host, port: port), method: "POST", path: path, json: json, timeoutSeconds: timeoutSeconds)
    }
}

#if canImport(Glibc)
@inline(__always) func Glibc_connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>?, _ l: socklen_t) -> Int32 { Glibc.connect(fd, a, l) }
#else
@inline(__always) func Glibc_connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>?, _ l: socklen_t) -> Int32 { Darwin.connect(fd, a, l) }
#endif

/// An http or https URL, as a person writes one (P18.12).
public struct WebURL: Equatable, Sendable {
    public var https: Bool
    public var host: String
    public var port: UInt16
    public var path: String

    public init?(_ text: String) {
        let lower = text.lowercased()
        let rest: Substring
        if lower.hasPrefix("https://") { https = true; rest = text.dropFirst(8) }
        else if lower.hasPrefix("http://") { https = false; rest = text.dropFirst(7) }
        else { return nil }
        let hostport = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        var p = String(rest.dropFirst(hostport.count))
        if let hash = p.firstIndex(of: "#") { p = String(p[..<hash]) }
        path = p.isEmpty ? "/" : (p.hasPrefix("?") ? "/" + p : p)
        guard !hostport.contains("@") else { return nil }   // no userinfo: a host is a host
        let parts = hostport.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        host = String(parts[0]).lowercased()
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        if parts.count == 2 {
            guard let n = UInt16(parts[1]), n > 0 else { return nil }
            port = n
        } else { port = https ? 443 : 80 }
    }

    public var endpoint: HTTP.Endpoint { https ? .tls(host: host, port: port, cafile: nil) : .tcp(host: host, port: port) }
    public var text: String {
        (https ? "https://" : "http://") + host + (port == (https ? 443 : 80) ? "" : ":\(port)") + path
    }

    /// A redirect's Location, against this URL.
    public func resolve(_ location: String) -> WebURL? {
        if let u = WebURL(location) { return u }
        guard location.hasPrefix("/") else { return nil }
        var u = self; u.path = location; return u
    }
}
