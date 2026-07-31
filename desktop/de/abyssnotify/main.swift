// abyssnotify — post a desktop notification, the brokerless `notify-send`.
//
//     abyssnotify "Build finished"                      # summary only
//     abyssnotify "Build finished" "all tests green"     # summary + body
//     abyssnotify -t 8 "Slow job" "took a while"         # 8-second timeout
//
// It asks the **portal**, which relays to the shell's notification centre — the
// same path a jailed app takes. A sandboxed process never holds the notify
// service's socket, so it can post a toast without being able to reach the shell
// or impersonate it. `--direct` talks to the notify service instead, which is
// what the desktop's own components do.

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
func fail(_ s: String) -> Never { emit(2, "abyssnotify: \(s)"); exit(1) }

var timeout: UInt64?
var direct = false
var positional: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "-t", "--timeout":
        i += 1
        guard i < args.count, let n = UInt64(args[i]), n > 0 else {
            fail("-t wants a number of seconds")
        }
        timeout = n
    case "--direct":
        direct = true
    case "-h", "--help":
        emit(1, "usage: abyssnotify [-t SECONDS] [--direct] <summary> [body]")
        exit(0)
    default:
        positional.append(args[i])
    }
    i += 1
}

guard let summary = positional.first, !summary.isEmpty else {
    emit(2, "usage: abyssnotify [-t SECONDS] [--direct] <summary> [body]")
    exit(2)
}

signal(SIGPIPE, SIG_IGN)

var request = Msg()
request.set("method", "notify")
request.set("summary", summary)
if positional.count > 1 { request.set("body", positional[1]) }
if let t = timeout { request.set("timeout", t) }

let service = direct
    ? ((getenv("ABYSS_NOTIFY_SERVICE").map { String(cString: $0) }) ?? "notify")
    : ((getenv("ABYSS_PORTAL_SERVICE").map { String(cString: $0) }) ?? "portal")

do {
    let reply = try Current.call(service, request)
    guard reply.bool("ok") == true else {
        fail(reply.string("error") ?? "the desktop declined the notification")
    }
    if let id = reply.uint64("id") { emit(1, "posted #\(id)") } else { emit(1, "posted") }
} catch {
    if case CurrentError.system(let e, _) = error, e == ENOENT || e == ECONNREFUSED {
        fail("no '\(service)' service — is the desktop running?")
    }
    fail("\(error)")
}
