//! The machine, as a value (Inventory.swift).
//!
//! "Is that disk mounted?" is not a pure question, and the predicate that
//! has to answer it is the one whose failure mode is somebody's data. So the
//! machine is an **argument**: something privileged gathers this once, and
//! every refusal is then a function of plan and inventory, testable on a
//! machine with no disks.

/// One disk, as much of it as a refusal needs to know.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Disk {
    /// The device name with no `/dev/`: `ada0`, `nvd0`, `vtbd1`.
    pub name: String,
    pub bytes: u64,
    /// What the machine calls it: shown to a person, never parsed.
    pub description: String,
    /// Filesystems mounted from any partition of it, by mount point.
    pub mounted_at: Vec<String>,
    /// The running system's root lives here: the strongest refusal.
    pub holds_running_root: bool,
    /// ZFS pools on it that are **not imported**: somebody else's
    /// installed system, seen from a live medium, where the mounts above
    /// describe only the stick.
    pub existing_pools: Vec<String>,
    /// Partition types already on it (`efi`, `ntfs`, `freebsd-zfs`). A
    /// refusal that protects only our filesystems eats everybody else's.
    pub partition_kinds: Vec<String>,
    /// The largest **contiguous** gap, in bytes: an install needs room in
    /// one piece, and a disk with room takes one beside what is there.
    pub free_bytes: u64,
    /// Whether it has a partition table at all. Blank is not full.
    pub has_partition_table: bool,
}

impl Disk {
    /// An empty disk: nothing mounted, no table.
    pub fn new(name: &str, bytes: u64) -> Disk {
        Disk { name: name.to_owned(), bytes, ..Disk::default() }
    }

    /// Everything a person should be told before this disk is touched:
    /// pool names first, because a name is more use than a type.
    pub fn contents(&self) -> Vec<String> {
        self.existing_pools.iter().map(|p| format!("ZFS pool {p}")).chain(self.partition_kinds.iter().cloned()).collect()
    }
}

/// What a machine calls itself, from `smbios.system.*` (PHASE12 §4.2).
/// Optional wherever it appears: a machine that does not identify itself is
/// a real case, and guessing is how a workaround reaches a machine that has
/// nothing to work around.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MachineIdentity {
    pub maker: String,
    pub product: String,
}

/// Everything the safety predicate is allowed to know about the machine.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct DiskInventory {
    pub disks: Vec<Disk>,
    /// Pools already imported here: a ZFS-rooted medium already has `zroot`.
    pub imported_pools: Vec<String>,
    /// What this machine says it is. A fact about the machine, so the
    /// privileged half supplies it, never the plan.
    pub machine: Option<MachineIdentity>,
}

impl DiskInventory {
    pub fn new(disks: Vec<Disk>) -> DiskInventory {
        DiskInventory { disks, ..DiskInventory::default() }
    }

    pub fn disk(&self, name: &str) -> Option<&Disk> {
        self.disks.iter().find(|d| d.name == name)
    }
}
