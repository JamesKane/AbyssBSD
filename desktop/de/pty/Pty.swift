// Pty — a program on a pseudo-terminal (PHASE15 P15.4a).
//
// The shell under Terminal: started on the slave side as its controlling
// terminal, talked to through the master. The fork-and-exec half is C
// (`ap_pty_spawn`) so the child makes only async-signal-safe calls, as `Spawn`
// requires everywhere (HANDOFF §2.25); this is the Swift side — the argv and
// environment built before the fork, reads and writes on the master, the
// window size, and reaping the child.

import CPlatform
import Spawn

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class Pty {
    /// The master side: non-blocking, close-on-exec.
    public let fd: Int32
    public let pid: pid_t
    public private(set) var exitStatus: Int32?

    /// What a terminal says it is (PHASE15 §6.4): `xterm`, which claims less
    /// than `xterm-256color` does, until the parser is measured against vttest.
    public static let term = "xterm"

    /// Start `argv` on a new pseudo-terminal of `rows` × `cols`. `environment`
    /// is added to this process's, after `TERM`.
    public init?(_ argv: [String], rows: Int, cols: Int, environment: [String: String] = [:]) {
        guard let first = argv.first, let exe = Spawn.resolveExecutable(first) else { return nil }
        var env = ["TERM": Pty.term, "COLUMNS": String(cols), "LINES": String(rows)]
        env.merge(environment) { $1 }
        var args: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = Spawn.environmentBlock(adding: env).map { strdup($0) } + [nil]
        defer { for p in args { free(p) }; for p in envp { free(p) } }
        var master: Int32 = -1
        let child = args.withUnsafeMutableBufferPointer { a in
            envp.withUnsafeMutableBufferPointer { e in
                ap_pty_spawn(exe, a.baseAddress, e.baseAddress,
                             UInt16(clamping: rows), UInt16(clamping: cols), &master)
            }
        }
        guard child > 0 else { return nil }
        fd = master
        pid = pid_t(child)
    }

    deinit {
        close(fd)
        if exitStatus == nil {
            kill(pid, SIGHUP)                 // what closing a terminal window says
            var st: Int32 = 0
            _ = waitpid(pid, &st, WNOHANG)
        }
    }

    /// Everything readable now; empty when there is nothing, nil at end of
    /// file (the program and everything it started have closed the terminal).
    public func read() -> [UInt8]? {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = buf.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { out.append(contentsOf: buf[0..<n]); continue }
            if n == 0 { return out.isEmpty ? nil : out }
            if errno == EINTR { continue }
            // EAGAIN: nothing more now. EIO: Linux's end of file on a master
            // whose slave has closed.
            if errno == EIO && out.isEmpty { return nil }
            return out
        }
    }

    /// Write all of `bytes`, waiting for room if the program is slow to read.
    @discardableResult
    public func write(_ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Glibc.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { off += n; continue }
            if n < 0 && (errno == EINTR) { continue }
            if n < 0 && errno == EAGAIN {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 100)
                continue
            }
            return false
        }
        return true
    }

    public func write(_ s: String) { write(Array(s.utf8)) }

    public func resize(rows: Int, cols: Int) {
        _ = ap_pty_resize(fd, UInt16(clamping: rows), UInt16(clamping: cols))
    }

    /// Wait up to `timeoutMs` for output.
    public func wait(timeoutMs: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, timeoutMs) > 0
    }

    /// Reap the child if it has exited; its status, once it has.
    @discardableResult
    public func reap() -> Int32? {
        if let s = exitStatus { return s }
        var st: Int32 = 0
        if waitpid(pid, &st, WNOHANG) == pid { exitStatus = st }
        return exitStatus
    }
}
