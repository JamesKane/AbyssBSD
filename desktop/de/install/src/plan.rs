//! The install, as a value (Plan.swift): the whole of what an install *is*,
//! so a test can ask what would happen on a machine it is not running on,
//! and `abyss-install` is left with nothing to decide.

/// A user account to create on the installed system.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Account {
    pub name: String,
    pub full_name: String,
    /// Already hashed, as `pw useradd -H` wants it. **The plan never carries
    /// a plaintext password**: it gets logged, rendered and sent.
    pub password_hash: String,
    /// Supplementary groups. `wheel` is what makes an administrator.
    pub groups: Vec<String>,
    pub shell: String,
}

impl Account {
    /// No full name, no groups, `/bin/sh`.
    pub fn new(name: &str, password_hash: &str) -> Account {
        Account { name: name.to_owned(), full_name: String::new(), password_hash: password_hash.to_owned(), groups: vec![], shell: "/bin/sh".to_owned() }
    }

    /// An account that can become root, which is what `NoAdministrator`
    /// counts.
    pub fn is_administrator(&self) -> bool {
        self.groups.iter().any(|g| g == "wheel")
    }
}

/// What to install, where, and what the machine should be when it reboots.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstallPlan {
    /// The whole disk to take, with no `/dev/`: `ada0`, not `/dev/ada0p2`.
    pub disk: String,
    /// The ZFS pool to create. Not `zroot` by default: a ZFS-rooted live
    /// medium already has one.
    pub pool_name: String,
    /// The EFI system partition, in bytes. Whole MiB.
    pub esp_bytes: u64,
    /// Swap, in bytes; zero means no swap partition. Whole MiB.
    pub swap_bytes: u64,
    /// Distribution sets to extract, in order. `base.txz` first, always.
    pub sets: Vec<String>,
    /// Where those sets are, on the running (live) system.
    pub dist_directory: String,
    /// Where the new root is mounted while it is built.
    pub mountpoint: String,
    pub hostname: String,
    /// A zoneinfo name (`America/Chicago`), or empty for UTC.
    pub timezone: String,
    /// A `kbdmap` name (`us.kbd`), or empty to leave the default.
    pub keymap: String,
    pub root_password_hash: String,
    pub accounts: Vec<Account>,
    /// Permission to destroy what is on the target disk. **False until a
    /// person says the words**, and the sentence that unlocks it names what
    /// will be lost.
    pub erase_existing_data: bool,
    /// Log the owner in with no password at boot (PHASE16 §6.2). Off by
    /// default: an installed desktop starts at the login window.
    pub auto_login: bool,
}

const MIB: u64 = 1 << 20;

impl InstallPlan {
    /// The distribution set that carries the Aqua desktop, built by
    /// `abyss/mk/live-image.sh` out of the very files the medium runs.
    pub const DESKTOP_SET: &str = "abyss.tzst";

    /// The plan for `disk` with every default.
    pub fn new(disk: &str) -> InstallPlan {
        InstallPlan {
            disk: disk.to_owned(),
            pool_name: "abyss".to_owned(),
            esp_bytes: 260 * MIB,
            swap_bytes: 2048 * MIB,
            sets: vec!["base.txz".to_owned(), "kernel.txz".to_owned()],
            dist_directory: "/usr/freebsd-dist".to_owned(),
            mountpoint: "/mnt".to_owned(),
            hostname: "abyss".to_owned(),
            timezone: String::new(),
            keymap: String::new(),
            root_password_hash: "*".to_owned(),
            accounts: vec![],
            erase_existing_data: false,
            auto_login: false,
        }
    }

    /// Whether this install puts the desktop on the machine.
    pub fn installs_desktop(&self) -> bool {
        self.sets.iter().any(|s| s == InstallPlan::DESKTOP_SET)
    }

    /// The GPT label prefix. Labels have to be unique **on the machine doing
    /// the install**, whose medium has labels of its own.
    pub fn label_prefix(&self) -> &str {
        &self.pool_name
    }

    /// Partition indices, which follow from the layout alone: the ESP
    /// first, swap before the pool so growing the pool is the easy way.
    pub fn esp_partition(&self) -> u32 {
        1
    }
    pub fn swap_partition(&self) -> Option<u32> {
        (self.swap_bytes > 0).then_some(2)
    }
    pub fn pool_partition(&self) -> u32 {
        if self.swap_bytes > 0 { 3 } else { 2 }
    }

    /// The smallest disk this plan could fit on: its partitions, 4 GiB of
    /// pool and 1 MiB of alignment at each end. Saturating, where Swift's
    /// sum traps on sizes from the wire.
    pub fn minimum_disk_bytes(&self) -> u64 {
        self.esp_bytes.saturating_add(self.swap_bytes).saturating_add(4096 * MIB).saturating_add(2 * MIB)
    }
}

/// One dataset of the layout, as `bsdinstall`'s `zfsboot` lays it out: the
/// property choices (`exec=off` on `/var/log`, `setuid=off` on `/tmp`) are a
/// decade of other people's incidents.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Dataset {
    /// Relative to the pool.
    pub name: &'static str,
    pub properties: &'static [(&'static str, &'static str)],
}

impl Dataset {
    pub fn property(&self, key: &str) -> Option<&'static str> {
        self.properties.iter().find(|(k, _)| *k == key).map(|(_, v)| *v)
    }

    /// Whether this dataset is mounted during the install: it has somewhere
    /// to go, and is not a container that exists only to hold properties.
    /// `ROOT/default` is mounted first and by name.
    pub fn is_mountable(&self) -> bool {
        self.property("canmount") != Some("off") && self.property("mountpoint") != Some("none") && self.name != "ROOT/default"
    }
}

const fn ds(name: &'static str, properties: &'static [(&'static str, &'static str)]) -> Dataset {
    Dataset { name, properties }
}

/// The boot environment: the two datasets that have to exist, and be
/// mounted, **before any other is created**. `zfs create` mounts what it
/// creates, and `pool/home` made before the root is mounted lands in a
/// directory of the live system that the root mount then hides.
pub const BOOT_ENVIRONMENT_DATASETS: [Dataset; 2] =
    [ds("ROOT", &[("mountpoint", "none")]), ds("ROOT/default", &[("mountpoint", "/"), ("canmount", "noauto")])];

/// Everything else, created after the root is mounted.
pub const STANDARD_DATASETS: [Dataset; 11] = [
    ds("home", &[("mountpoint", "/home")]),
    ds("tmp", &[("mountpoint", "/tmp"), ("exec", "on"), ("setuid", "off")]),
    ds("usr", &[("mountpoint", "/usr"), ("canmount", "off")]),
    ds("usr/ports", &[("setuid", "off")]),
    ds("usr/src", &[]),
    ds("var", &[("mountpoint", "/var"), ("canmount", "off")]),
    ds("var/audit", &[("exec", "off"), ("setuid", "off")]),
    ds("var/crash", &[("exec", "off"), ("setuid", "off")]),
    ds("var/log", &[("exec", "off"), ("setuid", "off")]),
    ds("var/mail", &[("atime", "on")]),
    ds("var/tmp", &[("setuid", "off")]),
];
