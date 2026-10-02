// abyss-fetch — an agent session's fetch bridge (PHASE18 P18.12b).
//
//   abyss-fetch serve --listen INSIDE --control OUTSIDE --session ID --transcript DIR
//       answers the agent at INSIDE (a socket in its jail): `fetch url=URL`,
//       for hosts the person allowed this session and no others; a new host
//       is answered `permission host=…`. The person's answer comes from the
//       keeper at OUTSIDE (0600, beside the transcript): `permit host=H
//       allow=BOOL`. Every request, permission and refusal is a line of
//       DIR/transcript.jsonl. $ABYSS_FETCH_ALLOW_LOCAL (tests only) lets it
//       reach this computer's own addresses, which it otherwise refuses.

import CurrentIPC
import Fetch
import Model

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func die(_ s: String) -> Never { emit(2, "abyss-fetch: \(s)"); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard args.first == "serve", let inside = opt("--listen"), let outside = opt("--control"),
      let session = opt("--session"), let dir = opt("--transcript") else {
    emit(2, "usage: abyss-fetch serve --listen INSIDE --control OUTSIDE --session ID --transcript DIR")
    exit(2)
}

let fd: Int32
do { fd = try TranscriptFile.open(dir: dir) } catch { die("\(error)") }
func line(_ event: String, _ fields: [(String, JSON)]) {
    let l = JSON.object([("t", .number((ModelSession.now() * 1000).rounded() / 1000)), ("session", .string(session)),
                         ("kind", .string("fetch")), ("event", .string(event))] + fields).text + "\n"
    let b = Array(l.utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
let allowLocal = getenv("ABYSS_FETCH_ALLOW_LOCAL") != nil
let bridge = FetchBridge(allowLocal: allowLocal, log: line)
signal(SIGPIPE, SIG_IGN)
unlink(inside); unlink(outside)
let agentSide: Current.Server, keeperSide: Current.Server
do {
    agentSide = try Current.Server(path: inside, mode: 0o600)
    keeperSide = try Current.Server(path: outside, mode: 0o600)
} catch { die("cannot listen: \(error)") }
emit(1, "ready (session \(session)\(allowLocal ? ", local addresses allowed: a test" : ""))")

while true {
    var fds = [pollfd(fd: agentSide.fd, events: Int16(POLLIN), revents: 0),
               pollfd(fd: keeperSide.fd, events: Int16(POLLIN), revents: 0)]
    if poll(&fds, 2, -1) < 0 { if errno == EINTR { continue }; die("poll: \(String(cString: strerror(errno)))") }
    for (i, server) in [agentSide, keeperSide].enumerated() where fds[i].revents != 0 {
        guard let c = try? server.accept() else { continue }
        defer { close(c) }
        guard let req = try? Current.receive(on: c) else { continue }
        var r = Msg()
        if i == 1 {
            // The keeper's side: the person's answers, and nothing else.
            if req.string("method") == "permit", let h = req.string("host") {
                bridge.permit(h, allow: req.bool("allow") == true)
                r.set("ok", true)
                emit(1, "\(req.bool("allow") == true ? "permitted" : "denied") \(h)")
            } else { r.set("ok", false); r.set("error", "the control socket answers permit") }
        } else if req.string("method") == "fetch" {
            switch bridge.fetch(req.string("url") ?? "") {
            case let .page(url, status, text):
                r.set("ok", true); r.set("url", url); r.set("status", UInt64(status)); r.set("text", text)
            case let .ask(host, url):
                r.set("ok", false); r.set("permission", true); r.set("host", host); r.set("url", url)
                r.set("error", "the person has not allowed \(host) yet; they are being asked")
            case .refused(let why):
                r.set("ok", false); r.set("error", why)
            }
            emit(1, "fetch \(req.string("url") ?? "") → \(r.bool("ok") == true ? "ok" : r.bool("permission") == true ? "ask" : "refused")")
        } else { r.set("ok", false); r.set("error", "the fetch bridge answers fetch") }
        try? Current.send(r, on: c)
    }
}
