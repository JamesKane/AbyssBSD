// abyss-agent — an agent session, inside its jail (PHASE18 P18.8).
//
//   abyss-agent serve --model SOCKET --listen SOCKET [--class CLASS]
//                     [--core CORE --binary BINARY --crash WHAT] [--vocab SOCKET]
//       the loop, answering questions on the socket at --listen (inside the
//       jail's runtime directory; the keeper hands its outside path to the
//       chat window). Its only way to a model is abyss-model at --model, and
//       its tools read only what the jail holds. `bye` ends the session.
//       With --core and --binary (a `debug` session, P18.9) it also has lldb
//       on that core, and is told what crashed. With --vocab (P18.10) it can
//       drive the applications this session was given, through the bridge.
//   abyss-agent ask --listen SOCKET TEXT...
//       ask the agent at SOCKET: one `call=` line per tool as it is called,
//       then its answer, then `stop=` and `steps=`. Exits 0 when it answered, 3
//       when the budget stopped it, 4 when the step limit did, 1 otherwise.
//   abyss-agent bye --listen SOCKET

import Agent
import Jails
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
    // Where its home is, said outright: on the 12700KF, told only "your own
    // home", Granite tried /home/agent, /abyss and / before /home/abyss.
    let home = getenv("HOME").map { String(cString: $0) } ?? "/home"
    var system = """
        You are an agent on the AbyssBSD desktop, working for the person who asked. \
        You run confined, in a jail of class \(cls): you see the system read-only, your own home \
        (\(home)), and only the files the person granted you (under \(JailLayout.granted)). \
        Use the tools to look before you answer. Answer plainly and briefly.
        """
    var tools = AgentTools.reading
    // A debug session (P18.9): one crash, its core and binary granted in.
    if let core = opt("--core"), let binary = opt("--binary") {
        tools.append(AgentTools.lldb(core: core, binary: binary))
        system += " " + """
        A program crashed: \(opt("--crash") ?? "it was killed by a signal"). \
        Its core is \(core) and its binary \(binary); the lldb tool runs one command on them. \
        Find where and why it crashed — start with "bt" — and say so in a short report: \
        the signal, the frame that faulted with its file and line if known, and the likely cause.
        """
    }
    if let vocab = opt("--vocab") {
        tools += AgentTools.vocabulary(socket: vocab)
        system += " " + """
        You can drive the applications the person gave you, by their menus: list them with apps, \
        read one's commands with describe_app, and run a command with activate. Use only verbs \
        describe_app lists, and say what you did.
        """
    }
    let loop = AgentLoop(system: system, tools: tools, model: modelOverSocket(modelSocket))
    emit(1, "ready (class \(cls), model at \(modelSocket))")
    while true {
        guard let c = try? server.accept() else { continue }
        guard let req = try? Current.receive(on: c) else { close(c); continue }
        var reply = Msg()
        switch req.string("method") {
        case "ask":
            // Each tool call as it starts, as an event on the same connection
            // before the reply (the chat window shows it then, not after).
            loop.onCall = { call in
                var e = Msg(); e.set("event", "call"); e.set("call", call)
                try? Current.send(e, on: c)
            }
            defer { loop.onCall = { _ in } }
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
    var r = Msg()
    do {
        let fd = try Current.connect(path: listen)
        defer { close(fd) }
        try Current.send(m, on: fd)
        // Events first (a tool call as it starts), then the reply.
        while true {
            r = try Current.receive(on: fd)
            guard r.string("event") == "call" else { break }
            emit(1, "call=\(r.string("call") ?? "")")
        }
    } catch { die("no agent at \(listen): \(error)") }
    guard r.bool("ok") == true else { die(r.string("error") ?? "refused") }
    if args[0] == "bye" { emit(1, "bye"); exit(0) }
    emit(1, r.string("text") ?? "")
    let stop = r.string("stop") ?? "failed"
    emit(1, "stop=\(stop)")
    emit(1, "steps=\(r.uint64("steps") ?? 0)")
    exit(stop == "answered" ? 0 : stop == "budget" ? 3 : stop == "steps" ? 4 : 1)

default:
    die("unknown command \(args.first ?? "")")
}
