// abyss-installctl — the command-line face of the installer.
//
//   abyss-installctl disks
//   abyss-installctl check   --disk NAME [plan options]
//   abyss-installctl install --disk NAME [plan options]
//
// It links `InstallWire` and **not** `InstallRun`: a client speaks the protocol,
// it does not carry the code that forks `gpart`. The GUI (P5.4) is built the
// same way. This exists because the harness needs a caller, and because an installer whose privileged half can
// only be driven by a graphical program is one you cannot debug on a machine
// that has no graphics — which, for an installer, is every machine it has not
// finished installing yet.

import CurrentIPC
import Install
import InstallWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}

func usage() -> Never {
    emit(1, """
    usage: abyss-installctl <disks|check|install> [options]
      --disk NAME          the whole disk to take (required for check/install)
      --pool NAME          pool name (default abyss)
      --dist DIR           where the distribution sets are
      --sets a.txz,b.txz   which sets to extract (default base,kernel)
      --hostname NAME
      --timezone ZONE      e.g. America/Chicago
      --swap MiB           0 for none
      --root-hash HASH     already-hashed root password
      --user NAME:HASH[:GROUPS]
      --service NAME       the service to talk to (default install)
      --yes                do not ask before the first destructive step
    """)
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first, ["disks", "check", "install"].contains(verb) else { usage() }
args.removeFirst()

var disk = "", pool = "abyss", dist = "", host = "abyss", tz = "", rootHash = ""
var swapMiB: UInt64?
var sets: [String] = []
var users: [Account] = []
var erase = false
var serviceName = "install"
var assumeYes = false

// Options are read with the loop spelled out rather than a helper, because a
// top-level `func` here is nonisolated and cannot touch these (Swift 6 strict
// concurrency, HANDOFF §2.4) — the same shape `anchorbin` and `portalbin` use.
var i = 0
while i < args.count {
    let flag = args[i]
    let needsValue = ["--disk", "--pool", "--dist", "--hostname", "--timezone",
                      "--swap", "--root-hash", "--service", "--user",
                      "--sets"].contains(flag)
    var value = ""
    if needsValue {
        i += 1
        guard i < args.count else {
            emit(2, "abyss-installctl: \(flag) needs a value"); exit(2)
        }
        value = args[i]
    }
    switch flag {
    case "--disk": disk = value
    case "--pool": pool = value
    case "--dist": dist = value
    case "--hostname": host = value
    case "--timezone": tz = value
    case "--swap": swapMiB = UInt64(value) ?? 0
    case "--root-hash": rootHash = value
    case "--sets": sets = value.split(separator: ",").map(String.init)
    case "--service": serviceName = value
    case "--yes": assumeYes = true
    case "--user":
        let spec = value.split(separator: ":", maxSplits: 2).map(String.init)
        guard spec.count >= 2 else {
            emit(2, "abyss-installctl: --user wants NAME:HASH[:GROUPS]"); exit(2)
        }
        users.append(Account(name: spec[0], passwordHash: spec[1],
                             groups: spec.count > 2
                                 ? spec[2].split(separator: ",").map(String.init) : []))
    // **The confirmation, spelled out.** A disk that is already full is refused
    // until somebody says this — and the flag is long and unpleasant on purpose,
    // because it is the sentence that turns "refuse" into "destroy what is
    // there". `--force` would have been shorter and would not have said what it
    // does.
    case "--erase-this-disk": erase = true
    case "-h", "--help": usage()
    default:
        emit(2, "abyss-installctl: unknown option '\(flag)'")
        exit(2)
    }
    i += 1
}

let defaults = InstallPlan(disk: "")
var plan = InstallPlan(disk: disk, poolName: pool,
                       swapBytes: swapMiB.map { $0 * 1024 * 1024 } ?? defaults.swapBytes,
                       sets: sets.isEmpty ? defaults.sets : sets,
                       distDirectory: dist.isEmpty ? defaults.distDirectory : dist,
                       hostname: host, timezone: tz,
                       rootPasswordHash: rootHash.isEmpty ? "*" : rootHash,
                       accounts: users,
                       eraseExistingData: erase)

var request = Msg()
request.set("method", verb == "disks" ? "disks" : verb)
if verb != "disks" { Wire.encode(plan, into: &request) }

let sock: Int32
do { sock = try Current.connect(serviceName) } catch {
    emit(2, "abyss-installctl: cannot reach the installer: \(error)")
    exit(1)
}
defer { close(sock) }
do { try Current.send(request, on: sock) } catch {
    emit(2, "abyss-installctl: cannot send the request: \(error)")
    exit(1)
}

switch verb {
case "disks":
    guard let reply = try? Current.receive(on: sock) else {
        emit(2, "abyss-installctl: no reply"); exit(1)
    }
    guard reply.bool("ok") == true else {
        emit(2, "cannot look at this machine's disks: \(reply.string("error") ?? "?")")
        exit(1)
    }
    let inv = Wire.decodeInventory(reply)
    for d in inv.disks {
        var notes: [String] = []
        if d.holdsRunningRoot { notes.append("holds the running root") }
        if !d.mountedAt.isEmpty { notes.append("mounted at " + d.mountedAt.joined(separator: " ")) }
        // No Foundation in this tree, so no String(format:) — a tenth of a GiB
        // by integer arithmetic, the same way PlanRefusal says a size.
        let tenths = (d.bytes * 10) / (1024 * 1024 * 1024)
        emit(1, "\(d.name)\t\(tenths / 10).\(tenths % 10) GiB"
             + (d.description.isEmpty ? "" : "\t\(d.description)")
             + (notes.isEmpty ? "" : "\t[\(notes.joined(separator: "; "))]"))
    }
    emit(1, "pools: " + (inv.importedPools.isEmpty ? "(none)"
                         : inv.importedPools.joined(separator: " ")))

case "check":
    guard let reply = try? Current.receive(on: sock) else {
        emit(2, "abyss-installctl: no reply"); exit(1)
    }
    let n = Int(reply.uint64("problems.count") ?? 0)
    if n > 0 {
        for k in 0..<n { emit(2, "refused: " + (reply.string("problem.\(k)") ?? "?")) }
        exit(1)
    }
    emit(1, "\(reply.uint64("steps.count") ?? 0) steps:")
    emit(1, reply.string("render") ?? "")

case "install":
    if !assumeYes {
        emit(2, "abyss-installctl: refusing to install without --yes."
             + " This rewrites \(plan.disk) and there is no undo.")
        exit(2)
    }
    var failed = false
    while let m = try? Current.receive(on: sock) {
        guard let event = Wire.event(from: m) else {
            // A refusal arrives as an ordinary reply rather than an event.
            if m.bool("ok") == false {
                emit(2, "refused: \(m.string("error") ?? "?")"); exit(1)
            }
            continue
        }
        switch event {
        case .starting(let idx, let total, let what, let destructive):
            emit(1, "[\(idx + 1)/\(total)] \(what)\(destructive ? "  *" : "")")
        case .ok: break
        case .failed(let _idx, _, let why, let ignored):
            _ = _idx
            emit(2, ignored ? "    (allowed to fail: \(why))" : "    FAILED: \(why)")
        case .finished(let ok, let error):
            if ok { emit(1, "installed.") } else { emit(2, "install failed: \(error)"); failed = true }
        }
    }
    exit(failed ? 1 : 0)

default: usage()
}
