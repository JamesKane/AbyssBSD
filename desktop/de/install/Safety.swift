// The refusals.
//
// This is the first code in this tree whose bug destroys something that cannot
// be rebuilt by running the build again, so it is deliberately the *first* pass
// of the phase and deliberately pure: every one of these refusals is reachable
// from a unit test on a machine that has no disks to lose.
//
// The ordering below is not arbitrary. Cheap structural checks come first so
// that a malformed plan is rejected on its own terms; the checks that depend on
// the machine come after, so their messages are about the machine rather than
// about a typo.

/// Why an install plan was refused. Every case carries enough to say what is
/// wrong *in a sentence a person can act on* — a refusal a user cannot fix is
/// one they will work around.
public enum PlanRefusal: Error, Equatable {
    case emptyDisk
    case notAWholeDisk(String)
    case noSuchDisk(String, available: [String])
    case diskIsMounted(String, at: [String])
    case diskHoldsRunningRoot(String)
    case diskTooSmall(String, has: UInt64, needs: UInt64)
    case badPoolName(String, why: String)
    case poolNameInUse(String)
    case noSets
    case baseSetNotFirst([String])
    case sizeNotWholeMiB(String, UInt64)
    case relativePath(String, String)
    case noAdministrator
    case diskIsFull(String, contents: [String], freeBytes: UInt64, needBytes: UInt64)

    /// The sentence to put in front of a person.
    public var message: String {
        switch self {
        case .emptyDisk:
            return "no disk was chosen"
        case .notAWholeDisk(let d):
            return "\(d) is a partition, not a disk — an install takes the whole disk"
        case .noSuchDisk(let d, let available):
            return available.isEmpty
                ? "this machine has no disks, so there is nowhere to install"
                : "there is no disk called \(d); this machine has \(available.joined(separator: ", "))"
        case .diskIsMounted(let d, let at):
            return "\(d) is in use — something is mounted from it at \(at.joined(separator: ", "))"
        case .diskHoldsRunningRoot(let d):
            return "\(d) is the disk this system is running from"
        case .diskTooSmall(let d, let has, let needs):
            return "\(d) holds \(gib(has)) and this install needs at least \(gib(needs))"
        case .badPoolName(let n, let why):
            return "\"\(n)\" cannot be a ZFS pool name: \(why)"
        case .poolNameInUse(let n):
            return "a pool called \(n) is already imported on this machine"
        case .noSets:
            return "an install with no distribution sets would install nothing"
        case .baseSetNotFirst(let sets):
            return "base.txz has to be extracted first, before \(sets.first ?? "anything else")"
        case .sizeNotWholeMiB(let what, let bytes):
            return "\(what) is \(bytes) bytes, which is not a whole number of MiB"
        case .relativePath(let what, let p):
            return "\(what) must be an absolute path, and \"\(p)\" is not"
        case .noAdministrator:
            return "nobody could log in to the installed system:"
                 + " set a root password or give an account the wheel group"
        case .diskIsFull(let d, let contents, let free, let need):
            // **Say what is on it, and how short it is.** A refusal a person
            // cannot act on is one they work around, and "choose another disk"
            // is not advice on a machine where every disk is full — knowing
            // *what* would be destroyed is what makes the next decision theirs.
            let what = contents.isEmpty ? "partitions" : contents.joined(separator: ", ")
            return "\(d) is fully partitioned (\(what)) — \(gib(free)) free,"
                 + " and this install needs \(gib(need)) in one piece."
                 + " Choose a disk with room, or confirm that this one is to be erased"
        }
    }

    func gib(_ bytes: UInt64) -> String {
        let tenths = (bytes * 10) / (1024 * 1024 * 1024)
        return "\(tenths / 10).\(tenths % 10) GiB"
    }
}

/// ZFS pool names the pool code itself reserves, plus the shapes it rejects.
/// Getting this wrong means `zpool create` fails **after** `gpart` has already
/// written a new partition table over somebody's disk — which is why it is
/// checked here, before any step exists to run.
private let reservedPoolNames: Set<String> = ["mirror", "raidz", "raidz1", "raidz2",
                                              "raidz3", "draid", "spare", "log", "cache"]

private func poolNameProblem(_ name: String) -> String? {
    if name.isEmpty { return "it is empty" }
    guard let first = name.first else { return "it is empty" }
    if !(first.isLetter) { return "it has to begin with a letter" }
    if reservedPoolNames.contains(name) { return "that name is reserved by ZFS" }
    // `c[0-9]` is refused by ZFS because it looks like a Solaris disk name.
    if name.count >= 2, first == "c", name.dropFirst().first!.isNumber {
        return "a name beginning c<digit> looks like a device to ZFS"
    }
    for ch in name where !(ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." || ch == ":") {
        return "\"\(ch)\" is not allowed in a pool name"
    }
    return nil
}

/// True if this device name is a partition or slice rather than a whole disk:
/// `ada0p2`, `da0s1`, `da0s1a`. A plan that names one would have `gpart create`
/// build a partition table *inside a partition*, which succeeds.
public func namesAPartition(_ device: String) -> Bool {
    var sawDigit = false
    var i = device.startIndex
    // Skip the leading driver name.
    while i < device.endIndex, device[i].isLetter { i = device.index(after: i) }
    // Then the unit number.
    while i < device.endIndex, device[i].isNumber { sawDigit = true; i = device.index(after: i) }
    guard sawDigit, i < device.endIndex else { return false }
    // Anything left that starts p/s (partition/slice) and has a digit after it.
    let rest = device[i...]
    guard let head = rest.first, head == "p" || head == "s" else { return false }
    return rest.dropFirst().first?.isNumber ?? false
}

/// Refuse a plan that must not be run, given what this machine looks like.
///
/// Throws the *first* problem it finds, most structural first. Callers that want
/// to show a person everything wrong at once should call `problems` instead.
public func check(_ plan: InstallPlan, on inventory: DiskInventory) throws {
    if let first = problems(plan, on: inventory).first { throw first }
}

/// Every reason this plan would be refused, in the order they are checked.
///
/// A list rather than a single throw because a summary page wants to say all of
/// it: an installer that reveals one problem per attempt is one people learn to
/// distrust.
public func problems(_ plan: InstallPlan, on inventory: DiskInventory) -> [PlanRefusal] {
    var found: [PlanRefusal] = []

    // ---- structural: true or false with no machine involved --------------
    if plan.disk.isEmpty { found.append(.emptyDisk) }
    else if namesAPartition(plan.disk) { found.append(.notAWholeDisk(plan.disk)) }

    if let why = poolNameProblem(plan.poolName) {
        found.append(.badPoolName(plan.poolName, why: why))
    }

    let mib: UInt64 = 1024 * 1024
    if plan.espBytes % mib != 0 { found.append(.sizeNotWholeMiB("the EFI partition", plan.espBytes)) }
    if plan.swapBytes % mib != 0 { found.append(.sizeNotWholeMiB("swap", plan.swapBytes)) }

    if plan.sets.isEmpty { found.append(.noSets) }
    else if plan.sets[0] != "base.txz" { found.append(.baseSetNotFirst(plan.sets)) }

    if !plan.distDirectory.hasPrefix("/") {
        found.append(.relativePath("the distribution directory", plan.distDirectory))
    }
    if !plan.mountpoint.hasPrefix("/") {
        found.append(.relativePath("the mount point", plan.mountpoint))
    }

    // A machine nobody can log into is not an installed machine. `*` is the
    // hash `pw` writes for "no password will ever match".
    let rootUsable = !plan.rootPasswordHash.isEmpty && plan.rootPasswordHash != "*"
    if !rootUsable && !plan.accounts.contains(where: { $0.isAdministrator }) {
        found.append(.noAdministrator)
    }

    // ---- the machine ------------------------------------------------------
    if inventory.importedPools.contains(plan.poolName) {
        found.append(.poolNameInUse(plan.poolName))
    }

    if !plan.disk.isEmpty, !namesAPartition(plan.disk) {
        guard let disk = inventory.disk(named: plan.disk) else {
            found.append(.noSuchDisk(plan.disk, available: inventory.disks.map(\.name)))
            return found
        }
        // Strongest first: this is the disk you are running from.
        if disk.holdsRunningRoot { found.append(.diskHoldsRunningRoot(disk.name)) }
        else if !disk.mountedAt.isEmpty {
            found.append(.diskIsMounted(disk.name, at: disk.mountedAt))
        }
        // **The refusal that only a live medium needs.** The two above describe
        // the *running* system, and on a medium the running system is the USB
        // stick — so a disk carrying somebody's whole FreeBSD install is
        // unmounted, its pool unimported, and silent to both. Without this a
        // machine with one disk in it presents that disk as a clean target.
        //
        // Not permanent: `eraseExistingData` lifts it, because an installer that
        // can never reinstall is broken. The guard is that it is off by default
        // and the sentence that turns it on names the pool being destroyed.
        // **A disk with room is installable; a full one is not.**
        //
        // The old rule refused any disk carrying a ZFS pool, which protected our
        // own filesystem and offered somebody's Windows as a clean target. The
        // rule that generalises is not "refuse anything with partitions" — that
        // would refuse every disk on a machine that has ever been used — it is
        // **refuse a disk with nowhere to put the install**, and say what is in
        // the way.
        //
        // A disk with no table at all is empty, not full: nothing to destroy,
        // and `steps` creates the table rather than replacing one.
        if !plan.eraseExistingData, disk.hasPartitionTable,
           disk.freeBytes < plan.minimumDiskBytes {
            found.append(.diskIsFull(disk.name, contents: disk.contents,
                                     freeBytes: disk.freeBytes,
                                     needBytes: plan.minimumDiskBytes))
        }
        if disk.bytes < plan.minimumDiskBytes {
            found.append(.diskTooSmall(disk.name, has: disk.bytes, needs: plan.minimumDiskBytes))
        }
    }

    return found
}
