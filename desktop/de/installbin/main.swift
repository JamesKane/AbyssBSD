// abyss-install — the installer's privileged half.
//
//   abyss-install [--uid N] [--dry-run] [--once] [--service NAME]
//
// It runs as root, it is commanded by an unprivileged GUI, and it is the only
// program in this tree whose job is to destroy data. Everything about it is
// arranged around that: no toolkit, no display, no network, no event loop, and
// it decides nothing — it is handed a plan, refuses it or compiles it, and runs
// the list (PHASE5 §1).
//
// `--uid` is who may command it. `anchor` knows the session's user and says so;
// on its own it admits only the uid it runs as, which for a root installer means
// root alone. It is never inferred from the socket's permissions, because
// CurrentIPC's own 0700/0600 defaults make a root-owned socket unreachable by
// the caller that must reach it (PHASE5 §4.4).

import CurrentIPC
import Install
import InstallRun

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}

var allowed: UInt32?
var dryRun = false
var once = false
var serviceName = "install"

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--uid":
        i += 1
        guard i < args.count, let n = UInt32(args[i]) else {
            emit(2, "abyss-install: --uid needs a number"); exit(2)
        }
        allowed = n
    case "--dry-run": dryRun = true
    case "--once": once = true
    case "--service":
        i += 1
        guard i < args.count else { emit(2, "abyss-install: --service needs a name"); exit(2) }
        serviceName = args[i]
    case "-h", "--help":
        emit(1, "usage: abyss-install [--uid N] [--dry-run] [--once] [--service NAME]")
        exit(0)
    default:
        emit(2, "abyss-install: unknown option '\(args[i])'")
        exit(2)
    }
    i += 1
}

// A client that hangs up mid-install must not kill us (HANDOFF §2.33) — and here
// it matters more than anywhere else in the tree, because the disk is already
// half-rewritten when it happens.
signal(SIGPIPE, SIG_IGN)

let authority = allowed.map { Authority(allowed: $0) } ?? Authority()
let service = InstallService(authority: authority, dryRun: dryRun)

let server: Current.Server
do {
    server = try Current.Server(service: serviceName)
} catch {
    emit(2, "abyss-install: cannot bind the install service: \(error)")
    exit(1)
}

// **Being allowed to command it has to mean being able to reach it.** The peer
// check answers "is this caller the one I was started for"; it does not get the
// caller through a root-owned 0600 socket in the first place. So the socket is
// opened to exactly the uid named — one uid, by name, rather than the wider mode
// that would hand the installer to every process on the machine.
//
// The two are not redundant. Permissions alone are defeated by anything running
// as root, and the peer check alone grants nobody access; together the socket
// admits one uid and the service then confirms the caller *is* that uid.
if authority.allowed != geteuid() {
    if chown(server.path, uid_t(authority.allowed), gid_t(bitPattern: -1)) != 0 {
        emit(2, "abyss-install: cannot hand \(server.path) to uid"
             + " \(authority.allowed): \(String(cString: strerror(errno)))")
        exit(1)
    }
}

emit(2, "install: serving \(server.path) for uid \(authority.allowed)"
     + (dryRun ? " (dry run — nothing will be written)" : "")
     + (geteuid() == 0 ? "" : " — NOT running as root, so every step will fail"))

// Strictly one connection at a time. There is no version of this program where
// two installs at once is a thing somebody wanted.
while true {
    guard let client = try? server.accept() else { continue }
    let note = service.serve(client) { emit(2, "install: \($0)") }
    emit(2, "install: \(note)")
    close(client)
    if once { break }
}
server.shutdownAndUnlink()
