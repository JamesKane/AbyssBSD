// Sessions — the login window's second job (PHASE16 P16.5b), greetd's shape,
// and fast user switching (P16.6b).
//
// While nobody is logged in, the root daemon runs the **greeter session** —
// `abyss-session` in greeter mode (undertow and the Aqua login window) — as
// the login window's account, `_loginwindow`. When the window's `login` is
// accepted, the greeter is ended and **that person's session** started:
// `abyss-session` as them (`setusercontext(LOGIN_SETALL)` through
// `ap_child_spawn_as`), in their own runtime directory, with a login's
// environment. When their session ends — Log Out — the greeter comes back.
//
// **Fast user switching (P16.6b, §6.4):** sessions run side by side, one in
// front. "Login Window…" in a session asks the daemon to switch; the session
// is **locked first** (its agent, as before a sleep) and stays running behind
// the greeter. At the window, a person who already has a session is taken
// back to it — where their own lock screen asks — and anyone else gets one
// of their own, beside the others.
//
// **One VT each, on metal.** The greeter on VT 9 (ttyv8: FreeBSD's /etc/ttys
// leaves it for a display manager; ttyv0–7 have gettys), people on 10 and up.
// The daemon switches to a session's VT before starting it, so its compositor
// takes that VT through seatd, and switches back to it to bring it to the
// front. The command is an argument: a test records the switches instead.

import CProc

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Which VT each session has: pure, so it is tested without a console.
public struct VTPlan: Equatable, Sendable {
    public static let greeter = 9
    public static let first = 10, last = 16
    public private(set) var assigned: [String: Int] = [:]
    public init() {}

    /// A VT for `user`: theirs if they have one, else the lowest free; nil
    /// when every one is taken.
    public mutating func vt(for user: String) -> Int? {
        if let v = assigned[user] { return v }
        let used = Set(assigned.values)
        guard let v = (VTPlan.first...VTPlan.last).first(where: { !used.contains($0) }) else { return nil }
        assigned[user] = v
        return v
    }
    public mutating func release(_ user: String) { assigned[user] = nil }
}

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
        /// Bring VT n to the front: nil for the console's own `VT_ACTIVATE`;
        /// a command (given n as its argument) for a test's stand-in.
        public var vtCommand: String?
        /// A test's: run every named user's session as this process's own
        /// account, each still in its own runtime directory and with its own
        /// name — two sessions side by side without root. Never the daemon's.
        public var sessionsAsSelf = false
        public init() {}
    }

    public enum Who: Equatable, Sendable { case greeter, user(String) }

    private let config: Config
    private let say: (String) -> Void
    private var greeter = ap_child(fd: -1, pid: -1)
    private var users: [String: ap_child] = [:]
    private var vts = VTPlan()
    /// Which session is on the screen.
    public private(set) var front: Who?
    private var greeterFailures: [Double] = []

    public init(config: Config = Config(), log: @escaping (String) -> Void) {
        self.config = config
        self.say = log
    }

    /// Every named user runs as this process (a test); see Config.
    public var sessionsAsSelf: Bool { config.sessionsAsSelf }

    /// The people with a session running, in no particular order.
    public var loggedIn: [String] { Array(users.keys) }
    /// Kept for P16.5b's callers: what is in front.
    public var running: Who? { front }

    /// Every descriptor to poll, with whose it is.
    public var childFDs: [(fd: Int32, who: Who)] {
        var out: [(Int32, Who)] = []
        if greeter.fd >= 0 { out.append((greeter.fd, .greeter)) }
        for (u, c) in users where c.fd >= 0 { out.append((c.fd, .user(u))) }
        return out
    }
    /// P16.5b's single descriptor (the first), for callers that poll one.
    public var childFD: Int32? { childFDs.first?.fd }

    static func seconds() -> Double {
        var ts = timespec(); clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    // MARK: VTs

    private func activate(_ vt: Int) {
        if let cmd = config.vtCommand {
            var c = ap_child(fd: -1, pid: -1)
            let argv = [cmd, "\(vt)"]
            let env = ["PATH=" + config.path]
            _ = withCStrings(argv) { a in withCStrings(env) { e in ap_child_spawn(a, e, -1, &c) } }
            if c.fd >= 0 {
                var p = pollfd(fd: c.fd, events: Int16(ap_child_exit_events() | POLLHUP | POLLIN), revents: 0)
                _ = poll(&p, 1, 5000)
                _ = ap_child_reap(&c, nil)
            }
        } else if ap_vt_activate(Int32(vt)) != 0 {
            say("sessions: could not bring VT \(vt) to the front: " + String(cString: strerror(errno)))
            return
        }
        say("sessions: VT \(vt) to the front")
    }

    // MARK: Starting

    public func startGreeter() {
        guard greeter.fd < 0 else { bringGreeterForward(); return }
        activate(VTPlan.greeter)
        if let c = spawn(user: config.greeterUser, name: config.greeterUser, mode: "greeter") {
            greeter = c
            front = .greeter
            say("sessions: the login window is up, as \(config.greeterUser)")
        }
    }

    private func bringGreeterForward() {
        activate(VTPlan.greeter)
        front = .greeter
        say("sessions: the login window, to the front")
    }

    /// "Login Window…" (P16.6b): the session in front — already locked by the
    /// daemon — stays running; the login window comes forward.
    public func showLoginWindow(for user: String) {
        guard front == .user(user) else {
            say("sessions: \(user) asked for the login window but is not in front — ignored")
            return
        }
        startGreeter()
    }

    /// At the login window, someone whose session is running chose
    /// themselves: back to it, **asking nothing here** — their session is
    /// locked, and its own lock screen asks. One password, not two.
    @discardableResult
    public func resume(_ user: String) -> Bool {
        guard front == .greeter, users[user] != nil, let vt = vts.vt(for: user) else { return false }
        endGreeter(because: "back to \(user)'s session")
        activate(vt)
        front = .user(user)
        say("sessions: back to \(user)'s session (VT \(vt)) — locked; its own lock screen asks")
        return true
    }

    /// The login window accepted `user`.
    public func login(_ user: String) {
        guard front == .greeter else {
            say("sessions: a login for \(user) with no login window showing — ignored")
            return
        }
        endGreeter(because: "\(user) logged in")
        if users[user] != nil, let vt = vts.vt(for: user) {
            // Theirs is running, locked: back to it, and their lock screen asks.
            activate(vt)
            front = .user(user)
            say("sessions: back to \(user)'s session (VT \(vt)) — it is locked; their password opens it")
            return
        }
        guard let vt = vts.vt(for: user) else {
            say("sessions: every VT is taken — \(user) cannot have a session of their own now")
            startGreeter()
            return
        }
        activate(vt)
        if let c = spawn(user: user, name: user, mode: "desktop") {
            users[user] = c
            front = .user(user)
            say("sessions: \(user)'s session started on VT \(vt)" + (users.count > 1 ? " — \(users.count) sessions" : ""))
        } else {
            vts.release(user)
            startGreeter()
        }
    }

    /// The runtime directory, the environment, and the spawn, as `user`
    /// (or as ourselves, named `name`, in a test).
    private func spawn(user: String, name: String, mode: String) -> ap_child? {
        let account = config.sessionsAsSelf ? (getpwuid(geteuid()).map { String(cString: $0.pointee.pw_name) } ?? user) : user
        guard let pw = getpwnam(account) else { say("sessions: no account \(account)"); return nil }
        let uid = pw.pointee.pw_uid, gid = pw.pointee.pw_gid
        let home = String(cString: pw.pointee.pw_dir)
        let shell = String(cString: pw.pointee.pw_shell)
        // **The runtime directory is made here, because the session cannot**:
        // /var/run is root's. Theirs, 0700.
        let dir = config.runtimeRoot + "/abyss-" + name
        _ = mkdir(dir, 0o700)
        if geteuid() == 0 { _ = chown(dir, uid, gid) }
        _ = chmod(dir, 0o700)
        var st = stat()
        guard stat(dir, &st) == 0, st.st_uid == uid else {
            say("sessions: \(dir) is not \(account)'s — not starting a session there"); return nil
        }
        var env: [String: String] = [
            "HOME": home, "USER": name, "LOGNAME": name, "SHELL": shell, "PATH": config.path,
            "ABYSS_RUNTIME_DIR": dir, "XDG_RUNTIME_DIR": dir, "ABYSS_SESSION_MODE": mode,
        ]
        for (k, v) in config.extraEnvironment { env[k] = v }
        let log = config.logDirectory + "/abyss-session-" + name + ".log"
        let out = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        if out >= 0, geteuid() == 0 { _ = fchown(out, uid, gid) }
        defer { if out >= 0 { close(out) } }
        let argv = [config.command]
        let envp = env.map { "\($0.key)=\($0.value)" }.sorted()
        var c = ap_child(fd: -1, pid: -1)
        let rc = withCStrings(argv) { a in withCStrings(envp) { e in ap_child_spawn_as(account, a, e, out, &c) } }
        guard rc == 0 else {
            say("sessions: could not start \(mode == "greeter" ? "the login window" : "\(name)'s session"): "
                + String(cString: strerror(errno)))
            return nil
        }
        if mode != "greeter" { say("sessions: \(name)'s session runs as uid \(uid), in \(dir)") }
        return c
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

    /// SIGTERM, five seconds, then SIGKILL. anchor takes its whole session
    /// down on SIGTERM.
    private func end(_ c: inout ap_child, _ what: String, because why: String) {
        guard c.fd >= 0 else { return }
        say("sessions: ending \(what) — \(why)")
        _ = ap_child_signal(&c, SIGTERM)
        var p = pollfd(fd: c.fd, events: Int16(ap_child_exit_events() | POLLHUP | POLLIN), revents: 0)
        if poll(&p, 1, 5000) <= 0 {
            say("sessions: it did not end in 5 s — killing it")
            _ = ap_child_signal(&c, SIGKILL)
            _ = poll(&p, 1, 2000)
        }
        _ = ap_child_reap(&c, nil)
    }

    private func endGreeter(because why: String) {
        end(&greeter, "the login window", because: why)
        if front == .greeter { front = nil }
    }

    /// A session's descriptor said it ended.
    public func childExited(_ who: Who) {
        switch who {
        case .user(let u):
            guard var c = users[u] else { return }
            _ = ap_child_reap(&c, nil)
            users[u] = nil
            vts.release(u)
            say("sessions: \(u) logged out" + (users.isEmpty ? "" : " — \(users.count) session(s) still running"))
            if front == .user(u) {
                front = nil
                say("sessions: the login window again")
                startGreeter()
            }
        case .greeter:
            _ = ap_child_reap(&greeter, nil)
            guard front == .greeter || front == nil else { return }
            front = nil
            let now = SessionManager.seconds()
            greeterFailures = greeterFailures.filter { now - $0 < 60 } + [now]
            guard greeterFailures.count <= 5 else {
                say("sessions: the login window died \(greeterFailures.count) times in a minute — giving up")
                return
            }
            say("sessions: the login window ended — starting it again (\(greeterFailures.count)/5)")
            startGreeter()
        }
    }

    /// P16.5b's form: whatever is in front ended.
    public func childExited() { if let f = front { childExited(f) } }

    /// The daemon is stopping: end everything.
    public func shutdown() {
        endGreeter(because: "the daemon is stopping")
        for u in Array(users.keys) {
            if var c = users[u] { end(&c, "\(u)'s session", because: "the daemon is stopping") }
            users[u] = nil
        }
    }
}
