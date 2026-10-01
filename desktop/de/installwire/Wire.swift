// The plan on the wire.
//
// `Install` knows nothing about `CurrentIPC` and `CurrentIPC` knows nothing
// about installing; this is the seam. It lives here rather than in either so
// that P5.1 keeps the property that earns it its tests — `de/install` imports
// nothing at all, and every one of its refusals runs on a machine with no disks.
//
// **And it is its own target so that the GUI can link the protocol without
// linking the executor.** The Aqua installer (P5.4) needs to ask for disks,
// check a plan and watch an install; it must not link `InstallRun`, which is
// the code that forks `gpart`. Keeping the wire format separate is what makes
// "the GUI does not touch the disk" (PHASE5 §1) true of the binary and not just
// of the design.
//
// `Msg` has scalars and no arrays, so lists are indexed field names
// (`disk.0.name`). Verbose on the wire and trivial to read in a log, which for a
// control plane whose messages describe rewriting somebody's disk is the right
// trade.

import CurrentIPC
import Install

/// What an install reports as it happens.
///
/// Lives beside the wire format rather than with the runner, because it is the
/// vocabulary **both ends** share: the executor emits these and the GUI decodes
/// them, and the GUI must not link the executor to do so.
public enum RunEvent: Sendable, Equatable {
    /// About to do this. `destructive` is true from the first step that changes
    /// the disk — a caller that wants to confirm has until this event.
    case starting(index: Int, total: Int, what: String, destructive: Bool)
    case ok(index: Int)
    /// A step failed. `ignored` when the plan allowed it to.
    case failed(index: Int, what: String, why: String, ignored: Bool)
    case finished(ok: Bool, error: String)
}

public enum Wire {

    // MARK: - The plan

    public static func encode(_ p: InstallPlan, into m: inout Msg) {
        m.set("disk", p.disk)
        m.set("pool", p.poolName)
        m.set("esp", p.espBytes)
        m.set("swap", p.swapBytes)
        m.set("dist", p.distDirectory)
        m.set("mountpoint", p.mountpoint)
        m.set("hostname", p.hostname)
        m.set("timezone", p.timezone)
        m.set("keymap", p.keymap)
        m.set("rootpw", p.rootPasswordHash)
        // **The confirmation has to cross the wire or it does nothing.** The
        // unprivileged half is where a person says "yes, erase it"; the
        // privileged half is where that permission is spent. A flag that stops
        // at the socket is a guard that silently never lifts — and worse, one
        // that looks like it did.
        m.set("erase", p.eraseExistingData ? UInt64(1) : UInt64(0))
        m.set("autologin", p.autoLogin ? UInt64(1) : UInt64(0))
        m.set("sets.count", UInt64(p.sets.count))
        for (i, s) in p.sets.enumerated() { m.set("set.\(i)", s) }
        m.set("accounts.count", UInt64(p.accounts.count))
        for (i, a) in p.accounts.enumerated() {
            m.set("account.\(i).name", a.name)
            m.set("account.\(i).full", a.fullName)
            m.set("account.\(i).hash", a.passwordHash)
            m.set("account.\(i).groups", a.groups.joined(separator: ","))
            m.set("account.\(i).shell", a.shell)
        }
    }

    public static func decodePlan(_ m: Msg) -> InstallPlan {
        let defaults = InstallPlan(disk: "")
        var sets: [String] = []
        for i in 0..<Int(m.uint64("sets.count") ?? 0) {
            if let s = m.string("set.\(i)") { sets.append(s) }
        }
        var accounts: [Account] = []
        for i in 0..<Int(m.uint64("accounts.count") ?? 0) {
            guard let name = m.string("account.\(i).name") else { continue }
            let groups = (m.string("account.\(i).groups") ?? "")
                .split(separator: ",").map(String.init)
            accounts.append(Account(name: name,
                                    fullName: m.string("account.\(i).full") ?? "",
                                    passwordHash: m.string("account.\(i).hash") ?? "*",
                                    groups: groups,
                                    shell: m.string("account.\(i).shell") ?? "/bin/sh"))
        }
        return InstallPlan(
            disk: m.string("disk") ?? "",
            poolName: m.string("pool") ?? defaults.poolName,
            espBytes: m.uint64("esp") ?? defaults.espBytes,
            swapBytes: m.uint64("swap") ?? defaults.swapBytes,
            sets: sets.isEmpty ? defaults.sets : sets,
            distDirectory: m.string("dist") ?? defaults.distDirectory,
            mountpoint: m.string("mountpoint") ?? defaults.mountpoint,
            hostname: m.string("hostname") ?? defaults.hostname,
            timezone: m.string("timezone") ?? "",
            keymap: m.string("keymap") ?? "",
            rootPasswordHash: m.string("rootpw") ?? "*",
            accounts: accounts,
            eraseExistingData: (m.uint64("erase") ?? 0) == 1,
            autoLogin: (m.uint64("autologin") ?? 0) == 1)
    }

    // MARK: - The machine

    public static func encode(_ inv: DiskInventory, into m: inout Msg) {
        m.set("disks.count", UInt64(inv.disks.count))
        for (i, d) in inv.disks.enumerated() {
            m.set("disk.\(i).name", d.name)
            m.set("disk.\(i).bytes", d.bytes)
            m.set("disk.\(i).descr", d.description)
            m.set("disk.\(i).mounted", d.mountedAt.joined(separator: ","))
            m.set("disk.\(i).root", d.holdsRunningRoot)
            // **Everything a refusal is made of, or the screen judges blind.**
            // The *service* evaluates `problems` against its own locally-probed
            // inventory and refuses correctly — which is why an install could
            // never actually eat a disk. The **GUI** evaluates the same rules
            // against whatever crossed this socket, and these four fields did
            // not: so every disk arrived looking empty, every row showed no
            // objection, and the erase sheet could never open. Caught by
            // `live-installer.sh` choosing a disk that plainly had a pool on it
            // (§2.46 — a GUI cannot be trusted to be right about itself).
            m.set("disk.\(i).pools", d.existingPools.joined(separator: ","))
            m.set("disk.\(i).kinds", d.partitionKinds.joined(separator: ","))
            m.set("disk.\(i).free", d.freeBytes)
            m.set("disk.\(i).table", d.hasPartitionTable)
        }
        m.set("pools.count", UInt64(inv.importedPools.count))
        for (i, p) in inv.importedPools.enumerated() { m.set("pool.\(i)", p) }
        if let mach = inv.machine {
            m.set("machine.maker", mach.maker)
            m.set("machine.product", mach.product)
        }
    }

    public static func decodeInventory(_ m: Msg) -> DiskInventory {
        var disks: [Disk] = []
        for i in 0..<Int(m.uint64("disks.count") ?? 0) {
            guard let name = m.string("disk.\(i).name") else { continue }
            let mounted = (m.string("disk.\(i).mounted") ?? "")
                .split(separator: ",").map(String.init)
            func list(_ key: String) -> [String] {
                (m.string("disk.\(i).\(key)") ?? "")
                    .split(separator: ",").map(String.init).filter { !$0.isEmpty }
            }
            disks.append(Disk(name: name,
                              bytes: m.uint64("disk.\(i).bytes") ?? 0,
                              description: m.string("disk.\(i).descr") ?? "",
                              mountedAt: mounted,
                              holdsRunningRoot: m.bool("disk.\(i).root") ?? false,
                              existingPools: list("pools"),
                              partitionKinds: list("kinds"),
                              freeBytes: m.uint64("disk.\(i).free") ?? 0,
                              hasPartitionTable: m.bool("disk.\(i).table") ?? false))
        }
        var pools: [String] = []
        for i in 0..<Int(m.uint64("pools.count") ?? 0) {
            if let p = m.string("pool.\(i)") { pools.append(p) }
        }
        var machine: MachineIdentity?
        if let mk = m.string("machine.maker"), let pr = m.string("machine.product"),
           !mk.isEmpty, !pr.isEmpty {
            machine = MachineIdentity(maker: mk, product: pr)
        }
        return DiskInventory(disks: disks, importedPools: pools, machine: machine)
    }

    // MARK: - Progress

    public static func message(for event: RunEvent) -> Msg {
        var m = Msg()
        switch event {
        case .starting(let i, let total, let what, let destructive):
            m.set("event", "starting")
            m.set("index", UInt64(i))
            m.set("total", UInt64(total))
            m.set("what", what)
            m.set("destructive", destructive)
        case .ok(let i):
            m.set("event", "ok")
            m.set("index", UInt64(i))
        case .failed(let i, let what, let why, let ignored):
            m.set("event", "failed")
            m.set("index", UInt64(i))
            m.set("what", what)
            m.set("why", why)
            m.set("ignored", ignored)
        case .finished(let ok, let error):
            m.set("event", "finished")
            m.set("ok", ok)
            m.set("error", error)
        }
        return m
    }

    public static func event(from m: Msg) -> RunEvent? {
        switch m.string("event") {
        case "starting":
            return .starting(index: Int(m.uint64("index") ?? 0),
                             total: Int(m.uint64("total") ?? 0),
                             what: m.string("what") ?? "",
                             destructive: m.bool("destructive") ?? false)
        case "ok":
            return .ok(index: Int(m.uint64("index") ?? 0))
        case "failed":
            return .failed(index: Int(m.uint64("index") ?? 0),
                           what: m.string("what") ?? "",
                           why: m.string("why") ?? "",
                           ignored: m.bool("ignored") ?? false)
        case "finished":
            return .finished(ok: m.bool("ok") ?? false, error: m.string("error") ?? "")
        default:
            return nil
        }
    }
}
