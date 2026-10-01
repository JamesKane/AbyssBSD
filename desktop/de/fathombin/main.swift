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
//   fathom --save       also write it to the medium's ESP, so it leaves with the
//                       stick — FAT is the one filesystem every desktop reads
//   fathom --save-to D  write it to a directory of your choosing instead
//
// **Exit status is about completeness, not suitability.** A machine with no
// battery and no wifi produces a complete report and a perfectly good desktop;
// one where `kldstat` could not be read produces an incomplete one. Conflating
// "I could not ask" with "the answer is no" is the thing this whole design is
// built to avoid, so the exit code follows the same rule.

import Fathom
import Vents
import Spawn

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
///
/// `Spawn.run` (S.3). The first version forked here, built argv inside the
/// child, and read stdout to its end *before* stderr — so a program that
/// filled its stderr pipe first would have waited for us while we waited for
/// it. Spawn services both in one loop, and stdin is /dev/null.
func run(_ argv: [String]) -> (stdout: String?, reason: String) {
    let r = Spawn.run(argv)
    // Not found, or could not start: that is the reason, in its own words.
    if r.rawStatus == nil { return (nil, r.failure ?? "\(argv.first ?? "") could not start") }
    // A command that ran and failed tells us nothing. One that succeeded and
    // printed nothing has told us something — an empty string is an answer
    // and nil is not.
    guard r.succeeded else {
        // The last non-empty line: a failing program's useful sentence is
        // usually its last, and the ones above it are context we did not ask for.
        let last = r.stderrText.split(separator: "\n")
            .map { String($0) }.last { !$0.trimmingPrefixSpaces().isEmpty }
        return (nil, last ?? "\(argv[0]) exited \(r.code) and said nothing")
    }
    return (r.stdoutText, "")
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
    probeBootMethod(Vents.Sysctl.string("machdep.bootmethod"), arch: Vents.Sysctl.string("hw.machine_arch")),
    probeModules(kldstat: capture(["kldstat"])),
    // `/dev/dri` absent is `absent`; unreadable for another reason is `unknown`,
    // and `listDirectory` distinguishes them by returning [] versus nil only
    // when the directory itself is missing — which on FreeBSD is what "no GPU
    // bound" looks like.
    probeGPU(driEntries: listDirectory("/dev/dri") ?? []),
    probeNetwork(interfaceList: capture(["ifconfig", "-l"])),
    probeWifi(wlanDevices: Vents.Sysctl.string("net.wlan.devices"),
              // `-m` finds a module compiled into the kernel too; nil where
              // kldstat itself could not be run.
              wlanLoaded: canAsk ? Spawn.run(["kldstat", "-q", "-m", "wlan"]).succeeded : nil),
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
    // Absolute path first, then bare so `Spawn` searches PATH — the medium
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

// ------------------------------------------------------------------ save
//
// **The matrix is populated by strangers, so retrieval cannot assume a
// network** — and the machines where the network does not come up are exactly
// the ones worth hearing about. The ESP is FAT16 and every desktop OS reads
// FAT, so a report written there leaves with the stick and opens on whatever
// computer the person actually has.
func saveReport(_ text: String, to directory: String, name: String) -> String? {
    let path = directory + "/" + name
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    let bytes = Array(text.utf8)
    let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, bytes.count) }
    return n == bytes.count ? path : nil
}

let name = reportFilename(maker: machine?.maker, product: machine?.product)
let text = renderText(final)

if let i = args.firstIndex(of: "--save-to"), i + 1 < args.count {
    if let path = saveReport(text, to: args[i + 1], name: name) {
        emit(1, "fathom: wrote \(path)\n")
    } else {
        emit(2, "fathom: could not write into \(args[i + 1])\n")
        exit(2)
    }
} else if args.contains("--save") {
    // The ESP by the label the medium's own build gives it, rather than by
    // parsing a partition table: `makefs -o volume_label=EFISYS` puts it there
    // and geom_label makes it a device node.
    let esp = "/dev/msdosfs/EFISYS"
    let mount = "/tmp/fathom-esp"
    _ = mkdir(mount, 0o700)
    // **FAT stores no permissions**, so `-m 644` sets what *this* mount
    // synthesises and nothing more — verified both ways: the same file reads
    // `-rwx------` under a default mount and `-rw-r--r--` under this one. How it
    // appears anywhere else is that reader's mount's business, not ours, which
    // is the point of writing to FAT rather than to the UFS root: every desktop
    // OS mounts it readable and none of them needs to be told how.
    guard run(["mount_msdosfs", "-m", "644", "-M", "755", esp, mount]).stdout != nil else {
        emit(2, "fathom: could not mount \(esp) — is this the live medium, and are you root?\n")
        exit(2)
    }
    let saved = saveReport(text, to: mount, name: name)
    _ = run(["umount", mount])
    guard let path = saved else {
        emit(2, "fathom: mounted the ESP and could not write to it\n")
        exit(2)
    }
    // Report the name it will have *on the stick*, not the temporary mount
    // point, because the whole point is reading it somewhere else.
    emit(1, "fathom: wrote \(name) to the stick's EFI partition"
         + " — readable on any machine that reads FAT\n")
    _ = path
}

let quiet = args.contains("--quiet")
if !quiet {
    emit(1, text)
    if !measure {
        emit(1, "\n(frame contract not measured; pass --measure to run the compositor)\n")
    }
}
exit(final.isComplete ? 0 : 1)
