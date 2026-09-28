// Running a step list.
//
// `Install` decides; this runs. The split is the whole point of P5.1 — by the
// time a list gets here every question has been answered, so the runner has no
// judgement of its own to exercise and no plan to second-guess. It executes,
// reports, and stops at the first thing that goes wrong.
//
// **It stops.** An installer that carries on past a failed `gpart add` finishes
// with a confident summary and a machine that will not boot. The one exception
// is a step the plan marked `mayFail`, and the plan says why each of those is
// allowed to.

import Install
import InstallWire
import Spawn

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The result of running one command.
struct CommandResult {
    let status: Int32
    /// Whatever it said on stderr, trimmed — this is what a person is shown
    /// when a step fails, so it matters that it survives.
    let message: String
}

/// Execute a step list. Returns nil on success, or the failure to report.
///
/// - Parameters:
///   - dryRun: do everything except run the commands and write the files. The
///     events are identical, which is what makes it useful: a caller can drive
///     the whole flow, including its confirmations, against a machine it is not
///     touching.
@discardableResult
public func execute(_ steps: [Step], dryRun: Bool = false,
                    report: (RunEvent) -> Void) -> String? {
    for (i, step) in steps.enumerated() {
        report(.starting(index: i, total: steps.count,
                         what: step.what, destructive: step.destructive))
        if dryRun { report(.ok(index: i)); continue }

        let failure: String?
        switch step.action {
        case .run(let argv, let stdin):
            let r = runCommand(argv, stdin: stdin)
            failure = r.status == 0 ? nil
                : (r.message.isEmpty ? "exited \(r.status)" : r.message)
        case .write(let path, let contents, let mode):
            failure = writeFile(path: path, contents: contents, mode: mode)
        case .append(let path, let contents):
            failure = appendFile(path: path, contents: contents)
        }

        if let why = failure {
            report(.failed(index: i, what: step.what, why: why, ignored: step.mayFail))
            if !step.mayFail {
                // The plan wrote this sentence when it was thinking clearly
                // about what this step is for; the kernel's errno is the detail
                // underneath it.
                let error = "\(step.onFailure) (\(why))"
                report(.finished(ok: false, error: error))
                return error
            }
        } else {
            report(.ok(index: i))
        }
    }
    report(.finished(ok: true, error: ""))
    return nil
}

// MARK: - Doing one thing

/// Run a command, feeding it `stdin` if it has any, and collect its stderr.
func runCommand(_ argv: [String], stdin: String?) -> CommandResult {
    // `Spawn.run`, not a fork of our own (S.3): this ran as root and built its
    // argv inside the child, after `fork` — the async-signal-safety mistake
    // HANDOFF §2.25 forbids. And it stopped reading at 8 KiB and closed the
    // pipe, so a chattier command died of SIGPIPE and was reported as failed;
    // Spawn keeps the first 8 KiB and drains the rest.
    //
    // stdout follows stderr (`.merge`) so a chatty command cannot interleave
    // with the service's own protocol on its real stdout; and without `stdin`
    // the child reads /dev/null, never the installer's stdin — a command that
    // decided to ask a question would otherwise hang the install for ever.
    let input = stdin.map { Array(($0.hasSuffix("\n") ? $0 : $0 + "\n").utf8) }
    let r = Spawn.run(argv, input: input, stderr: .merge, limit: 8192)
    if r.rawStatus == nil { return CommandResult(status: r.code, message: r.failure ?? "") }
    return CommandResult(status: r.code, message: trimmed(r.stdoutText))
}

func writeFile(path: String, contents: String, mode: UInt16) -> String? {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(mode))
    guard fd >= 0 else { return "open \(path): \(errnoText())" }
    defer { close(fd) }
    let bytes = Array(contents.utf8)
    var off = 0
    let wrote: Bool = bytes.withUnsafeBufferPointer { buf in
        while off < bytes.count {
            let n = write(fd, buf.baseAddress! + off, bytes.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
    guard wrote else { return "write \(path): \(errnoText())" }
    // `open` honours the umask; the plan said what the mode should be.
    guard fchmod(fd, mode_t(mode)) == 0 else { return "chmod \(path): \(errnoText())" }
    return nil
}

func appendFile(path: String, contents: String) -> String? {
    let fd = open(path, O_WRONLY | O_APPEND)
    guard fd >= 0 else { return "open \(path): \(errnoText())" }
    defer { close(fd) }
    let bytes = Array(contents.utf8)
    var off = 0
    let wrote: Bool = bytes.withUnsafeBufferPointer { buf in
        while off < bytes.count {
            let n = write(fd, buf.baseAddress! + off, bytes.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
    return wrote ? nil : "write \(path): \(errnoText())"
}

// MARK: - Small helpers

func errnoText() -> String {
    String(cString: strerror(errno))
}

func trimmed(_ s: String) -> String {
    var out = Substring(s)
    while let f = out.first, f == " " || f == "\n" || f == "\t" { out = out.dropFirst() }
    while let l = out.last, l == " " || l == "\n" || l == "\t" { out = out.dropLast() }
    return String(out)
}
