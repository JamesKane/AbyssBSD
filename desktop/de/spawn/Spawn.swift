// Spawn — start a program and forget it, safely (BACKLOG S.2, the first of S.3).
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
    @discardableResult
    public static func detached(_ argv: [String]) -> Bool {
        guard let first = argv.first, let exe = resolveExecutable(first) else { return false }

        // Everything the child will touch, allocated here.
        var args: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        args.append(nil)
        let path = strdup(exe)
        defer {
            for p in args { free(p) }
            free(path)
        }

        // The pointer is taken before the fork too: after it, the child runs
        // nothing of Swift's — no array access, no bridging — only C calls.
        return args.withUnsafeMutableBufferPointer { a -> Bool in
            let argvp = a.baseAddress!
            let middle = fork()
            if middle < 0 { return false }
            if middle == 0 {
                // The middle child forks again and leaves, so the grandchild is
                // reparented to init and nobody here ever has to wait for it.
                if fork() == 0 {
                    _ = setsid()
                    _ = execve(path!, argvp, environ)
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

    private static func isExecutableFile(_ p: String) -> Bool {
        var st = stat()
        guard stat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(p, X_OK) == 0
    }
}
