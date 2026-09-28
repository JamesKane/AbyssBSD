// The settings helper's privileged half, as a service (PHASE14 P14.3).
//
//   read   {kind}    → what the machine says now, as a plan of that kind
//   check  {plan…}   → the refusals, or the steps it compiles to — nothing run
//   apply  {plan…}   → the same compile, then run it, one message per step and
//                      a final `finished`
//
// `abyss-install`'s shape, deliberately (PHASE14 §3): the caller describes, this
// decides, and the caller never names a command, a file or a variable.

import CPlatform
import CurrentIPC
import Settings
import SettingsWire
import Spawn

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Who may change the machine (§6.1)

/// The uid this helper was started for, **and only while it is an
/// administrator.** Membership is asked at every connection rather than once
/// at startup: a person removed from `wheel` stops being able to change the
/// machine at that moment, not at the next reboot. No password is asked in
/// this phase — a trustworthy prompt is Phase 16's to build (§6.1).
public struct Authority: Sendable {
    public let allowed: UInt32
    /// The group that makes an administrator: `wheel`, as the installer says.
    /// A parameter so a test can name one its user is not in.
    public let adminGroup: String

    public init(allowed: UInt32, adminGroup: String = "wheel") {
        self.allowed = allowed
        self.adminGroup = adminGroup
    }

    /// The decision, and the sentence to log when it is no. Never fails open.
    public func admits(_ socket: Int32) -> (ok: Bool, why: String) {
        var uid: UInt32 = 0
        guard ap_peer_uid(socket, &uid) == 0 else {
            return (false, "the kernel would not identify the caller")
        }
        guard uid == allowed else {
            return (false, "uid \(uid) may not use a settings helper started for uid \(allowed)")
        }
        guard Authority.isMember(uid: uid, of: adminGroup) else {
            return (false, "\(Authority.name(uid) ?? "uid \(uid)") is not an administrator"
                    + " (not in \(adminGroup)), and only an administrator may change the machine")
        }
        return (true, "")
    }

    static func name(_ uid: UInt32) -> String? {
        guard let pw = getpwuid(uid_t(uid)), let n = pw.pointee.pw_name else { return nil }
        return String(cString: n)
    }

    /// Whether `uid` is in `group` — as its primary group or a listed member.
    static func isMember(uid: UInt32, of group: String) -> Bool {
        guard let gr = getgrnam(group) else { return false }
        guard let pw = getpwuid(uid_t(uid)) else { return false }
        if pw.pointee.pw_gid == gr.pointee.gr_gid { return true }
        guard let me = pw.pointee.pw_name.map({ String(cString: $0) }),
              var members = gr.pointee.gr_mem else { return false }
        while let m = members.pointee {
            if String(cString: m) == me { return true }
            members += 1
        }
        return false
    }
}

// MARK: - The service

public final class SettingsService {
    public let authority: Authority
    /// Run everything except the commands: identical events, nothing written.
    public let dryRun: Bool
    /// The rc.conf this helper edits — `/etc/rc.conf`, or a scratch file for a
    /// test that must not touch the machine it runs on.
    public let rcConf: String
    /// Where every apply is recorded, whatever its outcome. Empty for none.
    public let journal: String

    public init(authority: Authority, dryRun: Bool = false,
                rcConf: String = "/etc/rc.conf", journal: String = "/var/log/abyss-settings.log") {
        self.authority = authority
        self.dryRun = dryRun
        self.rcConf = rcConf
        self.journal = journal
    }

    /// Why this machine cannot be changed by this helper at all, or nil.
    /// **On Linux it refuses, and says why** (§6.4) — the positive control that
    /// shows the refusal exists, rather than a skip that shows nothing.
    public var platformRefusal: String? {
        #if os(FreeBSD)
        return nil
        #else
        return "this helper changes FreeBSD's rc.conf, and this machine is not FreeBSD"
            + " — nothing was read or written"
        #endif
    }

    @discardableResult
    public func serve(_ client: Int32, log: (String) -> Void = { _ in }) -> String {
        let verdict = authority.admits(client)
        guard verdict.ok else {
            var deny = Msg()
            deny.set("ok", false)
            deny.set("error", "refused: " + verdict.why)
            try? Current.send(deny, on: client)
            return "refused a caller: \(verdict.why)"
        }
        var request: Msg
        do { request = try Current.receive(on: client) } catch {
            return "a client connected and said nothing useful: \(error)"
        }
        request.closeFDs()
        switch request.string("method") ?? "" {
        case "read": return handleRead(client, request)
        case "check": return handleCheck(client, request)
        case "apply": return handleApply(client, request, log: log)
        case let other:
            var reply = Msg()
            reply.set("ok", false)
            reply.set("error", other.isEmpty ? "no method named in the request" : "no such method: \(other)")
            try? Current.send(reply, on: client)
            return "unknown method '\(other)'"
        }
    }

    private func refuse(_ client: Int32, _ why: String) -> String {
        var reply = Msg()
        reply.set("ok", false)
        reply.set("error", why)
        try? Current.send(reply, on: client)
        return "refused: \(why)"
    }

    private func handleRead(_ client: Int32, _ request: Msg) -> String {
        let kind = request.string("kind") ?? ""
        guard let keys = Settings.keys(for: kind) else { return refuse(client, "there is no \(kind) plan") }
        if let why = platformRefusal { return refuse(client, why) }
        var values: [String: String] = [:]
        for k in keys {
            // `sysrc -n` answers as rc(8) would — the defaults, then rc.conf.
            let r = Spawn.run(["sysrc", "-f", rcConf, "-n", k], limit: 4096)
            if r.succeeded { values[k] = trimmed(r.stdoutText) }
        }
        guard let plan = Settings.current(kind: kind, values: values) else {
            return refuse(client, "could not read the \(kind) settings")
        }
        var reply = Msg()
        reply.set("ok", true)
        SettingsWire.encode(plan, into: &reply)
        try? Current.send(reply, on: client)
        return "read \(kind): \(values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: " "))"
    }

    private func handleCheck(_ client: Int32, _ request: Msg) -> String {
        let plan: SettingsPlan
        switch SettingsWire.decodePlan(request) {
        case .failure(let r): return refuse(client, r.message)
        case .success(let p): plan = p
        }
        var reply = Msg()
        let refusals = Settings.problems(plan)
        reply.set("ok", refusals.isEmpty)
        reply.set("problems.count", UInt64(refusals.count))
        for (i, r) in refusals.enumerated() { reply.set("problem.\(i)", r.message) }
        if refusals.isEmpty, let steps = try? Settings.compile(plan) {
            reply.set("steps.count", UInt64(steps.count))
            reply.set("render", Settings.render(steps, rcConf: rcConf))
        }
        try? Current.send(reply, on: client)
        return refusals.isEmpty ? "check \(plan.kind): ok" : "check \(plan.kind): refused"
    }

    private func handleApply(_ client: Int32, _ request: Msg, log: (String) -> Void) -> String {
        let plan: SettingsPlan
        switch SettingsWire.decodePlan(request) {
        case .failure(let r): return refuse(client, r.message)
        case .success(let p): plan = p
        }
        if !dryRun, let why = platformRefusal { return refuse(client, why) }
        let steps: [SettingsStep]
        do { steps = try Settings.compile(plan) } catch let r as SettingsRefusal {
            return refuse(client, r.message)
        } catch { return refuse(client, "\(error)") }

        var record: [String] = ["apply \(plan.kind) for uid \(authority.allowed)"
                                + (dryRun ? " (dry run)" : "")]
        let ok = Runner.apply(steps, rcConf: rcConf, dryRun: dryRun) { e in
            try? Current.send(SettingsWire.encode(e), on: client)
            switch e {
            case .starting(let i, _, let what): record.append("  \(i + 1). \(what)")
            case .failed(_, _, let why, let ignored): record.append("     \(ignored ? "failed, and that is allowed" : "FAILED"): \(why)")
            case .finished(let ok, let err): record.append(ok ? "  done" : "  NOT APPLIED: \(err)")
            case .ok: break
            }
        }
        appendJournal(record)
        for line in record { log(line) }
        return "apply \(plan.kind): " + (ok ? "done" : "failed") + (dryRun ? " (dry run)" : "")
    }

    private func appendJournal(_ lines: [String]) {
        guard !journal.isEmpty, let f = fopen(journal, "a") else { return }
        defer { fclose(f) }
        var t = time(nil)
        var tm = tm()
        localtime_r(&t, &tm)
        var buf = [CChar](repeating: 0, count: 32)
        strftime(&buf, buf.count, "%Y-%m-%d %H:%M:%S", &tm)
        fputs("\(String(cString: buf)) " + lines.joined(separator: "\n") + "\n", f)
    }
}

// MARK: - The runner

public enum Runner {
    /// Run the steps, reporting each. rc.conf writes go into a **staged copy**
    /// that replaces the real file in one `rename`, and only once every write
    /// succeeded — so a plan that fails half-way leaves rc.conf exactly as it
    /// was, rather than half-changed with nobody knowing which half. Services
    /// act after that, on the rc.conf that is now in place.
    @discardableResult
    public static func apply(_ steps: [SettingsStep], rcConf: String, dryRun: Bool,
                             emit: (SettingsEvent) -> Void) -> Bool {
        let staged = rcConf + ".abyss-staged"
        let lastRc = steps.lastIndex { if case .rcConf = $0 { return true }; return false }
        var stagedExists = false
        func fail(_ i: Int, _ what: String, _ why: String) -> Bool {
            if stagedExists { unlink(staged) }
            emit(.failed(index: i, what: what, why: why, ignored: false))
            emit(.finished(ok: false, error: "\(what): \(why)"))
            return false
        }

        for (i, step) in steps.enumerated() {
            emit(.starting(index: i, total: steps.count, what: step.description))
            if dryRun { emit(.ok(index: i)); continue }
            switch step {
            case .rcConf:
                if !stagedExists {
                    if let why = copyFile(rcConf, to: staged) { return fail(i, step.description, why) }
                    stagedExists = true
                }
                let r = Spawn.run(step.command(rcConf: staged), stderr: .merge, limit: 8192)
                guard r.succeeded else {
                    return fail(i, step.description, reason(r))
                }
                if i == lastRc {
                    guard rename(staged, rcConf) == 0 else {
                        return fail(i, step.description, "could not put the new rc.conf in place: "
                                    + String(cString: strerror(errno)))
                    }
                    stagedExists = false
                }
                emit(.ok(index: i))
            case .service(_, _, let mayFail):
                let r = Spawn.run(step.command(rcConf: rcConf), stderr: .merge, limit: 8192)
                if r.succeeded { emit(.ok(index: i)); continue }
                if mayFail {
                    emit(.failed(index: i, what: step.description, why: reason(r), ignored: true))
                    continue
                }
                return fail(i, step.description, reason(r))
            }
        }
        emit(.finished(ok: true, error: ""))
        return true
    }

    static func reason(_ r: Spawn.Result) -> String {
        if let f = r.failure { return f }
        let said = trimmed(r.stdoutText)
        return said.isEmpty ? "exited \(r.code) and said nothing" : said
    }

    /// Copy `from` to `to` with `from`'s mode — or, when `from` does not exist,
    /// an empty file: a machine with no rc.conf yet gets its first one.
    static func copyFile(_ from: String, to: String) -> String? {
        var st = stat()
        let exists = stat(from, &st) == 0
        let mode = exists ? mode_t(st.st_mode & 0o7777) : 0o644
        let out = open(to, O_WRONLY | O_CREAT | O_TRUNC, mode)
        guard out >= 0 else { return "could not stage \(to): \(String(cString: strerror(errno)))" }
        defer { close(out) }
        guard exists else { return nil }
        let inp = open(from, O_RDONLY)
        guard inp >= 0 else { return "could not read \(from): \(String(cString: strerror(errno)))" }
        defer { close(inp) }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(inp, $0.baseAddress, $0.count) }
            if n == 0 { return nil }
            if n < 0 { return "could not read \(from): \(String(cString: strerror(errno)))" }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(out, $0.baseAddress! + off, n - off) }
                if w <= 0 { return "could not stage \(to): \(String(cString: strerror(errno)))" }
                off += w
            }
        }
    }
}

func trimmed(_ s: String) -> String {
    var out = Substring(s)
    while let f = out.first, f == " " || f == "\n" || f == "\t" { out = out.dropFirst() }
    while let l = out.last, l == " " || l == "\n" || l == "\t" { out = out.dropLast() }
    return String(out)
}
