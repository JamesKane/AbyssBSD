// Portal — the service: run the picker, open what the user chose, hand back the
// descriptor.

import CProc
import CPlatform
import CurrentIPC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class PortalService {
    /// The picker binary. `$ABYSS_PICKER` overrides; otherwise the AquaDemo
    /// beside this executable, resolved once so the child never searches `$PATH`
    /// after forking.
    public let pickerBinary: String
    public private(set) var journal: [String] = []

    public init(pickerBinary: String? = nil) {
        if let p = pickerBinary {
            self.pickerBinary = p
        } else if let env = getenv("ABYSS_PICKER"), env.pointee != 0 {
            self.pickerBinary = String(cString: env)
        } else {
            self.pickerBinary = PortalService.siblingBinary("AquaDemo") ?? "AquaDemo"
        }
    }

    private static func siblingBinary(_ name: String) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer { ap_self_executable($0.baseAddress!, $0.count) }
        guard n > 0 else { return nil }
        let path = String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[path.startIndex..<slash]) + "/" + name
    }

    func log(_ msg: String) {
        journal.append(msg)
        let line = "portal: \(msg)\n"
        let b = Array(line.utf8)
        _ = b.withUnsafeBufferPointer { write(2, $0.baseAddress, b.count) }
    }

    // MARK: - Handling a request

    /// Answer one request. Returns the reply and, when the user chose a file,
    /// **an open descriptor the caller must close after sending**.
    public func handle(_ request: PortalRequest) -> (reply: Msg, fd: Int32?) {
        switch request {
        case .openFile(let dir):
            return choose(startDir: dir, name: nil, mode: .read)
        case .saveFile(let dir, let name):
            return choose(startDir: dir, name: name, mode: .write)
        case .notify(let summary, let body, let timeout):
            return (relayNotify(summary: summary, body: body, timeout: timeout), nil)
        case .unknown(let method):
            log("unknown method '\(method)'")
            var reply = Msg()
            reply.set("ok", false)
            reply.set("error", "unknown method")
            return (reply, nil)
        }
    }

    /// Relay a notification to the shell's notify service.
    ///
    /// The portal is the only thing that talks to it, so a sandboxed app can
    /// post a toast without being able to reach — or impersonate — the shell.
    private func relayNotify(summary: String, body: String?, timeout: UInt64?) -> Msg {
        var out = Msg()
        out.set("method", "notify")
        out.set("summary", summary)
        if let b = body { out.set("body", b) }
        if let t = timeout { out.set("timeout", t) }

        var reply = Msg()
        do {
            let service = (getenv("ABYSS_NOTIFY_SERVICE").map { String(cString: $0) }) ?? "notify"
            let answer = try Current.call(service, out)
            log("relayed a notification: \(summary)")
            reply.set("ok", answer.bool("ok") ?? false)
            if let id = answer.uint64("id") { reply.set("id", id) }
        } catch {
            // No notification centre running is a normal state, not a crash.
            log("no notify service to relay to (\(error))")
            reply.set("ok", false)
            reply.set("error", "no notification service")
        }
        return reply
    }

    private func choose(startDir: String?, name: String?, mode: PortalOpenMode)
        -> (reply: Msg, fd: Int32?) {
        let outcome = runPicker(startDir: startDir, suggestedName: name)
        guard case .chose(let path) = outcome else {
            log(outcome == .cancelled ? "cancelled" : "picker failed: \(outcome)")
            return (portalReply(outcome, mode: mode), nil)
        }

        // The portal opens the path THE USER CHOSE. Nothing the requesting app
        // sent reaches this call — see PortalRequest's doc comment.
        let flags = mode == .read ? O_RDONLY : (O_WRONLY | O_CREAT)
        let fd = open(path, flags, 0o600)
        guard fd >= 0 else {
            let why = String(cString: strerror(errno))
            log("cannot open \(path): \(why)")
            return (portalReply(.failed("cannot open the chosen file: \(why)"), mode: mode), nil)
        }
        log("handing over \(path) (\(mode == .read ? "read" : "write"))")
        return (portalReply(.chose(path), mode: mode), fd)
    }

    /// Run the picker and wait. Blocking is correct here: a file dialog is
    /// modal, and the sibling's portal did the same. The cost is that the
    /// service answers one request at a time, which is worth knowing.
    public func runPicker(startDir: String?, suggestedName: String?) -> PickerOutcome {
        // A private result file the picker writes its answer into. In the
        // runtime dir (0700), not /tmp: another user must not be able to plant
        // a path for the portal to open.
        guard let runtime = try? Current.runtimeDir() else {
            return .failed("no runtime directory")
        }
        let result = runtime + "/pick.\(getpid())"
        unlink(result)
        defer { unlink(result) }

        var env = ProcessEnvironment()
        env["AQUA_SCENE"] = "finder"
        env["ABYSS_FINDER_PICK"] = result
        if let d = startDir { env["ABYSS_FINDER_DIR"] = d }
        if let n = suggestedName { env["ABYSS_FINDER_SAVE_NAME"] = n }

        let argv = [pickerBinary]
        let envp = env.block()
        var signalled: Int32 = 0
        let status = withCStrings(argv) { a in
            withCStrings(envp) { e in
                ap_run_and_wait(a, e, &signalled)
            }
        }
        if status < 0 {
            return .failed("could not run the picker (\(String(cString: strerror(errno))))")
        }
        return PickerOutcome.from(status: status, signalled: signalled != 0,
                                  result: FinderPickerResult.read(result))
    }
}

/// Reading the picker's result file — the portal's half of P7.1's contract.
///
/// Duplicated from `FinderPicker.readResult` on purpose: the portal must not
/// link the Aqua toolkit (and through it Wayland and cairo) just to read one
/// line of text, and this is the *reader's* side of a documented file format.
/// The absolute-path rule is the load-bearing part — the portal opens what this
/// returns.
public enum FinderPickerResult {
    public static func read(_ path: String) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer { Glibc.read(fd, $0.baseAddress, 4096) }
        guard n > 0 else { return nil }
        var s = String(decoding: buf[0..<n], as: UTF8.self)
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        guard !s.isEmpty, s.hasPrefix("/") else { return nil }
        return s
    }
}

/// The environment to hand the picker: this process's, plus overrides.
struct ProcessEnvironment {
    private var vars: [String: String]

    init() {
        var out: [String: String] = [:]
        var p = environ
        while let entry = p.pointee {
            let s = String(cString: entry)
            if let eq = s.firstIndex(of: "=") {
                out[String(s[s.startIndex..<eq])] = String(s[s.index(after: eq)...])
            }
            p += 1
        }
        vars = out
    }

    subscript(key: String) -> String? {
        get { vars[key] }
        set { vars[key] = newValue }
    }

    /// Sorted, so a child's environment is reproducible.
    func block() -> [String] { vars.keys.sorted().map { "\($0)=\(vars[$0]!)" } }
}

/// Build a NULL-terminated C array for `execve`, valid for the duration of
/// `body`. `strdup` because every pointer must be live at once — see Anchor's
/// copy of this for why the obvious `map` over borrowed buffers is UB.
func withCStrings<R>(_ strings: [String],
                     _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer { for p in ptrs { free(p) } }
    ptrs.append(nil)
    return ptrs.withUnsafeBufferPointer { buf in
        buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self,
                                           capacity: buf.count) { body($0) }
    }
}
