// abyssctl — drive a running session over the control plane.
//
// The client half of the brokerless design (docs/PLAN.md goal #3): no bus, no
// daemon to ask — connect straight to the service's socket in the session's
// runtime directory. Deferred here from P3.5, which had no service to control.
//
//   abyssctl status              is the session up, and what is it running?
//   abyssctl quit                tear the session down
//   abyssctl lock                lock the screen (PHASE16 P16.2c)
//   abyssctl --service NAME ...  talk to some other service (default: anchor)

import CurrentIPC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}

func fail(_ msg: String) -> Never {
    emit(2, "abyssctl: \(msg)")
    exit(1)
}

var service = "anchor"
var method: String?
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--service":
        i += 1
        guard i < args.count else { fail("--service needs a name") }
        service = args[i]
    case "-h", "--help":
        emit(1, "usage: abyssctl [--service NAME] status|quit|lock")
        exit(0)
    default:
        guard method == nil else { fail("one method at a time (got '\(args[i])' too)") }
        method = args[i]
    }
    i += 1
}

guard let method else {
    emit(2, "usage: abyssctl [--service NAME] status|quit|lock")
    exit(2)
}

var request = Msg()
request.set("method", method)

do {
    let reply = try Current.call(service, request)
    guard reply.bool("ok") == true else {
        fail(reply.string("error") ?? "the service said no")
    }
    switch method {
    case "status":
        emit(1, "session: running")
        emit(1, "components: \(reply.uint64("components") ?? 0)")
        // The lock (P16.2c/P16.3): "locked" only once the compositor said so.
        emit(1, "lock: " + (reply.bool("locked") == true ? "locked" : reply.bool("locking") == true ? "locking" : "no"))
        if let detail = reply.string("detail"), !detail.isEmpty {
            for part in detail.split(separator: ",") { emit(1, "  \(part)") }
        }
        // The session's own bus, so "which bus is this desktop on" has an answer
        // that does not involve reading a log or guessing a path.
        if let bus = reply.string("bus"), !bus.isEmpty {
            emit(1, "bus: \(bus)")
        }
    case "quit", "shutdown":
        emit(1, "session: shutting down")
    case "lock":
        emit(1, reply.bool("already") == true ? "session: already locked" : "session: locking")
    default:
        emit(1, "ok")
    }
} catch {
    // The common case by far is "nothing is running", so say that rather than
    // printing a raw errno at someone.
    if case CurrentError.system(let e, _) = error, e == ENOENT || e == ECONNREFUSED {
        fail("no '\(service)' service — is the session running? "
             + "(runtime dir: \((try? Current.runtimeDir()) ?? "?"))")
    }
    fail("\(error)")
}
