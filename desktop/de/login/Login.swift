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

public enum LoginClient {
    /// Ask whether `password` is this process's user's. The caller's copy is
    /// theirs to wipe; this one's is wiped before it returns.
    public static func verify(password: [UInt8], socket: String = Login.defaultSocket) throws -> Verdict {
        var request = LoginWire.request(password: password)
        defer {
            if var b = request.bytes("password") { b.withUnsafeMutableBytes { abyss_wipe($0.baseAddress, $0.count) } }
            request = Msg()
        }
        let s = try Current.connect(path: socket)
        defer { close(s) }
        try Current.send(request, on: s)
        let reply = try Current.receive(on: s)
        guard reply.bool("ok") == true else { throw LoginError.service(reply.string("error") ?? "refused") }
        guard let v = LoginWire.decode(reply) else { throw LoginError.garbled }
        return v
    }
}

/// The caller of a connected socket, as the kernel reports it.
public func loginPeerUID(_ socket: Int32) -> UInt32? {
    var uid: UInt32 = 0
    guard ap_peer_uid(socket, &uid) == 0 else { return nil }
    return uid
}
