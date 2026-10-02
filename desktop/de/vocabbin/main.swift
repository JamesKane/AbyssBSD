// abyss-vocab — an agent session's vocabulary bridge (PHASE18 P18.10).
//
//   abyss-vocab serve --listen INSIDE --control OUTSIDE --session ID --transcript DIR
//       answers the agent at INSIDE (a socket in its jail): apps, describe,
//       activate — for the applications given to this session and no others.
//       Gives come from the keeper at OUTSIDE (a socket outside the jail, 0600):
//       `give service=menus.APP.PID`, and `take app=NAME` (P18.11). Every give, activation and refusal is a
//       line of DIR/transcript.jsonl. The keeper starts it beside abyss-model
//       and stops it with the agent.

import CurrentIPC
import Model
import Vocabulary

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func die(_ s: String) -> Never { emit(2, "abyss-vocab: \(s)"); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard args.first == "serve", let inside = opt("--listen"), let outside = opt("--control"),
      let session = opt("--session"), let dir = opt("--transcript") else {
    emit(2, "usage: abyss-vocab serve --listen INSIDE --control OUTSIDE --session ID --transcript DIR")
    exit(2)
}

let fd: Int32
do { fd = try TranscriptFile.open(dir: dir) } catch { die("\(error)") }
func line(_ kind: String, _ fields: [(String, JSON)]) {
    let l = JSON.object([("t", .number((ModelSession.now() * 1000).rounded() / 1000)), ("session", .string(session)),
                         ("kind", .string("vocabulary")), ("event", .string(kind))] + fields).text + "\n"
    let b = Array(l.utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
let bridge = VocabularyBridge(menus: LiveMenus(), log: line)
signal(SIGPIPE, SIG_IGN)
unlink(inside); unlink(outside)
let agentSide: Current.Server, keeperSide: Current.Server
do {
    agentSide = try Current.Server(path: inside, mode: 0o600)
    keeperSide = try Current.Server(path: outside, mode: 0o600)
} catch { die("cannot listen: \(error)") }
emit(1, "ready (session \(session))")

while true {
    var fds = [pollfd(fd: agentSide.fd, events: Int16(POLLIN), revents: 0),
               pollfd(fd: keeperSide.fd, events: Int16(POLLIN), revents: 0)]
    if poll(&fds, 2, -1) < 0 { if errno == EINTR { continue }; die("poll: \(String(cString: strerror(errno)))") }
    for (i, server) in [agentSide, keeperSide].enumerated() where fds[i].revents != 0 {
        guard let c = try? server.accept() else { continue }
        defer { close(c) }
        guard let req = try? Current.receive(on: c) else { continue }
        var reply: Msg
        if i == 1 {
            // The keeper's side: gives, and nothing else.
            reply = Msg()
            if req.string("method") == "give", let s = req.string("service") {
                do {
                    let name = try bridge.give(service: s)
                    reply.set("ok", true); reply.set("app", name)
                    emit(1, "given \(name) (\(s))")
                } catch { reply.set("ok", false); reply.set("error", "\(s) did not answer: \(error)") }
            } else if req.string("method") == "take", let app = req.string("app") {
                // Taken back (P18.11): refused from now on, as never given.
                if bridge.take(app) { reply.set("ok", true); emit(1, "taken \(app)") }
                else { reply.set("ok", false); reply.set("error", "\(app) was not given to this session") }
            } else { reply.set("ok", false); reply.set("error", "the control socket answers give and take") }
        } else {
            reply = bridge.handle(req)
            emit(1, "\(req.string("method") ?? "?") \(req.string("app") ?? "")\(req.string("verb").map { " " + $0 } ?? "") → \(reply.bool("ok") == true ? "ok" : "refused")")
        }
        try? Current.send(reply, on: c)
    }
}
