// abyss-portal — host the desktop's `portal` service for a session.
//
//   abyss-portal [--picker PATH] [--once]
//
// Methods (over CurrentIPC, in the session's runtime dir):
//   file.open {dir?}         → {ok, path, mode:"r"} + fd `file`  (O_RDONLY)
//   file.save {dir?, name?}  → {ok, path, mode:"w"} + fd `file`  (O_WRONLY|CREAT)
//   both               → {ok:false, error:"cancelled"} if the user declined.
//
// The requesting app never names the file that gets opened — see
// PortalRequest, where that is enforced by the type.

import CurrentIPC
import Portal

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}

var picker: String?
var once = false
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--picker":
        i += 1
        guard i < args.count else { emit(2, "abyss-portal: --picker needs a path"); exit(2) }
        picker = args[i]
    case "--once":
        once = true
    case "-h", "--help":
        emit(1, "usage: abyss-portal [--picker PATH] [--once]")
        exit(0)
    default:
        emit(2, "abyss-portal: unknown option '\(args[i])'")
        exit(2)
    }
    i += 1
}

// A client that hangs up mid-reply must not kill the portal (HANDOFF §2.33).
signal(SIGPIPE, SIG_IGN)

let service = PortalService(pickerBinary: picker)
let server: Current.Server
do {
    server = try Current.Server(service: "portal")
} catch {
    emit(2, "abyss-portal: cannot bind the portal service: \(error)")
    exit(1)
}
emit(2, "portal: serving \(server.path) (picker: \(service.pickerBinary))")

// One request at a time, on purpose: the picker is a modal dialog, and the
// portal is blocked while the user decides.
var served = 0
while true {
    do {
        let client = try server.accept()
        defer { close(client) }
        var request = try Current.receive(on: client)
        request.closeFDs()          // a request carries no descriptors
        let (reply, fd) = service.handle(PortalRequest(request))
        var out = reply
        if let f = fd { out.set("file", fd: f) }
        try? Current.send(out, on: client)
        // The descriptor was duplicated into the client by SCM_RIGHTS; ours is
        // done. Closing after the send is what keeps the portal from leaking a
        // descriptor per request.
        if let f = fd { close(f) }
        served += 1
        if once { break }
    } catch {
        // One bad client costs that connection and nothing else.
        continue
    }
}
server.shutdownAndUnlink()
emit(2, "portal: served \(served) request(s)")
