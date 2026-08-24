// The machine, as a value.
//
// "Is that disk mounted?" is not a pure question, and the safety predicate that
// has to answer it is the one predicate in this tree whose failure mode is
// somebody's data. So the machine is an **argument**: something privileged
// gathers this inventory once, and every refusal in `Safety.swift` is then a
// function of plan-and-inventory and nothing else.
//
// That is what makes the refusals testable on Linux, where `gpart` does not
// exist and never will — a unit test constructs the exact machine on which a
// refusal must fire, and checks that it does. A predicate that reads the system
// directly could only be tested on a machine that happened to be wrong.

/// One disk, as much of it as a refusal needs to know.
public struct Disk: Equatable, Sendable {
    /// The device name with no `/dev/` on it: `ada0`, `nvd0`, `md0`, `vtbd1`.
    public let name: String
    /// Its size in bytes.
    public let bytes: UInt64
    /// What the machine calls it — shown to a person choosing, never parsed.
    public let description: String
    /// Filesystems currently mounted from any partition of this disk, by
    /// mount point. A non-empty list is a refusal.
    public let mountedAt: [String]
    /// True if the running system's root filesystem lives here. The strongest
    /// refusal of the set: this is the disk you are running from.
    public let holdsRunningRoot: Bool

    public init(name: String, bytes: UInt64, description: String = "",
                mountedAt: [String] = [], holdsRunningRoot: Bool = false) {
        self.name = name
        self.bytes = bytes
        self.description = description
        self.mountedAt = mountedAt
        self.holdsRunningRoot = holdsRunningRoot
    }
}

/// Everything the safety predicate is allowed to know about the machine.
public struct DiskInventory: Equatable, Sendable {
    public let disks: [Disk]
    /// Pools already imported here. A live medium that is itself ZFS-rooted —
    /// which the build VM is — already has `zroot`, so an install plan that
    /// defaults to that name would collide with the machine running it. Found
    /// the honest way: the spike had to rename its pool to get started.
    public let importedPools: [String]

    public init(disks: [Disk], importedPools: [String] = []) {
        self.disks = disks
        self.importedPools = importedPools
    }

    public func disk(named name: String) -> Disk? {
        disks.first { $0.name == name }
    }
}
