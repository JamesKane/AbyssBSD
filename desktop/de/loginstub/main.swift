// abyss-loginstub — a stand-in authenticator, for tests only (PHASE16 P16.2b).
//
//     abyss-loginstub --socket PATH --password-file FILE [--acpiconf PATH] [--shutdown PATH]
//
// The lock screen's test needs an authenticator that answers on Linux, where
// there is no PAM, and in the guest without a throwaway account to log in as.
// This serves the **real** `Authenticator` — the same uid-from-the-kernel, the
// same limiter, the same log lines — with PAM's check replaced by "is it the
// bytes in FILE". Like `ipcprobe` it is a probe, not part of the product:
// abyss/mk/desktop-files.sh does not ship it.

import CurrentIPC
import Login

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(2, $0.baseAddress, b.count) }
}

var socketPath = "", passwordFile = ""
var commands = PowerCommands()
var lockTimeout = 8.0
var systemUID: UInt32 = 0
var greeterUID: UInt32? = nil
var greeter = false
var sessionConfig = SessionManager.Config()
var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--socket": socketPath = args.isEmpty ? "" : args.removeFirst()
    case "--password-file": passwordFile = args.isEmpty ? "" : args.removeFirst()
    case "--acpiconf": commands.acpiconf = args.isEmpty ? "" : args.removeFirst()
    case "--shutdown": commands.shutdown = args.isEmpty ? "" : args.removeFirst()
    case "--lock-timeout": lockTimeout = Double(args.isEmpty ? "" : args.removeFirst()) ?? 8
    // Whose word counts as devd's: a test cannot be root.
    case "--system-uid": systemUID = UInt32(args.isEmpty ? "" : args.removeFirst()) ?? 0
    // Whose word counts as the login window's: a test's own account.
    case "--greeter-uid": greeterUID = UInt32(args.isEmpty ? "" : args.removeFirst())
    // Sessions, as the real daemon's --greeter (P16.5b), with this test's own
    // account standing in for _loginwindow and for whoever logs in.
    case "--greeter": greeter = true
    case "--greeter-user": sessionConfig.greeterUser = args.isEmpty ? "" : args.removeFirst()
    case "--session-command": sessionConfig.command = args.isEmpty ? "" : args.removeFirst()
    case "--session-log-dir": sessionConfig.logDirectory = args.isEmpty ? "" : args.removeFirst()
    case "--runtime-root": sessionConfig.runtimeRoot = args.isEmpty ? "" : args.removeFirst()
    case "--session-path": sessionConfig.path = args.isEmpty ? "" : args.removeFirst()
    case "--vt-command": sessionConfig.vtCommand = args.isEmpty ? "" : args.removeFirst()
    // Two named users, both this account, each in its own runtime directory (P16.6b).
    case "--sessions-as-self": sessionConfig.sessionsAsSelf = true
    case "--session-env":
        let kv = args.isEmpty ? "" : args.removeFirst()
        if let eq = kv.firstIndex(of: "=") { sessionConfig.extraEnvironment[String(kv[..<eq])] = String(kv[kv.index(after: eq)...]) }
    default: emit("abyss-loginstub: unknown option '\(a)'"); exit(2)
    }
}
guard !socketPath.isEmpty, !passwordFile.isEmpty, let f = fopen(passwordFile, "r") else {
    emit("usage: abyss-loginstub --socket PATH --password-file FILE"); exit(2)
}
var secret: [UInt8] = []
while true { let c = fgetc(f); if c == EOF || c == 10 { break }; secret.append(UInt8(c)) }
fclose(f)

signal(SIGPIPE, SIG_IGN)
let server: Current.Server
do { server = try Current.Server(path: socketPath, mode: 0o600) } catch {
    emit("abyss-loginstub: cannot bind \(socketPath): \(error)"); exit(1)
}
emit("loginstub: answering at \(socketPath)")

// Power requests run the real service's path with stand-in commands
// (--acpiconf, --shutdown; by default ones that fail, so nothing is asked of
// this machine by accident).
if commands.acpiconf == PowerCommands().acpiconf { commands.acpiconf = "/nonexistent/acpiconf" }
if commands.shutdown == PowerCommands().shutdown { commands.shutdown = "/nonexistent/shutdown" }
let auth = Authenticator(userName: { uid in
    guard let pw = getpwuid(uid_t(uid)), let n = pw.pointee.pw_name else { return nil }
    return String(cString: n)
}, check: { _, password in password == secret ? .yes : .no("not the stub's password") })
let service = LoginService(server: server, authenticator: auth, commands: commands, log: emit)
service.lockTimeout = lockTimeout
service.systemUID = systemUID
service.greeterUID = greeterUID
if greeter {
    sessionConfig.extraEnvironment["ABYSS_LOGIN_SOCKET"] = socketPath
    if sessionConfig.sessionsAsSelf { service.uidOf = { _ in UInt32(geteuid()) } }
    service.sessions = SessionManager(config: sessionConfig, log: emit)
}
service.run()
