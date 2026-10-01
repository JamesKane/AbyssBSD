// abyss-loginstub — a stand-in authenticator, for tests only (PHASE16 P16.2b).
//
//     abyss-loginstub --socket PATH --password-file FILE
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
var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--socket": socketPath = args.isEmpty ? "" : args.removeFirst()
    case "--password-file": passwordFile = args.isEmpty ? "" : args.removeFirst()
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

func now() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}

var auth = Authenticator(userName: { uid in
    guard let pw = getpwuid(uid_t(uid)), let n = pw.pointee.pw_name else { return nil }
    return String(cString: n)
}, check: { _, password in password == secret ? .yes : .no("not the stub's password") })
while true {
    guard let client = try? server.accept() else { continue }
    let uid = loginPeerUID(client)
    if let request = try? Current.receive(on: client) {
        let (reply, line) = auth.handle(uid: uid, request: request, now: now())
        try? Current.send(reply, on: client)
        emit("loginwindow: \(line)")
    }
    close(client)
}
