// abyss-appgen — write an application bundle for every installed port that has
// a desktop entry (PHASE15 P15.1).
//
//   abyss-appgen [--from DIR]... [--to DIR] [--jails FILE] [--system DIR] [--dry-run]
//
// `--system`: the machine's Applications folder (default /Applications). A
// run into any other folder is a person's, and makes there only the
// desktop's own applications the machine's folder lacks, and Agent.
//
// `--jails`: the jails.ini whose `[apps]` says which applications run
// confined (PHASE18 P18.5) — by default the machine's
// (/usr/local/etc/abyss/jails.ini) when run as root, the person's otherwise.
//
// Reads `*.desktop` from each `--from` (default: /usr/local/share/applications
// and /usr/share/applications), and writes `<Name>.app` into `--to` —
// /Applications when run as root (a medium's build, and later the `pkg` hook of
// Phase 17), ~/Applications otherwise (PHASE15 §6.2). The rules are
// `AppBundles`'s; this is the I/O: find the entries and the icons, rasterise an
// SVG with `rsvg-convert` when that is the best there is, and write.
//
// **It only ever touches its own bundles.** Each carries a marker naming the
// entry it came from (`Contents/abyss-appgen`); a bundle without one was put
// there by somebody else and is neither replaced nor removed, and a generated
// bundle whose entry has gone is removed. Every bundle is built in a temporary
// directory and renamed into place, so the Finder never sees half of one.
//
// One line per decision on stdout, for a person and for the live test.

import AppBundles
import PoolConfig
import Spawn
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func say(_ s: String) { print(s) }
func die(_ s: String) -> Never {
    // write(2), not stderr: Swift 6 refuses the mutable global (HANDOFF §2.4).
    let line = "abyss-appgen: \(s)\n"
    _ = line.withCString { write(2, $0, strlen($0)) }
    exit(2)
}

var froms: [String] = []
var to: String?
var dryRun = false
var jailsFile: String?
var systemDir = "/Applications"
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--from":
        guard let d = args.popFirst() else { die("--from needs a directory") }
        froms.append(d)
    case "--to":
        guard let d = args.popFirst() else { die("--to needs a directory") }
        to = d
    case "--dry-run": dryRun = true
    case "--system":
        guard let d = args.popFirst() else { die("--system needs a directory") }
        systemDir = d
    case "--jails":
        guard let f = args.popFirst() else { die("--jails needs a file") }
        jailsFile = f
    case "-h", "--help":
        say("usage: abyss-appgen [--from DIR]... [--to DIR] [--jails FILE] [--system DIR] [--dry-run]"); exit(0)
    default: die("unknown option '\(a)'")
    }
}
if froms.isEmpty { froms = ["/usr/local/share/applications", "/usr/share/applications"] }
/// Terminal, for `Terminal=true` entries: the shell binary, installed beside
/// this one (P15.4). Absent, those entries are skipped and say why.
let terminalProgram: String? = {
    // Absolute: a launcher runs from wherever the Finder or the Dock is, so a
    // relative argv[0] (`.build/debug/abyss-appgen`) would name nothing there.
    guard let found = Spawn.resolveExecutable(CommandLine.arguments[0]),
          let real = realpath(found, nil) else { return nil }
    let me = String(cString: real); free(real)
    let dir = me.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
    let t = (dir.isEmpty ? "." : dir) + "/AquaDemo"
    return access(t, X_OK) == 0 ? t : nil
}()
let home = String(cString: getenv("HOME") ?? strdup("/"))
let dest = to ?? (getuid() == 0 ? "/Applications" : home + "/Applications")
let iconRoots = ["/usr/local/share/icons", "/usr/share/icons", "/usr/local/share/pixmaps", "/usr/share/pixmaps"]

// MARK: - Files

func list(_ path: String) -> [String] {
    guard let d = opendir(path) else { return [] }
    defer { closedir(d) }
    var names: [String] = []
    while let e = readdir(d) {
        let name = withUnsafeBytes(of: e.pointee.d_name) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if name != "." && name != ".." { names.append(name) }
    }
    return names.sorted()
}

func isDirectory(_ p: String) -> Bool {
    var st = stat(); return stat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
}
func exists(_ p: String) -> Bool { access(p, F_OK) == 0 }

func read(_ path: String, limit: Int = 1 << 20) -> String? {
    let fd = open(path, O_RDONLY); guard fd >= 0 else { return nil }
    defer { close(fd) }
    var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536)
    while out.count < limit {
        let n = buf.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        out += buf[0..<n]
    }
    return String(decoding: out, as: UTF8.self)
}

@discardableResult
func write(_ path: String, _ text: String, mode: mode_t = 0o644) -> Bool {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode); guard fd >= 0 else { return false }
    defer { close(fd) }
    return text.utf8CString.withUnsafeBytes { raw in
        Glibc.write(fd, raw.baseAddress, raw.count - 1) == raw.count - 1
    }
}

func run(_ argv: [String]) -> Bool { Spawn.run(argv, limit: 1 << 16).succeeded }

// MARK: - The icon index, built once

/// Every PNG and SVG under the icon roots, by name — walked once rather than
/// once per application (the themes on the guest hold tens of thousands).
func index(_ dir: String, depth: Int, into idx: inout [String: [String]]) {
    for name in list(dir) {
        let p = dir + "/" + name
        if depth > 0, isDirectory(p) { index(p, depth: depth - 1, into: &idx); continue }
        for ext in [".png", ".svg", ".svgz"] where name.hasSuffix(ext) {
            idx[String(name.dropLast(ext.count)), default: []].append(p)
        }
    }
}
var iconIndex: [String: [String]] = [:]
for r in iconRoots { index(r, depth: 4, into: &iconIndex) }

func iconChoice(_ icon: String, _ idx: [String: [String]]) -> AppIconChoice? {
    if icon.hasPrefix("/") {
        return icon.hasSuffix(".svg") ? .svg(icon, size: IconLookup.wanted) : exists(icon) ? .png(icon) : nil
    }
    return IconLookup.choose(from: idx[icon] ?? [])
}

// MARK: - Confinement (PHASE18 P18.5)

let jailApps: [(String, String)] = {
    let path = jailsFile ?? (geteuid() == 0 ? "/usr/local/etc/abyss/jails.ini"
                                            : ((try? Pool.configDir()).map { $0 + "/jails.ini" } ?? ""))
    guard !path.isEmpty, let text = read(path) else { return [] }
    return Config.parse(text).pairs("apps")
}()

// MARK: - Entries

struct Planned { let dir: String; let entry: DesktopEntry; let argv: [String]; let source: String }
var planned: [Planned] = []
var names = Set<String>()
for from in froms {
    for file in list(from) where file.hasSuffix(".desktop") {
        let source = from + "/" + file
        guard let text = read(source), let e = DesktopEntry.parse(text) else {
            say("skip \(file): not a desktop entry"); continue
        }
        if let why = e.skipReason(haveTerminal: terminalProgram != nil) { say("skip \(file): \(why)"); continue }
        if !e.tryExec.isEmpty, Spawn.resolveExecutable(e.tryExec) == nil {
            say("skip \(file): \(e.tryExec) is not installed"); continue
        }
        guard let cmd = e.command() else { say("skip \(file): its Exec cannot be run"); continue }
        let dir = AppBundle.directoryName(e.name)
        if names.contains(dir) { say("skip \(file): \(dir) is taken by an earlier entry"); continue }
        names.insert(dir)
        planned.append(Planned(dir: dir, entry: e, argv: cmd.argv, source: source))
    }
}

// MARK: - Write

func jailOf(_ p: Planned) -> String? {
    p.entry.terminal ? nil : AppBundle.jailClass(entry: p.entry, desktopFile: p.source, apps: jailApps)
}

if !dryRun, !exists(dest), mkdir(dest, 0o755) != 0 { die("cannot create \(dest)") }
for p in planned {
    let bundle = dest + "/" + p.dir
    if exists(bundle), !exists(bundle + "/" + AppBundle.marker) {
        say("kept \(p.dir): it is not ours (no \(AppBundle.marker))"); continue
    }
    let stem = String(p.dir.dropLast(4))
    let icon = iconChoice(p.entry.icon, iconIndex)
    let iconWords: String
    switch icon {
    case .png(let f)?: iconWords = f
    case .svg(let f, let size)?: iconWords = "\(f) at \(size)px"
    case nil: iconWords = "none found for '\(p.entry.icon)'"
    }
    let confined = jailOf(p).map { ", confined in \($0)" } ?? ""
    if dryRun { say("would make \(p.dir) from \(p.source) (icon: \(iconWords)\(confined))"); continue }

    let tmp = dest + "/.\(stem).app.tmp"
    _ = run(["rm", "-rf", tmp])
    guard mkdir(tmp, 0o755) == 0, mkdir(tmp + "/Contents", 0o755) == 0,
          mkdir(tmp + "/Contents/MacOS", 0o755) == 0, mkdir(tmp + "/Contents/Resources", 0o755) == 0,
          write(tmp + "/Contents/MacOS/" + stem, AppBundle.launcher(argv: p.argv, source: p.source,
                                                                            terminal: p.entry.terminal ? terminalProgram : nil,
                                                                            jail: jailOf(p)), mode: 0o755),
          write(tmp + "/" + AppBundle.marker, p.source + "\n"),
          write(tmp + "/" + AppBundle.appIDFile,
                p.entry.appIDs(desktopFile: p.source).joined(separator: "\n") + "\n") else {
        say("FAILED \(p.dir): could not write it"); _ = run(["rm", "-rf", tmp]); continue
    }
    let png = tmp + "/Contents/Resources/" + stem + ".png"
    var iconOK = true
    switch icon {
    case .png(let f)?: iconOK = run(["cp", f, png])
    case .svg(let f, let size)?:
        iconOK = run(["rsvg-convert", "-w", "\(size)", "-h", "\(size)", "-o", png, f])
    case nil: break
    }
    if !iconOK { say("note \(p.dir): its icon could not be made from \(iconWords)") }
    // Into place in one rename; an old copy of ours is moved out first.
    _ = run(["rm", "-rf", bundle])
    guard rename(tmp, bundle) == 0 else { say("FAILED \(p.dir): could not move it into place"); continue }
    say("made \(p.dir) from \(p.source) (icon: \(icon == nil ? iconWords : iconOK ? iconWords : "none")\(confined))")
}

// MARK: - The desktop's own (P18.13 loose ends)
//
// A bundle for each of the desktop's own applications, so the Applications
// folder shows them as a Mac's does (BuiltinApp's layout: Utilities for the
// utilities, no Finder). Its launcher runs the shell binary in the app's
// scene; its icon is the theme's (`Contents/theme-icon`), so it follows the
// theme. Root's run puts them in /Applications. A person's run puts in
// ~/Applications only what /Applications lacks (a developer's session has
// no root run), and Agent, which is the person's: there only while their
// agents are on (P18.13a: off, the rest of the desktop does not know).
var builtinsMade = Set<String>()   // "Utilities/Terminal.app", "Agent.app"
func builtinBundle(_ b: BuiltinApp, under folder: String) -> String {
    let sub = b.folder ?? ""
    return (sub.isEmpty ? folder : folder + "/" + sub) + "/" + AppBundle.directoryName(b.name)
}
let systemApplications = systemDir
let personal = dest != systemApplications
let agentsOn = Agents.on()
if let binary = terminalProgram {
    for b in BuiltinApp.all where b.folder != nil {
        if b.token == "agent" {
            if !personal { say("skip \(b.name): it is the person's, in ~/Applications, while their agents are on"); continue }
            if !agentsOn { continue }
        } else if personal, exists(builtinBundle(b, under: systemApplications)) {
            continue   // /Applications has it
        }
        let bundle = builtinBundle(b, under: dest)
        let rel = String(bundle.dropFirst(dest.count + 1))
        if exists(bundle), !exists(bundle + "/" + AppBundle.marker) {
            say("kept \(rel): it is not ours (no \(AppBundle.marker))"); continue
        }
        builtinsMade.insert(rel)
        if dryRun { say("would make \(rel), the desktop's own"); continue }
        let parent = String(bundle.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/"))
        if !exists(parent), mkdir(parent, 0o755) != 0 { say("FAILED \(rel): cannot create \(parent)"); continue }
        let stem = String(AppBundle.directoryName(b.name).dropLast(4))
        let tmp = parent + "/.\(stem).app.tmp"
        _ = run(["rm", "-rf", tmp])
        guard mkdir(tmp, 0o755) == 0, mkdir(tmp + "/Contents", 0o755) == 0, mkdir(tmp + "/Contents/MacOS", 0o755) == 0,
              write(tmp + "/Contents/MacOS/" + stem, b.launcher(binary: binary), mode: 0o755),
              write(tmp + "/" + AppBundle.marker, b.marker + "\n"),
              write(tmp + "/" + AppBundle.appIDFile, b.appID + "\n"),
              write(tmp + "/" + AppBundle.themeIconFile, b.themeIcon + "\n") else {
            say("FAILED \(rel): could not write it"); _ = run(["rm", "-rf", tmp]); continue
        }
        _ = run(["rm", "-rf", bundle])
        guard rename(tmp, bundle) == 0 else { say("FAILED \(rel): could not move it into place"); continue }
        say("made \(rel), the desktop's own (scene \(b.scene))")
    }
} else {
    say("skip the desktop's own applications: there is no AquaDemo beside abyss-appgen")
}

// Ours, whose entry has gone: a port's whose desktop entry went, or a
// built-in's not wanted here any more (Agent with agents turned off).
if !dryRun {
    for sub in ["", "Utilities"] {
        let dir = sub.isEmpty ? dest : dest + "/" + sub
        for name in list(dir) where name.hasSuffix(".app") {
            let rel = sub.isEmpty ? name : sub + "/" + name
            if sub.isEmpty, names.contains(name) { continue }
            if builtinsMade.contains(rel) { continue }
            let marker = dir + "/" + name + "/" + AppBundle.marker
            guard exists(marker) else { continue }
            let source = read(marker)?.trimmingNewline() ?? "?"     // before it goes with the bundle
            _ = run(["rm", "-rf", dir + "/" + name])
            say(source.hasPrefix("builtin:") ? "removed \(rel): not wanted here now"
                                             : "removed \(rel): its entry \(source) is gone")
        }
    }
}

extension String {
    func trimmingNewline() -> String { hasSuffix("\n") ? String(dropLast()) : self }
}
