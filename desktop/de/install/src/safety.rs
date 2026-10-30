//! The refusals (Safety.swift): the first code in the tree whose bug
//! destroys something a rebuild cannot bring back, so deliberately pure.
//! Cheap structural checks come first, so a malformed plan is refused on
//! its own terms; the machine's come after.

use crate::inventory::DiskInventory;
use crate::plan::InstallPlan;
use std::fmt;

/// Why an install plan was refused, each with enough to say what is wrong
/// in a sentence a person can act on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PlanRefusal {
    EmptyDisk,
    NotAWholeDisk(String),
    NoSuchDisk { disk: String, available: Vec<String> },
    DiskIsMounted { disk: String, at: Vec<String> },
    DiskHoldsRunningRoot(String),
    DiskTooSmall { disk: String, has: u64, needs: u64 },
    BadPoolName { name: String, why: String },
    PoolNameInUse(String),
    NoSets,
    BaseSetNotFirst(Vec<String>),
    SizeNotWholeMiB { what: String, bytes: u64 },
    RelativePath { what: String, path: String },
    NoAdministrator,
    DiskIsFull { disk: String, contents: Vec<String>, free_bytes: u64, need_bytes: u64 },
}

pub(crate) fn gib(bytes: u64) -> String {
    let tenths = u128::from(bytes) * 10 / (1 << 30);
    format!("{}.{} GiB", tenths / 10, tenths % 10)
}

impl PlanRefusal {
    /// The sentence to put in front of a person.
    pub fn message(&self) -> String {
        use PlanRefusal::*;
        match self {
            EmptyDisk => "no disk was chosen".into(),
            NotAWholeDisk(d) => format!("{d} is a partition, not a disk — an install takes the whole disk"),
            NoSuchDisk { disk, available } => {
                if available.is_empty() {
                    "this machine has no disks, so there is nowhere to install".into()
                } else {
                    format!("there is no disk called {disk}; this machine has {}", available.join(", "))
                }
            }
            DiskIsMounted { disk, at } => format!("{disk} is in use — something is mounted from it at {}", at.join(", ")),
            DiskHoldsRunningRoot(d) => format!("{d} is the disk this system is running from"),
            DiskTooSmall { disk, has, needs } => format!("{disk} holds {} and this install needs at least {}", gib(*has), gib(*needs)),
            BadPoolName { name, why } => format!("\"{name}\" cannot be a ZFS pool name: {why}"),
            PoolNameInUse(n) => format!("a pool called {n} is already imported on this machine"),
            NoSets => "an install with no distribution sets would install nothing".into(),
            BaseSetNotFirst(sets) => {
                format!("base.txz has to be extracted first, before {}", sets.first().map_or("anything else", String::as_str))
            }
            SizeNotWholeMiB { what, bytes } => format!("{what} is {bytes} bytes, which is not a whole number of MiB"),
            RelativePath { what, path } => format!("{what} must be an absolute path, and \"{path}\" is not"),
            NoAdministrator => {
                "nobody could log in to the installed system: set a root password or give an account the wheel group".into()
            }
            // **Say what is on it, and how short it is**: knowing *what*
            // would be destroyed is what makes the next decision theirs.
            DiskIsFull { disk, contents, free_bytes, need_bytes } => {
                let what = if contents.is_empty() { "partitions".to_owned() } else { contents.join(", ") };
                format!(
                    "{disk} is fully partitioned ({what}) — {} free, and this install needs {} in one piece. Choose a disk with room, or confirm that this one is to be erased",
                    gib(*free_bytes),
                    gib(*need_bytes)
                )
            }
        }
    }
}

impl fmt::Display for PlanRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message())
    }
}

impl std::error::Error for PlanRefusal {}

/// Names the pool code itself reserves. Wrong here means `zpool create`
/// fails **after** `gpart` has written over somebody's disk.
const RESERVED_POOL_NAMES: [&str; 9] = ["mirror", "raidz", "raidz1", "raidz2", "raidz3", "draid", "spare", "log", "cache"];

/// ZFS's letters and digits are ASCII (`valid_char` in zfs_namecheck.c);
/// Swift's `isLetter` is Unicode's, and passes names `zpool` refuses.
fn pool_name_problem(name: &str) -> Option<String> {
    let mut chars = name.chars();
    let Some(first) = chars.next() else { return Some("it is empty".into()) };
    if !first.is_ascii() {
        return Some(format!("\"{first}\" is not allowed in a pool name"));
    }
    if !first.is_ascii_alphabetic() {
        return Some("it has to begin with a letter".into());
    }
    if RESERVED_POOL_NAMES.contains(&name) {
        return Some("that name is reserved by ZFS".into());
    }
    // `c[0-9]` looks like a Solaris disk name.
    if first == 'c' && chars.next().is_some_and(|c| c.is_ascii_digit()) {
        return Some("a name beginning c<digit> looks like a device to ZFS".into());
    }
    name.chars().find(|&c| !(c.is_ascii_alphanumeric() || "_-.:".contains(c))).map(|c| format!("\"{c}\" is not allowed in a pool name"))
}

/// True if this device name is a partition or slice rather than a whole
/// disk: `ada0p2`, `da0s1`, `da0s1a`. `gpart create` inside a partition
/// succeeds, which is what makes this a refusal.
pub fn names_a_partition(device: &str) -> bool {
    let rest = device.trim_start_matches(|c: char| c.is_ascii_alphabetic());
    let after_unit = rest.trim_start_matches(|c: char| c.is_ascii_digit());
    if after_unit.len() == rest.len() {
        return false; // no unit number
    }
    let mut tail = after_unit.chars();
    matches!(tail.next(), Some('p' | 's')) && tail.next().is_some_and(|c| c.is_ascii_digit())
}

/// Refuse a plan that must not be run: the *first* problem, most
/// structural first. A summary page wants [`problems`].
pub fn check(plan: &InstallPlan, inventory: &DiskInventory) -> Result<(), PlanRefusal> {
    problems(plan, inventory).into_iter().next().map_or(Ok(()), Err)
}

/// Every reason this plan would be refused, in the order checked: an
/// installer that reveals one problem per attempt is one people distrust.
pub fn problems(plan: &InstallPlan, inventory: &DiskInventory) -> Vec<PlanRefusal> {
    use PlanRefusal::*;
    let mut found = vec![];

    // structural: true or false with no machine involved
    if plan.disk.is_empty() {
        found.push(EmptyDisk);
    } else if names_a_partition(&plan.disk) {
        found.push(NotAWholeDisk(plan.disk.clone()));
    }
    if let Some(why) = pool_name_problem(&plan.pool_name) {
        found.push(BadPoolName { name: plan.pool_name.clone(), why });
    }
    const MIB: u64 = 1 << 20;
    if !plan.esp_bytes.is_multiple_of(MIB) {
        found.push(SizeNotWholeMiB { what: "the EFI partition".into(), bytes: plan.esp_bytes });
    }
    if !plan.swap_bytes.is_multiple_of(MIB) {
        found.push(SizeNotWholeMiB { what: "swap".into(), bytes: plan.swap_bytes });
    }
    match plan.sets.first() {
        None => found.push(NoSets),
        Some(s) if s != "base.txz" => found.push(BaseSetNotFirst(plan.sets.clone())),
        _ => {}
    }
    if !plan.dist_directory.starts_with('/') {
        found.push(RelativePath { what: "the distribution directory".into(), path: plan.dist_directory.clone() });
    }
    if !plan.mountpoint.starts_with('/') {
        found.push(RelativePath { what: "the mount point".into(), path: plan.mountpoint.clone() });
    }
    // A machine nobody can log into is not an installed machine. `*` is
    // the hash `pw` writes for "no password will ever match".
    let root_usable = !plan.root_password_hash.is_empty() && plan.root_password_hash != "*";
    if !root_usable && !plan.accounts.iter().any(|a| a.is_administrator()) {
        found.push(NoAdministrator);
    }

    // the machine
    if inventory.imported_pools.contains(&plan.pool_name) {
        found.push(PoolNameInUse(plan.pool_name.clone()));
    }
    if !plan.disk.is_empty() && !names_a_partition(&plan.disk) {
        let Some(disk) = inventory.disk(&plan.disk) else {
            found.push(NoSuchDisk { disk: plan.disk.clone(), available: inventory.disks.iter().map(|d| d.name.clone()).collect() });
            return found;
        };
        // Strongest first: this is the disk you are running from.
        if disk.holds_running_root {
            found.push(DiskHoldsRunningRoot(disk.name.clone()));
        } else if !disk.mounted_at.is_empty() {
            found.push(DiskIsMounted { disk: disk.name.clone(), at: disk.mounted_at.clone() });
        }
        // **A disk with room is installable; a full one is not**, and the
        // refusal says what is in the way. A disk with no table is empty,
        // not full. Saying "erase" lifts this one and nothing else.
        let need = plan.minimum_disk_bytes();
        if !plan.erase_existing_data && disk.has_partition_table && disk.free_bytes < need {
            found.push(DiskIsFull { disk: disk.name.clone(), contents: disk.contents(), free_bytes: disk.free_bytes, need_bytes: need });
        }
        if disk.bytes < need {
            found.push(DiskTooSmall { disk: disk.name.clone(), has: disk.bytes, needs: need });
        }
    }
    found
}
