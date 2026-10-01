// abyss-loginwindow — the session's privileged half (PHASE16 P16.1).
//
//   abyss-loginwindow [--socket PATH] [--pam-service NAME] [--once]
//
// Root. Answers one question, for whoever asks, about themselves: *is this my
// password?* The lock screen asks it (P16.2), and the login window will
// (P16.5). The caller is who the kernel says (`ap_peer_uid`); a request names
// nobody. A run of wrong answers makes the next one wait (`Login.Limiter`).
// The password is never logged.
//
// Later passes give it its other jobs — starting sessions, sleep and power
// (PHASE16 §6.1: one daemon, greetd-shaped). Linux has no PAM here, and it
// says so rather than answering.

import CurrentIPC
import Login

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}

var socketPath = Login.defaultSocket, service = Login.defaultService, once = false
var commands = PowerCommands()
var greeter = false
var sessionConfig = SessionManager.Config()
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
@MainActor func value(_ flag: String) -> String {
    i += 1
    guard i < args.count else { emit(2, "abyss-loginwindow: \(flag) needs a value"); exit(2) }
    return args[i]
}
while i < args.count {
    switch args[i] {
    case "--socket": socketPath = value("--socket")
    case "--pam-service": service = value("--pam-service")
    case "--once": once = true
    // Stand-ins that record what was asked, for a test (PHASE16 §6.3).
    case "--acpiconf": commands.acpiconf = value("--acpiconf")
    case "--shutdown": commands.shutdown = value("--shutdown")
    // The login window's sessions (P16.5b): the greeter, then whoever logs in.
    case "--greeter": greeter = true
    case "--session-command": sessionConfig.command = value("--session-command")
    case "--session-log-dir": sessionConfig.logDirectory = value("--session-log-dir")
    case "--runtime-root": sessionConfig.runtimeRoot = value("--runtime-root")
    case "-h", "--help":
        emit(1, "usage: abyss-loginwindow [--socket PATH] [--pam-service NAME] [--once] [--acpiconf PATH] [--shutdown PATH]\n"
             + "                         [--greeter [--session-command PATH] [--session-log-dir DIR] [--runtime-root DIR]]")
        exit(0)
    default:
        emit(2, "abyss-loginwindow: unknown option '\(args[i])'"); exit(2)
    }
    i += 1
}

#if !os(FreeBSD)
// The PAM the authenticator is written against is OpenPAM's, in FreeBSD's
// base; the Linux dev box has no PAM headers. Refuse in words rather than
// answer "no" to every password.
emit(2, "abyss-loginwindow: this platform has no PAM to ask — the authenticator is FreeBSD's")
exit(1)
#endif

// Only root can read master.passwd, so only root can answer (PHASE16 §4.2).
if geteuid() != 0 {
    emit(2, "abyss-loginwindow: not running as root — PAM can check no password but root's own")
}

signal(SIGPIPE, SIG_IGN)
let server: Current.Server
// 0666: every user — every session, and the login window's own — may ask.
// What they may ask is limited by who the kernel says they are, not by this.
do { server = try Current.Server(path: socketPath, mode: 0o666) } catch {
    emit(2, "abyss-loginwindow: cannot bind \(socketPath): \(error)"); exit(1)
}
emit(2, "loginwindow: answering at \(socketPath), PAM service \(service)")

let daemon = LoginService(server: server, authenticator: .system(service: service), commands: commands,
                           log: { emit(2, $0) })
if let g = getpwnam(Login.greeterUser) {
    daemon.greeterUID = UInt32(g.pointee.pw_uid)
    emit(2, "loginwindow: the login window's account is \(Login.greeterUser) (uid \(daemon.greeterUID!))")
}
if greeter {
    // Without its account, the login window cannot run, and nobody could log
    // in: say so, and answer the rest (the lock screen still needs it).
    if daemon.greeterUID == nil {
        emit(2, "loginwindow: --greeter, but there is no \(Login.greeterUser) account — no login window")
    } else {
        daemon.sessions = SessionManager(config: sessionConfig, log: { emit(2, $0) })
    }
}
daemon.run(once: once)
server.shutdownAndUnlink()
