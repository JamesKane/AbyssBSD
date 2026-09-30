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
    /// ZFS pools that live on this disk and are **not imported** — somebody
    /// else's installed system, seen from a live medium.
    ///
    /// **This is the field that makes the other refusals mean anything on a
    /// live medium.** `mountedAt` and `holdsRunningRoot` both describe the
    /// *running* system, and on a medium the running system is the USB stick:
    /// the machine's own disk is not mounted, its pool is not imported, and
    /// every existing refusal is therefore silent about it. A disk holding a
    /// working FreeBSD install looked exactly like an empty one.
    ///
    /// Found by scanning, not by importing — `zpool import` with no arguments
    /// lists what *could* be imported and imports nothing, which was verified
    /// both ways before this field existed.
    public let existingPools: [String]
    /// Partition types already on this disk — `efi`, `ntfs`, `ms-basic-data`,
    /// `freebsd-zfs`. Empty means no partition table at all.
    ///
    /// **`existingPools` was only ever half the guard.** It answers "is somebody's
    /// ZFS here", which on the bring-up machine correctly refused the disk
    /// holding `zroot` — and said nothing about the two beside it carrying a
    /// Windows install and 223 GB of NTFS. Those were offered as clean targets.
    /// A refusal that protects only the filesystems we happen to use is one that
    /// eats everybody else's.
    public let partitionKinds: [String]
    /// The largest **contiguous** gap on the disk, in bytes.
    ///
    /// Contiguous rather than total, because partitions are extents and an
    /// install needs room in one piece. This is what turns "every disk has
    /// something on it" from a dead end into a question: a disk with space to
    /// spare can take an install *beside* what is already there.
    public let freeBytes: UInt64
    /// Whether the disk has a partition table at all. A blank disk is not a full
    /// one, and the two need different treatment: nothing to destroy, but a
    /// table to create.
    public let hasPartitionTable: Bool

    public init(name: String, bytes: UInt64, description: String = "",
                mountedAt: [String] = [], holdsRunningRoot: Bool = false,
                existingPools: [String] = [], partitionKinds: [String] = [],
                freeBytes: UInt64 = 0, hasPartitionTable: Bool = false) {
        self.name = name
        self.bytes = bytes
        self.description = description
        self.mountedAt = mountedAt
        self.holdsRunningRoot = holdsRunningRoot
        self.existingPools = existingPools
        self.partitionKinds = partitionKinds
        self.freeBytes = freeBytes
        self.hasPartitionTable = hasPartitionTable
    }

    /// Everything a person should be told before this disk is touched — pool
    /// names first, because a name is more use than a type.
    public var contents: [String] {
        existingPools.map { "ZFS pool \($0)" } + partitionKinds
    }
}

/// What a machine calls itself, from `smbios.system.*` in the kernel
/// environment (PHASE12 §4.2).
///
/// Optional wherever it appears, because a machine that does not identify itself
/// is a real case — a VM, a board with no SMBIOS — and it must be distinguishable
/// from one that identifies itself as something else. Guessing here is how a
/// workaround ends up on a machine that has nothing to work around.
public struct MachineIdentity: Equatable, Sendable {
    public let maker: String
    public let product: String
    public init(maker: String, product: String) {
        self.maker = maker
        self.product = product
    }
}

/// Everything the safety predicate is allowed to know about the machine.
public struct DiskInventory: Equatable, Sendable {
    public let disks: [Disk]
    /// What this machine says it is, or nil if it does not say.
    ///
    /// Here rather than in the plan because it is a fact about the machine and
    /// not a choice the user made — the same reason the disks are here. It never
    /// crosses the wire: the unprivileged half sends intent, and the privileged
    /// half, which is the only one that may look at the machine, supplies this.
    public let machine: MachineIdentity?
    /// Pools already imported here. A live medium that is itself ZFS-rooted —
    /// which the build VM is — already has `zroot`, so an install plan that
    /// defaults to that name would collide with the machine running it. Found
    /// the honest way: the spike had to rename its pool to get started.
    public let importedPools: [String]

    public init(disks: [Disk], importedPools: [String] = [],
                machine: MachineIdentity? = nil) {
        self.disks = disks
        self.importedPools = importedPools
        self.machine = machine
    }

    public func disk(named name: String) -> Disk? {
        disks.first { $0.name == name }
    }
}
