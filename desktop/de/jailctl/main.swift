// abyss-jail — ask abyss-jaild for a jail, by hand (PHASE18 P18.2).
//
//   abyss-jail run CLASS -- PROGRAM [ARG...]
//       open the class's jail, run PROGRAM in it with this terminal, wait for
//       it, and let go of the jail (if this was its only holder, it goes).
//       Exits with PROGRAM's status (128 + N if a signal N killed it), so a
//       test can ask a jail a yes-or-no question.
//   abyss-jail hold CLASS [-- PROGRAM [ARG...]...]
//       open it, print "held NAME jid=N root=… runtime=…", start PROGRAM in it
//       detached if given, and keep the jail until stdin reaches EOF.
//   abyss-jail grants NAME          the files granted into a jail (P18.4)
//   abyss-jail revoke NAME N        take grant N back
//   abyss-jail grant NAME PATH [--fd-of FILE] [--write]
//       grant PATH, proven by a descriptor of PATH (or, as a test's forgery,
//       of FILE), opened read-only (or read-write with --write).
//   abyss-jail spawn-by-name NAME -- PROGRAM [ARG...]
//       a test's probe: ask to run in a jail named by NAME rather than held —
//       jaild must refuse it unless the jail is the caller's own.
//
//   abyss-jail serve
//       the session's half (P18.5): a session component that holds a jail
//       per class, with its Wayland socket, bus and portal, and launches into
//       it. Answers on the session's `jails` socket.
//   abyss-jail agent CLASS
//       ask the session for an agent session in CLASS (P18.8): prints
//       "agent SESSION socket=… transcript=… pid=…"; `abyss-agent ask
//       --listen SOCKET` then talks to it.
//   abyss-jail give SESSION APP
//       give a running application to an agent session (P18.10): APP as
//       abyssmenu names it, or its menu service; the agent may then drive it.
//   abyss-jail raise SESSION TOKENS
//       allow an agent session TOKENS more (P18.11): what the Agent window's
//       budget requester sends when the person says Allow.
//   abyss-jail take SESSION APP
//       take a given application back from an agent session (P18.11).
//   abyss-jail permit SESSION APP yes|no
//       the person's answer to requester 1 (P18.11): may APP write for the
//       session's agent? What the Agent window sends.
//   abyss-jail crashes
//       the confined programs that died of a signal this session (P18.9).
//   abyss-jail debug N
//       a `debug` session for crash N, its core granted read-only; prints as
//       `agent` does.
//   abyss-jail launch CLASS -- PROGRAM [ARG...]
//       ask the session to start PROGRAM confined; an ARG that names one of
//       your files is granted into the jail and rewritten. What an
//       application bundle's launcher runs when the application is confined.
//
// [--socket PATH] before the command talks to another jaild (a test's).

import CJail
import CPlatform
import CWaylandClient
import CurrentIPC
import JailD
import JailKeeper
import Jails
import Spawn

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func die(_ s: String) -> Never { emit(2, "abyss-jail: \(s)"); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
var socket = JailWire.defaultSocket
if args.first == "--socket", args.count > 1 { socket = args[1]; args.removeFirst(2) }
if args.first == "serve" {
    var runtime = ""
    do { runtime = try Current.runtimeDir() } catch { die("no runtime directory: \(error)") }
    var buf = [CChar](repeating: 0, count: 4096)
    let n = buf.withUnsafeMutableBufferPointer { ap_self_executable($0.baseAddress!, $0.count) }
    let me = n > 0 ? String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
    let binDir = me.lastIndex(of: "/").map { String(me[..<$0]) } ?? "/usr/local/bin"
    let display = wl_display_connect(nil)
    if display == nil { emit(2, "abyss-jail: no compositor to register jails with — launched programs get no display") }
    let server: Current.Server
    do { server = try Current.Server(service: KeeperWire.service) } catch { die("cannot serve \(KeeperWire.service): \(error)") }
    signal(SIGPIPE, SIG_IGN)
    // The person's jails.ini: an agent class's model and budget are theirs
    // to set (P18.8). What a jail can reach is jaild's, from the system's.
    let keeper = JailKeeper(server: server, display: display, runtimeDir: runtime, binDir: binDir,
                            classes: JailClass.load(), log: { emit(1, $0) })
    keeper.jaildSocket = socket
    // A crash is shown to the person (P18.9b) — when there is a display to
    // show it on.
    if display != nil, access(binDir + "/AquaDemo", X_OK) == 0 { keeper.crashDialog = [binDir + "/AquaDemo"] }
    // The bundles follow [apps] (P18.6): the same appgen anchor runs at login.
    if access(binDir + "/abyss-appgen", X_OK) == 0, let home = getenv("HOME") {
        keeper.appgen = [binDir + "/abyss-appgen", "--to", String(cString: home) + "/Applications"]
    }
    emit(1, "jails: ready")
    keeper.run()
    server.shutdownAndUnlink()
    exit(0)
}
if args.first == "crashes" {
    var m = Msg(); m.set("method", "crashes")
    do {
        let r = try Current.call(KeeperWire.service, m)
        guard r.bool("ok") == true else { die(r.string("error") ?? "refused") }
        for c in JailWire.unlist(r.bytes("crashes") ?? []) { emit(1, c) }
        exit(0)
    } catch { die("the session's jails are not running (\(error))") }
}
guard args.count >= 2 else {
    emit(2, "usage: abyss-jail [--socket PATH] run|hold CLASS [-- PROGRAM ARG...] | spawn-by-name NAME -- PROGRAM ARG...")
    exit(2)
}
let command = args[0], subject = args[1]
let program = args.firstIndex(of: "--").map { Array(args[($0 + 1)...]) } ?? []

func waitFor(_ proc: Int32) {
    var p = pollfd(fd: proc, events: Int16(POLLHUP), revents: 0)
    while poll(&p, 1, -1) < 0 && errno == EINTR {}
}

switch command {
case "run":
    guard !program.isEmpty else { die("run needs a program after --") }
    let j: JailClient.Opened
    do { j = try JailClient.open(subject, socket: socket) } catch { die("\(error)") }
    do {
        let (_, proc) = try JailClient.spawn(jail: j.jail, argv: program, stdin: 0, stdout: 1, stderr: 2, socket: socket)
        let status = ap_procdesc_wait(proc)
        close(proc)
        close(j.jail)
        guard status >= 0 else { die("lost track of \(program[0])") }
        exit(status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    } catch { die("\(error)") }
case "hold":
    let j: JailClient.Opened
    do { j = try JailClient.open(subject, socket: socket) } catch { die("\(error)") }
    emit(1, "held \(j.name) jid=\(j.jid) root=\(j.root) runtime=\(j.runtime) shared=\(j.shared)")
    if !program.isEmpty {
        do {
            let (pid, proc) = try JailClient.spawn(jail: j.jail, argv: program, stdout: 2, stderr: 2, daemon: true, socket: socket)
            close(proc)
            emit(1, "started \(program[0]) pid=\(pid)")
        } catch { die("\(error)") }
    }
    var b = [UInt8](repeating: 0, count: 256)
    while read(0, &b, b.count) > 0 {}
    close(j.jail)
    emit(1, "released \(j.name)")
case "launch":
    guard !program.isEmpty else { die("launch needs a program after --") }
    var m = Msg(); m.set("method", "launch"); m.set("class", subject); m.set("argv", bytes: JailWire.list(program))
    do {
        let r = try Current.call(KeeperWire.service, m)
        guard r.bool("ok") == true else { die(r.string("error") ?? "refused") }
        emit(1, "launched \(program[0]) pid=\(r.uint64("pid") ?? 0) confined in \(subject)")
    } catch { die("the session's jails are not running (\(error))") }
case "agent":
    var m = Msg(); m.set("method", "agent"); m.set("class", subject)
    do {
        let r = try Current.call(KeeperWire.service, m)
        guard r.bool("ok") == true else { die(r.string("error") ?? "refused") }
        emit(1, "agent \(r.string("session") ?? "") socket=\(r.string("socket") ?? "") transcript=\(r.string("transcript") ?? "") pid=\(r.uint64("pid") ?? 0)")
    } catch { die("the session's jails are not running (\(error))") }
case "give":
    guard args.count >= 3 else { die("give needs a session and an application") }
    var m = Msg(); m.set("method", "give"); m.set("session", subject); m.set("app", args[2])
    do {
        let r = try Current.call(KeeperWire.service, m)
        guard r.bool("ok") == true else { die(r.string("error") ?? "refused") }
        emit(1, "gave \(r.string("app") ?? args[2]) to \(subject)")
    } catch { die("the session's jails are not running (\(error))") }
case "raise", "take", "permit":
    guard args.count >= 3 else { die("\(command) needs a session and \(command == "raise" ? "tokens" : "an application")") }
    var m = Msg(); m.set("method", command); m.set("session", subject)
    if command == "raise" { m.set("tokens", UInt64(args[2]) ?? 0) } else { m.set("app", args[2]) }
    if command == "permit" { m.set("allow", args.count > 3 && args[3] == "yes") }
    do {
        let r = try Current.call(KeeperWire.service, m)
        guard r.bool("ok") == true else { die(r.string("error") ?? "refused") }
        emit(1, command == "raise" ? "budget \(r.uint64("budget") ?? 0)"
                : command == "take" ? "took \(args[2]) back" : "\(args.count > 3 && args[3] == "yes" ? "allowed" : "did not allow") \(args[2])")
    } catch { die("the session's jails are not running (\(error))") }
case "debug":
    var m = Msg(); m.set("method", "debug"); m.set("crash", UInt64(subject) ?? 0)
    do {
        let r = try Current.call(KeeperWire.service, m)
        guard r.bool("ok") == true else { die(r.string("error") ?? "refused") }
        emit(1, "agent \(r.string("session") ?? "") socket=\(r.string("socket") ?? "") transcript=\(r.string("transcript") ?? "") pid=\(r.uint64("pid") ?? 0)")
    } catch { die("the session's jails are not running (\(error))") }
case "grants":
    do { for g in try JailClient.grants(jail: subject, socket: socket) { emit(1, g) } } catch { die("\(error)") }
case "revoke":
    guard args.count >= 3, let n = UInt64(args[2]) else { die("revoke needs a jail and a grant number") }
    do { try JailClient.revoke(jail: subject, grant: n, socket: socket); emit(1, "revoked \(n)") } catch { die("\(error)") }
case "grant":
    guard args.count >= 3 else { die("grant needs a jail and a path") }
    let path = args[2]
    let proof = args.firstIndex(of: "--fd-of").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? path
    let fd = open(proof, args.contains("--write") ? O_RDWR : O_RDONLY)
    guard fd >= 0 else { die("cannot open \(proof): \(String(cString: strerror(errno)))") }
    do {
        let g = try JailClient.grant(jail: subject, path: path, file: fd, socket: socket)
        emit(1, "granted \(g.n) at \(g.inside)")
    } catch { die("\(error)") }
case "spawn-by-name":
    let desc = ap_jail_desc_by_name(subject)
    guard desc >= 0 else { die("no jail named \(subject) that this user may see") }
    do {
        let (pid, proc) = try JailClient.spawn(jail: desc, argv: program.isEmpty ? ["true"] : program, socket: socket)
        emit(1, "spawned pid=\(pid)")
        waitFor(proc)
    } catch { die("\(error)") }
default:
    die("unknown command '\(command)'")
}
