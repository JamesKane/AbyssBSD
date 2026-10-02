// HTTP — just enough HTTP/1.1 for the model wire (PHASE18 P18.7).
//
// `abyss-model` speaks OpenAI-compatible chat completions **over a unix
// socket**, so any OpenAI client — and `curl --unix-socket` — can use it, and
// calls llama.cpp's `llama-server` over loopback TCP. One request per
// connection, `Content-Length` bodies, no chunking, no keep-alive: the agent is
// one client asking one thing at a time, and a parser this small is one that
// can be read.

import CPlatform

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

    /// POST a JSON body to http://HOST:PORT/PATH over TCP and read the reply.
    public static func post(host: String, port: UInt16, path: String, json: JSON,
                            timeoutSeconds: Int = 600) throws -> HTTPResponse {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { throw Failure("cannot resolve \(host)") }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { throw Failure("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        _ = ap_socket_nosigpipe(fd)
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else {
            throw Failure("connect \(host):\(port): \(String(cString: strerror(errno)))")
        }
        let body = Array(json.text.utf8)
        let head = "POST \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try writeAll(fd, Array(head.utf8) + body)
        return try response(try readAll(fd) { _ in false })
    }
}
