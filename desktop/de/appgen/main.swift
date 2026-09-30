// abyss-appgen — write an application bundle for every installed port that has
// a desktop entry (PHASE15 P15.1).
//
//   abyss-appgen [--from DIR]... [--to DIR] [--dry-run]
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
    case "-h", "--help":
        say("usage: abyss-appgen [--from DIR]... [--to DIR] [--dry-run]"); exit(0)
    default: die("unknown option '\(a)'")
    }
}
if froms.isEmpty { froms = ["/usr/local/share/applications", "/usr/share/applications"] }
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
        if let why = e.skipReason() { say("skip \(file): \(why)"); continue }
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
    if dryRun { say("would make \(p.dir) from \(p.source) (icon: \(iconWords))"); continue }

    let tmp = dest + "/.\(stem).app.tmp"
    _ = run(["rm", "-rf", tmp])
    guard mkdir(tmp, 0o755) == 0, mkdir(tmp + "/Contents", 0o755) == 0,
          mkdir(tmp + "/Contents/MacOS", 0o755) == 0, mkdir(tmp + "/Contents/Resources", 0o755) == 0,
          write(tmp + "/Contents/MacOS/" + stem, AppBundle.launcher(argv: p.argv, source: p.source), mode: 0o755),
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
    say("made \(p.dir) from \(p.source) (icon: \(icon == nil ? iconWords : iconOK ? iconWords : "none"))")
}

// Ours, whose entry has gone.
if !dryRun {
    for name in list(dest) where name.hasSuffix(".app") && !names.contains(name) {
        let marker = dest + "/" + name + "/" + AppBundle.marker
        guard exists(marker) else { continue }
        let source = read(marker)?.trimmingNewline() ?? "?"     // before it goes with the bundle
        _ = run(["rm", "-rf", dest + "/" + name])
        say("removed \(name): its entry \(source) is gone")
    }
}

extension String {
    func trimmingNewline() -> String { hasSuffix("\n") ? String(dropLast()) : self }
}
