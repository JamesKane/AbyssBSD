// Volumes — ZFS datasets and snapshots, for Disk Utility (PHASE15 P15.8).
//
// Reading needs no privilege — `zfs list` answers anyone — so it happens here,
// in the person's own process; changing anything (a snapshot, a rollback, a
// mount) is a typed plan for the settings helper (`VolumePlan`, P14.3). The
// parsing is pure and tested against real captured output: `-H` (no header,
// tabs between fields) and `-p` (exact numbers, not "1.2G").

import Spawn

public struct ZFSDataset: Equatable, Hashable, Sendable {
    public let name: String
    public let used: UInt64
    public let available: UInt64
    /// A path, or `none` / `legacy` / `-` as zfs says.
    public let mountpoint: String
    public let mounted: Bool
    public init(name: String, used: UInt64, available: UInt64, mountpoint: String, mounted: Bool) {
        self.name = name; self.used = used; self.available = available
        self.mountpoint = mountpoint; self.mounted = mounted
    }
    public var pool: String { String(name.split(separator: "/").first ?? Substring(name)) }
    /// How deep it is under its pool: `zroot` 0, `zroot/usr/obj` 2.
    public var depth: Int { name.split(separator: "/").count - 1 }
    /// Its last component: what a sidebar shows.
    public var leaf: String { String(name.split(separator: "/").last ?? Substring(name)) }
    /// Whether it has somewhere to be mounted (not `none` or `legacy`).
    public var mountable: Bool { mountpoint.hasPrefix("/") }
}

public struct ZFSSnapshot: Equatable, Hashable, Sendable {
    /// `dataset@name`.
    public let name: String
    public let created: Int64
    public let used: UInt64
    public init(name: String, created: Int64, used: UInt64) { self.name = name; self.created = created; self.used = used }
    public var dataset: String { String(name.split(separator: "@", maxSplits: 1).first ?? "") }
    public var short: String { String(name.split(separator: "@", maxSplits: 1).last ?? "") }
}

public enum ZFSList {
    /// `zfs list -H -p -o name,used,avail,mountpoint,mounted -t filesystem`.
    public static func datasets(_ text: String) -> [ZFSDataset] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let used = UInt64(f[1]), let avail = UInt64(f[2]) else { return nil }
            return ZFSDataset(name: f[0], used: used, available: avail, mountpoint: f[3], mounted: f[4] == "yes")
        }
    }

    /// `zfs list -H -p -o name,creation,used -t snapshot`, oldest first.
    public static func snapshots(_ text: String) -> [ZFSSnapshot] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, f[0].contains("@"), let created = Int64(f[1]), let used = UInt64(f[2]) else { return nil }
            return ZFSSnapshot(name: f[0], created: created, used: used)
        }.sorted { $0.created != $1.created ? $0.created < $1.created : $0.name < $1.name }
    }
}

public enum Volumes {
    public struct State: Equatable, Sendable {
        public var datasets: [ZFSDataset] = []
        public var snapshots: [ZFSSnapshot] = []
        /// Why there is nothing to show, when there is not.
        public var unavailable: String?
        public init() {}
        public func snapshots(of dataset: String) -> [ZFSSnapshot] { snapshots.filter { $0.dataset == dataset } }
    }

    /// What the machine's pools hold now — or why that cannot be said.
    public static func read() -> State {
        var s = State()
        guard let zfs = Spawn.resolveExecutable("zfs") else {
            s.unavailable = "ZFS is not installed on this machine"
            return s
        }
        let d = Spawn.run([zfs, "list", "-H", "-p", "-o", "name,used,avail,mountpoint,mounted", "-t", "filesystem"],
                          stderr: .merge, limit: 4 << 20)
        guard d.succeeded else {
            s.unavailable = "zfs could not list the pools: \(d.stdoutText.split(separator: "\n").first ?? "")"
            return s
        }
        s.datasets = ZFSList.datasets(d.stdoutText)
        let n = Spawn.run([zfs, "list", "-H", "-p", "-o", "name,creation,used", "-t", "snapshot"],
                          stderr: .merge, limit: 4 << 20)
        if n.succeeded { s.snapshots = ZFSList.snapshots(n.stdoutText) }
        if s.datasets.isEmpty { s.unavailable = "this machine has no ZFS pools" }
        return s
    }

    /// A snapshot named for when it was taken: `abyss-2026-10-01-153007`.
    public static func snapshotName(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> String {
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "abyss-\(year)-\(two(month))-\(two(day))-\(two(hour))\(two(minute))\(two(second))"
    }
}
