// The fetch bridge (PHASE18 P18.12b): an agent's only way to the network.
//
// The agent's jail has no network at all. Its `fetch` tool asks this bridge,
// run by the keeper outside the jail, which:
//
//   - reaches only hosts the person allowed this session (requester 3): a new
//     host is answered "the person must be asked", and the answer comes on the
//     keeper's side, never the agent's;
//   - never reaches this computer's own services or private networks
//     (loopback, RFC 1918, link-local): the agent must not be able to use the
//     bridge to knock on the person's own doors;
//   - follows a redirect only to a host that is allowed too;
//   - gives back text: a page's words without its markup, cut to 16 KB;
//   - says every request, permission and refusal in the session's transcript.

import Model

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum PageText {
    public static let limit = 16 << 10

    /// A page's words: markup, scripts and styles gone, entities read, space
    /// folded. Plain text passes through.
    public static func from(_ body: String, contentType: String) -> String {
        guard contentType.lowercased().contains("html") else { return cut(body) }
        var out = "", tag = "", inTag = false, skipping: String?
        for ch in body {
            if inTag {
                if ch == ">" {
                    inTag = false
                    let name = tag.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init) ?? ""
                    if let s = skipping { if name == "/" + s { skipping = nil } }
                    else if name == "script" || name == "style" { skipping = name }
                    else if ["p", "/p", "br", "br/", "div", "/div", "li", "tr", "h1", "h2", "h3", "/h1", "/h2", "/h3", "title", "/title"].contains(name) { out += "\n" }
                    tag = ""
                } else { tag.append(ch) }
                continue
            }
            if ch == "<" { inTag = true; continue }
            if skipping == nil { out.append(ch) }
        }
        let entities = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")]
        for (e, r) in entities { out = replace(out, e, r) }
        let lines = out.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return cut(lines.joined(separator: "\n"))
    }

    static func replace(_ s: String, _ a: String, _ b: String) -> String {
        guard s.contains(a) else { return s }
        return s.split(separator: Substring(a), omittingEmptySubsequences: false).joined(separator: b)
    }

    static func cut(_ s: String) -> String {
        let b = Array(s.utf8)
        return b.count <= limit ? s : String(decoding: b.prefix(limit), as: UTF8.self) + "\n(cut at 16 KB)"
    }
}

public enum Addresses {
    /// Whether an address is this computer's or a private network's: the
    /// bridge does not reach them.
    public static func isLocal(_ ip: String) -> Bool {
        if ip.contains(":") {
            let l = ip.lowercased()
            return l == "::1" || l == "::" || l.hasPrefix("fe8") || l.hasPrefix("fe9") || l.hasPrefix("fea") || l.hasPrefix("feb")
                || l.hasPrefix("fc") || l.hasPrefix("fd") || l.hasPrefix("::ffff:127.") || l.hasPrefix("::ffff:10.")
                || l.hasPrefix("::ffff:192.168.")
        }
        let o = ip.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return true }   // not an address we can read: refuse
        switch (o[0], o[1]) {
        case (127, _), (10, _), (0, _), (169, 254), (192, 168): return true
        case (172, let b) where (16...31).contains(b): return true
        case (100, let b) where (64...127).contains(b): return true   // carrier-grade NAT
        default: return false
        }
    }

    /// The addresses a host resolves to, as text.
    public static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var p = res
        while let a = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            // The buffer's length is a socklen_t on Linux and a size_t here.
            #if os(Linux)
            let len = socklen_t(buf.count)
            #else
            let len = buf.count
            #endif
            if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, len, nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            p = a.pointee.ai_next
        }
        return out
    }
}

/// What the bridge says to one fetch.
public enum FetchAnswer: Equatable, Sendable {
    case page(url: String, status: Int, text: String)
    /// The person must be asked about `host` first.
    case ask(host: String, url: String)
    case refused(String)
}

public final class FetchBridge {
    public typealias Get = (WebURL) throws -> HTTPResponse
    public private(set) var permitted: Set<String> = []
    let get: Get
    let resolve: (String) -> [String]
    let allowLocal: Bool
    let log: (String, [(String, JSON)]) -> Void

    public init(allowLocal: Bool = false, resolve: @escaping (String) -> [String] = Addresses.resolve,
                get: @escaping Get = { u in
                    try HTTP.call(u.endpoint, method: "GET", path: u.path,
                                  headers: [("User-Agent", "AbyssBSD agent"), ("Accept", "text/html, text/plain;q=0.9, */*;q=0.1")],
                                  version: "1.0", timeoutSeconds: 20)
                }, log: @escaping (String, [(String, JSON)]) -> Void = { _, _ in }) {
        self.allowLocal = allowLocal; self.resolve = resolve; self.get = get; self.log = log
    }

    /// The person's answer for `host` (the keeper's side).
    public func permit(_ host: String, allow: Bool) {
        if allow { permitted.insert(host.lowercased()) }
        log(allow ? "permitted" : "denied", [("host", .string(host.lowercased()))])
    }

    public func fetch(_ text: String) -> FetchAnswer {
        guard var url = WebURL(text) else { return refuse("not an http or https URL: \(text)", url: text) }
        for _ in 0..<4 {
            if let why = local(url.host) { return refuse(why, url: url.text) }
            guard permitted.contains(url.host) else {
                log("asked", [("host", .string(url.host)), ("url", .string(url.text))])
                return .ask(host: url.host, url: url.text)
            }
            let r: HTTPResponse
            do { r = try get(url) } catch { return refuse("\(url.host) did not answer: \(error)", url: url.text) }
            if (300...399).contains(r.status), let loc = r.headers.last(where: { $0.0.lowercased() == "location" })?.1 {
                guard let next = url.resolve(loc) else { return refuse("a redirect to \(loc), which is not a URL", url: url.text) }
                log("redirected", [("from", .string(url.text)), ("to", .string(next.text))])
                url = next
                continue
            }
            let type = r.headers.last { $0.0.lowercased() == "content-type" }?.1 ?? "text/plain"
            let text = PageText.from(String(decoding: r.body, as: UTF8.self), contentType: type)
            log("fetched", [("url", .string(url.text)), ("status", .number(Double(r.status))), ("bytes", .number(Double(r.body.count)))])
            return .page(url: url.text, status: r.status, text: text)
        }
        return refuse("too many redirects", url: url.text)
    }

    func local(_ host: String) -> String? {
        if allowLocal { return nil }
        let ips = resolve(host)
        if ips.isEmpty { return "\(host) does not resolve" }
        if let ip = ips.first(where: Addresses.isLocal) {
            return "\(host) is this computer's or a private network's (\(ip)): an agent does not reach those"
        }
        return nil
    }

    func refuse(_ why: String, url: String) -> FetchAnswer {
        log("refused", [("url", .string(url)), ("reason", .string(why))])
        return .refused(why)
    }
}
