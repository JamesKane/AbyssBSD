// Sessions — the login window's second job (PHASE16 P16.5b), greetd's shape.
//
// While nobody is logged in, the root daemon runs the **greeter session** —
// `abyss-session` in greeter mode (undertow and the Aqua login window) — as
// the login window's account, `_loginwindow`. When the window's `login` is
// accepted, the greeter is ended and **that person's session** started:
// `abyss-session` as them (`setusercontext(LOGIN_SETALL)` through
// `ap_child_spawn_as`), in their own runtime directory, with a login's
// environment. When their session ends — Log Out — the greeter comes back.
//
// One session at a time, and the greeter is gone before the person's starts:
// on metal both want the display, and two compositors on one GPU is neither.

import CProc

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class SessionManager {
    public struct Config: Sendable {
        /// The session program: the greeter's and everyone's.
        public var command = "/usr/local/libexec/abyss-session"
        public var greeterUser = Login.greeterUser
        /// Where runtime directories go: `<root>/abyss-<user>`.
        public var runtimeRoot = "/var/run"
        /// Where each session's output goes: `<dir>/abyss-session-<user>.log`.
        public var logDirectory = "/var/log"
        public var path = "/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"
        /// Passed to every session as well (a test's stand-in daemon socket).
        public var extraEnvironment: [String: String] = [:]
        public init() {}
    }

    public enum Who: Equatable, Sendable { case greeter, user(String) }

    private let config: Config
    private let say: (String) -> Void
    private var child = ap_child(fd: -1, pid: -1)
    public private(set) var running: Who?
    private var greeterFailures: [Double] = []

    public init(config: Config = Config(), log: @escaping (String) -> Void) {
        self.config = config
        self.say = log
    }

    /// The descriptor to poll: readable when the running session has ended.
    public var childFD: Int32? { child.fd >= 0 ? child.fd : nil }

    static func seconds() -> Double {
        var ts = timespec(); clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    // MARK: Starting

    public func startGreeter() {
        guard running == nil else { return }
        if start(user: config.greeterUser, mode: "greeter") { running = .greeter }
    }

    /// The login window accepted `user`: end the greeter, start theirs.
    public func login(_ user: String) {
        guard running == .greeter else {
            say("sessions: a login for \(user) with no login window showing — ignored")
            return
        }
        endRunning(because: "\(user) logged in")
        if start(user: user, mode: "desktop") { running = .user(user) }
        else { startGreeter() }
    }

    /// The runtime directory, the environment, and the spawn, as `user`.
    private func start(user: String, mode: String) -> Bool {
        guard let pw = getpwnam(user) else { say("sessions: no account \(user)"); return false }
        let uid = pw.pointee.pw_uid, gid = pw.pointee.pw_gid
        let home = String(cString: pw.pointee.pw_dir)
        let shell = String(cString: pw.pointee.pw_shell)
        // **The runtime directory is made here, because the session cannot**:
        // /var/run is root's (HANDOFF's abyss_desktop note). Theirs, 0700.
        let dir = config.runtimeRoot + "/abyss-" + user
        _ = mkdir(dir, 0o700)
        if geteuid() == 0 { _ = chown(dir, uid, gid) }
        _ = chmod(dir, 0o700)
        var st = stat()
        guard stat(dir, &st) == 0, st.st_uid == uid else {
            say("sessions: \(dir) is not \(user)'s — not starting a session there"); return false
        }
        var env: [String: String] = [
            "HOME": home, "USER": user, "LOGNAME": user, "SHELL": shell, "PATH": config.path,
            "ABYSS_RUNTIME_DIR": dir, "XDG_RUNTIME_DIR": dir, "ABYSS_SESSION_MODE": mode,
        ]
        for (k, v) in config.extraEnvironment { env[k] = v }
        let log = config.logDirectory + "/abyss-session-" + user + ".log"
        let out = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        if out >= 0, geteuid() == 0 { _ = fchown(out, uid, gid) }
        defer { if out >= 0 { close(out) } }
        let argv = [config.command]
        let envp = env.map { "\($0.key)=\($0.value)" }.sorted()
        var c = ap_child(fd: -1, pid: -1)
        let rc = withCStrings(argv) { a in withCStrings(envp) { e in ap_child_spawn_as(user, a, e, out, &c) } }
        guard rc == 0 else {
            say("sessions: could not start \(mode == "greeter" ? "the login window" : "\(user)'s session"): "
                + String(cString: strerror(errno)))
            return false
        }
        child = c
        say("sessions: " + (mode == "greeter" ? "the login window is up, as \(user)"
                                             : "\(user)'s session started (uid \(uid), \(dir))"))
        return true
    }

    private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        ptrs.append(nil)
        defer { for p in ptrs { free(p) } }
        return ptrs.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { body($0) }
        }
    }

    // MARK: Ending

    /// Ask the running session to end, and wait for it: SIGTERM, five
    /// seconds, then SIGKILL. anchor takes its whole session down on SIGTERM.
    private func endRunning(because why: String) {
        guard child.fd >= 0 else { return }
        say("sessions: ending \(running == .greeter ? "the login window" : "the session") — \(why)")
        _ = ap_child_signal(&child, SIGTERM)
        var p = pollfd(fd: child.fd, events: Int16(ap_child_exit_events() | POLLHUP | POLLIN), revents: 0)
        if poll(&p, 1, 5000) <= 0 {
            say("sessions: it did not end in 5 s — killing it")
            _ = ap_child_signal(&child, SIGKILL)
            _ = poll(&p, 1, 2000)
        }
        _ = ap_child_reap(&child, nil)
        running = nil
    }

    /// The running session ended by itself.
    public func childExited() {
        let was = running
        _ = ap_child_reap(&child, nil)
        running = nil
        switch was {
        case .user(let u)?:
            say("sessions: \(u) logged out — the login window again")
            startGreeter()
        case .greeter?:
            let now = SessionManager.seconds()
            greeterFailures = greeterFailures.filter { now - $0 < 60 } + [now]
            guard greeterFailures.count <= 5 else {
                say("sessions: the login window died \(greeterFailures.count) times in a minute — giving up")
                return
            }
            say("sessions: the login window ended — starting it again (\(greeterFailures.count)/5)")
            startGreeter()
        case nil:
            break
        }
    }

    /// The daemon is stopping: end whatever runs.
    public func shutdown() { endRunning(because: "the daemon is stopping") }
}
