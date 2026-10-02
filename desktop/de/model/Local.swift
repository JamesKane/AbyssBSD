// LocalServer — llama.cpp's `llama-server`, run by `abyss-model` (PHASE18 P18.7b).
//
// The local backend is not ours to write ("we do not write an inference
// engine"); running it is. `abyss-model` starts `llama-server` as its own
// supervised child, outside any jail:
//
//   - it listens on **a unix socket** in a 0700 directory of abyss-model's,
//     never on a TCP port, so nothing else on the machine — no other user, no
//     jail with a network — can reach the model except through abyss-model,
//     its budget and its transcript;
//   - abyss-model is ready only once the server answers /health with 200
//     (loading a model takes seconds to minutes), and gives up, with the
//     server's own last words, if it exits first;
//   - the child dies with abyss-model: on FreeBSD it is a process descriptor
//     without PD_DAEMON, so the kernel kills it when abyss-model goes, however
//     abyss-model goes.

import CProc

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class LocalServer {
    public let socket: String
    public let log: String
    public private(set) var child: ap_child
    public private(set) var exited: Int32?

    /// The argv for `llama-server`: the model, the socket, tool calling
    /// (`--jinja`, the model's own chat template), no web UI, every layer on
    /// the GPU that will take it (`-ngl 999`; with no GPU, none are), and
    /// **one slot** (`-np 1`): a session is one client asking one thing at a
    /// time, and the default four slots cost VRAM the desktop needs (on the
    /// 6750 XT, Granite 8B Q8 at 16K context left 775 MiB free with four).
    public static func argv(server: String, model: String, socket: String, context: Int, extra: [String]) -> [String] {
        [server, "-m", model, "--host", socket, "--jinja", "--no-webui", "-ngl", "999",
         "-c", String(context), "-np", "1", "--offline"] + extra
    }

    /// Start it and wait until it is healthy, or throw with why not.
    public init(server: String, model: String, dir: String, context: Int = 16384, extra: [String] = [],
                waitSeconds: Int = 600) throws {
        guard access(model, R_OK) == 0 else { throw HTTP.Failure("cannot read the model \(model)") }
        guard server.hasPrefix("/"), access(server, X_OK) == 0 else { throw HTTP.Failure("cannot run \(server)") }
        guard mkdir(dir, 0o700) == 0 || errno == EEXIST else { throw HTTP.Failure("mkdir \(dir): \(String(cString: strerror(errno)))") }
        chmod(dir, 0o700)
        socket = dir + "/llama.sock"
        log = dir + "/llama-server.log"
        unlink(socket)
        let fd = open(log, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HTTP.Failure("open \(log): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var env: [String] = []
        var p = environ
        while let e = p.pointee { env.append(String(cString: e)); p += 1 }
        var c = ap_child(fd: -1, pid: 0)
        let argv = LocalServer.argv(server: server, model: model, socket: socket, context: context, extra: extra)
        let rc = argv.withCStringArray { a in env.withCStringArray { e in ap_child_spawn(a, e, fd, &c) } }
        guard rc == 0 else { throw HTTP.Failure("cannot start \(server): \(String(cString: strerror(errno)))") }
        child = c
        let deadline = ModelSession.now() + Double(waitSeconds)
        while true {
            if let why = checkExited() { throw HTTP.Failure("llama-server \(why) before it was ready: \(tail())") }
            if let r = try? HTTP.call(.unix(path: socket), method: "GET", path: "/health", timeoutSeconds: 5), r.status == 200 { break }
            if ModelSession.now() > deadline { stop(); throw HTTP.Failure("llama-server was not ready in \(waitSeconds)s: \(tail())") }
            usleep(200_000)
        }
    }

    /// Nil while it runs; once it has exited, how.
    public func checkExited() -> String? {
        if exited == nil {
            var pfd = pollfd(fd: child.fd, events: Int16(ap_child_exit_events()), revents: 0)
            guard poll(&pfd, 1, 0) > 0 else { return nil }
            var status: Int32 = 0
            _ = ap_child_reap(&child, &status)
            exited = status
        }
        let s = exited!
        return (s & 0x7f) != 0 ? "was killed by signal \(s & 0x7f)" : "exited \((s >> 8) & 0xff)"
    }

    /// The server's last lines, for a failure that should say what it said.
    public func tail(_ n: Int = 3) -> String {
        let fd = open(log, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536)
        while true { let k = read(fd, &buf, buf.count); if k <= 0 { break }; out += buf[0..<k]; if out.count > 1 << 20 { out.removeFirst(out.count - (1 << 19)) } }
        return String(decoding: out, as: UTF8.self).split(separator: "\n").suffix(n).joined(separator: " / ")
    }

    public func stop() {
        guard exited == nil else { return }
        _ = ap_child_signal(&child, SIGTERM)
        for _ in 0..<50 { if checkExited() != nil { break }; usleep(100_000) }
        if exited == nil { _ = ap_child_signal(&child, SIGKILL); var s: Int32 = 0; _ = ap_child_reap(&child, &s); exited = s }
        unlink(socket)
    }
}

/// `llama-server` behind abyss-model: a backend that says so when the server
/// has gone, rather than failing to connect.
public final class LocalBackend: ModelBackend {
    public let name: String
    public let server: LocalServer
    let http: HTTPBackend
    public init(server: LocalServer, model: String) {
        self.server = server
        name = "local:" + (model.split(separator: "/").last.map(String.init) ?? model)
        http = HTTPBackend(socket: server.socket, name: name)
    }
    public func complete(_ request: JSON) throws -> JSON {
        if let why = server.checkExited() { throw HTTP.Failure("llama-server \(why): \(server.tail())") }
        return try http.complete(request)
    }
}

extension Array where Element == String {
    func withCStringArray<R>(_ body: ([UnsafePointer<CChar>?]) -> R) -> R {
        var owned = map { strdup($0) }
        defer { owned.forEach { free($0) } }
        owned.append(nil)
        return body(owned.map { $0.map { UnsafePointer($0) } })
    }
}
