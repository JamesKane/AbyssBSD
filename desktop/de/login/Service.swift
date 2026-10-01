// LoginService — the root daemon's loop, as a library (PHASE16 P16.4a).
//
// `abyss-loginwindow` answers three things on its one socket:
//
//   - `verify`: is this my password? (P16.1, the `Authenticator`.)
//   - `watch`: a session's agent (`abyss-idle`) keeps this connection open,
//     and is told before the machine sleeps.
//   - `power`: sleep, restart or shut down the machine.
//
// **The machine does not sleep with a session showing.** Whoever asks — the
// system menu, the idle policy, the lid — every watching session is told
// `sleep` first and must answer that it is locked (or needs no lock: no
// password required). A session that answers no, or not in time, stops the
// sleep: a computer that stays awake is better than one that wakes unlocked
// (HANDOFF §2.104). Only then is the requester told yes and `acpiconf -s 3`
// run; when it returns, the machine has woken, and the sessions are told.
//
// **Who may**: anyone at the machine may put it to sleep, as on the Mac.
// Restart and shut down need root, `wheel` or `operator` — FreeBSD's own rule
// for shutdown(8), and the groups the installer gives an administrator.
// (P16.5 can narrow it to "the user at the console".)
//
// The commands are arguments, so a test runs stand-ins that record what was
// asked (PHASE16 §6.3) — the same loop, the same order, nothing suspended.
//
// One request at a time, as before: a power request holds the loop while the
// sessions lock, which is the point.

import CurrentIPC
import Spawn

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Who may ask for what: pure, so it is tested without accounts.
public enum PowerPolicy {
    public static func may(_ action: PowerAction, uid: UInt32, groups: [String], systemUID: UInt32 = 0,
                           greeterUID: UInt32? = nil) -> Bool {
        // The lid and the keys are devd's — root's. Anyone else saying "the
        // power key was pressed" could, with no session watching, shut the
        // machine down.
        if action.isHardware { return uid == systemUID }
        if action == .sleep || uid == 0 { return true }
        // The login window: nobody is logged in at the console, and the Mac's
        // login window has always offered Restart and Shut Down (P16.5).
        if let g = greeterUID, uid == g { return true }
        return groups.contains("wheel") || groups.contains("operator")
    }

    /// The command that does `action`.
    public static func argv(_ action: PowerAction, commands: PowerCommands) -> [String] {
        switch action {
        case .sleep, .lid, .sleepKey: return [commands.acpiconf, "-s", "3"]
        case .restart: return [commands.shutdown, "-r", "now"]
        // The power key with no session to ask: what the kernel's own
        // `power_button_state=S5` would have done.
        case .shutDown, .powerKey: return [commands.shutdown, "-p", "now"]
        }
    }
}

public struct PowerCommands: Sendable {
    public var acpiconf = "/usr/sbin/acpiconf"
    public var shutdown = "/sbin/shutdown"
    public init() {}
}

/// The groups an account belongs to, by name.
public func loginGroups(of uid: UInt32) -> [String] {
    guard let pw = getpwuid(uid_t(uid)) else { return [] }
    let name = pw.pointee.pw_name
    let gid = pw.pointee.pw_gid
    var n: Int32 = 64
    var list = [gid_t](repeating: 0, count: Int(n))
    #if canImport(Darwin)
    var ilist = [Int32](repeating: 0, count: Int(n))
    guard getgrouplist(name, Int32(gid), &ilist, &n) >= 0 else { return [] }
    list = ilist.prefix(Int(n)).map { gid_t($0) }
    #else
    guard getgrouplist(name, gid, &list, &n) >= 0 else { return [] }
    list = Array(list.prefix(Int(n)))
    #endif
    return list.compactMap { g in getgrgid(g).flatMap { $0.pointee.gr_name }.map { String(cString: $0) } }
}

public final class LoginService {
    private let server: Current.Server
    private var auth: Authenticator
    private let commands: PowerCommands
    private let groupsOf: (UInt32) -> [String]
    private let say: (String) -> Void
    /// How long the sessions have to lock before a sleep is called off.
    public var lockTimeout: Double = 8
    /// Who reports the machine's buttons: root (devd). Only a test's
    /// stand-in, which is never shipped, names another.
    public var systemUID: UInt32 = 0
    /// The login window's account (P16.5): the only caller that may ask about
    /// another account's password. Nil: no login window on this machine.
    public var greeterUID: UInt32?
    /// Someone logged in at the window (P16.5b starts their session here).
    public var onLogin: ((String) -> Void)?
    private let uidOf: (String) -> UInt32? = { name in getpwnam(name).map { UInt32($0.pointee.pw_uid) } }
    private var watchers: [(fd: Int32, uid: UInt32)] = []

    public init(server: Current.Server, authenticator: Authenticator,
                commands: PowerCommands = PowerCommands(),
                groupsOf: @escaping (UInt32) -> [String] = loginGroups,
                log: @escaping (String) -> Void) {
        self.server = server
        self.auth = authenticator
        self.commands = commands
        self.groupsOf = groupsOf
        self.say = log
    }

    static func now() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    /// Serve until `once` has answered one request (a test), or for ever.
    public func run(once: Bool = false) {
        while true {
            var fds = [pollfd(fd: server.fd, events: Int16(POLLIN), revents: 0)]
            for w in watchers { fds.append(pollfd(fd: w.fd, events: Int16(POLLIN), revents: 0)) }
            let n = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), -1) }
            if n < 0 { if errno == EINTR { continue }; return }
            // A watcher readable outside a sleep has hung up — or is answering
            // a sleep that was already called off (it was too slow). A late
            // answer is read and set aside; anything else ends the watch.
            for p in fds.dropFirst() where p.revents != 0 {
                if let late = try? Current.receive(on: p.fd), late.bool("ready") != nil {
                    say("loginwindow: a late answer from a session, after its sleep was called off — ignored")
                } else {
                    dropWatcher(p.fd, "hung up")
                }
            }
            if fds[0].revents != 0 {
                serveOne()
                if once { return }
            }
        }
    }

    private func dropWatcher(_ fd: Int32, _ why: String) {
        guard let w = watchers.first(where: { $0.fd == fd }) else { return }
        watchers.removeAll { $0.fd == fd }
        close(fd)
        say("loginwindow: uid \(w.uid)'s session stopped watching (\(why))")
    }

    private func serveOne() {
        guard let client = try? server.accept() else { return }
        let uid = loginPeerUID(client)
        guard var request = try? Current.receive(on: client) else { close(client); return }
        switch request.string("method") {
        case "watch":
            guard let uid else { reply(client, LoginWire.error("the kernel would not identify the caller")); close(client); return }
            var ok = Msg(); ok.set("ok", true)
            guard (try? Current.send(ok, on: client)) != nil else { close(client); return }
            watchers.append((client, uid))
            say("loginwindow: uid \(uid)'s session is watching (\(watchers.count) watching)")
        case "power":
            power(client, uid: uid, request: request)
        case "login":
            let isGreeter = uid != nil && greeterUID != nil && uid == greeterUID
            let (r, line, user) = auth.handleLogin(callerIsGreeter: isGreeter, request: request,
                                                    now: LoginService.now(), uidOf: uidOf)
            request = Msg()
            reply(client, r)
            close(client)
            say("loginwindow: " + (isGreeter ? "" : "uid \(uid.map(String.init) ?? "?"): ") + line)
            if let user { onLogin?(user) }
        default:
            let (r, line) = auth.handle(uid: uid, request: request, now: LoginService.now())
            request = Msg()
            reply(client, r)
            close(client)
            say("loginwindow: \(line)")
        }
    }

    private func reply(_ fd: Int32, _ m: Msg) { _ = try? Current.send(m, on: fd) }

    private func power(_ client: Int32, uid: UInt32?, request: Msg) {
        defer { close(client) }
        guard let uid else {
            reply(client, LoginWire.error("the kernel would not identify the caller")); return
        }
        guard let action = request.string("action").flatMap(PowerAction.init(rawValue:)) else {
            reply(client, LoginWire.error("power: no such action \(request.string("action") ?? "(none)")")); return
        }
        guard PowerPolicy.may(action, uid: uid, groups: groupsOf(uid), systemUID: systemUID,
                              greeterUID: greeterUID) else {
            say("loginwindow: uid \(uid): \(action.rawValue) refused — " + (action.isHardware ? "not root" : "not an administrator"))
            reply(client, LoginWire.error(action.isHardware ? "only the system reports the machine's buttons"
                : "only an administrator can \(action == .restart ? "restart" : "shut down") this computer"))
            return
        }
        // **The power key asks** (Jaguar's dialog: Restart, Sleep, Cancel,
        // Shut Down) — in every watching session; it does nothing itself.
        // With no session to ask, it shuts down, as the kernel would have.
        if action == .powerKey, !watchers.isEmpty {
            for w in watchers {
                var m = Msg(); m.set("event", "power-key")
                if (try? Current.send(m, on: w.fd)) == nil { dropWatcher(w.fd, "gone") }
            }
            say("loginwindow: the power key — asking \(watchers.count) session(s) what to do")
            var ok = Msg(); ok.set("ok", true)
            reply(client, ok)
            return
        }
        let sleeps = action == .sleep || action == .lid || action == .sleepKey
        if sleeps, let why = lockEverySession() {
            say("loginwindow: uid \(uid): sleep called off — \(why)")
            reply(client, LoginWire.error("the computer did not sleep: \(why)"))
            return
        }
        var ok = Msg(); ok.set("ok", true)
        reply(client, ok)
        let argv = PowerPolicy.argv(action, commands: commands)
        say("loginwindow: uid \(uid): \(action.rawValue) — \(argv.joined(separator: " "))")
        let r = Spawn.run(argv)
        if !r.succeeded {
            say("loginwindow: \(argv[0]) failed (\(r.failure ?? "exit \(r.code)")): \(r.stderrText)")
        }
        if sleeps {
            // `acpiconf -s 3` returns once the machine is awake again.
            say("loginwindow: awake")
            for w in watchers {
                var m = Msg(); m.set("event", "resumed")
                if (try? Current.send(m, on: w.fd)) == nil { dropWatcher(w.fd, "gone while asleep") }
            }
        }
    }

    /// Tell every watching session the machine is about to sleep, and wait for
    /// each to say it is locked. Nil when all did, else why not.
    private func lockEverySession() -> String? {
        var waiting: [(fd: Int32, uid: UInt32)] = []
        for w in watchers {
            var m = Msg(); m.set("event", "sleep")
            if (try? Current.send(m, on: w.fd)) != nil { waiting.append(w) }
            else { dropWatcher(w.fd, "gone") }
        }
        if !waiting.isEmpty { say("loginwindow: asking \(waiting.count) session(s) to lock before sleeping") }
        let deadline = LoginService.now() &+ UInt64(lockTimeout * 1_000_000_000)
        while !waiting.isEmpty {
            let now = LoginService.now()
            guard now < deadline else {
                return "uid " + waiting.map { String($0.uid) }.joined(separator: ", ")
                    + " did not lock in \(Int(lockTimeout)) s"
            }
            var fds = waiting.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            let ms = Int32((deadline - now) / 1_000_000)
            let n = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), ms) }
            if n < 0 { if errno == EINTR { continue }; return "poll failed" }
            for p in fds where p.revents != 0 {
                guard let w = waiting.first(where: { $0.fd == p.fd }) else { continue }
                waiting.removeAll { $0.fd == p.fd }
                guard let answer = try? Current.receive(on: p.fd) else {
                    dropWatcher(p.fd, "hung up instead of locking")
                    return "uid \(w.uid)'s session went away instead of locking"
                }
                guard answer.bool("ready") == true else {
                    return "uid \(w.uid)'s session could not lock: \(answer.string("why") ?? "?")"
                }
                say("loginwindow: uid \(w.uid)'s session is ready (\(answer.string("why") ?? "locked"))")
            }
        }
        return nil
    }
}
