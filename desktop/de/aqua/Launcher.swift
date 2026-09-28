// Launcher — what happens when you double-click something that isn't a folder.
//
// Three cases, in the order the Finder tries them:
//   1. an **application bundle** (`Foo.app`) → run `Foo.app/Contents/MacOS/Foo`,
//      the Mac convention (falling back to the first executable in that folder);
//   2. a plain **executable file** → run it;
//   3. anything else → hand the path to the **opener command**
//      (`$ABYSS_OPEN`, else `open_command` in `finder.ini`), if one is set.
// With no handler, nothing runs and the caller says so — a double-click that
// silently does nothing is worse than one that reports why.
//
// Processes are started **detached**: fork → fork → `execve`, with the parent
// reaping the middle child immediately, so the grandchild is reparented to init
// and this process never accumulates zombies (we have no SIGCHLD handler and the
// run loop must not block in waitpid). Everything the child needs — argv, envp,
// the resolved absolute path — is built *before* the fork, so the child only
// makes async-signal-safe calls. The real session supervisor is FreeBSD's
// `anchor` (pdfork + kqueue) in Phase 3; this is the Linux-dev stand-in.

import PoolConfig
import Spawn
import CPlatform

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What a double-click did.
public enum LaunchOutcome: Equatable, Sendable {
    case launchedApp(String)        // an .app bundle's executable
    case ranExecutable(String)      // a plain executable file
    case openedWith(String)         // handed to the opener command
    case noHandler                  // nothing knows how to open it
    case failed(String)             // we tried and the exec/fork failed

    /// A short line for the log (the live tests assert on these).
    public var description: String {
        switch self {
        case .launchedApp(let p):   return "launched \(p)"
        case .ranExecutable(let p): return "ran \(p)"
        case .openedWith(let c):    return "opened with \(c)"
        case .noHandler:            return "no handler"
        case .failed(let why):      return "launch failed: \(why)"
        }
    }
}

public enum Launcher {
    // MARK: - Resolution (pure enough to test)

    /// Whether `path` is a regular file with any execute bit set.
    public static func isExecutableFile(_ path: String) -> Bool {
        var st = stat()
        guard path.withCString({ stat($0, &st) == 0 }) else { return false }
        let mode = UInt32(st.st_mode)
        return (mode & 0o170000) == 0o100000 && (mode & 0o111) != 0
    }

    /// The executable inside an application bundle: `Foo.app/Contents/MacOS/Foo`
    /// by the Mac convention, else the first executable in `Contents/MacOS`.
    public static func bundleExecutable(_ bundlePath: String) -> String? {
        let macOS = finderJoin(bundlePath, "Contents/MacOS")
        let name = finderDisplayName(bundlePath)
        let stem = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        let conventional = finderJoin(macOS, stem)
        if isExecutableFile(conventional) { return conventional }
        for entry in readDirectory(macOS, showHidden: false) {
            let candidate = finderJoin(macOS, entry.name)
            if isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    /// The opener command line, split on spaces: `$ABYSS_OPEN`, else
    /// `finder.ini`'s `open_command`. Empty/unset means "no handler".
    public static func openerCommand() -> [String] {
        if let e = getenv("ABYSS_OPEN") {
            let s = String(cString: e)
            if !s.isEmpty { return splitCommand(s) }
        }
        let config = (try? Pool.load("finder")) ?? Config()
        guard let s = config.string("finder", "open_command"), !s.isEmpty else {
            return []
        }
        return splitCommand(s)
    }

    /// Split a command line on runs of spaces/tabs. No quoting: a launcher
    /// config with embedded spaces in one argument would need a real parser, and
    /// pretending otherwise would silently mangle it.
    public static func splitCommand(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// This process's own executable — how the Dock launches another copy of the
    /// shell. `$ABYSS_APP_BINARY` overrides; otherwise `CPlatform` answers,
    /// since the mechanism is per-OS (`/proc/self/exe` on Linux, the
    /// `KERN_PROC_PATHNAME` sysctl on FreeBSD, which has no procfs mounted by
    /// default — and Swift's libc module surfaces no `<sys/sysctl.h>`).
    public static func selfExecutable() -> String? {
        if let e = getenv("ABYSS_APP_BINARY") {
            let s = String(cString: e)
            if isExecutableFile(s) { return s }
        }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer {
            ap_self_executable($0.baseAddress!, $0.count)
        }
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Opening

    /// Decide what to do with `path` and do it.
    @discardableResult
    public static func open(_ path: String) -> LaunchOutcome {
        if path.hasSuffix(".app"), finderIsDirectory(path) {
            guard let exe = bundleExecutable(path) else {
                return .failed("\(path) has no executable in Contents/MacOS")
            }
            return launchDetached([exe]) ? .launchedApp(exe)
                                         : .failed("could not start \(exe)")
        }
        if isExecutableFile(path) {
            return launchDetached([path]) ? .ranExecutable(path)
                                          : .failed("could not start \(path)")
        }
        let opener = openerCommand()
        guard !opener.isEmpty else { return .noHandler }
        let argv = opener + [path]
        return launchDetached(argv) ? .openedWith(opener.joined(separator: " "))
                                    : .failed("could not run \(opener[0])")
    }

    // MARK: - Spawning

    /// Start `argv` detached from this process: its own session, reaped by
    /// init. Returns false if the command can't be resolved or the fork fails.
    /// The fork itself is `Spawn`'s — one async-signal-safe copy for the
    /// Finder, the Dock, the menu bar and the compositor's keybinds (S.3).
    @discardableResult
    public static func launchDetached(_ argv: [String],
                                      extraEnv: [String: String] = [:]) -> Bool {
        Spawn.detached(argv, environment: extraEnv)
    }
}
