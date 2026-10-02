// JailService — abyss-jaild's loop, as a library (PHASE18 P18.2).
//
// Root, one socket, two requests, always for the caller's own uid (the kernel
// says who that is; a request names nobody):
//
//   open  class=NAME  → builds the class's root for the caller (P18.1's plan,
//                       refused if it has any violation), creates the jail,
//                       and hands back an OWNING jail descriptor. The jail
//                       lives exactly as long as the caller holds it (§4.2).
//                       Pooled: a second open of a live jail gets a
//                       non-owning descriptor of the same one.
//   spawn jail=FD argv=… → starts argv in that jail as the caller, and hands
//                       back its process descriptor. The descriptor proves
//                       which jail; the jail's name proves whose.
//   grant jail=NAME path=P file=FD → mounts that one file into the caller's
//                       jail (P18.4) and answers where it is inside. FD is the
//                       caller's own descriptor of P — the portal's, opened on
//                       the file the person chose — and it is the proof: a
//                       grant reaches nothing the caller could not open, and
//                       is writable only if FD is.
//   revoke jail=NAME grant=N, grants jail=NAME → take one back; list them.
//
// It watches every jail it made through a non-owning descriptor of its own,
// and when one is removed — its owner closed it, or died — it unmounts and
// removes the root. On start it does the same for whatever a previous run left
// (`sweep`), and adopts the jails still alive.
//
// The classes are the shipped ones and a root-owned file's (`--classes`),
// never a user's: a person's own `jails.ini` is a request, and what a root
// daemon mounts is the system's decision.

import CurrentIPC
import CPlatform
import CProc
import CJail
import Jails
import PoolConfig

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum JailWire {
    public static let defaultSocket = "/var/run/abyss-jaild.sock"

    public static func error(_ why: String) -> Msg {
        var m = Msg(); m.set("ok", false); m.set("error", why); return m
    }

    /// A list of strings as one field: NUL-separated, so nothing in an
    /// argument can be mistaken for a separator.
    public static func list(_ xs: [String]) -> [UInt8] {
        var b: [UInt8] = []
        for (i, x) in xs.enumerated() { if i > 0 { b.append(0) }; b += Array(x.utf8) }
        return b
    }
    public static func unlist(_ b: [UInt8]) -> [String] {
        b.isEmpty ? [] : b.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The environment a spawn gets: the plan's, with the caller's extras
    /// added — but never over the plan's own keys, which say where the jail's
    /// home and runtime directory are.
    public static func environment(plan: [(String, String)], extra: [String]) -> [String] {
        var out = plan.map { "\($0.0)=\($0.1)" }
        let fixed = Set(plan.map(\.0))
        for e in extra {
            guard let eq = e.firstIndex(of: "="), eq != e.startIndex else { continue }
            if !fixed.contains(String(e[..<eq])) { out.append(e) }
        }
        return out
    }

    /// Whether `uid` may use the jail named `name`: only its own.
    public static func owns(_ uid: UInt32, _ name: String) -> Bool {
        name.hasPrefix("abyss-\(uid)-")
    }
}

/// Who an account is, as a jail needs it: the person, and where their real
/// home is (resolved, so a symlinked /home is seen for what it is).
public struct JailAccount: Sendable {
    public var user: JailUser
    public var home: String
    public init(user: JailUser, home: String) { self.user = user; self.home = home }

    public static func system(_ uid: UInt32) -> JailAccount? {
        guard uid != 0, let pw = getpwuid(uid_t(uid)) else { return nil }
        let dir = String(cString: pw.pointee.pw_dir)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let home = realpath(dir, &buf) != nil ? cString(buf) : dir
        return JailAccount(user: JailUser(name: String(cString: pw.pointee.pw_name), uid: uid,
                                          gid: UInt32(pw.pointee.pw_gid)), home: home)
    }
}

public final class JailService {
    private let server: Current.Server
    public var layout: JailLayout
    public var classes: [JailClass]
    public var pool: String?
    public var accountOf: (UInt32) -> JailAccount? = JailAccount.system
    private let performer: JailPerformer
    private let say: (String) -> Void
    private let kq: Int32
    public struct Grant: Equatable, Sendable {
        public var n: Int
        public var source: String
        public var inside: String
        public var writable: Bool
    }
    private struct Live {
        var watch: Int32; var plan: JailPlan; var uid: UInt32
        var grants: [Grant] = []
        var nextGrant = 1
    }
    private var live: [String: Live] = [:]

    public init(server: Current.Server, layout: JailLayout = .standard, classes: [JailClass] = JailClass.shipped,
                pool: String? = nil, commands: JailCommands = JailCommands(), log: @escaping (String) -> Void) {
        self.server = server
        self.layout = layout
        self.classes = classes
        self.pool = pool
        self.performer = JailPerformer(commands: commands, log: log)
        self.say = log
        self.kq = ap_kqueue()
    }

    // MARK: - start: what a previous run left

    /// Adopt the jails still alive under our roots; tear down the roots of
    /// those that are gone.
    public func sweep() {
        for root in MountTable.roots(under: layout.rootBase, in: performer.mounted()) {
            guard let name = MountTable.jailName(root: root, base: layout.rootBase) else { continue }
            let parts = name.split(separator: "-", maxSplits: 2)
            let watch = ap_jail_desc_by_name(name)
            if watch >= 0, parts.count == 3, let uid = UInt32(parts[1]), let acct = accountOf(uid),
               let cls = classes.first(where: { $0.name == parts[2] }) {
                _ = ap_jail_watch(kq, watch)
                live[name] = Live(watch: watch, plan: JailPlan.make(cls, for: acct.user, pool: pool, layout: layout), uid: uid)
                say("jaild: adopted \(name), still running")
            } else {
                if watch >= 0 { close(watch) }
                teardown(root, name: name, why: "left by a previous run")
            }
        }
    }

    private func teardown(_ root: String, name: String, why: String) {
        let failures = performer.performAll(JailSteps.teardown(root: root, mounted: performer.mounted(),
                                                               commands: performer.commands))
        if failures.isEmpty { say("jaild: \(name) removed (\(why)); its root is gone") }
        for f in failures { say("jaild: \(name): teardown: \(f)") }
    }

    // MARK: - the loop

    /// Serve until `once` has answered one request (a test), or for ever.
    ///
    /// **Every program a jail runs is this daemon's child** (pdfork), and on
    /// FreeBSD closing a process descriptor does not reap one (HANDOFF
    /// §2.108): the person's copy closes, the program dies, and without a
    /// `waitpid` here it stays a zombie — inside its jail, which then never
    /// finishes dying (§2.123). So SIGCHLD comes in on a self-pipe, and every
    /// exited child is reaped.
    public func run(once: Bool = false) {
        var sigs: [Int32] = [SIGCHLD]
        let chld = ap_signal_pipe(&sigs, 1)
        while true {
            var fds = [pollfd(fd: server.fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: kq, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: chld, events: Int16(POLLIN), revents: 0)]
            let n = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), -1) }
            if n < 0 { if errno == EINTR { continue }; return }
            if chld >= 0, fds[2].revents != 0 { reapChildren(chld) }
            if kq >= 0, fds[1].revents != 0 { reap() }
            if fds[0].revents != 0 {
                serveOne()
                if once { return }
            }
        }
    }

    /// Every child that has exited, waited for.
    private func reapChildren(_ pipe: Int32) {
        var b = [UInt8](repeating: 0, count: 64)
        _ = read(pipe, &b, b.count)
        var status: Int32 = 0
        while waitpid(-1, &status, WNOHANG) > 0 {}
    }

    /// Jails whose owners let go: tear their roots down.
    private func reap() {
        while true {
            let gone = ap_jail_removed(kq)
            guard gone >= 0 else { return }
            guard let e = live.first(where: { $0.value.watch == gone }) else { close(gone); continue }
            let name = e.key, l = e.value
            close(gone)
            live[name] = nil
            teardown(l.plan.root, name: name, why: "its owner let go")
        }
    }

    private func serveOne() {
        guard let client = try? server.accept() else { return }
        defer { close(client) }
        var peer: UInt32 = 0
        let known = ap_peer_uid(client, &peer) == 0
        guard var request = try? Current.receive(on: client) else { return }
        defer { request.closeFDs() }
        var reply: Msg
        var handOver: [Int32] = []
        if !known {
            reply = JailWire.error("the kernel would not identify the caller")
        } else if peer == 0 {
            reply = JailWire.error("root is not confined")
        } else {
            switch request.string("method") {
            case "open": (reply, handOver) = open(uid: peer, className: request.string("class") ?? "")
            case "spawn": (reply, handOver) = spawn(uid: peer, request: &request)
            case "grant": reply = grant(uid: peer, request: request)
            case "revoke": reply = revoke(uid: peer, request: request)
            case "grants": reply = grants(uid: peer, request: request)
            default: reply = JailWire.error("unknown method '\(request.string("method") ?? "")'")
            }
        }
        try? Current.send(reply, on: client)
        // Our copies go: an owning jail descriptor kept here would keep every
        // jail alive for ever.
        for fd in handOver { close(fd) }
    }

    // MARK: - open

    private func open(uid: UInt32, className: String) -> (Msg, [Int32]) {
        guard let acct = accountOf(uid) else { return (JailWire.error("uid \(uid) has no account"), []) }
        guard let cls = classes.first(where: { $0.name == className }) else {
            return (JailWire.error("no class '\(className)' (there are: \(classes.map(\.name).joined(separator: ", ")))"), [])
        }
        let plan = JailPlan.make(cls, for: acct.user, pool: pool, layout: layout)
        let v = plan.violations(for: cls, hostHome: acct.home)
        guard v.isEmpty else {
            say("jaild: refused \(plan.name): \(v.joined(separator: "; "))")
            return (JailWire.error("refused: " + v.joined(separator: "; ")), [])
        }

        if live[plan.name] != nil {
            let shared = ap_jail_desc_by_name(plan.name)
            guard shared >= 0 else { return (JailWire.error("\(plan.name) is live but cannot be named: \(errText())"), []) }
            return (opened(plan, desc: shared, shared: true), [shared])
        }
        if ap_jail_desc_by_name(plan.name) >= 0 {
            return (JailWire.error("a jail named \(plan.name) exists and is not ours"), [])
        }

        do {
            try performer.perform(JailSteps.build(plan, user: acct.user, commands: performer.commands))
        } catch {
            say("jaild: \(plan.name): \(error)")
            teardown(plan.root, name: plan.name, why: "its build failed")
            return (JailWire.error("cannot build \(plan.name): \(error)"), [])
        }

        let keys = plan.params.map(\.0), values = plan.params.map { $0.1 ?? "true" }
        var desc: Int32 = -1
        var err = [CChar](repeating: 0, count: 256)
        let errLen = err.count
        let jid = withCStrings(keys) { k in withCStrings(values) { v in
            ap_jail_create(k, v, Int32(keys.count), &desc, &err, errLen)
        } }
        guard jid >= 0 else {
            let why = cString(err)
            say("jaild: \(plan.name): \(why)")
            teardown(plan.root, name: plan.name, why: "the jail was refused")
            return (JailWire.error("cannot create \(plan.name): \(why)"), [])
        }
        let watch = ap_jail_desc_by_name(plan.name)
        if watch >= 0 { _ = ap_jail_watch(kq, watch) }
        live[plan.name] = Live(watch: watch, plan: plan, uid: uid)
        say("jaild: \(plan.name) is jail \(jid), for uid \(uid)")
        return (opened(plan, desc: desc, shared: false), [desc])
    }

    private func opened(_ plan: JailPlan, desc: Int32, shared: Bool) -> Msg {
        var jid: Int32 = 0
        var name = [CChar](repeating: 0, count: 256)
        let nameLen = name.count
        _ = ap_jail_identify(desc, &jid, &name, nameLen)
        var m = Msg()
        m.set("ok", true)
        m.set("jail", fd: desc)
        m.set("jid", UInt64(max(jid, 0)))
        m.set("name", plan.name)
        m.set("root", plan.root)
        m.set("runtime", plan.root + JailLayout.runtime)
        m.set("shared", shared)
        return m
    }

    // MARK: - spawn

    private func spawn(uid: UInt32, request: inout Msg) -> (Msg, [Int32]) {
        guard let jail = request.fd("jail") else { return (JailWire.error("spawn needs a jail descriptor"), []) }
        var jid: Int32 = 0
        var nameBuf = [CChar](repeating: 0, count: 256)
        let nameLen = nameBuf.count
        guard ap_jail_identify(jail, &jid, &nameBuf, nameLen) == 0 else {
            return (JailWire.error("that is not a jail descriptor: \(errText())"), [])
        }
        let name = cString(nameBuf)
        guard JailWire.owns(uid, name), let l = live[name], l.uid == uid else {
            say("jaild: uid \(uid) refused a spawn in \(name)")
            return (JailWire.error("\(name) is not yours"), [])
        }
        let argv = JailWire.unlist(request.bytes("argv") ?? [])
        guard !argv.isEmpty, !argv[0].isEmpty else { return (JailWire.error("spawn needs argv"), []) }
        let env = JailWire.environment(plan: l.plan.env, extra: JailWire.unlist(request.bytes("env") ?? []))
        let home = l.plan.env.first { $0.0 == "HOME" }?.1 ?? "/"
        guard let acct = accountOf(uid) else { return (JailWire.error("uid \(uid) has no account"), []) }
        var proc: Int32 = -1
        let pid = withCStrings(argv) { a in withCStrings(env) { e in
            ap_jail_spawn(jail, uid, acct.user.gid, a, e, home,
                          request.fd("stdin") ?? -1, request.fd("stdout") ?? -1, request.fd("stderr") ?? -1,
                          request.bool("daemon") == true ? 1 : 0, &proc)
        } }
        guard pid > 0 else { return (JailWire.error("cannot start \(argv[0]) in \(name): \(errText())"), []) }
        say("jaild: \(argv[0]) is pid \(pid) in \(name)")
        var m = Msg()
        m.set("ok", true)
        m.set("pid", UInt64(pid))
        m.set("proc", fd: proc)
        return (m, [proc])
    }
}

// MARK: - grants (P18.4)

extension JailService {
    /// The caller's live jail named in `request`, or why not.
    private func owned(_ uid: UInt32, _ request: Msg) -> Result<String, Refusal> {
        let name = request.string("jail") ?? ""
        guard JailWire.owns(uid, name), let l = live[name], l.uid == uid else {
            return .failure(Refusal("\(name.isEmpty ? "no jail named" : name + " is not yours")"))
        }
        return .success(name)
    }
    struct Refusal: Error { let why: String; init(_ w: String) { why = w } }

    func grant(uid: UInt32, request: Msg) -> Msg {
        let name: String
        switch owned(uid, request) { case .success(let n): name = n; case .failure(let r): return JailWire.error(r.why) }
        guard let fd = request.fd("file"), let path = request.string("path"), path.hasPrefix("/") else {
            return JailWire.error("grant needs the file's absolute path and the caller's descriptor of it")
        }
        // The descriptor and the path must be the same regular file, and the
        // path must be the file itself, not a way round to another.
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, held.st_mode & S_IFMT == S_IFREG else {
            return JailWire.error("the descriptor is not a regular file")
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &buf) != nil, cString(buf) == path else {
            return JailWire.error("\(path) is not a resolved path (a link, or gone)")
        }
        guard lstat(path, &named) == 0, named.st_dev == held.st_dev, named.st_ino == held.st_ino else {
            return JailWire.error("\(path) is not the file the descriptor is")
        }
        guard !JailPlan.under(path, layout.rootBase) else { return JailWire.error("\(path) is inside a jail") }
        let writable = fcntl(fd, F_GETFL) & O_ACCMODE != O_RDONLY

        guard var l = live[name] else { return JailWire.error("\(name) is gone") }
        let n = l.nextGrant
        do {
            try performer.perform(JailSteps.grant(root: l.plan.root, n: n, source: path, writable: writable,
                                                  commands: performer.commands))
        } catch {
            _ = performer.performAll(JailSteps.revoke(root: l.plan.root, n: n, source: path, commands: performer.commands))
            return JailWire.error("cannot grant \(path): \(error)")
        }
        // And what was mounted is what was proven: the same inode through the
        // jail's side, or it comes straight back out.
        var got = stat()
        let inside = JailSteps.grantPath(n, source: path)
        guard stat(l.plan.root + inside, &got) == 0, got.st_ino == held.st_ino else {
            _ = performer.performAll(JailSteps.revoke(root: l.plan.root, n: n, source: path, commands: performer.commands))
            return JailWire.error("\(path) changed while it was being granted")
        }
        l.nextGrant += 1
        l.grants.append(Grant(n: n, source: path, inside: inside, writable: writable))
        live[name] = l
        say("jaild: granted \(path) to \(name) at \(inside) (\(writable ? "read-write" : "read-only"))")
        var m = Msg()
        m.set("ok", true)
        m.set("path", inside)
        m.set("grant", UInt64(n))
        m.set("writable", writable)
        return m
    }

    func revoke(uid: UInt32, request: Msg) -> Msg {
        let name: String
        switch owned(uid, request) { case .success(let n): name = n; case .failure(let r): return JailWire.error(r.why) }
        guard var l = live[name], let n = request.uint64("grant"), let g = l.grants.first(where: { $0.n == Int(n) }) else {
            return JailWire.error("no such grant")
        }
        let failures = performer.performAll(JailSteps.revoke(root: l.plan.root, n: g.n, source: g.source,
                                                             commands: performer.commands))
        guard failures.isEmpty else { return JailWire.error("cannot revoke: \(failures[0])") }
        l.grants.removeAll { $0.n == g.n }
        live[name] = l
        say("jaild: revoked \(g.source) from \(name)")
        var m = Msg(); m.set("ok", true); return m
    }

    func grants(uid: UInt32, request: Msg) -> Msg {
        let name: String
        switch owned(uid, request) { case .success(let n): name = n; case .failure(let r): return JailWire.error(r.why) }
        let lines = (live[name]?.grants ?? []).map { "\($0.n)\t\($0.writable ? "rw" : "ro")\t\($0.inside)\t\($0.source)" }
        var m = Msg(); m.set("ok", true); m.set("grants", bytes: JailWire.list(lines)); return m
    }
}

/// A C buffer's string, up to its NUL.
func cString(_ b: [CChar]) -> String {
    String(decoding: b.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// `strings` as a NULL-terminated `char *const *`, for the length of `body`.
func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let copies = strings.map { strdup($0) }
    defer { copies.forEach { free($0) } }
    let ptrs: [UnsafePointer<CChar>?] = copies.map { UnsafePointer($0) } + [nil]
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}

// MARK: - the session's side

public enum JailClient {
    public struct Opened: Sendable {
        /// Owning, unless `shared`: hold it, and the jail lives.
        public let jail: Int32
        public let jid: UInt64
        public let name: String
        public let root: String
        /// The jail's runtime directory, as the host sees it: bind the jail's
        /// Wayland socket here (P18.3).
        public let runtime: String
        public let shared: Bool
    }

    public struct Refused: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    static func call(_ m: Msg, socket: String) throws -> Msg {
        let s = try Current.connect(path: socket)
        defer { close(s) }
        try Current.send(m, on: s)
        var r = try Current.receive(on: s)
        if r.bool("ok") != true {
            r.closeFDs()
            throw Refused(description: r.string("error") ?? "refused")
        }
        return r
    }

    public static func open(_ className: String, socket: String = JailWire.defaultSocket) throws -> Opened {
        var m = Msg(); m.set("method", "open"); m.set("class", className)
        var r = try call(m, socket: socket)
        guard let fd = r.takeFD("jail") else { throw Refused(description: "no jail descriptor in the answer") }
        return Opened(jail: fd, jid: r.uint64("jid") ?? 0, name: r.string("name") ?? "", root: r.string("root") ?? "",
                      runtime: r.string("runtime") ?? "", shared: r.bool("shared") ?? false)
    }

    /// Mount `path` into the caller's jail `name`, proven by `file` (the
    /// caller's descriptor of it). Answers where it is inside, and the grant's
    /// number.
    public static func grant(jail name: String, path: String, file: Int32,
                             socket: String = JailWire.defaultSocket) throws -> (inside: String, n: UInt64) {
        var m = Msg()
        m.set("method", "grant"); m.set("jail", name); m.set("path", path); m.set("file", fd: file)
        let r = try call(m, socket: socket)
        return (r.string("path") ?? "", r.uint64("grant") ?? 0)
    }

    public static func revoke(jail name: String, grant n: UInt64, socket: String = JailWire.defaultSocket) throws {
        var m = Msg(); m.set("method", "revoke"); m.set("jail", name); m.set("grant", n)
        _ = try call(m, socket: socket)
    }

    /// "N<TAB>rw|ro<TAB>inside<TAB>source", one per grant.
    public static func grants(jail name: String, socket: String = JailWire.defaultSocket) throws -> [String] {
        var m = Msg(); m.set("method", "grants"); m.set("jail", name)
        let r = try call(m, socket: socket)
        return JailWire.unlist(r.bytes("grants") ?? [])
    }

    /// Start `argv` in `jail`. The process descriptor is the caller's; closing
    /// it kills the process unless `daemon`.
    public static func spawn(jail: Int32, argv: [String], env: [String] = [], stdin: Int32? = nil,
                             stdout: Int32? = nil, stderr: Int32? = nil, daemon: Bool = false,
                             socket: String = JailWire.defaultSocket) throws -> (pid: UInt64, proc: Int32) {
        var m = Msg()
        m.set("method", "spawn")
        m.set("jail", fd: jail)
        m.set("argv", bytes: JailWire.list(argv))
        m.set("env", bytes: JailWire.list(env))
        if let stdin { m.set("stdin", fd: stdin) }
        if let stdout { m.set("stdout", fd: stdout) }
        if let stderr { m.set("stderr", fd: stderr) }
        m.set("daemon", daemon)
        var r = try call(m, socket: socket)
        guard let proc = r.takeFD("proc") else { throw Refused(description: "no process descriptor in the answer") }
        return (r.uint64("pid") ?? 0, proc)
    }
}
