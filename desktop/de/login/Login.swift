// Login — the session's authenticator, as a library (PHASE16 P16.1).
//
// Nothing unprivileged on FreeBSD can check a password: OpenPAM's `pam_unix`
// reads `master.passwd`, which only root can, so even a person checking their
// **own** password is refused (PHASE16 §4.2). The lock screen and the login
// window both need the answer, so one root daemon — `abyss-loginwindow` —
// gives it, on a socket every user can reach, to exactly one question: *is
// this my password?*
//
// Three rules carry the security, and each lives here, where it is tested:
//
//   - **The caller is who the kernel says.** The uid comes from the socket
//     (`ap_peer_uid`); the request carries no name, so there is nothing to
//     forge. A person can only ever learn about their own password.
//   - **Guessing is slow.** After a couple of typos each further failure
//     doubles a wait (2 s, 4 s, … five minutes), per uid, during which the
//     daemon refuses without asking PAM at all; a success clears it.
//   - **The password is never written down.** It is not logged, and every
//     copy this code holds is wiped when the answer is known.

import CurrentIPC
import CPAM
import CPlatform

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Login {
    /// Where the daemon listens: system-wide, outside any session's runtime
    /// directory, because every session — and the login window's own user —
    /// asks it.
    public static let defaultSocket = "/var/run/abyss-loginwindow.sock"
    /// The PAM service: its own stack in `/etc/pam.d/abyss`, **not** an
    /// `include` of `login` — whose first line, `pam_self`, passes when the
    /// caller is the target user, and the caller here is root.
    public static let defaultService = "abyss"
    /// The greeter's account (P16.5): the login window runs as it, and only
    /// it may ask about *another* account's password.
    public static let greeterUser = "_loginwindow"

    /// Zero a password's bytes and empty it, through a volatile write the
    /// optimiser cannot drop (CPAM's `abyss_wipe`).
    public static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { abyss_wipe($0.baseAddress, $0.count) }
        bytes = []
    }
}

// MARK: - The limiter

/// How long a uid must wait before it may try again. Pure, so it is tested
/// with a clock it is handed.
public struct Limiter: Sendable {
    /// Failures in a row that cost nothing: a typo, and another.
    public static let free = 2
    /// The longest wait, however many failures.
    public static let capNs: UInt64 = 300_000_000_000

    private var failures: [UInt32: Int] = [:]
    private var waitUntil: [UInt32: UInt64] = [:]

    public init() {}

    /// Nanoseconds `uid` must still wait at `now`; zero when it may ask.
    public func wait(for uid: UInt32, now: UInt64) -> UInt64 {
        guard let until = waitUntil[uid], until > now else { return 0 }
        return until - now
    }

    /// The answer was no: the next attempt waits longer.
    public mutating func failed(_ uid: UInt32, now: UInt64) {
        let n = (failures[uid] ?? 0) + 1
        failures[uid] = n
        guard n > Limiter.free else { return }
        let shift = min(n - Limiter.free, 20)
        let ns = min(UInt64(1_000_000_000) << UInt64(shift), Limiter.capNs)
        waitUntil[uid] = now &+ ns
    }

    /// The answer was yes: start over.
    public mutating func succeeded(_ uid: UInt32) {
        failures[uid] = nil
        waitUntil[uid] = nil
    }

    public func failures(of uid: UInt32) -> Int { failures[uid] ?? 0 }
}

// MARK: - The wire

/// What the daemon says.
public enum Verdict: Equatable, Sendable {
    case accepted
    case refused
    /// Too many failures: ask again after this many milliseconds.
    case wait(UInt64)
    /// The daemon cannot answer — no PAM, or PAM failed — and says why.
    case unavailable(String)
}

public enum LoginWire {
    public static func request(password: [UInt8]) -> Msg {
        var m = Msg()
        m.set("method", "verify")
        m.set("password", bytes: password)
        return m
    }

    public static func reply(_ v: Verdict) -> Msg {
        var m = Msg()
        m.set("ok", true)
        switch v {
        case .accepted: m.set("verdict", "accepted")
        case .refused: m.set("verdict", "refused")
        case .wait(let ms): m.set("verdict", "wait"); m.set("retry_after_ms", ms)
        case .unavailable(let why): m.set("verdict", "unavailable"); m.set("why", why)
        }
        return m
    }

    /// An `ok: false` reply, in the CurrentIPC idiom every service here uses.
    public static func error(_ why: String) -> Msg {
        var m = Msg()
        m.set("ok", false)
        m.set("error", why)
        return m
    }

    public static func decode(_ m: Msg) -> Verdict? {
        switch m.string("verdict") {
        case "accepted": return .accepted
        case "refused": return .refused
        case "wait": return .wait(m.uint64("retry_after_ms") ?? 0)
        case "unavailable": return .unavailable(m.string("why") ?? "")
        default: return nil
        }
    }
}

// MARK: - The decision

/// What PAM said, as the authenticator needs it.
public enum Check: Equatable, Sendable {
    case yes, no(String), unavailable(String)
}

/// One request → one verdict, and the line to log — which never contains the
/// password. Everything it needs is handed to it, so the tests drive it with
/// no root, no PAM and no socket.
public struct Authenticator {
    public var limiter = Limiter()
    /// The account name for a uid (getpwuid), nil if there is none.
    let userName: (UInt32) -> String?
    /// Is `password` the password of `user`?
    let check: (_ user: String, _ password: [UInt8]) -> Check

    public init(userName: @escaping (UInt32) -> String?,
                check: @escaping (_ user: String, _ password: [UInt8]) -> Check) {
        self.userName = userName
        self.check = check
    }

    /// The real thing: getpwuid and PAM service `service`.
    public static func system(service: String = Login.defaultService) -> Authenticator {
        Authenticator(userName: { uid in
            guard let pw = getpwuid(uid_t(uid)), let n = pw.pointee.pw_name else { return nil }
            return String(cString: n)
        }, check: { user, password in
            var why = [CChar](repeating: 0, count: 256)
            let rc = password.withUnsafeBufferPointer { p in
                abyss_pam_check(service, user, p.baseAddress, p.count, &why, why.count)
            }
            let text = String(decoding: why.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            switch rc {
            case 1: return .yes
            case 0: return .no(text)
            default: return .unavailable(text)
            }
        })
    }

    /// The login window's question (P16.5): is this **that account's**
    /// password? `callerIsGreeter` is the service's decision that the kernel's
    /// uid for the caller is the greeter's — nobody else may ask about an
    /// account not their own. The wait is per *account asked about*: guessing
    /// one account's password is slow however many accounts guess.
    public mutating func handleLogin(callerIsGreeter: Bool, request: Msg, now: UInt64,
                                     uidOf: (String) -> UInt32?) -> (reply: Msg, log: String, user: String?) {
        guard callerIsGreeter else {
            return (LoginWire.error("only the login window may ask about another account"),
                    "login refused: the caller is not the login window", nil)
        }
        guard let name = request.string("user"), !name.isEmpty else {
            return (LoginWire.error("login needs an account name"), "login: no account named", nil)
        }
        guard var password = request.bytes("password") else {
            return (LoginWire.error("login needs a password"), "login \(name): no password given", nil)
        }
        defer { password.withUnsafeMutableBytes { abyss_wipe($0.baseAddress, $0.count) } }
        // An account that does not exist is refused like a wrong password —
        // and costs a wait like one, under a key of its own — so the window
        // cannot be used to learn which names are accounts.
        let key = uidOf(name) ?? (0x8000_0000 | UInt32(truncatingIfNeeded: name.hashValue & 0x7fff_ffff))
        let w = limiter.wait(for: key, now: now)
        if w > 0 {
            let ms = (w + 999_999) / 1_000_000
            return (LoginWire.reply(.wait(ms)), "login \(name): asked again too soon — wait \(ms) ms", nil)
        }
        guard uidOf(name) != nil else {
            limiter.failed(key, now: now)
            return (LoginWire.reply(.refused), "login \(name): refused (no such account)", nil)
        }
        switch check(name, password) {
        case .yes:
            limiter.succeeded(key)
            return (LoginWire.reply(.accepted), "login \(name): accepted", name)
        case .no(let why):
            limiter.failed(key, now: now)
            let next = limiter.wait(for: key, now: now)
            return (LoginWire.reply(.refused), "login \(name): refused (\(why))"
                    + (next > 0 ? "; the next try waits \(next / 1_000_000_000) s" : ""), nil)
        case .unavailable(let why):
            return (LoginWire.reply(.unavailable(why)), "login \(name): could not ask PAM — \(why)", nil)
        }
    }

    /// `uid` is the kernel's answer for the caller, nil if it would not say.
    public mutating func handle(uid: UInt32?, request: Msg, now: UInt64) -> (reply: Msg, log: String) {
        guard let uid else {
            // Never fall back to "allow" — or to anyone's account.
            return (LoginWire.error("the kernel would not identify the caller"),
                    "refused a caller the kernel would not identify")
        }
        guard request.string("method") == "verify" else {
            return (LoginWire.error("unknown method \(request.string("method") ?? "(none)")"),
                    "uid \(uid): unknown method")
        }
        guard var password = request.bytes("password") else {
            return (LoginWire.error("verify needs a password"), "uid \(uid): no password given")
        }
        defer { password.withUnsafeMutableBytes { abyss_wipe($0.baseAddress, $0.count) } }
        let w = limiter.wait(for: uid, now: now)
        if w > 0 {
            let ms = (w + 999_999) / 1_000_000
            return (LoginWire.reply(.wait(ms)), "uid \(uid): asked again too soon — wait \(ms) ms")
        }
        guard let user = userName(uid) else {
            return (LoginWire.reply(.refused), "uid \(uid): no such account")
        }
        switch check(user, password) {
        case .yes:
            limiter.succeeded(uid)
            return (LoginWire.reply(.accepted), "uid \(uid) (\(user)): accepted")
        case .no(let why):
            limiter.failed(uid, now: now)
            let next = limiter.wait(for: uid, now: now)
            return (LoginWire.reply(.refused), "uid \(uid) (\(user)): refused (\(why))"
                    + (next > 0 ? "; the next try waits \(next / 1_000_000_000) s" : ""))
        case .unavailable(let why):
            return (LoginWire.reply(.unavailable(why)), "uid \(uid) (\(user)): could not ask PAM — \(why)")
        }
    }
}

// MARK: - The client

public enum LoginError: Error, CustomStringConvertible {
    case service(String)
    case garbled
    public var description: String {
        switch self {
        case .service(let s): return s
        case .garbled: return "the authenticator's answer could not be read"
        }
    }
}

// MARK: - Accounts

/// An account the login window offers.
public struct LoginAccount: Equatable, Sendable {
    public let name: String
    public let fullName: String
    public let uid: UInt32
    public init(name: String, fullName: String, uid: UInt32) { self.name = name; self.fullName = fullName; self.uid = uid }
}

public enum LoginAccounts {
    /// Who may log in at the window: people, not the system's accounts —
    /// uid 1000 and up (FreeBSD's first user), not `nobody`, and with a
    /// shell that lets them in. Pure, so it is tested with made-up entries.
    public static func offered(_ entries: [(name: String, uid: UInt32, gecos: String, shell: String)]) -> [LoginAccount] {
        entries.filter { e in
            e.uid >= 1000 && e.uid < 65534 && !e.name.hasPrefix("_")
                && !e.shell.hasSuffix("/nologin") && !e.shell.hasSuffix("/false") && !e.shell.isEmpty
        }.map { e in
            let full = e.gecos.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return LoginAccount(name: e.name, fullName: full.isEmpty ? e.name : full, uid: e.uid)
        }.sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
    }

    /// From a passwd(5) file's text — a scratch root's, in a test (P16.6a).
    public static func parse(passwd text: String) -> [LoginAccount] {
        offered(text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, !line.hasPrefix("#"), let uid = UInt32(f[2]) else { return nil }
            return (f[0], uid, f[4], f[6])
        })
    }

    /// Who is in `group`, from a group(5) file's text.
    public static func members(of group: String, in text: String) -> Set<String> {
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ":", omittingEmptySubsequences: false)
            if f.count >= 4, f[0] == group { return Set(f[3].split(separator: ",").map(String.init)) }
        }
        return []
    }

    /// Who logs in at boot, from rc.conf's text: `abyss_desktop_user`, when
    /// `abyss_desktop_enable` says so — nil for the login window.
    public static func autoLogin(rcConf text: String) -> String? {
        var enabled = false, user: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingPrefix(while: { $0 == " " || $0 == "\t" })
            func value(_ key: String) -> String? {
                guard line.hasPrefix(key + "=") else { return nil }
                return String(line.dropFirst(key.count + 1)).filter { $0 != "\"" && $0 != "'" }
            }
            if let v = value("abyss_desktop_enable") { enabled = v.uppercased() == "YES" }
            if let v = value("abyss_desktop_user") { user = v.isEmpty ? nil : v }
        }
        return enabled ? user : nil
    }

    /// This machine's, from the password database.
    public static func system() -> [LoginAccount] {
        var all: [(name: String, uid: UInt32, gecos: String, shell: String)] = []
        setpwent()
        while let p = getpwent() {
            func s(_ c: UnsafeMutablePointer<CChar>?) -> String { c.map { String(cString: $0) } ?? "" }
            all.append((s(p.pointee.pw_name), UInt32(p.pointee.pw_uid), s(p.pointee.pw_gecos), s(p.pointee.pw_shell)))
        }
        endpwent()
        return offered(all)
    }
}

public enum LoginClient {
    /// The login window's question (P16.5a): is `password` the password of
    /// `user`? Only the greeter's account may ask.
    public static func login(user: String, password: [UInt8], socket: String = LoginClient.socket) throws -> Int32 {
        var m = LoginWire.request(password: password)
        m.set("method", "login")
        m.set("user", user)
        defer {
            if var b = m.bytes("password") { b.withUnsafeMutableBytes { abyss_wipe($0.baseAddress, $0.count) } }
            m = Msg()
        }
        let s = try Current.connect(path: socket)
        do { try Current.send(m, on: s) } catch { close(s); throw error }
        return s
    }

    /// The socket a session asks: `$ABYSS_LOGIN_SOCKET` if set (a test's own
    /// authenticator), else the system's.
    public static var socket: String {
        getenv("ABYSS_LOGIN_SOCKET").map { String(cString: $0) } ?? Login.defaultSocket
    }

    /// Ask whether `password` is this process's user's, and wait for the
    /// answer. The caller's copy is theirs to wipe; this one's is wiped before
    /// it returns.
    public static func verify(password: [UInt8], socket: String = Login.defaultSocket) throws -> Verdict {
        let s = try begin(password: password, socket: socket)
        defer { close(s) }
        return try finish(on: s)
    }

    /// The first half, for a run loop: connect and ask, and return the socket
    /// to poll. The request's copy of the password is wiped once it is sent.
    public static func begin(password: [UInt8], socket: String = Login.defaultSocket) throws -> Int32 {
        var request = LoginWire.request(password: password)
        defer {
            if var b = request.bytes("password") { b.withUnsafeMutableBytes { abyss_wipe($0.baseAddress, $0.count) } }
            request = Msg()
        }
        let s = try Current.connect(path: socket)
        do { try Current.send(request, on: s) } catch { close(s); throw error }
        return s
    }

    /// The second half: read the answer from a socket `begin` returned.
    /// The caller closes it.
    public static func finish(on s: Int32) throws -> Verdict {
        let reply = try Current.receive(on: s)
        guard reply.bool("ok") == true else { throw LoginError.service(reply.string("error") ?? "refused") }
        guard let v = LoginWire.decode(reply) else { throw LoginError.garbled }
        return v
    }
}

// MARK: - Power (the wire; the daemon's half is P16.4)

/// What the session may ask the root daemon to do to the machine: the idle
/// policy's "sleep" (P16.3), the system menu's three and the lid (P16.4).
public enum PowerAction: String, CaseIterable, Sendable {
    case sleep, restart, shutDown = "shut-down"
    /// The machine's own buttons, from devd (P16.4b): root's to send.
    case lid, sleepKey = "sleep-key", powerKey = "power-key"

    /// An event from the hardware rather than a person's choice.
    public var isHardware: Bool { self == .lid || self == .sleepKey || self == .powerKey }
}

public enum PowerClient {
    /// Ask for `action`. The reply's `ok`, or why not — an error naming the
    /// method is a daemon from before P16.4, which says so and does nothing.
    public static func request(_ action: PowerAction, socket: String = LoginClient.socket) throws -> Msg {
        var m = Msg()
        m.set("method", "power")
        m.set("action", action.rawValue)
        let s = try Current.connect(path: socket)
        defer { close(s) }
        try Current.send(m, on: s)
        return try Current.receive(on: s)
    }
}

/// The caller of a connected socket, as the kernel reports it.
public func loginPeerUID(_ socket: Int32) -> UInt32? {
    var uid: UInt32 = 0
    guard ap_peer_uid(socket, &uid) == 0 else { return nil }
    return uid
}
