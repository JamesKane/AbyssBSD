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
    /// The resolver configuration name servers go into (P14.4).
    public let resolvconf: String
    /// Kernel settings applied at boot — the default sound device (P14.6).
    public let sysctlConf: String
    /// The Wi-Fi networks this machine may join (P14.5).
    public let wpaConf: String
    /// Where every apply is recorded, whatever its outcome. Empty for none.
    public let journal: String
    /// Write the files for real, but run no service and no tool: for a test
    /// on a machine whose network is how the test reaches it (PHASE14 §6.3).
    /// Each step it does not run is reported as skipped, never as done.
    public let writeOnly: Bool

    public init(authority: Authority, dryRun: Bool = false,
                rcConf: String = "/etc/rc.conf", resolvconf: String = "/etc/resolvconf.conf",
                journal: String = "/var/log/abyss-settings.log", writeOnly: Bool = false,
                sysctlConf: String = "/etc/sysctl.conf", wpaConf: String = "/etc/wpa_supplicant.conf") {
        self.authority = authority
        self.dryRun = dryRun
        self.rcConf = rcConf
        self.resolvconf = resolvconf
        self.sysctlConf = sysctlConf
        self.wpaConf = wpaConf
        self.journal = journal
        self.writeOnly = writeOnly
    }

    /// Where each file this helper edits is, on this machine.
    public func path(_ f: ConfFile) -> String {
        switch f {
        case .rcConf: return rcConf
        case .resolvconf: return resolvconf
        case .sysctlConf: return sysctlConf
        case .wpaSupplicant: return wpaConf
        }
    }

    /// What this machine refuses that the plan alone cannot know: an
    /// interface that is not here.
    public func machineProblems(_ plan: SettingsPlan) -> [SettingsRefusal] {
        switch plan {
        case .energy: return []
        case .network(let n):
            guard Settings.isInterfaceName(n.interface) else { return [] }   // said already
            return if_nametoindex(n.interface) == 0
                ? [SettingsRefusal("there is no interface \(n.interface) on this machine")] : []
        case .wifi(let w):
            guard Settings.isRadioName(w.device) else { return [] }         // said already
            return radios().contains(w.device) ? []
                : [SettingsRefusal("there is no wireless device \(w.device) on this machine"
                                   + " (it has: \(radios().joined(separator: ", ").isEmpty ? "none" : radios().joined(separator: ", ")))")]
        case .sound(let s):
            // Before sysctl.conf is written: a default the kernel then refuses
            // would leave the next boot pointing at nothing.
            guard s.defaultUnit >= 0 else { return [] }                     // said already
            return access("/dev/dsp\(s.defaultUnit)", F_OK) != 0
                ? [SettingsRefusal("there is no sound device pcm\(s.defaultUnit) on this machine")] : []
        }
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
        case "read" where request.string("kind") == "wifi": return handleReadWifi(client, request)
        case "read": return handleRead(client, request)
        case "scan": return handleScan(client, request)
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

    /// The radios the kernel has: `net.wlan.devices`.
    func radios() -> [String] {
        let r = Spawn.run(["sysctl", "-n", "net.wlan.devices"], limit: 4096)
        return r.succeeded ? trimmed(r.stdoutText).split(separator: " ").map(String.init) : []
    }

    /// A radio's configuration: the wlan rc makes on it, and the networks
    /// wpa_supplicant.conf holds. Names only — never a key.
    private func handleReadWifi(_ client: Int32, _ request: Msg) -> String {
        let device = request.string("wifi.device") ?? ""
        guard Settings.isRadioName(device) else { return refuse(client, "\(device.isEmpty ? "no radio" : device) is not a wireless device's name") }
        if let why = platformRefusal { return refuse(client, why) }
        let r = Spawn.run(["sysrc", "-f", rcConf, "-n", "wlans_\(device)"], limit: 4096)
        let interface = r.succeeded ? trimmed(r.stdoutText) : ""
        let known = WifiKnown(device: device, interface: interface.isEmpty ? nil : interface,
                              networks: WpaConf.networks(Runner.readText(wpaConf) ?? ""))
        var reply = Msg()
        reply.set("ok", true)
        SettingsWire.encode(known, into: &reply)
        try? Current.send(reply, on: client)
        return "read wifi \(device): \(interface.isEmpty ? "no wlan" : interface), \(known.networks.count) network(s)"
    }

    /// Scan from a radio, as root (`ifconfig wlanN scan` is privileged). A
    /// radio rc has not given a wlan yet gets one for the scan, removed after:
    /// a scan must not leave the machine configured differently.
    private func handleScan(_ client: Int32, _ request: Msg) -> String {
        let device = request.string("wifi.device") ?? ""
        let interface = request.string("wifi.interface") ?? "wlan0"
        guard Settings.isRadioName(device) else { return refuse(client, "\(device.isEmpty ? "no radio" : device) is not a wireless device's name") }
        if let why = platformRefusal { return refuse(client, why) }
        guard radios().contains(device) else { return refuse(client, "there is no wireless device \(device) on this machine") }
        let exists = if_nametoindex(interface) != 0
        if !exists {
            let c = Spawn.run(["ifconfig", interface, "create", "wlandev", device], stderr: .merge, limit: 4096)
            guard c.succeeded else { return refuse(client, "could not make \(interface) on \(device): \(Runner.reason(c))") }
            _ = Spawn.run(["ifconfig", interface, "up"], limit: 4096)
        }
        defer { if !exists { _ = Spawn.run(["ifconfig", interface, "destroy"], limit: 4096) } }
        let r = Spawn.run(["ifconfig", interface, "scan"], stderr: .merge, limit: 65536)
        guard r.succeeded else { return refuse(client, "the scan failed: \(Runner.reason(r))") }
        let nets = WifiScan.parse(r.stdoutText)
        var reply = Msg()
        reply.set("ok", true)
        SettingsWire.encode(nets, into: &reply)
        try? Current.send(reply, on: client)
        return "scan \(device): \(nets.count) network(s)"
    }

    private func handleRead(_ client: Int32, _ request: Msg) -> String {
        let kind = request.string("kind") ?? ""
        let iface = request.string("interface") ?? ""
        guard let keys = Settings.keys(for: kind, interface: iface) else {
            return refuse(client, kind == "network" ? "\(iface.isEmpty ? "no interface" : iface) is not a wired interface's name"
                                                    : "there is no \(kind) plan")
        }
        if let why = platformRefusal { return refuse(client, why) }
        var values: [String: String] = [:]
        for (file, k) in keys {
            // `sysrc -n` answers as rc(8) would — the defaults, then the file.
            if !file.isShellVariables {
                // Not sh: read it ourselves. With no line for it, what the
                // kernel has now is what the next boot gets too.
                if let v = Settings.sysctlConfValue(Runner.readText(path(file)) ?? "", key: k) { values[k] = v }
                else {
                    let r = Spawn.run(["sysctl", "-n", k], limit: 4096)
                    if r.succeeded { values[k] = trimmed(r.stdoutText) }
                }
                continue
            }
            let r = Spawn.run(["sysrc", "-f", path(file), "-n", k], limit: 4096)
            if r.succeeded { values[k] = trimmed(r.stdoutText) }
        }
        guard let plan = Settings.current(kind: kind, interface: iface, values: values) else {
            return refuse(client, "this machine's \(kind) settings are not ones this pane can show: "
                          + values.keys.sorted().map { "\($0)=\"\(values[$0]!)\"" }.joined(separator: " "))
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
        let refusals = Settings.problems(plan) + machineProblems(plan)
        reply.set("ok", refusals.isEmpty)
        reply.set("problems.count", UInt64(refusals.count))
        for (i, r) in refusals.enumerated() { reply.set("problem.\(i)", r.message) }
        if refusals.isEmpty, let steps = try? Settings.compile(plan) {
            reply.set("steps.count", UInt64(steps.count))
            reply.set("render", Settings.render(steps, path: path))
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
        if let first = machineProblems(plan).first { return refuse(client, first.message) }
        let steps: [SettingsStep]
        do { steps = try Settings.compile(plan) } catch let r as SettingsRefusal {
            return refuse(client, r.message)
        } catch { return refuse(client, "\(error)") }

        var record: [String] = ["apply \(plan.kind) for uid \(authority.allowed)"
                                + (dryRun ? " (dry run)" : writeOnly ? " (write only)" : "")]
        let ok = Runner.apply(steps, path: path, dryRun: dryRun, writeOnly: writeOnly) { e in
            try? Current.send(SettingsWire.encode(e), on: client)
            switch e {
            case .starting(let i, _, let what): record.append("  \(i + 1). \(what)")
            case .failed(_, _, let why, let ignored): record.append("     \(ignored ? "failed, and that is allowed" : "FAILED"): \(why)")
            case .skipped(_, let why): record.append("     skipped: \(why)")
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
    /// Run the steps, reporting each. File writes go into a **staged copy** of
    /// each file, and the copies replace the real files only once every write
    /// to every file succeeded — so a plan that fails half-way leaves rc.conf
    /// and resolvconf.conf exactly as they were, rather than half-changed with
    /// nobody knowing which half. Services and tools act after that, on the
    /// files now in place.
    @discardableResult
    public static func apply(_ steps: [SettingsStep], path: (ConfFile) -> String, dryRun: Bool,
                             writeOnly: Bool = false, emit: (SettingsEvent) -> Void) -> Bool {
        let lastWrite = steps.lastIndex { !$0.acts }
        var staged: [ConfFile: String] = [:]
        func discard() { for (_, p) in staged { unlink(p) }; staged = [:] }
        func fail(_ i: Int, _ what: String, _ why: String) -> Bool {
            discard()
            emit(.failed(index: i, what: what, why: why, ignored: false))
            emit(.finished(ok: false, error: "\(what): \(why)"))
            return false
        }

        for (i, step) in steps.enumerated() {
            emit(.starting(index: i, total: steps.count, what: step.description))
            if dryRun { emit(.ok(index: i)); continue }
            if case .setVar(let file, _, _) = step {
                if staged[file] == nil {
                    let copy = path(file) + ".abyss-staged"
                    if let why = copyFile(path(file), to: copy, newMode: mode_t(file.newFileMode)) {
                        return fail(i, step.description, why)
                    }
                    staged[file] = copy
                }
                if case .setVar(_, let key, let value) = step, !file.isShellVariables {
                    // sysctl.conf is not sh; sysrc refuses it. Edited here.
                    let copy = staged[file]!
                    let text = Settings.editFile(file, readText(copy) ?? "", key: key, value: value)
                    if let why = writeText(text, to: copy) { return fail(i, step.description, why) }
                } else {
                    let r = Spawn.run(step.command { staged[$0] ?? path($0) }, stderr: .merge, limit: 8192)
                    guard r.succeeded else { return fail(i, step.description, reason(r)) }
                }
                if i == lastWrite {
                    // Every write succeeded: now, and only now, the real files.
                    for (f, copy) in staged.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                        guard rename(copy, path(f)) == 0 else {
                            return fail(i, step.description, "could not put the new \(f.rawValue) in place: "
                                        + String(cString: strerror(errno)))
                        }
                        staged[f] = nil
                    }
                }
                emit(.ok(index: i))
                continue
            }
            if writeOnly { emit(.skipped(index: i, why: "write-only: the machine is left as it is")); continue }
            let mayFail: Bool
            switch step {
            case .service(_, _, let m), .tool(_, let m): mayFail = m
            case .setVar: mayFail = false
            }
            let r = Spawn.run(step.command(path: path), stderr: .merge, limit: 8192)
            if r.succeeded { emit(.ok(index: i)); continue }
            if mayFail {
                emit(.failed(index: i, what: step.description, why: reason(r), ignored: true))
                continue
            }
            return fail(i, step.description, reason(r))
        }
        emit(.finished(ok: true, error: ""))
        return true
    }

    /// The single-file form the energy plan and its tests use.
    @discardableResult
    public static func apply(_ steps: [SettingsStep], rcConf: String, dryRun: Bool,
                             emit: (SettingsEvent) -> Void) -> Bool {
        apply(steps, path: { $0 == .rcConf ? rcConf : "/etc/" + $0.rawValue }, dryRun: dryRun, emit: emit)
    }

    static func reason(_ r: Spawn.Result) -> String {
        if let f = r.failure { return f }
        let said = trimmed(r.stdoutText)
        return said.isEmpty ? "exited \(r.code) and said nothing" : said
    }

    /// A whole (small) file, or nil when it cannot be read.
    static func readText(_ path: String) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return n == 0 ? String(decoding: bytes, as: UTF8.self) : nil }
            bytes += buf[0..<n]
        }
    }

    /// Replace a staged file's contents (its mode kept: it is truncated, not recreated).
    static func writeText(_ text: String, to path: String) -> String? {
        let fd = open(path, O_WRONLY | O_TRUNC)
        guard fd >= 0 else { return "could not write \(path): \(String(cString: strerror(errno)))" }
        defer { close(fd) }
        let b = Array(text.utf8)
        var off = 0
        while off < b.count {
            let w = b.withUnsafeBytes { write(fd, $0.baseAddress! + off, b.count - off) }
            if w <= 0 { return "could not write \(path): \(String(cString: strerror(errno)))" }
            off += w
        }
        return nil
    }

    /// Copy `from` to `to` with `from`'s mode — or, when `from` does not exist,
    /// an empty file: a machine with no rc.conf yet gets its first one.
    static func copyFile(_ from: String, to: String, newMode: mode_t = 0o644) -> String? {
        var st = stat()
        let exists = stat(from, &st) == 0
        let mode = exists ? mode_t(st.st_mode & 0o7777) : newMode
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
