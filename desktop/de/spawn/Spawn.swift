// Spawn — start programs safely: detached, or run to completion with its
// output (BACKLOG S.2 and S.3).
//
// **After `fork` a child may only make async-signal-safe calls** until it execs:
// the parent may have been holding the allocator's lock, or stdio's, at the
// instant of the fork, and the child inherits the lock held by a thread that
// does not exist in it. One `malloc` there and the child hangs for ever
// (HANDOFF §2.25). So everything is built in the parent — the absolute path,
// the C argv — and the child calls only `fork`, `setsid`, `execve` and `_exit`.
//
// `undertow`'s keybinds broke this rule: its child `strdup`ed every word, bridged
// a Swift `String` for the path, and searched `PATH` inside `execvp`, which is
// not on POSIX's async-signal-safe list. `Launcher` and `anchor` each got it
// right with a copy of their own; this target exists so there is one to share,
// and it depends on nothing so a supervisor or a compositor can take it without
// the toolkit.
//
// **S.3 found the same mistake three more times**: the installer's step runner
// (which runs as root), its machine probe, and `fathom` each built argv inside
// the child. So running a program *for its output* lives here too, and does not
// fork in Swift at all: `run` uses `posix_spawn`, whose child is libc's.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Spawn {
    /// Turn a command into an absolute executable path: used as-is when it
    /// contains a slash, otherwise searched along `path` (default `$PATH`).
    /// nil when nothing executable is found. Called in the parent, so the child
    /// never searches — and never needs `execvpe`, which FreeBSD does not have.
    public static func resolveExecutable(_ command: String, path: String? = nil) -> String? {
        guard !command.isEmpty else { return nil }
        if command.contains("/") { return isExecutableFile(command) ? command : nil }
        let search = path ?? getenv("PATH").map { String(cString: $0) } ?? "/usr/bin:/bin"
        for dir in search.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = dir.hasSuffix("/") ? "\(dir)\(command)" : "\(dir)/\(command)"
            if isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    /// Run `argv` detached: in a new session, reparented to init, never ours
    /// to reap — a compositor that collected a zombie every time someone
    /// pressed a volume key would leak slowly and nobody would know why.
    /// Returns false when the program cannot be found or `fork` fails; an
    /// `exec` that fails in the grandchild exits 127, unseen, as a launcher's
    /// always does.
    /// `environment` is added to (and overrides) this process's.
    @discardableResult
    public static func detached(_ argv: [String], environment: [String: String] = [:]) -> Bool {
        guard let first = argv.first, let exe = resolveExecutable(first) else { return false }

        // Everything the child will touch, allocated here.
        var args: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        args.append(nil)
        var env: [UnsafeMutablePointer<CChar>?] = environmentBlock(adding: environment)
            .map { strdup($0) }
        env.append(nil)
        let path = strdup(exe)
        defer {
            for p in args { free(p) }
            for p in env { free(p) }
            free(path)
        }

        // The pointers are taken before the fork too: after it, the child runs
        // nothing of Swift's — no array access, no bridging — only C calls.
        return args.withUnsafeMutableBufferPointer { a -> Bool in
          env.withUnsafeMutableBufferPointer { e -> Bool in
            let argvp = a.baseAddress!, envp = e.baseAddress!
            let middle = fork()
            if middle < 0 { return false }
            if middle == 0 {
                // The middle child forks again and leaves, so the grandchild is
                // reparented to init and nobody here ever has to wait for it.
                if fork() == 0 {
                    _ = setsid()
                    _ = execve(path!, argvp, envp)
                    _exit(127)
                }
                _exit(0)
            }
            // The middle child exits at once; reap it, through signals.
            var status: Int32 = 0
            while waitpid(middle, &status, 0) < 0 && errno == EINTR {}
            return true
          }
        }
    }

    // MARK: - Running a program for its output

    /// Where a child's stderr goes.
    public enum ErrorOutput: Sendable {
        /// Captured on its own, in `Result.stderr` — to quote, never to parse.
        case capture
        /// Into the same pipe as stdout, in order, in `Result.stdout`.
        case merge
        /// Left as ours.
        case inherit
    }

    /// What a finished program left behind.
    public struct Result: Sendable {
        /// The raw `waitpid` status, or nil when it never ran.
        public let rawStatus: Int32?
        public let stdout: [UInt8]
        public let stderr: [UInt8]
        /// Why it never ran, when it did not.
        public let failure: String?

        /// Its exit code, if it exited rather than being killed.
        public var exitCode: Int32? {
            guard let s = rawStatus, s & 0x7f == 0 else { return nil }
            return (s >> 8) & 0xff
        }
        /// The signal that killed it, if one did.
        public var signal: Int32? {
            guard let s = rawStatus, s & 0x7f != 0 else { return nil }
            return s & 0x7f
        }
        /// One number, the shell's convention: the exit code, 128 + a
        /// signal, 127 when the program was not found, -1 when it could not
        /// be started at all.
        public var code: Int32 {
            if let e = exitCode { return e }
            if let g = signal { return 128 + g }
            return failure?.hasSuffix(": not found") == true ? 127 : -1
        }
        public var succeeded: Bool { exitCode == 0 }
        public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Run `argv` to completion and collect what it printed.
    ///
    /// - stdin is `input` when given, `/dev/null` otherwise — a program that
    ///   decides to ask a question must not hang its caller on a terminal
    ///   nobody is looking at;
    /// - input, stdout and stderr are serviced by **one `poll` loop**, so a
    ///   child that fills one pipe while its parent waits on another cannot
    ///   deadlock them both (`fathom` read stdout to the end before stderr);
    /// - the first `limit` bytes of each stream are kept and **the rest is
    ///   read and dropped**, so a chatty program runs to its real end rather
    ///   than dying of SIGPIPE with a misleading status (the installer closed
    ///   the pipe at 8 KiB);
    /// - SIGPIPE is blocked while writing input, so a child that exits
    ///   without reading cannot kill the caller.
    public static func run(_ argv: [String], input: [UInt8]? = nil,
                           stderr errors: ErrorOutput = .capture,
                           environment: [String: String] = [:],
                           limit: Int = 1 << 20) -> Result {
        func never(_ why: String) -> Result {
            Result(rawStatus: nil, stdout: [], stderr: [], failure: why)
        }
        guard let first = argv.first else { return never("empty command") }
        guard let exe = resolveExecutable(first) else { return never("\(first): not found") }

        var outP: [Int32] = [-1, -1], errP: [Int32] = [-1, -1], inP: [Int32] = [-1, -1]
        func closeAll() { for fd in outP + errP + inP where fd >= 0 { close(fd) } }
        guard pipe(&outP) == 0 else { return never("pipe: \(errnoText())") }
        if errors == .capture, pipe(&errP) != 0 { closeAll(); return never("pipe: \(errnoText())") }
        if input != nil, pipe(&inP) != 0 { closeAll(); return never("pipe: \(errnoText())") }
        // Our ends must not leak into the child (or into anything else we
        // start meanwhile); dup2 clears the flag on the child's copies.
        for fd in outP + errP + inP where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        // A struct on Linux, a pointer on FreeBSD.
        #if os(Linux)
        var fa = posix_spawn_file_actions_t()
        #else
        var fa: posix_spawn_file_actions_t? = nil
        #endif
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        if inP[0] >= 0 {
            posix_spawn_file_actions_adddup2(&fa, inP[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fa, outP[1], 1)
        switch errors {
        case .capture: posix_spawn_file_actions_adddup2(&fa, errP[1], 2)
        case .merge:   posix_spawn_file_actions_adddup2(&fa, outP[1], 2)
        case .inherit: break
        }

        var pid: pid_t = 0
        // posix_spawn's argv is `char *const []`; the strings are ours and it
        // does not write them, so the const-ness is only in the spelling.
        let rc = withCStrings(argv) { a in
            withCStrings(environmentBlock(adding: environment)) { e in
                posix_spawn(&pid, exe, &fa, nil,
                            UnsafeRawPointer(a).assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self),
                            UnsafeRawPointer(e).assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self))
            }
        }
        // The child's ends are the child's now.
        for fd in [outP[1], errP[1], inP[0]] where fd >= 0 { close(fd) }
        guard rc == 0 else {
            for fd in [outP[0], errP[0], inP[1]] where fd >= 0 { close(fd) }
            return never("\(exe): \(String(cString: strerror(rc)))")
        }

        var out: [UInt8] = [], err: [UInt8] = []
        pump(read: outP[0], errP[0], into: &out, &err, limit: limit,
             write: inP[1], input: input ?? [])

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return Result(rawStatus: status, stdout: out, stderr: err, failure: nil)
    }

    /// The loop: write `input`, read both streams, until both are at EOF.
    /// Every descriptor passed in is closed by the time it returns.
    private static func pump(read outFd: Int32, _ errFd: Int32,
                             into out: inout [UInt8], _ err: inout [UInt8], limit: Int,
                             write inFd: Int32, input: [UInt8]) {
        var outFd = outFd, errFd = errFd, inFd = inFd
        var written = 0
        if inFd >= 0 && input.isEmpty { close(inFd); inFd = -1 }

        // SIGPIPE, blocked for this thread while we write; a pipe the child
        // closed early is then EPIPE, and any SIGPIPE it raised is consumed
        // before the old mask is put back.
        var block = sigset_t(), old = sigset_t()
        sigemptyset(&block); sigaddset(&block, SIGPIPE)
        var wasPending = sigset_t()
        sigpending(&wasPending)
        let pipeWasPending = sigismember(&wasPending, SIGPIPE) == 1
        pthread_sigmask(SIG_BLOCK, &block, &old)
        defer {
            var pending = sigset_t()
            sigpending(&pending)
            if !pipeWasPending && sigismember(&pending, SIGPIPE) == 1 {
                var zero = timespec(tv_sec: 0, tv_nsec: 0)
                _ = sigtimedwait(&block, nil, &zero)
            }
            pthread_sigmask(SIG_SETMASK, &old, nil)
        }

        var chunk = [UInt8](repeating: 0, count: 16384)
        func drain(_ fd: inout Int32, into buf: inout [UInt8]) {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let keep = min(n, max(0, limit - buf.count))
                if keep > 0 { buf.append(contentsOf: chunk[0..<keep]) }
            } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                close(fd); fd = -1
            }
        }

        while outFd >= 0 || errFd >= 0 {
            var fds: [pollfd] = []
            if outFd >= 0 { fds.append(pollfd(fd: outFd, events: Int16(POLLIN), revents: 0)) }
            if errFd >= 0 { fds.append(pollfd(fd: errFd, events: Int16(POLLIN), revents: 0)) }
            if inFd >= 0 { fds.append(pollfd(fd: inFd, events: Int16(POLLOUT), revents: 0)) }
            let r = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), -1) }
            if r < 0 { if errno == EINTR { continue }; break }
            for p in fds where p.revents != 0 {
                if p.fd == outFd { drain(&outFd, into: &out) }
                else if p.fd == errFd { drain(&errFd, into: &err) }
                else if p.fd == inFd {
                    let n = input.withUnsafeBytes {
                        write(inFd, $0.baseAddress! + written, min(input.count - written, 16384))
                    }
                    if n > 0 { written += n }
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 || written >= input.count { close(inFd); inFd = -1 }
                }
            }
        }
        for fd in [outFd, errFd, inFd] where fd >= 0 { close(fd) }
    }

    // MARK: - C string arrays

    /// A NULL-terminated C string array, valid for the duration of `body` —
    /// for `execve`, `posix_spawn` and `cproc`. `strdup` because every pointer
    /// must be live at once: a pointer taken inside `withCString` is not valid
    /// after that closure returns, so the obvious `map` over borrowed buffers
    /// is undefined behaviour, however plausible it looks. **Never call this
    /// between `fork` and `exec`** — it allocates.
    public static func withCStrings<R>(_ strings: [String],
                                       _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { for p in ptrs { free(p) } }
        ptrs.append(nil)
        return ptrs.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self,
                                               capacity: buf.count) { body($0) }
        }
    }

    /// `environ` as `KEY=VALUE` strings, with `extra` added or overriding.
    public static func environmentBlock(adding extra: [String: String] = [:]) -> [String] {
        var out: [String] = []
        var i = 0
        while let entry = environ[i] {
            let s = String(cString: entry)
            let key = String(s.prefix(while: { $0 != "=" }))
            if extra[key] == nil { out.append(s) }
            i += 1
        }
        for k in extra.keys.sorted() { out.append("\(k)=\(extra[k]!)") }
        return out
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }

    private static func isExecutableFile(_ p: String) -> Bool {
        var st = stat()
        guard stat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(p, X_OK) == 0
    }
}
