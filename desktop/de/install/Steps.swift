// The step list: what an install plan actually does, one command at a time.
//
// This is the whole reason the plan is a value. `abyss-install` (P5.2) is handed
// this list and runs it; it decides nothing, which means everything worth
// arguing about — the partition order, the pool properties, whether the root
// dataset auto-mounts — is argued about *here*, where a unit test on Linux can
// read the answer without a disk anywhere in sight.
//
// The list is also renderable (`render`), and there is a golden test over it, so
// that a change to what we run at somebody's disk shows up in a diff and has to
// be defended rather than noticed later.

/// One thing to do, and what it means if it fails.
import Fathom

public struct Step: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Run a command. `stdin` exists so a password hash never appears in
        /// argv, which every process on the machine can read out of `ps`.
        case run(argv: [String], stdin: String?)
        case write(path: String, contents: String, mode: UInt16)
        case append(path: String, contents: String)
    }

    public let action: Action
    /// What this step is for, in the present tense: "create the GPT".
    public let what: String
    /// What it means if it fails — the sentence the installer shows. A step
    /// whose failure needs no explanation still gets one, because the person
    /// reading it is watching their disk get rewritten.
    public let onFailure: String
    /// True from the first step that changes the disk. The GUI puts its
    /// confirmation in front of the first of these and nowhere else.
    public let destructive: Bool
    /// A step allowed to fail — `gpart destroy` on a disk that has no partition
    /// table at all is a success for our purposes, exactly as `mkdir` failing
    /// with EEXIST is for `Current.runtimeDir()`.
    public let mayFail: Bool

    public init(_ action: Action, what: String, onFailure: String,
                destructive: Bool = false, mayFail: Bool = false) {
        self.action = action
        self.what = what
        self.onFailure = onFailure
        self.destructive = destructive
        self.mayFail = mayFail
    }

    public static func run(_ argv: [String], what: String, onFailure: String,
                           stdin: String? = nil,
                           destructive: Bool = false, mayFail: Bool = false) -> Step {
        Step(.run(argv: argv, stdin: stdin), what: what, onFailure: onFailure,
             destructive: destructive, mayFail: mayFail)
    }
}

/// Where the pool cache is parked between `zpool create` and the copy into the
/// new root. It has to exist somewhere on the *live* system, because the new
/// root does not exist yet when the pool is created.
public let poolCachePath = "/tmp/abyss-install-zpool.cache"

private func mib(_ bytes: UInt64) -> String { "\(bytes / (1024 * 1024))M" }

/// Compile a plan into the list of things to do, refusing first.
///
/// The refusal happens here rather than in `abyss-install` so that **no step
/// exists** for a plan that should not run — there is nothing to accidentally
/// execute, and nothing a later bug can decide to run anyway.
public func compile(_ plan: InstallPlan, on inventory: DiskInventory) throws -> [Step] {
    try check(plan, on: inventory)
    return steps(for: plan, on: inventory)
}

/// The step list for a plan already known to be safe.
///
/// Split out from `compile` so a test can render the list for a machine it does
/// not have, but **not public**: the only way to get a step list from outside
/// this module is to pass the safety check.
func steps(for plan: InstallPlan, on inventory: DiskInventory = DiskInventory(disks: [])) -> [Step] {
    var s: [Step] = []
    let dev = "/dev/" + plan.disk
    let mnt = plan.mountpoint
    let pool = plan.poolName
    // **Address the new partitions by LABEL, not by index.**
    //
    // `p1`/`p2`/`p3` is only true of a table we just created. An install into
    // free space on somebody's existing disk lands at whatever index `gpart`
    // picks next, and hard-coding the number quietly formats the wrong
    // partition. Every `gpart add` below already sets a label, and the tree
    // already trusts `/dev/gpt/*` for the installed machine's fstab — which is
    // exactly why `loader.conf` disables the disk-ident class (§2.43's fourth
    // finding). The prefix keeps it distinct from the live medium's own labels.
    let esp = "/dev/gpt/\(plan.labelPrefix)esp"
    let poolDev = "/dev/gpt/\(plan.labelPrefix)zfs"

    // ---- the partition table ---------------------------------------------
    //
    // **Three cases, and only one of them destroys anything.**
    //
    //   erasing        the person confirmed: replace the table wholesale
    //   no table       a blank disk: create one, destroy nothing
    //   free space     somebody's disk with room: add beside what is there
    //
    // The third is the one that did not exist. An installer that only takes
    // whole disks has a single answer for a machine whose disks all have
    // something on them, and that answer is "destroy something".
    let target = inventory.disk(named: plan.disk)
    let erasing = plan.eraseExistingData
    let hasTable = target?.hasPartitionTable ?? false
    if erasing {
        s.append(.run(["gpart", "destroy", "-F", plan.disk],
                      what: "clear any existing partition table",
                      onFailure: "the old partition table on \(plan.disk) could not be removed",
                      destructive: true, mayFail: true))
    }
    if erasing || !hasTable {
        s.append(.run(["gpart", "create", "-s", "gpt", plan.disk],
                      what: "create the GPT",
                      onFailure: "a GPT could not be written to \(plan.disk)",
                      destructive: true))
    }
    s.append(.run(["gpart", "add", "-a", "1m", "-s", mib(plan.espBytes),
                   "-t", "efi", "-l", plan.labelPrefix + "esp", plan.disk],
                  what: "add the EFI system partition",
                  onFailure: "the EFI partition could not be created",
                  destructive: true))
    if plan.swapBytes > 0 {
        s.append(.run(["gpart", "add", "-a", "1m", "-s", mib(plan.swapBytes),
                       "-t", "freebsd-swap", "-l", plan.labelPrefix + "swap", plan.disk],
                      what: "add swap",
                      onFailure: "the swap partition could not be created",
                      destructive: true))
    }
    s.append(.run(["gpart", "add", "-a", "1m", "-t", "freebsd-zfs",
                   "-l", plan.labelPrefix + "zfs", plan.disk],
                  what: "add the pool partition",
                  onFailure: "the ZFS partition could not be created",
                  destructive: true))

    // ---- the ESP ----------------------------------------------------------
    // `-c 1` (one sector per cluster) because firmware has been known to reject
    // FAT32 volumes whose geometry it dislikes, and this is the shape the
    // official images use.
    s.append(.run(["newfs_msdos", "-F", "32", "-c", "1", esp],
                  what: "format the EFI partition",
                  onFailure: "FAT32 could not be written to \(esp)",
                  destructive: true))

    // ---- the pool ---------------------------------------------------------
    // `altroot` is what makes every mountpoint in the pool relative to /mnt for
    // the duration of the install and absolute again after the export — without
    // it, `mountpoint=/` would try to mount over the running root.
    s.append(.run(["zpool", "create", "-f",
                   "-o", "altroot=" + mnt,
                   "-o", "cachefile=" + poolCachePath,
                   "-O", "compress=lz4", "-O", "atime=off", "-O", "mountpoint=none",
                   pool, poolDev],
                  what: "create the pool",
                  onFailure: "the ZFS pool \(pool) could not be created on \(poolDev)",
                  destructive: true))

    func create(_ d: Dataset) -> Step {
        var argv = ["zfs", "create"]
        for (k, v) in d.properties { argv += ["-o", "\(k)=\(v)"] }
        argv.append("\(pool)/\(d.name)")
        return .run(argv, what: "create \(pool)/\(d.name)",
                    onFailure: "the dataset \(pool)/\(d.name) could not be created")
    }
    for d in bootEnvironmentDatasets { s.append(create(d)) }

    // `ROOT/default` is `canmount=noauto` so that a machine with several boot
    // environments does not mount all of them — the loader mounts the one it
    // was told to. The cost is that the install has to mount it by hand, right
    // here, and forgetting to would extract the whole base system into the
    // pool's mountpoint and appear to work.
    s.append(.run(["zfs", "mount", "\(pool)/ROOT/default"],
                  what: "mount the new root",
                  onFailure: "\(pool)/ROOT/default could not be mounted at \(mnt)"))
    // Only now the rest, because `zfs create` mounts what it creates and there
    // is finally something for them to mount *into*.
    //
    // And note what is NOT here: `zfs mount -a`, which mounts every unmounted
    // dataset on the machine — the installer's own root pool included. The first
    // real run of this list said so out loud, "cannot unmount '/var/log': pool
    // or dataset is busy", about the live system. An install touches the pool it
    // is building and no other.
    for d in standardDatasets { s.append(create(d)) }
    s.append(.run(["zpool", "set", "bootfs=\(pool)/ROOT/default", pool],
                  what: "mark the boot environment",
                  onFailure: "the pool's bootfs property could not be set —"
                           + " the machine would not know what to boot"))

    // ---- the system itself -------------------------------------------------
    for set in plan.sets {
        s.append(.run(["tar", "-xpf", plan.distDirectory + "/" + set, "-C", mnt],
                      what: "extract \(set)",
                      onFailure: "\(set) could not be extracted —"
                               + " the distribution media may be damaged"))
    }

    // ---- boot ---------------------------------------------------------------
    // `loader.efi` comes from what we just extracted, not from the running live
    // system: the installed machine must boot the loader that matches its own
    // kernel, not whatever the installer happened to be running.
    s.append(.run(["mkdir", "-p", mnt + "/boot/efi"],
                  what: "make the ESP mount point",
                  onFailure: "\(mnt)/boot/efi could not be created"))
    s.append(.run(["mount", "-t", "msdosfs", esp, mnt + "/boot/efi"],
                  what: "mount the EFI partition",
                  onFailure: "the EFI partition could not be mounted"))
    s.append(.run(["mkdir", "-p", mnt + "/boot/efi/EFI/BOOT"],
                  what: "make EFI/BOOT",
                  onFailure: "EFI/BOOT could not be created on the EFI partition"))
    s.append(.run(["cp", mnt + "/boot/loader.efi", mnt + "/boot/efi/EFI/BOOT/BOOTX64.efi"],
                  what: "install the boot loader",
                  onFailure: "the boot loader could not be copied to the EFI partition"))

    s.append(.run(["mkdir", "-p", mnt + "/boot/zfs"],
                  what: "make /boot/zfs",
                  onFailure: "\(mnt)/boot/zfs could not be created"))
    // **`zpool create -o cachefile=X` records the property and does not write
    // X.** The file appears whenever ZFS next decides to flush the config,
    // which during an install may be never — so ask for it explicitly rather
    // than copying a file and hoping. Found by running the list: the copy below
    // failed with ENOENT on a pool whose `cachefile` property was set correctly.
    s.append(.run(["zpool", "set", "cachefile=" + poolCachePath, pool],
                  what: "write the pool cache",
                  onFailure: "the pool cache could not be written"))
    s.append(.run(["cp", poolCachePath, mnt + "/boot/zfs/zpool.cache"],
                  what: "install the pool cache",
                  onFailure: "the pool cache could not be copied —"
                           + " the machine would import its pool the slow way"))

    // ---- configuration ------------------------------------------------------
    s.append(Step(.write(path: mnt + "/boot/loader.conf",
                         contents: loaderConf(plan, machine: inventory.machine),
                         mode: 0o644),
                  what: "write loader.conf",
                  onFailure: "loader.conf could not be written —"
                           + " the machine would not find its root filesystem"))
    s.append(Step(.write(path: mnt + "/etc/rc.conf", contents: rcConf(plan), mode: 0o644),
                  what: "write rc.conf",
                  onFailure: "rc.conf could not be written"))
    s.append(Step(.write(path: mnt + "/etc/fstab", contents: fstab(plan), mode: 0o644),
                  what: "write fstab",
                  onFailure: "fstab could not be written"))

    if !plan.timezone.isEmpty {
        s.append(.run(["cp", mnt + "/usr/share/zoneinfo/" + plan.timezone,
                       mnt + "/etc/localtime"],
                      what: "set the time zone to \(plan.timezone)",
                      onFailure: "the time zone \(plan.timezone) is not in the installed zoneinfo"))
    }

    // ---- who can log in -----------------------------------------------------
    if !plan.rootPasswordHash.isEmpty && plan.rootPasswordHash != "*" {
        s.append(.run(["pw", "-R", mnt, "usermod", "root", "-H", "0"],
                      what: "set the root password",
                      onFailure: "the root password could not be set",
                      stdin: plan.rootPasswordHash))
    }
    for a in plan.accounts {
        var argv = ["pw", "-R", mnt, "useradd", "-n", a.name, "-m", "-s", a.shell, "-H", "0"]
        if !a.fullName.isEmpty { argv += ["-c", a.fullName] }
        if !a.groups.isEmpty { argv += ["-G", a.groups.joined(separator: ",")] }
        s.append(.run(argv,
                      what: "create the account \(a.name)",
                      onFailure: "the account \(a.name) could not be created",
                      stdin: a.passwordHash))
    }

    // ---- leave nothing mounted ---------------------------------------------
    // The teardown is part of the list, not a `defer` in the executor, because
    // an install that is interrupted here must be resumable by running the list
    // again — and because a pool left imported is a pool the next attempt
    // cannot create.
    s.append(.run(["umount", mnt + "/boot/efi"],
                  what: "unmount the EFI partition",
                  onFailure: "the EFI partition could not be unmounted", mayFail: true))
    // No `zfs umount -a` here either, and for the same reason — `zpool export`
    // unmounts everything in the pool it is exporting, which is exactly the set
    // we want and nothing else.
    s.append(.run(["zpool", "export", pool],
                  what: "export the pool",
                  onFailure: "the pool \(pool) could not be exported —"
                           + " the installed system may not import it on first boot"))
    return s
}

// MARK: - The files we write

public func loaderConf(_ plan: InstallPlan, machine: MachineIdentity? = nil) -> String {
    var out = "# Written by the AbyssBSD installer.\n"
    out += "zfs_load=\"YES\"\n"
    out += "vfs.root.mountfrom=\"zfs:\(plan.poolName)/ROOT/default\"\n"
    // A serial console costs nothing on hardware that has none and is the only
    // way to see a boot that fails before the desktop — which is the boot that
    // matters when an install has gone wrong.
    out += "boot_serial=\"YES\"\n"
    out += "comconsole_speed=\"115200\"\n"
    out += "console=\"comconsole,vidconsole\"\n"
    // **The GPT labels this install writes into fstab have to survive to the
    // installed machine, and by default they may not.** GEOM's disk-ident class
    // can consume the whole disk first, so the GPT lands under
    // `diskid/DISK-<serial>` and no `/dev/gpt/*` provider is ever created —
    // `gpart show -l` still lists the labels, which is what makes this so
    // convincing to look at and so wrong. The machine then boots with
    // "swapon: /dev/gpt/<pool>swap: No such file or directory" in a log nobody
    // reads, and no swap. Measured: with this line, /dev/gpt appears and
    // swapinfo shows the partition; without it, neither.
    out += "kern.geom.label.disk_ident.enable=\"0\"\n"
    // **A Mac Pro accommodation, and since P12.2 only Mac Pros get it.**
    // Without it a 2013 Mac Pro's first boot is "pcib26: Power Fault Detected"
    // scrolling and nothing else — its internal PCIe bridges report a
    // power-fault bit that never clears, so pcib(4) re-logs it forever. The live
    // medium sets it too, but that only rescues the install: the machine we just
    // built has its own loader.conf, and a fresh install that spews over its own
    // first boot is the install having failed. It is a loader tunable, so there
    // is no fixing it after the fact from a shell.
    //
    // It used to be written to **every** machine, because nothing could ask what
    // machine it was on. That was defensible while it was true and stopped being
    // true when `Vents.Kenv` landed: `smbios.system.*` names the machine, and a
    // workaround for somebody else's PCIe bridges has no business in the
    // loader.conf of a board that has none.
    //
    // **A machine that does not identify itself does not get it.** That is the
    // deliberate direction to fail in: the cost of omitting it is a Mac Pro
    // whose console scrolls, which is visible and recoverable by reinstalling
    // from a medium that still sets it; the cost of adding it everywhere is a
    // silent, permanent change to machines we never examined.
    if needsPCIeHotplugDisabled(maker: machine?.maker, product: machine?.product) {
        out += "hw.pci.enable_pcie_hp=\"0\"\n"
    }
    return out
}

public func rcConf(_ plan: InstallPlan) -> String {
    var out = "# Written by the AbyssBSD installer.\n"
    out += "zfs_enable=\"YES\"\n"
    out += "hostname=\"\(plan.hostname)\"\n"
    out += "ifconfig_DEFAULT=\"DHCP\"\n"
    if !plan.keymap.isEmpty { out += "keymap=\"\(plan.keymap)\"\n" }
    // **A machine that installed the desktop should start it.** The rule is
    // derived rather than assumed: the desktop is enabled exactly when the set
    // that contains it is one of the sets being extracted, so a plan that
    // installs a plain FreeBSD produces a plain FreeBSD. And it names the
    // account to run as, because an installed desktop belongs to whoever this
    // machine was installed for — there is no login window yet (PHASE5 §6.8).
    if plan.installsDesktop {
        out += "abyss_desktop_enable=\"YES\"\n"
        if let owner = plan.accounts.first(where: { $0.isAdministrator })
                    ?? plan.accounts.first {
            out += "abyss_desktop_user=\"\(owner.name)\"\n"
        }
    }
    return out
}

public func fstab(_ plan: InstallPlan) -> String {
    var out = "# Device\tMountpoint\tFStype\tOptions\tDump\tPass#\n"
    if plan.swapBytes > 0 {
        out += "/dev/gpt/\(plan.labelPrefix)swap\tnone\tswap\tsw\t0\t0\n"
    }
    // The root filesystem is not here on purpose: ZFS mounts it from the pool,
    // and an entry for it in fstab is how you get a machine that mounts its root
    // twice.
    return out
}

// MARK: - Rendering

/// One argument, unambiguously. The rendered list is evidence of what we run at
/// somebody's disk, and `-c J Kane` reads as three arguments when it is two.
private func shellQuoted(_ arg: String) -> String {
    if arg.isEmpty { return "''" }
    let safe = arg.allSatisfy { $0.isLetter || $0.isNumber
        || "-_./=:,+@".contains($0) }
    if safe { return arg }
    // Foundation is not available here (the `de/` rule), so quote by hand: a
    // single quote inside single quotes closes, escapes and reopens.
    var out = "'"
    for ch in arg { out += ch == "'" ? "'\\''" : String(ch) }
    return out + "'"
}

/// The step list as text, stable enough to keep in a golden test.
public func render(_ steps: [Step]) -> String {
    var out = ""
    for (i, step) in steps.enumerated() {
        var flags = ""
        if step.destructive { flags += " [destructive]" }
        if step.mayFail { flags += " [may fail]" }
        out += "\(i + 1). \(step.what)\(flags)\n"
        switch step.action {
        case .run(let argv, let stdin):
            out += "   $ " + argv.map(shellQuoted).joined(separator: " ") + "\n"
            if stdin != nil { out += "   < (on stdin, kept out of argv)\n" }
        case .write(let path, let contents, let mode):
            out += "   > \(path) (\(String(mode, radix: 8)))\n"
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false)
            where !line.isEmpty {
                out += "     | \(line)\n"
            }
        case .append(let path, let contents):
            out += "   >> \(path)\n"
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false)
            where !line.isEmpty {
                out += "     | \(line)\n"
            }
        }
    }
    return out
}
