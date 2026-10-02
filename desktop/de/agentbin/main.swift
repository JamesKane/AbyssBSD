// abyss-agent — an agent session, inside its jail (PHASE18 P18.8).
//
//   abyss-agent serve --model SOCKET --listen SOCKET [--class CLASS]
//       the loop, answering questions on the socket at --listen (inside the
//       jail's runtime directory; the keeper hands its outside path to the
//       chat window). Its only way to a model is abyss-model at --model, and
//       its tools read only what the jail holds. `bye` ends the session.
//   abyss-agent ask --listen SOCKET TEXT...
//       ask the agent at SOCKET, and print its answer, then `stop=` `steps=`
//       and one `call=` line per tool it used. Exits 0 when it answered, 3
//       when the budget stopped it, 4 when the step limit did, 1 otherwise.
//   abyss-agent bye --listen SOCKET

import Agent
import CurrentIPC
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
func die(_ s: String) -> Never { emit(2, "abyss-agent: \(s)"); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let listen = opt("--listen") else {
    emit(2, "usage: abyss-agent serve --model SOCKET --listen SOCKET [--class C] | ask --listen SOCKET TEXT... | bye --listen SOCKET")
    exit(2)
}

switch args.first {
case "serve":
    guard let modelSocket = opt("--model") else { die("serve needs --model SOCKET") }
    let cls = opt("--class") ?? "agent"
    signal(SIGPIPE, SIG_IGN)
    unlink(listen)
    let server: Current.Server
    do { server = try Current.Server(path: listen, mode: 0o600) } catch { die("cannot listen at \(listen): \(error)") }
    let loop = AgentLoop(
        system: """
        You are an agent on the AbyssBSD desktop, working for the person who asked. \
        You run confined, in a jail of class \(cls): you see the system read-only, your own home, \
        and only the files the person granted you. Use the tools to look before you answer. \
        Answer plainly and briefly.
        """,
        tools: AgentTools.reading, model: modelOverSocket(modelSocket))
    emit(1, "ready (class \(cls), model at \(modelSocket))")
    while true {
        guard let c = try? server.accept() else { continue }
        guard let req = try? Current.receive(on: c) else { close(c); continue }
        var reply = Msg()
        switch req.string("method") {
        case "ask":
            let a = loop.ask(req.string("text") ?? "")
            reply.set("ok", true)
            reply.set("text", a.text)
            reply.set("stop", a.stop.rawValue)
            reply.set("steps", UInt64(a.steps))
            reply.set("calls", bytes: Array(a.calls.joined(separator: "\n").utf8))
            emit(1, "asked: \(a.stop.rawValue) after \(a.steps) step(s), \(a.calls.count) tool call(s)")
        case "bye":
            reply.set("ok", true)
            try? Current.send(reply, on: c)
            close(c)
            server.shutdownAndUnlink()
            emit(1, "bye")
            exit(0)
        default:
            reply.set("ok", false); reply.set("error", "unknown method")
        }
        try? Current.send(reply, on: c)
        close(c)
    }

case "ask", "bye":
    var m = Msg()
    m.set("method", args[0])
    if args[0] == "ask" {
        // Everything after the options is the question.
        var words: [String] = [], skip = false
        for a in args.dropFirst() {
            if skip { skip = false; continue }
            if a == "--listen" { skip = true; continue }
            words.append(a)
        }
        m.set("text", words.joined(separator: " "))
    }
    let r: Msg
    do {
        let fd = try Current.connect(path: listen)
        defer { close(fd) }
        try Current.send(m, on: fd)
        r = try Current.receive(on: fd)
    } catch { die("no agent at \(listen): \(error)") }
    guard r.bool("ok") == true else { die(r.string("error") ?? "refused") }
    if args[0] == "bye" { emit(1, "bye"); exit(0) }
    emit(1, r.string("text") ?? "")
    let stop = r.string("stop") ?? "failed"
    emit(1, "stop=\(stop)")
    emit(1, "steps=\(r.uint64("steps") ?? 0)")
    for c in String(decoding: r.bytes("calls") ?? [], as: UTF8.self).split(separator: "\n") { emit(1, "call=\(c)") }
    exit(stop == "answered" ? 0 : stop == "budget" ? 3 : stop == "steps" ? 4 : 1)

default:
    die("unknown command \(args.first ?? "")")
}
