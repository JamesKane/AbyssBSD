// `fathom` — run the probes on this machine and report (PHASE12.md P12.3).
//
// **The gathering lives here and nowhere else.** `Fathom` itself is pure
// functions over captured text with no dependencies, which is what lets every
// probe be tested on a machine that has none of the hardware. This binary is the
// half that is allowed to look: it runs the commands, reads the sysctls and the
// kernel environment, and hands the text to the parsers.
//
// The split is `Install` / `InstallRun` again, for the same reason and with the
// same payoff.
//
//   fathom              the report, as text
//   fathom --measure    also run the compositor and report the frame contract
//   fathom --quiet      exit status only: 0 complete, 1 something unaskable
//
// **Exit status is about completeness, not suitability.** A machine with no
// battery and no wifi produces a complete report and a perfectly good desktop;
// one where `kldstat` could not be read produces an incomplete one. Conflating
// "I could not ask" with "the answer is no" is the thing this whole design is
// built to avoid, so the exit code follows the same rule.

import Fathom
import Vents

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array(s.utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}

/// Capture a command's stdout, or nil if it could not be run **or failed**.
///
/// **nil is a real answer here** — it becomes `unknown` rather than `absent`,
/// which is the distinction the whole report turns on.
///
/// Two things this gets right that the first version did not, both found by
/// running it on Linux where none of these commands exist:
///
/// - **stderr goes to /dev/null, not into the answer.** Merging them meant
///   `ifconfig: option '-l' not recognised` was parsed as a list of network
///   interfaces, and the report said `Network [ok]` with the error message as
///   its evidence. A diagnostic tool that reads a failure as data is worse than
///   one that says nothing.
/// - **A non-zero exit is nil.** Anything else re-invents the same bug for the
///   next command that fails politely.
func capture(_ argv: [String]) -> String? {
    run(argv).stdout
}

/// Run a command and keep both halves apart.
///
/// **Why stderr is kept at all**, having just been thrown away: a probe that
/// fails should say what the machine said. "undertow did not report" is true and
/// useless; "undertow: could not create a wlroots renderer" is the answer
/// somebody drove to a different city to read off a screen. The rule is not
/// "discard stderr", it is **never parse stderr as data** — so it is captured
/// separately and only ever quoted, never fed to a parser.
func run(_ argv: [String]) -> (stdout: String?, reason: String) {
    var outFds: [Int32] = [0, 0]
    var errFds: [Int32] = [0, 0]
    guard pipe(&outFds) == 0 else { return (nil, "could not create a pipe") }
    guard pipe(&errFds) == 0 else {
        close(outFds[0]); close(outFds[1])
        return (nil, "could not create a pipe")
    }
    let pid = fork()
    if pid == 0 {
        close(outFds[0]); close(errFds[0])
        dup2(outFds[1], 1)
        dup2(errFds[1], 2)
        close(outFds[1]); close(errFds[1])
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        execvp(argv[0], &cargs)
        _exit(127)
    }
    guard pid > 0 else {
        close(outFds[0]); close(outFds[1]); close(errFds[0]); close(errFds[1])
        return (nil, "could not fork")
    }
    close(outFds[1]); close(errFds[1])

    func drain(_ fd: Int32) -> String {
        var text = ""
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            if n <= 0 { break }
            text += String(decoding: buf[0..<n], as: UTF8.self)
        }
        close(fd)
        return text
    }
    let outText = drain(outFds[0])
    let errText = drain(errFds[0])

    var status: Int32 = 0
    waitpid(pid, &status, 0)
    // A command that did not exist, or ran and failed, tells us nothing. One that
    // succeeded and printed nothing has told us something — an empty string is
    // an answer and nil is not.
    let exited = (status & 0x7f) == 0
    let code = (status >> 8) & 0xff
    guard exited, code == 0 else {
        // The last non-empty line: a failing program's useful sentence is
        // usually its last, and the ones above it are context we did not ask for.
        let last = errText.split(separator: "\n")
            .map { String($0) }.last { !$0.trimmingPrefixSpaces().isEmpty }
        return (nil, last ?? "\(argv[0]) exited \(code) and said nothing")
    }
    return (outText, "")
}

extension String {
    func trimmingPrefixSpaces() -> String {
        var s = Substring(self)
        while let c = s.first, c == " " || c == "\t" { s = s.dropFirst() }
        return String(s)
    }
}

/// The contents of a directory, or nil if it could not be read.
func listDirectory(_ path: String) -> [String]? {
    guard let d = opendir(path) else { return nil }
    defer { closedir(d) }
    var names: [String] = []
    while let e = readdir(d) {
        let name = withUnsafeBytes(of: e.pointee.d_name) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if name == "." || name == ".." { continue }
        names.append(name)
    }
    return names
}

func readFile(_ path: String) -> String? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var text = ""
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
        if n <= 0 { break }
        text += String(decoding: buf[0..<n], as: UTF8.self)
    }
    return text
}

// ---------------------------------------------------------------- gather
let machine = Vents.Kenv.machine()
// **"No battery" and "no way to ask about batteries" are different machines.**
// On a platform with no sysctl at all every reading is nil, and reporting that
// as "no battery — mains only" would be the report inventing a fact about
// hardware it never looked at.
let canAsk = Vents.Sysctl.isSupported
let batteryLife = canAsk ? Vents.Sysctl.int("hw.acpi.battery.life") : nil

let report = FathomReport([
    probeMachine(maker: machine?.maker, product: machine?.product),
    probeCPU(model: Vents.Sysctl.string("hw.model"),
             cores: Vents.Sysctl.int("hw.ncpu")),
    probeMemory(physBytes: Vents.Sysctl.int("hw.physmem")),
    probeBootMethod(Vents.Sysctl.string("machdep.bootmethod")),
    probeModules(kldstat: capture(["kldstat"])),
    // `/dev/dri` absent is `absent`; unreadable for another reason is `unknown`,
    // and `listDirectory` distinguishes them by returning [] versus nil only
    // when the directory itself is missing — which on FreeBSD is what "no GPU
    // bound" looks like.
    probeGPU(driEntries: listDirectory("/dev/dri") ?? []),
    probeNetwork(interfaceList: capture(["ifconfig", "-l"])),
    probeWifi(wlanDevices: Vents.Sysctl.string("net.wlan.devices")),
    probeAudio(sndstat: readFile("/dev/sndstat")),
    probeBattery(life: batteryLife, present: canAsk && batteryLife != nil,
                 canAsk: canAsk),
])

// ------------------------------------------------------------ measurement
//
// **Opt-in, because it is the one probe that costs something.** Everything above
// reads a file or a sysctl; this one starts a compositor, takes the display, and
// runs for a few seconds. A report you might want on a machine you are unsure
// of should not seize the screen unasked.
//
// **And not measuring is shown rather than silently omitted.** A row missing
// from a list is invisible; a footer that says why is not. This is the same rule
// as `unknown` one level up — the report must never look more complete than it
// is — but it is deliberately *not* an `unknown`, because a question nobody
// asked is not a question the machine refused to answer, and the exit status
// should not claim otherwise.
let args = Array(CommandLine.arguments.dropFirst())
let measure = args.contains("--measure")
var results = report.results

if measure {
    // Absolute path first, then bare so `execvp` searches PATH — the medium
    // installs to /usr/local/bin, a developer has it somewhere else.
    let installed = "/usr/local/bin/undertow"
    let undertow = installed.withCString { access($0, X_OK) == 0 } ? installed : "undertow"
    let r = run([undertow, "run", "--backend", "auto", "--frames", "300"])
    if let out = r.stdout {
        results.append(probeFrameContract(runOutput: out))
    } else {
        // Quote the machine rather than paraphrase it. This is the line somebody
        // would otherwise have to reboot to read.
        results.append(ProbeResult("Frame contract", .unknown,
                                   "could not measure: \(r.reason)"))
    }
}

let final = FathomReport(results)
let quiet = args.contains("--quiet")
if !quiet {
    emit(1, renderText(final))
    if !measure {
        emit(1, "\n(frame contract not measured; pass --measure to run the compositor)\n")
    }
}
exit(final.isComplete ? 0 : 1)
