// JailKeeper — the session's half of confinement (PHASE18 P18.5).
//
// `abyss-jail serve`, a session component beside the portal and the bridge.
// It answers `launch class=C argv=…` on the session's `jails` socket:
//
//   1. the class's jail, opened from abyss-jaild once and **held for the
//      session**: pooled, never one per launch (PLAN's cost note). The keeper
//      holds the owning descriptor, so the jails end with the session, and so
//      does everything in them;
//   2. the first time, the jail's own Wayland socket, bound inside its runtime
//      directory from outside and registered with the compositor as a
//      security context (P18.3); its own D-Bus *bridge* (BACKLOG D.1, never a
//      bus) listening inside the jail, with the jail's portal — an
//      `abyss-dbus --jail` — on the bridge's services socket, which is outside
//      the jail where nothing jailed can reach it (P18.4). Both are this
//      process's children by descriptor, so they die with it;
//   3. any argument that names one of the person's files is granted into the
//      jail first and rewritten to where it is there — a document opened from
//      the Finder opens, and saves, in place;
//   4. the program, started in the jail as the person.
//
// For an agent class (P18.8) it answers `agent class=C` instead: a session of
// its own — `abyss-model` started outside the jail for this session alone
// (its budget, its transcript under ~/Library/Logs/Agents), its socket inside
// the jail, and `abyss-agent` started in the jail on it. The chat window talks
// to the agent's socket; when the agent ends, its model goes too.
//
// And it watches `jails.ini` (P18.6): when its `[apps]` changes — an
// application put in a jail, or let out — it runs `abyss-appgen` again, so
// the bundles say so now rather than at the next login.
//
// Anyone in the session may ask it: they are the person already. A jailed
// process cannot — the socket is in the session's runtime directory, which no
// jail can see.

import CurrentIPC
import CProc
import CWayland
import CWaylandClient
import JailD
import Jails
import PoolConfig
import Spawn

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum KeeperWire {
    public static let service = "jails"
    public static let engine = "org.abyssbsd.jail"
}

/// Which arguments of a launch are the person's files (P18.5): an absolute path
/// to a regular file outside what the jail sees anyway. Pure, given how to
/// resolve a path.
public enum LaunchFiles {
    public static func indices(_ argv: [String], system: [String],
                               resolve: (String) -> String?) -> [(Int, String)] {
        var out: [(Int, String)] = []
        for (i, a) in argv.enumerated().dropFirst() where a.hasPrefix("/") {
            guard let real = resolve(a) else { continue }
            if system.contains(where: { JailPlan.under(real, $0) }) { continue }
            out.append((i, real))
        }
        return out
    }

    /// A path's resolved form if it is a regular file, else nil.
    public static func regularFile(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &buf) != nil else { return nil }
        let real = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var st = stat()
        guard stat(real, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return real
    }
}

public final class JailKeeper {
    public struct Held {
        public var opened: JailClient.Opened
        var closeFD: Int32
        var bus: ap_child?
        var bridge: ap_child?
        /// The jail's GTK menu bridge, serving `menus-dbus-CLASS` to the bar.
        var menus: ap_child?
    }

    public var jaildSocket = JailWire.defaultSocket
    /// Where abyss-dbus is (this binary's directory).
    public var binDir: String
    public private(set) var held: [String: Held] = [:]
    /// `abyss-appgen` and its arguments, run when `[apps]` changes (P18.6).
    public var appgen: [String]?
    private var appsSeen = ""
    private var procs: [(fd: Int32, pid: UInt64, name: String, jail: String, model: ap_child?)] = []
    private var sessions = 0
    /// Where agent transcripts are kept: outside every jail, and past the
    /// session — "the session is the log".
    public var agentLogs: String = (getenv("HOME").map { String(cString: $0) } ?? "/tmp") + "/Library/Logs/Agents"
    private let server: Current.Server
    private let display: OpaquePointer?
    private let runtimeDir: String
    private let classes: [JailClass]
    private let say: (String) -> Void

    public init(server: Current.Server, display: OpaquePointer?, runtimeDir: String, binDir: String,
                classes: [JailClass] = JailClass.shipped, log: @escaping (String) -> Void) {
        self.server = server
        self.display = display
        self.runtimeDir = runtimeDir
        self.binDir = binDir
        self.classes = classes
        self.say = log
    }

    // MARK: - the jail, once per class

    func ensure(_ cls: String) throws -> Held {
        if let h = held[cls] { return h }
        let opened = try JailClient.open(cls, socket: jaildSocket)
        var h = Held(opened: opened, closeFD: -1, bus: nil, bridge: nil, menus: nil)
        do {
            // Wayland: a socket of the jail's own, made from outside.
            if let display, classes.first(where: { $0.name == cls })?.wayland ?? true {
                let path = opened.runtime + "/" + JailLayout.waylandDisplay
                var closer: Int32 = -1
                let rc = aw_jail_listen(display, path, KeeperWire.engine, cls, String(opened.jid), &closer)
                guard rc == 0 else { throw JailClient.Refused(description: "the compositor would not take \(opened.name)'s socket (\(-rc))") }
                h.closeFD = closer
            }
            // A class without a display (an agent's) has no GTK application,
            // so no bridge, portal or menus: nothing it does not need.
            guard classes.first(where: { $0.name == cls })?.wayland ?? true else {
                held[cls] = h
                say("jails: \(opened.name) is jail \(opened.jid); no display, so no socket or bus")
                return h
            }
            // Its D-Bus bridge (never a bus: §5.6), and the jail's portal on
            // the bridge's services socket — outside the jail.
            let dir = runtimeDir + "/jails/" + cls
            _ = Spawn.run(["/bin/mkdir", "-p", dir])
            let services = dir + "/dbus-services"
            h.bus = try child([binDir + "/abyss-dbus", "--endpoint", "--listen", opened.runtime + "/bus",
                               "--services", services], log: dir + "/endpoint.log")
            var i = 0
            while access(services, F_OK) != 0 && i < 100 { usleep(20_000); i += 1 }
            h.bridge = try child([binDir + "/abyss-dbus", "--bus", "unix:path=" + services,
                                  "--jail", opened.name, "--jaild", jaildSocket], log: dir + "/bridge.log")
            // And its menu bridge: a confined GTK application's menus are on
            // this bus, which the session's menu bridge cannot reach.
            h.menus = try child([binDir + "/abyss-dbus", "--menus", "--bus", "unix:path=" + services,
                                 "--class", cls], log: dir + "/menus.log")
        } catch {
            if h.closeFD >= 0 { close(h.closeFD) }
            for var c in [h.bus, h.bridge, h.menus].compactMap({ $0 }) { _ = ap_child_signal(&c, SIGKILL); _ = ap_child_reap(&c, nil) }
            close(opened.jail)
            throw error
        }
        held[cls] = h
        say("jails: \(opened.name) is jail \(opened.jid); its socket, bus, portal and menus are up")
        return h
    }

    private func child(_ argv: [String], log: String) throws -> ap_child {
        let fd = open(log, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        defer { if fd >= 0 { close(fd) } }
        var env: [String] = []
        var p = environ
        while let e = p.pointee { env.append(String(cString: e)); p += 1 }
        var c = ap_child(fd: -1, pid: 0)
        let rc = Spawn.withCStrings(argv) { a in Spawn.withCStrings(env) { e in ap_child_spawn(a, e, fd, &c) } }
        guard rc == 0 else { throw JailClient.Refused(description: "cannot start \(argv[0]): \(String(cString: strerror(errno)))") }
        return c
    }

    private func write(_ path: String, _ text: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw JailClient.Refused(description: "cannot write \(path)") }
        defer { close(fd) }
        let b = Array(text.utf8)
        _ = b.withUnsafeBufferPointer { Glibc.write(fd, $0.baseAddress, b.count) }
    }

    // MARK: - launch

    public func launch(_ cls: String, argv: [String]) throws -> UInt64 {
        guard !argv.isEmpty else { throw JailClient.Refused(description: "nothing to launch") }
        let h = try ensure(cls)
        let system = classes.first { $0.name == cls }?.system ?? JailClass.baseSystem
        var args = argv
        for (i, real) in LaunchFiles.indices(argv, system: system, resolve: LaunchFiles.regularFile) {
            // Edited in place when the person may write it; read-only if not.
            var fd = open(real, O_RDWR | O_CLOEXEC)
            if fd < 0 { fd = open(real, O_RDONLY | O_CLOEXEC) }
            guard fd >= 0 else { continue }
            defer { close(fd) }
            let g = try JailClient.grant(jail: h.opened.name, path: real, file: fd, socket: jaildSocket)
            say("jails: \(real) is \(g.inside) in \(h.opened.name)")
            args[i] = g.inside
        }
        let (pid, proc) = try JailClient.spawn(jail: h.opened.jail, argv: args, socket: jaildSocket)
        procs.append((proc, pid, argv[0], h.opened.name, nil))
        say("jails: launched \(argv[0]) as pid \(pid) in \(h.opened.name)")
        return pid
    }

    // MARK: - agents (P18.8)

    public struct AgentSession: Equatable {
        public var id: String
        /// The agent's socket, as the chat window outside reaches it.
        public var socket: String
        public var transcript: String
        public var pid: UInt64
    }

    /// `abyss-model serve`'s backend arguments for a class's `model=`.
    public static func modelArgs(_ spec: String) -> [String]? {
        if spec.hasPrefix("local:") { return ["--local", String(spec.dropFirst(6))] }
        if spec.hasPrefix("stub:") { return ["--stub", String(spec.dropFirst(5))] }
        if spec.hasPrefix("http://") { return ["--backend", spec] }
        return nil
    }

    public func agent(_ cls: String) throws -> AgentSession {
        guard let k = classes.first(where: { $0.name == cls }), k.agent else {
            throw JailClient.Refused(description: "\(cls) is not an agent class")
        }
        guard !k.model.isEmpty else {
            throw JailClient.Refused(description: "no model is set for \(cls): set model= in jails.ini [\(cls)]")
        }
        guard let backend = Self.modelArgs(k.model) else {
            throw JailClient.Refused(description: "\(cls)'s model= is not local:, stub: or http://: \(k.model)")
        }
        let h = try ensure(cls)
        sessions += 1
        let n = sessions
        var t = time(nil), tmv = tm()
        localtime_r(&t, &tmv)
        var buf = [CChar](repeating: 0, count: 32)
        strftime(&buf, buf.count, "%Y%m%d-%H%M%S", &tmv)
        let id = "\(String(cString: buf))-\(cls)-\(getpid())-\(n)"
        let transcript = agentLogs + "/" + id
        _ = Spawn.run(["/bin/mkdir", "-p", "-m", "700", agentLogs, transcript])

        // The model, outside the jail, on a socket inside it.
        let modelSock = "model-\(n).sock", agentSock = "agent-\(n).sock"
        let outside = h.opened.runtime + "/" + modelSock
        var model = try child([binDir + "/abyss-model", "serve", "--listen", outside, "--session", id,
                               "--budget", String(k.budget), "--transcript", transcript] + backend,
                              log: transcript + "/abyss-model.log")   // outside the jail, with the transcript
        func fail(_ why: String) -> JailClient.Refused {
            _ = ap_child_signal(&model, SIGTERM); _ = ap_child_reap(&model, nil)
            return JailClient.Refused(description: why)
        }
        guard waitForSocket(outside, seconds: 300, unless: model) else { throw fail("abyss-model did not start for \(id)") }

        // The agent, in the jail. A build outside what the jail sees (a
        // developer's) comes in as a read-only grant, like a document.
        var agentPath = binDir + "/abyss-agent"
        if !k.system.contains(where: { JailPlan.under(agentPath, $0) }) {
            let fd = open(agentPath, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw fail("cannot open \(agentPath)") }
            defer { close(fd) }
            do { agentPath = try JailClient.grant(jail: h.opened.name, path: agentPath, file: fd, socket: jaildSocket).inside }
            catch { throw fail("cannot give the jail abyss-agent: \(error)") }
        }
        let (pid, proc): (UInt64, Int32)
        do {
            (pid, proc) = try JailClient.spawn(jail: h.opened.jail, argv: [
                agentPath, "serve", "--model", JailLayout.runtime + "/" + modelSock,
                "--listen", JailLayout.runtime + "/" + agentSock, "--class", cls], socket: jaildSocket)
        } catch { throw fail("cannot start abyss-agent: \(error)") }
        procs.append((proc, pid, "abyss-agent", h.opened.name, model))
        let socket = h.opened.runtime + "/" + agentSock
        guard waitForSocket(socket, seconds: 30, unless: nil) else {
            throw JailClient.Refused(description: "abyss-agent did not start in \(h.opened.name)")
        }
        say("jails: agent session \(id) in \(h.opened.name): agent pid \(pid), transcript \(transcript)")
        return AgentSession(id: id, socket: socket, transcript: transcript, pid: pid)
    }

    /// Wait for a socket to appear, giving up if `child` exits first.
    private func waitForSocket(_ path: String, seconds: Int, unless child: ap_child?) -> Bool {
        for _ in 0..<(seconds * 20) {
            if access(path, F_OK) == 0 { return true }
            if let c = child {
                var p = pollfd(fd: c.fd, events: Int16(ap_child_exit_events()), revents: 0)
                if poll(&p, 1, 0) > 0 { return false }
            }
            usleep(50_000)
        }
        return false
    }

    // MARK: - the loop

    /// `[apps]` as it stands, one row per line.
    static func appsRows() -> String {
        ((try? Pool.load("jails"))?.pairs(JailClass.appsSection) ?? []).map { "\($0.0)=\($0.1)" }.joined(separator: "\n")
    }

    private func appsMayHaveChanged() {
        let now = Self.appsRows()
        guard now != appsSeen else { return }
        appsSeen = now
        guard let appgen else { return }
        say("jails: jails.ini's [apps] changed; making the applications again")
        _ = Spawn.detached(appgen)
    }

    public func run() {
        let wlfd = display.map { wl_display_get_fd($0) } ?? -1
        appsSeen = Self.appsRows()
        let watcher = try? Pool.Watcher()
        while true {
            if let display { _ = wl_display_flush(display) }
            var fds = [pollfd(fd: server.fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wlfd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: watcher?.fileDescriptor ?? -1, events: Int16(POLLIN), revents: 0)]
            for p in procs { fds.append(pollfd(fd: p.fd, events: Int16(POLLHUP | POLLIN), revents: 0)) }
            let n = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), -1) }
            if n < 0 { if errno == EINTR { continue }; return }
            if fds[2].revents != 0, let watcher, watcher.drain() { appsMayHaveChanged() }
            if wlfd >= 0, fds[1].revents != 0, let display {
                // The compositor went away: the session is over.
                if wl_display_dispatch(display) < 0 { say("jails: the compositor is gone"); return }
            }
            for (i, p) in procs.enumerated().reversed() where fds[i + 3].revents != 0 {
                say("jails: \(p.name) (pid \(p.pid)) in \(p.jail) exited")
                if var m = p.model {
                    _ = ap_child_signal(&m, SIGTERM)
                    _ = ap_child_reap(&m, nil)
                    say("jails: its model stopped")
                }
                close(p.fd)
                procs.remove(at: i)
            }
            if fds[0].revents != 0 { serveOne() }
        }
    }

    private func serveOne() {
        guard let c = try? server.accept() else { return }
        defer { close(c) }
        guard var req = try? Current.receive(on: c) else { return }
        defer { req.closeFDs() }
        var reply = Msg()
        switch req.string("method") {
        case "launch":
            do {
                let pid = try launch(req.string("class") ?? "", argv: JailWire.unlist(req.bytes("argv") ?? []))
                reply.set("ok", true); reply.set("pid", pid)
            } catch {
                say("jails: launch refused: \(error)")
                reply = JailWire.error("\(error)")
            }
        case "agent":
            do {
                let a = try agent(req.string("class") ?? "")
                reply.set("ok", true); reply.set("session", a.id); reply.set("socket", a.socket)
                reply.set("transcript", a.transcript); reply.set("pid", a.pid)
            } catch {
                say("jails: agent refused: \(error)")
                reply = JailWire.error("\(error)")
            }
        case "held":
            reply.set("ok", true)
            reply.set("jails", bytes: JailWire.list(held.values.map { "\($0.opened.name) jid=\($0.opened.jid)" }.sorted()))
        default:
            reply = JailWire.error("unknown method")
        }
        try? Current.send(reply, on: c)
    }
}
