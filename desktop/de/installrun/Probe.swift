// What this machine looks like, for the refusals in `Install` to judge.
//
// P5.1 made the machine an argument so that every refusal could be tested on a
// machine that has no disks to lose. This is the other half: the one place that
// actually looks, and it is deliberately thin — read four commands, parse them,
// build the value. The parsing is pure and unit-tested against **real captured
// output**, because a parser tested against text somebody made up is a parser
// tested against an assumption.

import Install
import Vents

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum ProbeError: Error, Equatable {
    case notSupported(String)
    case commandFailed(String, String)
}

/// Gather the machine's disks, what is mounted from them, and which pools exist.
///
/// FreeBSD only, and it says so rather than guessing. **This is a positive
/// control, not a skip:** on Linux the installer must fail loudly and name what
/// it could not find, because "the tests were green on the machine I develop on"
/// is exactly how an installer ships broken.
public func probeMachine() throws -> DiskInventory {
    #if os(FreeBSD)
    let geom = try capture(["geom", "disk", "list"])
    let mounts = try capture(["mount", "-p"])
    let labels = (try? capture(["glabel", "status", "-s"])) ?? ""
    let poolNames = parsePoolNames(try capture(["zpool", "list", "-H", "-o", "name"]))
    var poolVdevs: [String: [String]] = [:]
    for p in poolNames {
        poolVdevs[p] = parseZpoolVdevs((try? capture(["zpool", "list", "-Hv", p])) ?? "")
    }
    // **Pools that are here but not imported — which on a live medium is all of
    // them.** `zpool import` with no arguments *scans* and lists what could be
    // imported; it imports nothing. Verified both ways before this line existed:
    // the scan found a pool on a disk and `zpool list` afterwards was unchanged.
    //
    // Best-effort, and deliberately so: it needs root, it can take a moment on a
    // machine with many disks, and a medium that cannot scan should still be
    // able to install. What it must never do is report *no* pools when it simply
    // failed — see the caller's use of `scanned`.
    let importScan = (try? capture(["zpool", "import"])) ?? ""
    let importable = parseImportablePools(importScan)
    // What this machine calls itself, from the kernel environment — **not from
    // sysctl**, where `smbios.system.*` is not (PHASE12 §4.2). nil when the
    // machine does not say, which is a real answer and not a failure: it is what
    // stops a Mac Pro's loader tunable being written to a board that never asked
    // for it.
    let machine = Vents.Kenv.machine().map {
        MachineIdentity(maker: $0.maker, product: $0.product)
    }
    return inventory(geom: geom, mounts: mounts, labels: labels,
                     poolVdevs: poolVdevs, importablePools: importable,
                     machine: machine)
    #else
    throw ProbeError.notSupported(
        "disk discovery needs FreeBSD's geom(8), mount(8) and zpool(8);"
        + " this is \(osName()), where an AbyssBSD install cannot be performed")
    #endif
}

func osName() -> String {
    #if os(Linux)
    return "Linux"
    #elseif os(FreeBSD)
    return "FreeBSD"
    #else
    return "an unsupported system"
    #endif
}

func capture(_ argv: [String]) throws -> String {
    let r = runCaptureStdout(argv)
    guard r.status == 0 else {
        throw ProbeError.commandFailed(argv.joined(separator: " "), r.text)
    }
    return r.text
}

// MARK: - The pure part

/// `geom disk list` → the disks and their sizes.
///
/// One command answers name, size and description together, which is why it is
/// preferred over `sysctl kern.disks` plus a `diskinfo` per disk — and
/// `diskinfo` needs to open the device, which needs root even to *look*.
public func parseGeomDiskList(_ text: String) -> [(name: String, bytes: UInt64, descr: String)] {
    var out: [(String, UInt64, String)] = []
    var name = ""
    var bytes: UInt64 = 0
    var descr = ""
    func flush() {
        if !name.isEmpty { out.append((name, bytes, descr)) }
        name = ""; bytes = 0; descr = ""
    }
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = trimmed(String(rawLine))
        if line.hasPrefix("Geom name:") {
            flush()
            name = trimmed(String(line.dropFirst("Geom name:".count)))
        } else if line.hasPrefix("Mediasize:") {
            // "Mediasize: 85899345920 (80G)" — the number, not the pretty part.
            let rest = trimmed(String(line.dropFirst("Mediasize:".count)))
            let digits = rest.prefix { $0.isNumber }
            bytes = UInt64(digits) ?? 0
        } else if line.hasPrefix("descr:") {
            let d = trimmed(String(line.dropFirst("descr:".count)))
            // virtio and several others report a literal "(null)"; an empty
            // description is more honest than showing that to a person.
            descr = d == "(null)" ? "" : d
        }
    }
    flush()
    return out
}

/// `mount -p` → (device-or-dataset, mountpoint). The first column is a device
/// for UFS and msdosfs and a **dataset name** for ZFS, which is why resolving it
/// to a disk needs the pool map as well.
public func parseMountP(_ text: String) -> [(source: String, mountpoint: String)] {
    var out: [(String, String)] = []
    for rawLine in text.split(separator: "\n") {
        let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2 else { continue }
        out.append((String(fields[0]), String(fields[1])))
    }
    return out
}

/// `glabel status -s` → label → the provider it labels (`gpt/efiboot0` →
/// `vtbd0p2`). Without this, a `/dev/gpt/…` mount cannot be traced to a disk,
/// and the disk holding it would look free.
public func parseLabelComponents(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for rawLine in text.split(separator: "\n") {
        let f = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard f.count >= 3 else { continue }
        out[String(f[0])] = String(f[2])
    }
    return out
}

public func parsePoolNames(_ text: String) -> [String] {
    text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
}

/// `zpool list -Hv <pool>` → the providers the pool is built from. The pool's
/// own line has no leading tab; the vdev lines do.
public func parseZpoolVdevs(_ text: String) -> [String] {
    var out: [String] = []
    for rawLine in text.split(separator: "\n") {
        guard rawLine.first == "\t" || rawLine.first == " " else { continue }
        let f = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = f.first else { continue }
        let name = String(first)
        // Skip the vdev *kinds*, which appear as parents of the real providers.
        if ["mirror", "raidz1", "raidz2", "raidz3", "draid", "logs", "cache",
            "spares", "special", "dedup"].contains(where: { name.hasPrefix($0) }) { continue }
        out.append(name)
    }
    return out
}

/// The disk a provider lives on: `vtbd0p2` → `vtbd0`, `ada0s1a` → `ada0`,
/// `/dev/gpt/efiboot0` → whatever `glabel` says it labels.
public func diskOf(provider: String, labels: [String: String], disks: [String]) -> String? {
    var name = provider
    if name.hasPrefix("/dev/") { name = String(name.dropFirst("/dev/".count)) }
    if let component = labels[name] { name = component }
    // Longest match wins so `ada1` never claims `ada10p1`.
    return disks.filter { name == $0 || name.hasPrefix($0) }
                .max(by: { $0.count < $1.count })
}

/// Build the inventory from four pieces of captured text. Pure, so the tests
/// feed it output captured from a real machine rather than a machine.
/// Pools `zpool import` can see but nobody has imported, and the devices each
/// one lives on.
///
/// Parsed from the real thing rather than from a description of it — the fixture
/// this is tested against was captured off a machine carrying a mirror, a
/// single-device pool and a partition-backed one at once, because a parser that
/// has only met one vdev shape has only been shown to handle one.
///
/// The config block is a tree: the pool's own name first, then vdev *type* nodes
/// (`mirror-0`, `raidz1-0`, `logs`, `cache`, …), then the leaves that are real
/// devices. Only the leaves map to a disk.
public func parseImportablePools(_ text: String) -> [String: [String]] {
    func trim(_ s: Substring) -> String {
        String(s.drop(while: { $0 == " " || $0 == "\t" })
                .reversed().drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" })
                .reversed())
    }
    var out: [String: [String]] = [:]
    var pool: String?
    var inConfig = false
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        let trimmed = trim(Substring(line))
        if trimmed.hasPrefix("pool:") {
            pool = trim(trimmed.dropFirst("pool:".count))
            inConfig = false
            if let p = pool, !p.isEmpty, out[p] == nil { out[p] = [] }
            continue
        }
        if trimmed == "config:" { inConfig = true; continue }
        guard inConfig, let p = pool else { continue }
        if trimmed.isEmpty { continue }
        // The config block is indented; anything flush left has ended it.
        guard line.hasPrefix("\t") || line.hasPrefix(" ") else { inConfig = false; continue }
        guard let name = trimmed.split(separator: " ").first.map(String.init) else { continue }
        if name == p { continue }                       // the pool's own row
        if isVdevTypeNode(name) { continue }            // mirror-0, raidz2-1, logs…
        out[p, default: []].append(name)
    }
    return out
}

/// True for the structural rows of a `zpool` config tree, which name a vdev
/// *kind* rather than a device: `mirror-0`, `raidz1-2`, `draid2:4d:1c:0s-0`,
/// `replacing-0`, and the bare section headings.
func isVdevTypeNode(_ name: String) -> Bool {
    if ["logs", "cache", "spares", "dedup", "special"].contains(name) { return true }
    for kind in ["mirror", "raidz", "raidz1", "raidz2", "raidz3", "draid",
                 "replacing", "spare", "indirect"] where name.hasPrefix(kind) {
        // `mirror-0` and `draid2:4d:1c:0s-0` both carry a trailing `-<n>`;
        // a device called `mirrorX` would not, and must not be eaten here.
        if let dash = name.lastIndex(of: "-"),
           !name[name.index(after: dash)...].isEmpty,
           name[name.index(after: dash)...].allSatisfy(\.isNumber) {
            return true
        }
    }
    return false
}

public func inventory(geom: String, mounts: String, labels: String,
                      poolVdevs: [String: [String]],
                      importablePools: [String: [String]] = [:],
                      machine: MachineIdentity? = nil) -> DiskInventory {
    let found = parseGeomDiskList(geom)
    let names = found.map(\.name)
    let labelMap = parseLabelComponents(labels)

    // Which disk does each pool sit on?
    var poolDisks: [String: Set<String>] = [:]
    for (pool, vdevs) in poolVdevs {
        var set = Set<String>()
        for v in vdevs {
            if let d = diskOf(provider: v, labels: labelMap, disks: names) { set.insert(d) }
        }
        poolDisks[pool] = set
    }

    var mountedAt: [String: [String]] = [:]
    var rootDisks = Set<String>()
    for (source, point) in parseMountP(mounts) {
        if source == "devfs" || source == "procfs" || source == "fdescfs" { continue }
        var disksForThis = Set<String>()
        if let d = diskOf(provider: source, labels: labelMap, disks: names) {
            disksForThis.insert(d)
        } else if let slash = source.firstIndex(of: "/"),
                  let ds = poolDisks[String(source[source.startIndex..<slash])] {
            // A ZFS dataset: `zroot/ROOT/default` belongs to the pool `zroot`.
            disksForThis.formUnion(ds)
        } else if let ds = poolDisks[source] {
            disksForThis.formUnion(ds)
        }
        for d in disksForThis {
            mountedAt[d, default: []].append(point)
            if point == "/" { rootDisks.insert(d) }
        }
    }

    // Which disk does each *un-imported* pool sit on? Same mapping as above —
    // a vdev of `vtbd2p3` means the pool lives on `vtbd2`.
    var existing: [String: [String]] = [:]
    for (pool, vdevs) in importablePools {
        for v in vdevs {
            guard let d = diskOf(provider: v, labels: labelMap, disks: names) else { continue }
            if !(existing[d]?.contains(pool) ?? false) { existing[d, default: []].append(pool) }
        }
    }

    let disks = found.map { f in
        Disk(name: f.name, bytes: f.bytes, description: f.descr,
             mountedAt: (mountedAt[f.name] ?? []).sorted(),
             holdsRunningRoot: rootDisks.contains(f.name),
             existingPools: (existing[f.name] ?? []).sorted())
    }
    return DiskInventory(disks: disks, importedPools: poolVdevs.keys.sorted(),
                         machine: machine)
}

// MARK: - Running a command for its stdout

struct CaptureResult { let status: Int32; let text: String }

func runCaptureStdout(_ argv: [String]) -> CaptureResult {
    guard let program = argv.first else { return CaptureResult(status: -1, text: "") }
    var p: [Int32] = [-1, -1]
    guard pipe(&p) == 0 else { return CaptureResult(status: -1, text: errnoText()) }
    let pid = fork()
    if pid < 0 { close(p[0]); close(p[1]); return CaptureResult(status: -1, text: errnoText()) }
    if pid == 0 {
        dup2(p[1], 1); dup2(p[1], 2)
        close(p[0]); close(p[1])
        let devnull = open("/dev/null", O_RDONLY)
        if devnull >= 0 { dup2(devnull, 0); close(devnull) }
        withCStrings(argv) { _ = execvp(program, $0) }
        _exit(127)
    }
    close(p[1])
    var captured = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = chunk.withUnsafeMutableBytes { read(p[0], $0.baseAddress, 8192) }
        if n <= 0 { break }
        captured.append(contentsOf: chunk[0..<n])
        if captured.count > 1 << 20 { break }
    }
    close(p[0])
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    return CaptureResult(status: exitStatus(status),
                         text: String(decoding: captured, as: UTF8.self))
}
