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
///
/// `fork`/`execvp` rather than `posix_spawn`: the file-actions type is a struct
/// on Linux and a pointer typedef on FreeBSD, so the spawn route needs a
/// platform fork of its own for no benefit here. The child does nothing between
/// fork and exec but `dup2` and `close`, which is async-signal-safe, and
/// `Aqua.Launcher` has spawned this way since Phase 2.
func runCommand(_ argv: [String], stdin: String?) -> CommandResult {
    guard let program = argv.first else { return CommandResult(status: -1, message: "empty command") }

    var inPipe: [Int32] = [-1, -1]
    if stdin != nil, pipe(&inPipe) != 0 {
        return CommandResult(status: -1, message: "pipe: \(errnoText())")
    }
    var errPipe: [Int32] = [-1, -1]
    if pipe(&errPipe) != 0 {
        if inPipe[0] >= 0 { close(inPipe[0]); close(inPipe[1]) }
        return CommandResult(status: -1, message: "pipe: \(errnoText())")
    }

    let pid = fork()
    if pid < 0 {
        let e = errnoText()
        if inPipe[0] >= 0 { close(inPipe[0]); close(inPipe[1]) }
        close(errPipe[0]); close(errPipe[1])
        return CommandResult(status: -1, message: "fork: \(e)")
    }

    if pid == 0 {
        // ---- child ----
        if inPipe[0] >= 0 {
            dup2(inPipe[0], 0)
            close(inPipe[0]); close(inPipe[1])
        } else {
            // Never let a step read from the installer's own stdin: a command
            // that decides to ask a question would hang the install forever
            // with no indication of why.
            let devnull = open("/dev/null", O_RDONLY)
            if devnull >= 0 { dup2(devnull, 0); close(devnull) }
        }
        // stdout follows stderr so a chatty command cannot interleave with the
        // service's own protocol on its real stdout.
        dup2(errPipe[1], 1)
        dup2(errPipe[1], 2)
        close(errPipe[0]); close(errPipe[1])
        withCStrings(argv) { cargv in
            _ = execvp(program, cargv)
        }
        // execvp only returns on failure, and the child must not run any of the
        // parent's cleanup.
        _exit(127)
    }

    // ---- parent ----
    if inPipe[0] >= 0 {
        close(inPipe[0])
        if let text = stdin {
            let bytes = Array((text.hasSuffix("\n") ? text : text + "\n").utf8)
            var off = 0
            bytes.withUnsafeBufferPointer { buf in
                while off < bytes.count {
                    let n = write(inPipe[1], buf.baseAddress! + off, bytes.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
        close(inPipe[1])
    }
    close(errPipe[1])

    var captured = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = chunk.withUnsafeMutableBytes { read(errPipe[0], $0.baseAddress, 4096) }
        if n <= 0 { break }
        captured.append(contentsOf: chunk[0..<n])
        // A command that decides to print a megabyte does not get to make the
        // installer hold it.
        if captured.count > 8192 { captured.removeLast(captured.count - 8192); break }
    }
    close(errPipe[0])

    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    let code = exitStatus(status)
    return CommandResult(status: code, message: trimmed(String(decoding: captured, as: UTF8.self)))
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

/// `WEXITSTATUS`/`WIFSIGNALED` are macros, so Swift cannot see them.
func exitStatus(_ raw: Int32) -> Int32 {
    if raw & 0x7f == 0 { return (raw >> 8) & 0xff }      // exited normally
    return 128 + (raw & 0x7f)                             // killed by a signal
}

func errnoText() -> String {
    String(cString: strerror(errno))
}

func trimmed(_ s: String) -> String {
    var out = Substring(s)
    while let f = out.first, f == " " || f == "\n" || f == "\t" { out = out.dropFirst() }
    while let l = out.last, l == " " || l == "\n" || l == "\t" { out = out.dropLast() }
    return String(out)
}

/// Hand an array of Swift strings to a C function wanting `char *const argv[]`.
func withCStrings(_ strings: [String],
                  _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Void) {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    for p in pointers where p != nil { free(p) }
}
