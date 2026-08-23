// Anchor — the parts of session supervision that are decisions rather than
// syscalls, kept pure so they can be tested without spawning anything.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What to do when a supervised component exits.
///
/// The rule is `abyss/session.sh`'s, which is the behaviour this component
/// replaces: a component that dies comes back — that is what a supervisor is
/// for — but one that dies *immediately*, over and over, is a broken build, and
/// respawning it forever just fills the log. A run that lasted a while clears
/// the streak, so a component that works for an hour and then crashes gets the
/// full budget again rather than inheriting failures from last week.
public struct RestartPolicy: Equatable, Sendable {
    /// Give up after this many failures **in a row**.
    public let maxConsecutiveFailures: Int
    /// A run at least this long counts as healthy and resets the streak.
    public let healthyRunSeconds: Double

    public init(maxConsecutiveFailures: Int = 5, healthyRunSeconds: Double = 5) {
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.healthyRunSeconds = healthyRunSeconds
    }

    public enum Decision: Equatable, Sendable {
        /// Start it again; `consecutiveFailures` is the streak including this exit.
        case restart(consecutiveFailures: Int)
        /// Stop trying, and tear the session down.
        case giveUp(consecutiveFailures: Int)
    }

    /// Decide, given how long this run lasted and how many failures preceded it.
    public func decide(ranFor: Double, previousFailures: Int) -> Decision {
        // A healthy run wipes the slate; this exit then starts a new streak.
        let failures = ranFor >= healthyRunSeconds ? 1 : previousFailures + 1
        return failures > maxConsecutiveFailures
            ? .giveUp(consecutiveFailures: failures)
            : .restart(consecutiveFailures: failures)
    }
}

/// A monotonic clock, so a wall-clock change (ntp, a VM resuming) can't make a
/// component look like it ran for -3 seconds.
public func monotonicSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}

/// One thing the supervisor starts and keeps alive.
public struct ComponentSpec: Equatable, Sendable {
    /// Short name, used in logs and in the control service's status reply.
    public let name: String
    /// argv, already resolved: argv[0] must be an absolute path, because the
    /// child after fork may not go looking through `$PATH`.
    public let argv: [String]
    /// Environment entries layered over the supervisor's own.
    public let env: [String: String]
    /// Unix sockets that must **accept a connection** before this component is
    /// started — its dependencies, stated as the only thing about them that can
    /// actually be checked.
    ///
    /// A session is not a list of processes, it is processes that *compose*
    /// (HANDOFF §2.26), and the ordering between them is real: the D-Bus bridge
    /// cannot own a name on a bus that is not listening yet. Sleeping instead
    /// would be a race with better manners. Waited on at every start, not only
    /// the first, because a restart has the same dependency the first start had
    /// — and it is the restart, arriving microseconds after the thing it needs
    /// died, that a bring-up-only gate would leave to burn its whole failure
    /// budget in a millisecond.
    public let requires: [String]

    public init(name: String, argv: [String], env: [String: String] = [:],
                requires: [String] = []) {
        self.name = name
        self.argv = argv
        self.env = env
        self.requires = requires
    }
}

/// Merge environment overrides over a base, producing the `KEY=VALUE` array
/// `execve` wants, sorted so a child's environment is reproducible.
public func environmentBlock(base: [String: String], overrides: [String: String]) -> [String] {
    var merged = base
    for (k, v) in overrides { merged[k] = v }
    return merged.keys.sorted().map { "\($0)=\(merged[$0]!)" }
}

/// This process's environment as a dictionary.
public func currentEnvironment() -> [String: String] {
    var out: [String: String] = [:]
    var p = environ           // not optional on Linux; a plain pointer either way
    while let entry = p.pointee {
        let s = String(cString: entry)
        if let eq = s.firstIndex(of: "=") {
            out[String(s[s.startIndex..<eq])] = String(s[s.index(after: eq)...])
        }
        p += 1
    }
    return out
}

/// Split a command string into argv the way a shell would for simple cases.
///
/// Deliberately *not* a shell parser: whitespace separates, and nothing else is
/// interpreted. A command with embedded spaces in one argument needs the
/// repeatable `--component` form instead — pretending to handle quoting here
/// would mangle it silently, which is the same call `Launcher.splitCommand`
/// made (HANDOFF §2.25).
public func splitCommand(_ s: String) -> [String] {
    s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
}

/// Turn a command into an absolute executable path: used as-is when it contains
/// a slash, otherwise searched along `path` (defaults to `$PATH`).
///
/// Resolving here, in the parent, is the same discipline `Launcher` follows for
/// the same reason (HANDOFF §2.25): after the fork a child may only make
/// async-signal-safe calls, and `execvpe` does not exist on FreeBSD. This is a
/// second copy of that logic on purpose — `Anchor` is a supervisor and must not
/// drag in the toolkit (and through it cairo, FreeType and HarfBuzz) to find a
/// binary on `$PATH`.
public func resolveExecutable(_ command: String, path: String? = nil) -> String? {
    guard !command.isEmpty else { return nil }
    func isExecutableFile(_ p: String) -> Bool {
        var st = stat()
        guard p.withCString({ stat($0, &st) == 0 }) else { return false }
        let mode = UInt32(st.st_mode)
        return (mode & 0o170000) == 0o100000 && (mode & 0o111) != 0
    }
    if command.contains("/") {
        return isExecutableFile(command) ? command : nil
    }
    let search = path ?? getenv("PATH").map { String(cString: $0) } ?? "/usr/bin:/bin"
    for dir in search.split(separator: ":", omittingEmptySubsequences: true) {
        let candidate = String(dir) + (dir.hasSuffix("/") ? "" : "/") + command
        if isExecutableFile(candidate) { return candidate }
    }
    return nil
}
