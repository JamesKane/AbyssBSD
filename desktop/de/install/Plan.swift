// The install, as a value.
//
// `SessionPlan`'s pattern (P8.4), pointed at a disk instead of a session: the
// whole of what an install *is* lives here as data, so a test can ask what would
// happen on a machine it is not running on, and `abyss-install` is left with
// nothing to decide — it runs a list.

/// A user account to create on the installed system.
public struct Account: Equatable, Sendable {
    public let name: String
    public let fullName: String
    /// Already hashed, as `pw useradd -H` wants it. **The plan never carries a
    /// plaintext password**: it is a value that gets logged, rendered into a
    /// golden test, and passed between processes.
    public let passwordHash: String
    /// Supplementary groups. `wheel` is what makes an account an administrator.
    public let groups: [String]
    public let shell: String

    public init(name: String, fullName: String = "", passwordHash: String,
                groups: [String] = [], shell: String = "/bin/sh") {
        self.name = name
        self.fullName = fullName
        self.passwordHash = passwordHash
        self.groups = groups
        self.shell = shell
    }

    /// An account that can become root, which is what `noAdministrator` counts.
    public var isAdministrator: Bool { groups.contains("wheel") }
}

/// What to install, where, and what the machine should be when it reboots.
public struct InstallPlan: Equatable, Sendable {
    /// The whole disk to take, with no `/dev/`: `ada0`, not `/dev/ada0p2`.
    public let disk: String
    /// The ZFS pool to create. Not `zroot` by default — see `DiskInventory`.
    public let poolName: String
    /// The EFI system partition, in bytes. Must be a whole number of MiB.
    public let espBytes: UInt64
    /// Swap, in bytes; zero means no swap partition at all. Whole MiB.
    public let swapBytes: UInt64
    /// Distribution sets to extract, in order. `base.txz` first, always.
    public let sets: [String]
    /// Where those sets are, on the running (live) system.
    public let distDirectory: String
    /// Where the new root gets mounted while we build it.
    public let mountpoint: String
    public let hostname: String
    /// A zoneinfo name (`America/Chicago`), or empty for UTC.
    public let timezone: String
    /// A `kbdmap` name (`us.kbd`), or empty to leave the default.
    public let keymap: String
    public let rootPasswordHash: String
    public let accounts: [Account]
    /// Permission to destroy a ZFS pool already on the target disk.
    ///
    /// Default `false`, so an install over somebody's existing system is
    /// **refused until a person says the words**. This is `write-stick.sh`'s
    /// `--allow-fixed` in the other half of the product: the guard is not that
    /// the operation is impossible, it is that it cannot happen by default and
    /// the sentence that unlocks it names what will be lost.
    public let eraseExistingData: Bool

    public init(disk: String,
                poolName: String = "abyss",
                espBytes: UInt64 = 260 * 1024 * 1024,
                swapBytes: UInt64 = 2 * 1024 * 1024 * 1024,
                sets: [String] = ["base.txz", "kernel.txz"],
                distDirectory: String = "/usr/freebsd-dist",
                mountpoint: String = "/mnt",
                hostname: String = "abyss",
                timezone: String = "",
                keymap: String = "",
                rootPasswordHash: String = "*",
                accounts: [Account] = [],
                eraseExistingData: Bool = false) {
        self.disk = disk
        self.poolName = poolName
        self.espBytes = espBytes
        self.swapBytes = swapBytes
        self.sets = sets
        self.distDirectory = distDirectory
        self.mountpoint = mountpoint
        self.hostname = hostname
        self.timezone = timezone
        self.keymap = keymap
        self.rootPasswordHash = rootPasswordHash
        self.accounts = accounts
        self.eraseExistingData = eraseExistingData
    }

    /// The distribution set that carries the Aqua desktop.
    ///
    /// Built by `abyss/mk/live-image.sh` out of the very files the medium runs,
    /// so what the medium carries and what the installer installs are the same
    /// collection rather than two that have to be kept in step.
    public static let desktopSet = "abyss.tzst"

    /// Whether this install puts the desktop on the machine.
    public var installsDesktop: Bool { sets.contains(InstallPlan.desktopSet) }

    /// The GPT label prefix. Labels have to be unique **on the machine doing the
    /// install**, not just on the target — the installer is running from a
    /// medium that has partitions of its own, and `/dev/gpt/swap` colliding with
    /// the live medium's own label is a corrupted-looking failure with an
    /// obvious cause that nobody will look for. Prefixing with the pool name
    /// makes a collision take deliberate effort.
    public var labelPrefix: String { poolName }

    /// Partition indices, which follow from the layout and from nothing else:
    /// the ESP is always first because firmware is happier that way, and swap
    /// precedes the pool so that growing the pool later is the easy direction.
    public var espPartition: Int { 1 }
    public var swapPartition: Int? { swapBytes > 0 ? 2 : nil }
    public var poolPartition: Int { swapBytes > 0 ? 3 : 2 }

    /// The smallest disk this plan could possibly fit on: the partitions it
    /// names, the sets it extracts, and 1 MiB of alignment slack at each end.
    public var minimumDiskBytes: UInt64 {
        let alignment: UInt64 = 2 * 1024 * 1024
        // Room for what we extract. base+kernel land at roughly 1.5 GB; asking
        // for 4 GiB of pool leaves a machine that can be logged into and used
        // rather than one that installs and then fills up.
        let pool: UInt64 = 4 * 1024 * 1024 * 1024
        return espBytes + swapBytes + pool + alignment
    }
}

/// The dataset layout, as `bsdinstall`'s `zfsboot` lays it out — the one part of
/// that script worth copying, because the property choices in it (`exec=off` on
/// `/var/log`, `setuid=off` on `/tmp`) are a decade of other people's incidents.
public struct Dataset: Equatable, Sendable {
    public let name: String                 // relative to the pool
    public let properties: [(String, String)]

    public init(_ name: String, _ properties: [(String, String)]) {
        self.name = name
        self.properties = properties
    }

    /// The value of one property, if this dataset sets it.
    public func property(_ key: String) -> String? {
        properties.first { $0.0 == key }?.1
    }

    /// Whether this dataset gets mounted during the install: it has somewhere to
    /// go, and it is not one of the container datasets that exist only to hold
    /// properties for their children.
    public var isMountable: Bool {
        if property("canmount") == "off" { return false }
        if property("mountpoint") == "none" { return false }
        // `ROOT/default` is mounted first and by name — it is the root, and it
        // is `canmount=noauto`, so it is not part of the general sweep.
        if name == "ROOT/default" { return false }
        return true
    }

    public static func == (a: Dataset, b: Dataset) -> Bool {
        a.name == b.name && a.properties.count == b.properties.count
            && zip(a.properties, b.properties).allSatisfy { $0 == $1 }
    }
}

/// The boot environment: the two datasets that have to exist, and be mounted,
/// **before any other dataset is created**.
///
/// `zfs create` mounts what it creates. Create `pool/home` while `pool/ROOT/
/// default` is not yet mounted and it mounts at `/mnt/home` — a directory on the
/// *live* filesystem — which the root mount then hides. The install proceeds,
/// extracts, and produces a machine whose `/home` is empty and whose files are
/// in a directory nobody will ever look in. Found by running the list.
public let bootEnvironmentDatasets: [Dataset] = [
    Dataset("ROOT",           [("mountpoint", "none")]),
    Dataset("ROOT/default",   [("mountpoint", "/"), ("canmount", "noauto")]),
]

/// Everything else, created after the root is mounted — and mounted by their own
/// creation, which is what `zfs create` does.
public let standardDatasets: [Dataset] = [
    Dataset("home",           [("mountpoint", "/home")]),
    Dataset("tmp",            [("mountpoint", "/tmp"), ("exec", "on"), ("setuid", "off")]),
    Dataset("usr",            [("mountpoint", "/usr"), ("canmount", "off")]),
    Dataset("usr/ports",      [("setuid", "off")]),
    Dataset("usr/src",        []),
    Dataset("var",            [("mountpoint", "/var"), ("canmount", "off")]),
    Dataset("var/audit",      [("exec", "off"), ("setuid", "off")]),
    Dataset("var/crash",      [("exec", "off"), ("setuid", "off")]),
    Dataset("var/log",        [("exec", "off"), ("setuid", "off")]),
    Dataset("var/mail",       [("atime", "on")]),
    Dataset("var/tmp",        [("setuid", "off")]),
]
