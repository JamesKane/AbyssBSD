// ipcprobe — two real processes, one descriptor.
//
// The unit tests prove the codec and prove SCM_RIGHTS over a socketpair, but the
// first honest test of a *control plane* is a real client against a real service
// in another process (PHASE2.md P2.9 made exactly that argument for deferring
// this component until there was something to talk to). This is the smallest
// thing that does it, and `abyss/tests/live-ipc.sh` drives it.
//
//   ipcprobe serve <service>          bind, handle one request, print what came
//                                     through the descriptor, reply, exit
//   ipcprobe send  <service> <text>   put <text> in a file, hand the *descriptor*
//                                     to the service, print the reply
//
// It is also the tool to reach for when debugging a service by hand later —
// P3.6's supervisor and P3.7's bridges both host one.

import CurrentIPC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func die(_ msg: String) -> Never {
    FileHandleWrite(2, "ipcprobe: \(msg)\n")
    exit(1)
}

/// Write straight to a descriptor: this module is Foundation-free like the rest
/// of `de/`, and `print` to stderr isn't a thing.
func FileHandleWrite(_ fd: Int32, _ s: String) {
    let b = Array(s.utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}

func out(_ s: String) { FileHandleWrite(1, s + "\n") }

/// Read everything readable from a descriptor, from its start.
func readAll(_ fd: Int32) -> [UInt8] {
    _ = lseek(fd, 0, SEEK_SET)
    var all: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, 4096) }
        if n <= 0 { break }
        all += buf[0..<n]
    }
    return all
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    die("usage: ipcprobe serve <service> | ipcprobe send <service> <text>")
}
let mode = args[1]
let service = args[2]

switch mode {
case "serve":
    do {
        let server = try Current.Server(service: service)
        out("serving \(server.path)")
        var replied = false
        try server.serve(while: { replied }) { request in
            var reply = Msg()
            reply.set("ok", true)
            var req = request          // a mutable copy, so we can take the fd out
            if let fd = req.takeFD("buffer") {
                let bytes = readAll(fd)
                close(fd)
                let text = String(decoding: bytes, as: UTF8.self)
                // The proof: this process read the *sender's* file through a
                // descriptor that arrived over the socket.
                out("got fd, contents: \(text)")
                reply.set("echo", text)
                reply.set("bytes", UInt64(bytes.count))
            } else {
                out("got a message with no descriptor")
                reply.set("ok", false)
            }
            replied = true
            return reply
        }
        server.shutdownAndUnlink()
    } catch {
        die("serve failed: \(error)")
    }

case "send":
    guard args.count >= 4 else { die("send needs <text>") }
    let text = args[3]
    // A real descriptor to hand over: a temp file, unlinked at once so only the
    // descriptor keeps it alive — which is how a handed-over shm buffer behaves.
    let tmp = (getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp") + "/ipcprobe-XXXXXX"
    var template = Array(tmp.utf8CString)
    let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
    guard fd >= 0 else { die("mkstemp: \(String(cString: strerror(errno)))") }
    let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    unlink(path)
    let payload = Array(text.utf8)
    _ = payload.withUnsafeBufferPointer { write(fd, $0.baseAddress, payload.count) }

    do {
        var req = Msg()
        req.set("method", "Buffer.Hand")
        req.set("buffer", fd: fd)
        req.set("bytes", UInt64(payload.count))
        let reply = try Current.call(service, req)
        close(fd)
        guard reply.bool("ok") == true else { die("service replied not-ok") }
        out("reply ok, echo: \(reply.string("echo") ?? "")")
        out("reply bytes: \(reply.uint64("bytes") ?? 0)")
    } catch {
        close(fd)
        die("send failed: \(error)")
    }

default:
    die("unknown mode '\(mode)'")
}
