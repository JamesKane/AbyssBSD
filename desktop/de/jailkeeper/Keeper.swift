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
// When a program it launched dies of a signal (P18.9), it keeps a crash:
// what died, how, and where its core is in the jail's home. `debug N` starts
// a session in the `debug` class with that core, and the binary if the jail
// does not see it already, granted in read-only — that crash and no other.
//
// And it watches `jails.ini` (P18.6): when its `[apps]` changes — an
// application put in a jail, or let out — it runs `abyss-appgen` again, so
// the bundles say so now rather than at the next login.
//
// Anyone in the session may ask it: they are the person already. A jailed
// process cannot — the socket is in the session's runtime directory, which no
// jail can see.

import CJail
import CurrentIPC
import CProc
import CWayland
import CWaylandClient
import JailD
import MenuWire
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

/// A confined program that died of a signal (P18.9). Pure, given the wait
/// status and where things are.
public struct Crash: Equatable, Sendable {
    public var id: Int
    public var program: String
    public var jail: String
    public var signal: Int32
    public var coreDumped: Bool
    /// The core, as the host sees it (it may not exist: a core size of 0).
    public var core: String
    /// The binary inside the jail, and as the host sees it.
    public var binaryInside: String
    public var binary: String

    public init(id: Int, program: String, jail: String, signal: Int32, coreDumped: Bool,
                core: String, binaryInside: String, binary: String) {
        self.id = id; self.program = program; self.jail = jail; self.signal = signal
        self.coreDumped = coreDumped; self.core = core; self.binaryInside = binaryInside; self.binary = binary
    }

    /// The signal and whether a core was written, from a wait(2) status; nil
    /// for a program that exited on its own, whatever its code.
    public static func signal(of status: Int32) -> (signal: Int32, core: Bool)? {
        let sig = status & 0x7f
        guard sig != 0, sig != 0x7f else { return nil }
        return (sig, status & 0x80 != 0)
    }

    /// The kernel's name for its core (`kern.corefile` = `%N.core`): the
    /// process's name, which is its file's, cut to MAXCOMLEN (19).
    public static func coreName(_ program: String) -> String {
        let base = program.split(separator: "/").last.map(String.init) ?? program
        return String(base.prefix(19)) + ".core"
    }

    /// Where the binary is inside the jail: as given when absolute, else the
    /// first of the jail's PATH that has it (asked of the host, which sees
    /// the jail's root at `root`).
    public static func binaryInside(_ program: String, root: String,
                                    path: [String] = ["/bin", "/usr/bin", "/usr/local/bin"]) -> String? {
        if program.hasPrefix("/") { return program }
        return path.map { $0 + "/" + program }.first { access(root + $0, X_OK) == 0 }
    }

    public static func signalName(_ s: Int32) -> String {
        switch s {
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGABRT: return "SIGABRT"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGKILL: return "SIGKILL"
        case SIGTERM: return "SIGTERM"
        case SIGTRAP: return "SIGTRAP"
        default: return "signal \(s)"
        }
    }

    /// What it said in a sentence: the debug agent's first line of context.
    public var summary: String {
        "\(program) was killed by \(Crash.signalName(signal))" + (coreDumped ? " and left a core" : ", leaving no core")
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
    /// What runs in the jails, and for an agent the helpers outside that end
    /// with it (its model, its vocabulary bridge).
    private var procs: [(fd: Int32, pid: UInt64, name: String, jail: String, model: ap_child?, root: String, home: String,
                         helpers: [ap_child])] = []
    /// Agent sessions' vocabulary control sockets, by session ID (P18.10).
    private var vocabularies: [String: String] = [:]
    /// Crashes seen this session, by number (P18.9).
    public private(set) var crashes: [Int: Crash] = [:]
    /// What shows a crash to the person (P18.9b): AquaDemo's Crash Reporter,
    /// given `ABYSS_CRASH_*`. Nil without a display, when nobody would see it.
    public var crashDialog: [String]?
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
        procs.append((proc, pid, args[0], h.opened.name, nil, h.opened.root, h.opened.home, []))
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
        /// Whether applications can be given to it (P18.10).
        public var vocabulary: Bool = false
    }

    /// `abyss-model serve`'s backend arguments for a class's `model=`.
    public static func modelArgs(_ spec: String) -> [String]? {
        if spec.hasPrefix("local:") { return ["--local", String(spec.dropFirst(6))] }
        if spec.hasPrefix("stub:") { return ["--stub", String(spec.dropFirst(5))] }
        if spec.hasPrefix("http://") { return ["--backend", spec] }
        return nil
    }

    // MARK: - crashes (P18.9)

    private func crashed(_ program: String, jail: String, root: String, home: String, signal: Int32, coreDumped: Bool) {
        // Named by the home's source, not its mount in the root: jaild grants
        // nothing from inside a jail's root (no jail-to-jail through a tree).
        let me = getpwuid(getuid()).map { String(cString: $0.pointee.pw_name) } ?? ""
        let core = home + "/" + Crash.coreName(program)
        let inside = Crash.binaryInside(program, root: root) ?? program
        let homeInside = "/home/" + me
        let binary = JailPlan.under(inside, homeInside) ? home + inside.dropFirst(homeInside.count) : root + inside
        let c = Crash(id: crashes.count + 1, program: program, jail: jail, signal: signal,
                      coreDumped: coreDumped && access(core, R_OK) == 0, core: core,
                      binaryInside: inside, binary: binary)
        crashes[c.id] = c
        say("jails: crash \(c.id): \(c.summary) in \(jail)\(c.coreDumped ? " (core \(core))" : "")")
        if let argv = crashDialog {
            let app = program.split(separator: "/").last.map(String.init) ?? program
            let shown = Spawn.detached(argv, environment: [
                "AQUA_SCENE": "crashreport", "ABYSS_CRASH_ID": String(c.id), "ABYSS_CRASH_APP": app,
                "ABYSS_CRASH_SIGNAL": Crash.signalName(signal), "ABYSS_CRASH_CORE": c.coreDumped ? "1" : "0"])
            say("jails: crash \(c.id) \(shown ? "shown" : "could not be shown")")
        }
    }

    /// A `debug` session for crash `id`: its core, and its binary if the debug
    /// jail does not see it anyway, granted read-only — that crash, no other.
    public func debug(_ id: Int) throws -> AgentSession {
        guard let c = crashes[id] else { throw JailClient.Refused(description: "there is no crash \(id)") }
        guard c.coreDumped else { throw JailClient.Refused(description: "\(c.summary): there is nothing to read") }
        let cls = "debug"
        let h = try ensure(cls)
        func grant(_ path: String) throws -> String {
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw JailClient.Refused(description: "cannot open \(path)") }
            defer { close(fd) }
            return try JailClient.grant(jail: h.opened.name, path: path, file: fd, socket: jaildSocket).inside
        }
        let core = try grant(c.core)
        let system = classes.first { $0.name == cls }?.system ?? JailClass.baseSystem
        var binary = c.binaryInside
        if !system.contains(where: { JailPlan.under(c.binaryInside, $0) }) {
            let granted = try grant(c.binary)
            // **lldb wants the binary where the core says it ran** (base lldb
            // 21 asserts in ResolveContainedAddress otherwise; HANDOFF §2.130).
            // A program from the person's home ran at /home/NAME/…, and the
            // debug jail's /home/NAME is its own home: a link there, made from
            // outside in the home's source, to the read-only grant.
            let me = getpwuid(getuid()).map { String(cString: $0.pointee.pw_name) } ?? ""
            let homeInside = "/home/" + me
            if JailPlan.under(c.binaryInside, homeInside), !h.opened.home.isEmpty {
                let link = h.opened.home + c.binaryInside.dropFirst(homeInside.count)
                var st = stat()
                if lstat(link, &st) == 0, st.st_mode & S_IFMT == S_IFLNK { unlink(link) }
                if lstat(link, &st) != 0, symlink(granted, link) == 0 {
                    say("jails: \(c.binaryInside) in \(h.opened.name) is a link to \(granted)")
                } else {
                    binary = granted   // something of the agent's own is there: lldb may not resolve it
                }
            } else {
                binary = granted
            }
        }
        say("jails: crash \(id)'s core is \(core) in \(h.opened.name), its binary \(binary)")
        return try agent(cls, extra: ["--core", core, "--binary", binary, "--crash", c.summary])
    }

    public func agent(_ cls: String, extra: [String] = []) throws -> AgentSession {
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

        // Its vocabulary (P18.10), when the class has one: the bridge outside,
        // answering inside; gives come on a control socket beside the
        // transcript, where nothing in the jail can reach.
        var helpers: [ap_child] = []
        var vocabArgs: [String] = []
        if k.vocabulary {
            let vocabSock = "vocab-\(n).sock"
            let control = transcript + "/vocabulary.sock"
            var v = try child([binDir + "/abyss-vocab", "serve", "--listen", h.opened.runtime + "/" + vocabSock,
                               "--control", control, "--session", id, "--transcript", transcript],
                              log: transcript + "/abyss-vocab.log")
            guard waitForSocket(control, seconds: 10, unless: v) else {
                _ = ap_child_signal(&v, SIGTERM); _ = ap_child_reap(&v, nil)
                throw fail("abyss-vocab did not start for \(id)")
            }
            helpers.append(v)
            vocabularies[id] = control
            vocabArgs = ["--vocab", JailLayout.runtime + "/" + vocabSock]
        }
        func failAll(_ why: String) -> JailClient.Refused {
            for var c in helpers { _ = ap_child_signal(&c, SIGTERM); _ = ap_child_reap(&c, nil) }
            return fail(why)
        }

        // The agent, in the jail. A build outside what the jail sees (a
        // developer's) comes in as a read-only grant, like a document.
        var agentPath = binDir + "/abyss-agent"
        if !k.system.contains(where: { JailPlan.under(agentPath, $0) }) {
            let fd = open(agentPath, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw failAll("cannot open \(agentPath)") }
            defer { close(fd) }
            do { agentPath = try JailClient.grant(jail: h.opened.name, path: agentPath, file: fd, socket: jaildSocket).inside }
            catch { throw failAll("cannot give the jail abyss-agent: \(error)") }
        }
        let (pid, proc): (UInt64, Int32)
        do {
            (pid, proc) = try JailClient.spawn(jail: h.opened.jail, argv: [
                agentPath, "serve", "--model", JailLayout.runtime + "/" + modelSock,
                "--listen", JailLayout.runtime + "/" + agentSock, "--class", cls] + extra + vocabArgs, socket: jaildSocket)
        } catch { throw failAll("cannot start abyss-agent: \(error)") }
        procs.append((proc, pid, "abyss-agent", h.opened.name, model, h.opened.root, h.opened.home, helpers))
        let socket = h.opened.runtime + "/" + agentSock
        guard waitForSocket(socket, seconds: 30, unless: nil) else {
            throw JailClient.Refused(description: "abyss-agent did not start in \(h.opened.name)")
        }
        say("jails: agent session \(id) in \(h.opened.name): agent pid \(pid), transcript \(transcript)")
        return AgentSession(id: id, socket: socket, transcript: transcript, pid: pid, vocabulary: k.vocabulary)
    }

    /// Give an application to an agent session (P18.10): `app` as a person
    /// names it (one running copy) or by its menu service, told to that
    /// session's bridge. Returns the application's own name.
    public func give(session: String, app: String) throws -> String {
        guard let control = vocabularies[session] else {
            throw JailClient.Refused(description: "there is no agent session \(session) with a vocabulary")
        }
        let service: String
        do { service = try MenuClient.resolve(app) } catch {
            throw JailClient.Refused(description: "no running application \(app): \(error)")
        }
        var m = Msg(); m.set("method", "give"); m.set("service", service)
        let fd = try Current.connect(path: control)
        defer { close(fd) }
        try Current.send(m, on: fd)
        let r = try Current.receive(on: fd)
        guard r.bool("ok") == true, let name = r.string("app") else {
            throw JailClient.Refused(description: r.string("error") ?? "the bridge refused")
        }
        say("jails: gave \(name) (\(service)) to agent session \(session)")
        return name
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
                let status = ap_procdesc_wait(p.fd)
                if status >= 0, p.model == nil, let (sig, dumped) = Crash.signal(of: status) {
                    crashed(p.name, jail: p.jail, root: p.root, home: p.home, signal: sig, coreDumped: dumped)
                }
                say("jails: \(p.name) (pid \(p.pid)) in \(p.jail) exited")
                if var m = p.model {
                    _ = ap_child_signal(&m, SIGTERM)
                    _ = ap_child_reap(&m, nil)
                    say("jails: its model stopped")
                }
                for var c in p.helpers {
                    _ = ap_child_signal(&c, SIGTERM)
                    _ = ap_child_reap(&c, nil)
                }
                if !p.helpers.isEmpty { say("jails: its vocabulary stopped") }
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
                reply.set("transcript", a.transcript); reply.set("pid", a.pid); reply.set("vocabulary", a.vocabulary)
            } catch {
                say("jails: agent refused: \(error)")
                reply = JailWire.error("\(error)")
            }
        case "debug":
            do {
                let a = try debug(Int(req.uint64("crash") ?? 0))
                reply.set("ok", true); reply.set("session", a.id); reply.set("socket", a.socket)
                reply.set("transcript", a.transcript); reply.set("pid", a.pid); reply.set("vocabulary", a.vocabulary)
            } catch {
                say("jails: debug refused: \(error)")
                reply = JailWire.error("\(error)")
            }
        case "give":
            do {
                let name = try give(session: req.string("session") ?? "", app: req.string("app") ?? "")
                reply.set("ok", true); reply.set("app", name)
            } catch {
                say("jails: give refused: \(error)")
                reply = JailWire.error("\(error)")
            }
        case "crashes":
            reply.set("ok", true)
            reply.set("crashes", bytes: JailWire.list(crashes.keys.sorted().map { id in
                let c = crashes[id]!
                return "\(id) \(c.summary) in \(c.jail)"
            }))
        case "held":
            reply.set("ok", true)
            reply.set("jails", bytes: JailWire.list(held.values.map { "\($0.opened.name) jid=\($0.opened.jid)" }.sorted()))
        default:
            reply = JailWire.error("unknown method")
        }
        try? Current.send(reply, on: c)
    }
}
