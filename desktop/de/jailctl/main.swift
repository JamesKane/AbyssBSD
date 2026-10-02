// abyss-jail — ask abyss-jaild for a jail, by hand (PHASE18 P18.2).
//
//   abyss-jail run CLASS -- PROGRAM [ARG...]
//       open the class's jail, run PROGRAM in it with this terminal, wait for
//       it, and let go of the jail (if this was its only holder, it goes).
//   abyss-jail hold CLASS [-- PROGRAM [ARG...]...]
//       open it, print "held NAME jid=N root=… runtime=…", start PROGRAM in it
//       detached if given, and keep the jail until stdin reaches EOF.
//   abyss-jail spawn-by-name NAME -- PROGRAM [ARG...]
//       a test's probe: ask to run in a jail named by NAME rather than held —
//       jaild must refuse it unless the jail is the caller's own.
//
// [--socket PATH] before the command talks to another jaild (a test's).

import CJail
import JailD

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
        waitFor(proc)
        close(proc)
    } catch { die("\(error)") }
    close(j.jail)
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
