// Install tests — the refusals and the step list.
//
// Every test here runs on Linux, where `gpart`, `zpool` and `zfs` do not exist.
// That is the point of P5.1: the machine is an argument, so the exact machine on
// which a refusal must fire can be built in three lines and the refusal proved,
// rather than waited for.

import XCTest
@testable import Install

final class InstallTests: XCTestCase {

    // A perfectly ordinary machine: one empty 64 GiB disk, and the live system
    // running from somewhere else entirely.
    private func machine(diskBytes: UInt64 = 64 * 1024 * 1024 * 1024,
                         mountedAt: [String] = [],
                         holdsRoot: Bool = false,
                         pools: [String] = [],
                         existingPools: [String] = [],
                         identity: MachineIdentity? = nil) -> DiskInventory {
        DiskInventory(disks: [Disk(name: "ada0", bytes: diskBytes,
                                   description: "QEMU HARDDISK",
                                   mountedAt: mountedAt,
                                   holdsRunningRoot: holdsRoot,
                                   existingPools: existingPools)],
                      importedPools: pools,
                      machine: identity)
    }

    /// A plan that is fine, so a test can break exactly one thing about it.
    private func goodPlan(disk: String = "ada0", pool: String = "abyss",
                          erase: Bool = false) -> InstallPlan {
        InstallPlan(disk: disk, poolName: pool, hostname: "abyss",
                    accounts: [Account(name: "jkane", fullName: "J Kane",
                                       passwordHash: "$6$fake", groups: ["wheel"])],
                    eraseExistingData: erase)
    }

    // MARK: - The refusals

    func testAnOrdinaryPlanOnAnOrdinaryMachineIsAccepted() {
        // The positive control. Without it every refusal test below would pass
        // just as happily against a predicate that refuses everything.
        XCTAssertEqual(problems(goodPlan(), on: machine()), [])
        XCTAssertNoThrow(try compile(goodPlan(), on: machine()))
    }

    func testTheDiskYouAreRunningFromIsRefused() {
        let ps = problems(goodPlan(), on: machine(holdsRoot: true))
        XCTAssertTrue(ps.contains(.diskHoldsRunningRoot("ada0")), "\(ps)")
    }

    func testADiskWithSomethingMountedFromItIsRefused() {
        let ps = problems(goodPlan(), on: machine(mountedAt: ["/media/photos"]))
        XCTAssertTrue(ps.contains(.diskIsMounted("ada0", at: ["/media/photos"])), "\(ps)")
    }

    func testTheRunningRootOutranksAMerelyMountedDisk() {
        // Both are true of a boot disk; the message a person sees should be the
        // one that explains why, not the one that lists a mount point.
        let ps = problems(goodPlan(), on: machine(mountedAt: ["/"], holdsRoot: true))
        XCTAssertTrue(ps.contains(.diskHoldsRunningRoot("ada0")))
        XCTAssertFalse(ps.contains(where: { if case .diskIsMounted = $0 { return true }; return false }))
    }

    // MARK: - The disk that already holds somebody's system

    /// A disk with a table and no room — the shape of all three fixed disks on
    /// the bring-up machine.
    private func fullDisk(pools: [String] = [], kinds: [String] = ["efi", "ntfs"]) -> DiskInventory {
        DiskInventory(disks: [Disk(name: "ada0", bytes: 64 << 30, description: "Samsung",
                                   existingPools: pools, partitionKinds: kinds,
                                   freeBytes: 2 << 20, hasPartitionTable: true)])
    }

    func testAFullDiskIsRefusedWhateverIsOnIt() {
        // **The rule that generalises.** The old one refused a disk carrying a
        // ZFS pool, which protected our filesystem and offered somebody's
        // Windows as a clean target — verified on the bring-up machine, where
        // `nda1` (zroot) was correctly refused and `nda0` (931 GB of Windows)
        // and `ada0` (223 GB of NTFS) were not.
        for kinds in [["efi", "ms-basic-data", "ms-recovery"], ["ntfs", "ntfs"]] {
            let ps = problems(goodPlan(), on: fullDisk(kinds: kinds))
            XCTAssertTrue(ps.contains(where: { if case .diskIsFull = $0 { return true }; return false }),
                          "\(kinds) was offered as a clean target: \(ps)")
        }
    }

    func testTheRefusalSaysWhatIsOnItAndHowShortItIs() {
        // "Choose another disk" is not advice on a machine where every disk is
        // full. What makes the next decision theirs is knowing what would go.
        let m = fullDisk(pools: ["zroot"], kinds: ["efi", "freebsd-swap", "freebsd-zfs"])
        let msg = problems(goodPlan(), on: m).compactMap { p -> String? in
            if case .diskIsFull = p { return p.message }; return nil
        }.first
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("ZFS pool zroot"), msg!)
        XCTAssertTrue(msg!.contains("freebsd-zfs"), msg!)
        XCTAssertTrue(msg!.contains("free"), msg!)
    }

    func testADiskWithRoomIsInstallableWithoutDestroyingAnything() {
        // **The case that did not exist before.** Somebody's disk with space to
        // spare takes an install beside what is already there — no confirmation,
        // because nothing is being destroyed.
        let roomy = DiskInventory(disks: [Disk(name: "ada0", bytes: 512 << 30,
                                               description: "Samsung",
                                               partitionKinds: ["efi", "ntfs"],
                                               freeBytes: 200 << 30,
                                               hasPartitionTable: true)])
        XCTAssertEqual(problems(goodPlan(), on: roomy), [])
    }

    func testABlankDiskIsEmptyNotFull() {
        // No table is not the same as a full table: nothing to destroy, and a
        // table to create rather than replace.
        let blank = DiskInventory(disks: [Disk(name: "ada0", bytes: 64 << 30,
                                               description: "Samsung",
                                               hasPartitionTable: false)])
        XCTAssertEqual(problems(goodPlan(), on: blank), [])
    }

    func testSayingEraseLiftsItAndNothingElse() {
        // An installer that can never reinstall is broken, so the guard is not
        // that this is impossible — it is that it is off by default. The opt-in
        // must lift THIS refusal and leave every other one standing.
        XCTAssertEqual(problems(goodPlan(erase: true), on: fullDisk(pools: ["zroot"])), [])
        let stillRoot = problems(goodPlan(erase: true),
                                 on: DiskInventory(disks: [Disk(name: "ada0", bytes: 64 << 30,
                                                                holdsRunningRoot: true,
                                                                partitionKinds: ["efi"],
                                                                hasPartitionTable: true)]))
        XCTAssertTrue(stillRoot.contains(.diskHoldsRunningRoot("ada0")), "\(stillRoot)")
    }

    func testAPartitionIsNotADisk() {
        // `gpart create` inside a partition SUCCEEDS, which is what makes this
        // worth a refusal rather than a comment.
        for name in ["ada0p2", "da0s1", "nvd0p1"] {
            XCTAssertTrue(namesAPartition(name), name)
            XCTAssertTrue(problems(goodPlan(disk: name), on: machine())
                            .contains(.notAWholeDisk(name)), name)
        }
        for name in ["ada0", "da0", "nvd0", "md0", "vtbd1"] {
            XCTAssertFalse(namesAPartition(name), name)
        }
    }

    func testADiskThatIsNotThereNamesTheOnesThatAre() {
        // The refusal a typo produces, and the only one whose message is a help
        // rather than a warning.
        let ps = problems(goodPlan(disk: "ada9"), on: machine())
        XCTAssertEqual(ps, [.noSuchDisk("ada9", available: ["ada0"])])
        XCTAssertTrue(ps[0].message.contains("ada0"))
    }

    func testATooSmallDiskIsRefusedBeforeAnythingIsWritten() {
        // 3 GiB: enough for the ESP and swap, not enough to be a machine.
        let ps = problems(goodPlan(), on: machine(diskBytes: 3 * 1024 * 1024 * 1024))
        XCTAssertTrue(ps.contains(where: { if case .diskTooSmall = $0 { return true }; return false }),
                      "\(ps)")
    }

    func testAPoolNameAlreadyImportedIsRefused() {
        // Not hypothetical: the build VM is itself ZFS-rooted with a pool called
        // `zroot`, so an install plan defaulting to that name collides with the
        // machine running the installer. The spike had to rename its pool to
        // get started, which is how this test exists.
        XCTAssertTrue(problems(goodPlan(pool: "zroot"), on: machine(pools: ["zroot"]))
                        .contains(.poolNameInUse("zroot")))
        // ...and is fine when nothing has claimed it.
        XCTAssertEqual(problems(goodPlan(pool: "zroot"), on: machine()), [])
    }

    func testPoolNamesZFSItselfWouldReject() {
        // Each of these fails at `zpool create` — which is AFTER `gpart` has
        // written a new partition table over the disk. Refusing here is the
        // difference between "that name will not work" and "your disk is gone
        // and that name did not work".
        // `c9x` belongs here, not below: zpool(8) forbids a name beginning with
        // the pattern c[0-9] outright, because it looks like a Solaris device.
        for bad in ["mirror", "raidz2", "spare", "9lives", "c0d0", "c9x", "", "a/b"] {
            XCTAssertTrue(problems(goodPlan(pool: bad), on: machine())
                            .contains(where: { if case .badPoolName = $0 { return true }
                                               return false }),
                          "expected \(bad) to be refused")
        }
        for good in ["abyss", "zroot", "tank", "abyss-2", "a.b", "cache2"] {
            XCTAssertFalse(problems(goodPlan(pool: good), on: machine())
                            .contains(where: { if case .badPoolName = $0 { return true }
                                               return false }),
                           "expected \(good) to be accepted")
        }
    }

    func testAMachineNobodyCanLogIntoIsRefused() {
        // `pw` writes `*` for "no password will ever match", and a plan with no
        // wheel account and no root password produces a system that installs
        // perfectly and cannot be used.
        var p = InstallPlan(disk: "ada0")
        XCTAssertTrue(problems(p, on: machine()).contains(.noAdministrator))
        // A non-administrator user is not enough.
        p = InstallPlan(disk: "ada0",
                        accounts: [Account(name: "guest", passwordHash: "$6$x")])
        XCTAssertTrue(problems(p, on: machine()).contains(.noAdministrator))
        // Either a wheel account...
        p = InstallPlan(disk: "ada0",
                        accounts: [Account(name: "jkane", passwordHash: "$6$x", groups: ["wheel"])])
        XCTAssertFalse(problems(p, on: machine()).contains(.noAdministrator))
        // ...or a root password will do.
        p = InstallPlan(disk: "ada0", rootPasswordHash: "$6$y")
        XCTAssertFalse(problems(p, on: machine()).contains(.noAdministrator))
    }

    func testAnInstallThatInstallsNothingIsRefused() {
        var p = InstallPlan(disk: "ada0", sets: [], rootPasswordHash: "$6$y")
        XCTAssertTrue(problems(p, on: machine()).contains(.noSets))
        // And base.txz has to be first: extracting kernel.txz onto an empty
        // pool and base.txz over the top of it works, right up until it doesn't.
        p = InstallPlan(disk: "ada0", sets: ["kernel.txz", "base.txz"],
                        rootPasswordHash: "$6$y")
        XCTAssertTrue(problems(p, on: machine())
                        .contains(.baseSetNotFirst(["kernel.txz", "base.txz"])))
    }

    func testPartitionSizesMustBeWholeMiB() {
        // `gpart` is told sizes in MiB, so a plan whose sizes are not whole MiB
        // would be silently rounded — and a swap partition that is not the size
        // the plan says is a plan that is lying.
        let p = InstallPlan(disk: "ada0", espBytes: 260 * 1024 * 1024 + 1,
                            rootPasswordHash: "$6$y")
        XCTAssertTrue(problems(p, on: machine())
                        .contains(.sizeNotWholeMiB("the EFI partition", 260 * 1024 * 1024 + 1)))
    }

    func testEveryProblemIsReportedNotJustTheFirst() {
        // A summary page shows all of it. An installer that reveals one problem
        // per attempt is one people learn to distrust.
        let p = InstallPlan(disk: "ada0p1", poolName: "mirror", sets: [])
        let ps = problems(p, on: machine())
        XCTAssertGreaterThanOrEqual(ps.count, 4, "\(ps)")
        XCTAssertTrue(ps.contains(.notAWholeDisk("ada0p1")))
        XCTAssertTrue(ps.contains(.noSets))
        XCTAssertTrue(ps.contains(.noAdministrator))
    }

    func testEveryRefusalSaysSomethingAPersonCouldActOn() {
        // A refusal a user cannot fix is one they will work around.
        let all: [PlanRefusal] = [
            .emptyDisk, .notAWholeDisk("ada0p1"), .noSuchDisk("ada9", available: ["ada0"]),
            .diskIsMounted("ada0", at: ["/media"]), .diskHoldsRunningRoot("ada0"),
            .diskTooSmall("ada0", has: 1 << 30, needs: 8 << 30),
            .badPoolName("mirror", why: "that name is reserved by ZFS"),
            .poolNameInUse("zroot"), .noSets, .baseSetNotFirst(["kernel.txz"]),
            .sizeNotWholeMiB("swap", 3), .relativePath("the mount point", "mnt"),
            .noAdministrator,
        ]
        for r in all {
            XCTAssertFalse(r.message.isEmpty, "\(r)")
            XCTAssertGreaterThan(r.message.count, 15, "\(r): \(r.message)")
        }
        // And the size is readable, not a byte count.
        XCTAssertTrue(PlanRefusal.diskTooSmall("ada0", has: 1 << 30, needs: 8 << 30)
                        .message.contains("1.0 GiB"))
    }

    func testNoStepListExistsForARefusedPlan() {
        // The refusal is what `compile` is FOR: there is nothing to run, so a
        // later bug cannot decide to run it anyway.
        XCTAssertThrowsError(try compile(goodPlan(), on: machine(holdsRoot: true))) { e in
            XCTAssertEqual(e as? PlanRefusal, .diskHoldsRunningRoot("ada0"))
        }
    }

    // MARK: - The step list

    func testTheFirstDestructiveStepIsWhereTheDiskChanges() {
        // The GUI puts its confirmation in front of the first destructive step,
        // so which step that is has to be right: everything before it must be
        // undoable by walking away.
        let s = try! compile(goodPlan(), on: machine())
        let firstDestructive = s.firstIndex(where: \.destructive)
        XCTAssertEqual(firstDestructive, 0)
        if case .run(let argv, _) = s[0].action {
            XCTAssertEqual(argv.first, "gpart")
        } else { XCTFail("expected a command") }
    }

    func testTheDiskIsPartitionedBeforeItIsFormattedAndTheBootFlagIsSetBeforeExtraction() {
        let s = try! compile(goodPlan(), on: machine())
        func index(of needle: String) -> Int? {
            s.firstIndex { if case .run(let a, _) = $0.action {
                return a.joined(separator: " ").contains(needle) }
                return false }
        }
        let create = index(of: "gpart create")!
        let addZFS = index(of: "-t freebsd-zfs")!
        let pool   = index(of: "zpool create")!
        let mount  = index(of: "zfs mount abyss/ROOT/default")!
        let base   = index(of: "base.txz")!
        let export = index(of: "zpool export")!
        XCTAssertLessThan(create, addZFS)
        XCTAssertLessThan(addZFS, pool)
        // The one that would fail silently: extract before mounting the root
        // dataset and base lands in the pool's mountpoint and looks installed.
        XCTAssertLessThan(mount, base)
        XCTAssertLessThan(base, export)
        XCTAssertEqual(export, s.count - 1, "the export has to be last")
    }

    func testTheRootDatasetIsMountedByHandBecauseItDoesNotAutoMount() {
        // canmount=noauto is what lets a machine have several boot environments
        // without mounting all of them — and it is why the install cannot rely
        // on `zpool create -o altroot` to have mounted anything.
        let s = try! compile(goodPlan(), on: machine())
        let creates = s.compactMap { step -> [String]? in
            if case .run(let a, _) = step.action, a.count > 2, a[0] == "zfs", a[1] == "create" {
                return a
            }
            return nil
        }
        let root = creates.first { $0.last == "abyss/ROOT/default" }
        XCTAssertNotNil(root)
        XCTAssertTrue(root!.contains("canmount=noauto"), "\(root!)")
        XCTAssertTrue(s.contains { if case .run(let a, _) = $0.action {
            return a == ["zfs", "mount", "abyss/ROOT/default"] }; return false })
    }

    func testTheRootIsMountedBeforeAnyOtherDatasetIsCreated() {
        // `zfs create` mounts what it creates. Create `abyss/home` before the
        // root dataset is mounted and it mounts at /mnt/home on the LIVE
        // filesystem, which the root mount then hides — an install that
        // completes, extracts, and produces a machine whose /home is empty.
        // Found by running the list; no unit test would have guessed it.
        let s = try! compile(goodPlan(), on: machine())
        func index(_ pred: ([String]) -> Bool) -> Int? {
            s.firstIndex { if case .run(let a, _) = $0.action { return pred(a) }; return false }
        }
        let mountRoot = index { $0 == ["zfs", "mount", "abyss/ROOT/default"] }!
        let firstOther = index { $0.count > 2 && $0[0] == "zfs" && $0[1] == "create"
                                 && !$0.last!.hasPrefix("abyss/ROOT") }!
        XCTAssertLessThan(mountRoot, firstOther,
                          "a dataset is created before the root it belongs in is mounted")
        // ...and the boot environment itself necessarily comes before the mount.
        let makeRoot = index { $0.last == "abyss/ROOT/default" && $0.contains("create") }!
        XCTAssertLessThan(makeRoot, mountRoot)
    }

    func testWeMountOurOwnDatasetsAndNobodyElsesEntirely() {
        // `zfs mount -a` mounts every unmounted dataset on the machine and
        // `zfs umount -a` unmounts every mounted one — including the running
        // installer's own root pool. The first real run of this list said so out
        // loud: "cannot unmount '/var/log': pool or dataset is busy", from the
        // live system. An install touches the pool it is building, and no other.
        let s = try! compile(goodPlan(), on: machine())
        for step in s {
            guard case .run(let a, _) = step.action else { continue }
            XCTAssertFalse(a == ["zfs", "mount", "-a"], "swept the whole machine")
            XCTAssertFalse(a == ["zfs", "umount", "-a"], "swept the whole machine")
        }
        // The only dataset mounted by hand is the root, because it is the only
        // one that does not mount itself.
        let mounted = s.compactMap { step -> String? in
            guard case .run(let a, _) = step.action, a.count == 3,
                  a[0] == "zfs", a[1] == "mount" else { return nil }
            return a[2]
        }
        XCTAssertEqual(mounted, ["abyss/ROOT/default"])
        // The pool export is what unmounts them, and it is still last.
        guard case .run(let last, _) = s.last!.action else { return XCTFail() }
        XCTAssertEqual(last, ["zpool", "export", "abyss"])
    }

    func testThePoolCacheIsWrittenBeforeItIsCopied() {
        // `zpool create -o cachefile=X` sets the property and does not write X.
        // Found by running the list: the copy failed with ENOENT on a pool whose
        // cachefile property was set correctly.
        let s = try! compile(goodPlan(), on: machine())
        func index(_ needle: String) -> Int? {
            s.firstIndex { if case .run(let a, _) = $0.action {
                return a.joined(separator: " ").contains(needle) }; return false }
        }
        let write = index("zpool set cachefile=")
        let copy = s.firstIndex { if case .run(let a, _) = $0.action {
            return a.first == "cp" && a.last!.hasSuffix("/boot/zfs/zpool.cache") }
            return false }
        XCTAssertNotNil(write, "nothing asks ZFS to write the cache")
        XCTAssertLessThan(write!, copy!)
    }

    func testASwaplessPlanHasNoSwapPartitionAndNoFstabEntry() {
        let p = InstallPlan(disk: "ada0", swapBytes: 0, rootPasswordHash: "$6$y")
        XCTAssertEqual(p.poolPartition, 2)
        XCTAssertNil(p.swapPartition)
        let s = try! compile(p, on: machine())
        XCTAssertFalse(s.contains { if case .run(let a, _) = $0.action {
            return a.contains("freebsd-swap") }; return false })
        XCTAssertFalse(fstab(p).contains("swap\tsw"))
        // ...and the pool is addressed **by label**, which is what makes the
        // index irrelevant. It used to be `/dev/ada0p2` here and `p3` with swap,
        // and that arithmetic is only true of a table we just created — an
        // install into free space on somebody's disk lands wherever `gpart`
        // puts it, and a hard-coded index would format the wrong partition.
        XCTAssertTrue(s.contains { if case .run(let a, _) = $0.action {
            return a.first == "zpool" && a.contains("/dev/gpt/abysszfs") }; return false })
    }

    func testInstallingIntoFreeSpaceDestroysNoPartitionTable() {
        // **The case the whole redesign is for.** A disk with room takes the
        // install beside what is already there: no `destroy`, and no `create`
        // either, because the table it would replace is the one being kept.
        let roomy = DiskInventory(disks: [Disk(name: "ada0", bytes: 512 << 30,
                                               description: "Samsung",
                                               partitionKinds: ["efi", "ntfs"],
                                               freeBytes: 200 << 30,
                                               hasPartitionTable: true)])
        let s = try! compile(goodPlan(), on: roomy)
        func runs(_ argv: String...) -> Bool {
            s.contains { if case .run(let a, _) = $0.action {
                return argv.allSatisfy(a.contains) }; return false }
        }
        XCTAssertFalse(runs("gpart", "destroy"), "an install into free space destroyed the table")
        XCTAssertFalse(runs("gpart", "create"), "an install into free space replaced the table")
        // ...and it still adds its own three partitions.
        XCTAssertTrue(runs("gpart", "add", "efi"))
        XCTAssertTrue(runs("gpart", "add", "freebsd-zfs"))
    }

    func testABlankDiskGetsATableButNothingIsDestroyed() {
        let blank = DiskInventory(disks: [Disk(name: "ada0", bytes: 64 << 30,
                                               hasPartitionTable: false)])
        let s = try! compile(goodPlan(), on: blank)
        func runs(_ argv: String...) -> Bool {
            s.contains { if case .run(let a, _) = $0.action {
                return argv.allSatisfy(a.contains) }; return false }
        }
        XCTAssertFalse(runs("gpart", "destroy"), "there was no table to destroy")
        XCTAssertTrue(runs("gpart", "create"), "a blank disk still needs a GPT")
    }

    func testErasingIsTheOnlyPathThatDestroysATable() {
        let occupied = DiskInventory(disks: [Disk(name: "ada0", bytes: 64 << 30,
                                                  partitionKinds: ["ntfs"],
                                                  freeBytes: 1 << 20,
                                                  hasPartitionTable: true)])
        let s = try! compile(goodPlan(erase: true), on: occupied)
        XCTAssertTrue(s.contains { if case .run(let a, _) = $0.action {
            return a.contains("destroy") }; return false })
    }

    func testAPasswordHashNeverAppearsInArgv() {
        // Every process on the machine can read argv out of `ps`. The installer
        // running as root is exactly the process where that matters.
        let s = try! compile(goodPlan(), on: machine())
        for step in s {
            if case .run(let argv, let stdin) = step.action {
                XCTAssertFalse(argv.contains { $0.contains("$6$fake") },
                               "hash leaked into argv: \(argv)")
                if argv.contains("useradd") { XCTAssertEqual(stdin, "$6$fake") }
            }
        }
        XCTAssertFalse(render(s).contains("$6$fake"), "hash leaked into the rendered list")
    }

    func testTheLoaderIsTakenFromWhatWeInstalledNotFromTheLiveSystem() {
        // The installed machine must boot the loader that matches its own
        // kernel. Copying /boot/loader.efi from the running installer works
        // right up until the medium and the sets are different versions.
        let s = try! compile(goodPlan(), on: machine())
        let cp = s.first { if case .run(let a, _) = $0.action {
            return a.first == "cp" && a.last!.hasSuffix("BOOTX64.efi") }; return false }
        guard case .run(let argv, _)? = cp?.action else { return XCTFail("no loader copy") }
        XCTAssertEqual(argv[1], "/mnt/boot/loader.efi")
    }

    func testTheLabelsWeWriteIntoFstabAreLabelsTheMachineWillHave() {
        // fstab names /dev/gpt/<pool>swap, and GEOM only creates that provider
        // if the disk-ident class has not consumed the disk first. Booting an
        // install without this line produced a machine with no swap and one
        // line about it in the log. The two halves have to agree, so they are
        // checked together.
        let p = goodPlan(pool: "tank")
        XCTAssertTrue(fstab(p).contains("/dev/gpt/tankswap"))
        XCTAssertTrue(loaderConf(p).contains("kern.geom.label.disk_ident.enable=\"0\""),
                      "fstab names a GPT label that may not exist on the installed machine")
    }

    private let macPro = MachineIdentity(maker: "Apple Inc.", product: "MacPro6,1")
    private let msi = MachineIdentity(maker: "Micro-Star International Co., Ltd.",
                                      product: "MS-7D25")

    func testAMacProStillGetsItsPowerFaultWorkaround() {
        // A 2013 Mac Pro's internal PCIe bridges report a power fault that never
        // clears, and pcib(4) re-logs it forever: the console scrolls and nothing
        // else on it can be read. The live medium sets this too, but that only
        // gets the install done — the machine we just wrote has its own
        // loader.conf, and it is a loader tunable, so a shell on the installed
        // system is too late to fix it.
        XCTAssertTrue(loaderConf(goodPlan(), machine: macPro)
                        .contains("hw.pci.enable_pcie_hp=\"0\""),
                      "the installed Mac Pro would scroll Power Fault Detected on its first boot")
    }

    func testEveryOtherMachineNoLongerInheritsIt() {
        // **This is the pass.** It used to be written to every machine, because
        // nothing could ask what machine it was on. A workaround for somebody
        // else's PCIe bridges has no business in the loader.conf of a board that
        // has none.
        XCTAssertFalse(loaderConf(goodPlan(), machine: msi).contains("enable_pcie_hp"))
    }

    func testAMachineThatWillNotSayWhatItIsDoesNotGetIt() {
        // The deliberate direction to fail in. Omitting it costs a Mac Pro a
        // scrolling console — visible, and recoverable by reinstalling from a
        // medium that still sets it. Adding it everywhere costs a silent,
        // permanent change to machines nobody examined.
        XCTAssertFalse(loaderConf(goodPlan(), machine: nil).contains("enable_pcie_hp"))
    }

    func testTheRestOfLoaderConfIsUnchangedEitherWay() {
        // The positive control: the quirk is the only thing that varies, so a
        // bug that emptied loader.conf would not pass the two tests above.
        for m in [macPro, msi, nil] {
            let c = loaderConf(goodPlan(), machine: m)
            XCTAssertTrue(c.contains("zfs_load=\"YES\""), "\(String(describing: m))")
            XCTAssertTrue(c.contains("kern.geom.label.disk_ident.enable=\"0\""))
            XCTAssertTrue(c.contains("vfs.root.mountfrom="))
        }
    }

    func testAPlainFreeBSDInstallDoesNotStartADesktopItDoesNotHave() {
        // The rule is derived from the sets, not assumed: install base and
        // kernel and you get base and kernel, with nothing in rc.conf about a
        // desktop that is not there.
        let plain = goodPlan()
        XCTAssertFalse(plain.installsDesktop)
        XCTAssertFalse(rcConf(plain).contains("abyss_desktop"))
    }

    /// **An installed desktop starts at the login window** (PHASE16 §6.2):
    /// the daemon runs it (`--greeter`), and nobody's session starts unasked.
    func testInstallingTheDesktopStartsTheLoginWindow() {
        let accounts = [Account(name: "guest", passwordHash: "$6$g"),
                        Account(name: "jkane", passwordHash: "$6$j", groups: ["wheel"])]
        let p = InstallPlan(disk: "ada0", sets: ["base.txz", "kernel.txz", InstallPlan.desktopSet],
                            accounts: accounts)
        XCTAssertTrue(p.installsDesktop)
        XCTAssertFalse(p.autoLogin, "automatic login is never the default")
        let rc = rcConf(p)
        XCTAssertTrue(rc.contains("abyss_loginwindow_enable=\"YES\""), rc)
        XCTAssertTrue(rc.contains("abyss_loginwindow_flags=\"--greeter\""), rc)
        XCTAssertFalse(rc.contains("abyss_desktop"), "no session at boot without a password: \(rc)")
        // The login window's own account is made, and it is nobody's to log in as.
        let steps = (try? compile(p, on: machine())) ?? []
        let made = steps.compactMap { step -> [String]? in
            if case .run(let argv, _) = step.action { return argv }; return nil
        }.first { $0.contains("_loginwindow") }
        XCTAssertNotNil(made)
        XCTAssertTrue(made?.contains("/usr/sbin/nologin") == true)
        XCTAssertTrue(made?.contains("no") == true, "no password: \(made ?? [])")
    }

    /// Automatic login, chosen: the owner's session at boot — the
    /// administrator, not merely the first account — and no login window.
    func testAutomaticLoginIsAChoiceAndStartsTheOwnersDesktop() {
        let p = InstallPlan(disk: "ada0", sets: ["base.txz", InstallPlan.desktopSet],
                            accounts: [Account(name: "guest", passwordHash: "$6$g"),
                                       Account(name: "jkane", passwordHash: "$6$j", groups: ["wheel"])],
                            autoLogin: true)
        let rc = rcConf(p)
        XCTAssertTrue(rc.contains("abyss_desktop_enable=\"YES\""), rc)
        XCTAssertTrue(rc.contains("abyss_desktop_user=\"jkane\""), rc)
        XCTAssertFalse(rc.contains("--greeter"), rc)
        // Asked for with nobody to log in as: the login window, not a desktop
        // for an account that does not exist.
        let nobody = InstallPlan(disk: "ada0", sets: ["base.txz", InstallPlan.desktopSet],
                                 rootPasswordHash: "$6$r", autoLogin: true)
        XCTAssertFalse(rcConf(nobody).contains("abyss_desktop"))
        XCTAssertTrue(rcConf(nobody).contains("--greeter"))
    }

    /// System Preferences' privileged half (PHASE14 P14.3) starts for the
    /// administrator the machine was installed for — and not at all when there
    /// is none, because it would admit nobody (§6.1), and a root service that
    /// refuses every caller is only a root service.
    func testTheSettingsHelperStartsForTheAdministratorAndOnlyForOne() {
        let admin = InstallPlan(disk: "ada0", sets: ["base.txz", InstallPlan.desktopSet],
                                accounts: [Account(name: "guest", passwordHash: "$6$g"),
                                           Account(name: "jkane", passwordHash: "$6$j", groups: ["wheel"])])
        let rc = rcConf(admin)
        XCTAssertTrue(rc.contains("abyss_settings_enable=\"YES\""), rc)
        XCTAssertTrue(rc.contains("abyss_settings_admin=\"jkane\""), rc)

        let noAdmin = InstallPlan(disk: "ada0", sets: ["base.txz", InstallPlan.desktopSet],
                                  rootPasswordHash: "$6$r",
                                  accounts: [Account(name: "guest", passwordHash: "$6$g")])
        XCTAssertFalse(rcConf(noAdmin).contains("abyss_settings"), rcConf(noAdmin))
        XCTAssertFalse(rcConf(goodPlan()).contains("abyss_settings"), "no desktop, no settings helper")
    }

    func testTheFilesWeWriteSayWhereTheRootIs() {
        let p = goodPlan(pool: "tank")
        XCTAssertTrue(loaderConf(p).contains("vfs.root.mountfrom=\"zfs:tank/ROOT/default\""))
        XCTAssertTrue(rcConf(p).contains("zfs_enable=\"YES\""))
        // And fstab must NOT carry the root: ZFS mounts it, and an entry here is
        // how a machine ends up mounting its root twice.
        XCTAssertFalse(fstab(p).contains("tank/ROOT"))
        XCTAssertTrue(fstab(p).contains("/dev/gpt/tankswap"))
    }

    func testPartitionLabelsCarryThePoolNameSoTheLiveMediumDoesNotCollide() {
        // /dev/gpt/swap on the installer's own medium and /dev/gpt/swap on the
        // disk being installed are the same name, and the second one to appear
        // simply does not.
        let s = try! compile(goodPlan(pool: "abyss"), on: machine())
        let labels = s.flatMap { step -> [String] in
            guard case .run(let a, _) = step.action, let i = a.firstIndex(of: "-l"),
                  i + 1 < a.count else { return [] }
            return [a[i + 1]]
        }
        XCTAssertEqual(labels, ["abyssesp", "abyssswap", "abysszfs"])
    }

    // MARK: - The golden list

    func testTheStepListIsWhatItWasLastTimeSomebodyLookedAtIt() {
        // A golden test over the exact commands we run at somebody's disk. Its
        // job is not to be right — it is to make a change to any of this show up
        // in a diff and have to be defended.
        let p = InstallPlan(disk: "ada0", poolName: "abyss",
                            distDirectory: "/usr/freebsd-dist",
                            hostname: "jaguar", timezone: "America/Chicago",
                            keymap: "us.kbd", rootPasswordHash: "$6$root",
                            accounts: [Account(name: "jkane", fullName: "J Kane",
                                               passwordHash: "$6$user",
                                               groups: ["wheel", "operator"],
                                               shell: "/bin/sh")],
                            // The confirmation, because this fixture erases an
                            // occupied disk on purpose. Without it the compile
                            // is refused — which is itself the guard working.
                            eraseExistingData: true)
        // **On a Mac Pro, and erasing a disk that already has something on it.**
        // Two deliberate choices, both to keep the *longest and most dangerous*
        // shape in the diff: the loader.conf with the power-fault workaround, and
        // the partition table being destroyed rather than added to. The
        // conditionals themselves are pinned by the tests above and below; this
        // is the one that makes a change to the destructive sequence have to be
        // defended.
        let occupied = DiskInventory(disks: [Disk(name: "ada0", bytes: 64 << 30,
                                                  description: "QEMU HARDDISK",
                                                  partitionKinds: ["efi", "ntfs"],
                                                  freeBytes: 1 << 20,
                                                  hasPartitionTable: true)],
                                     machine: macPro)
        let text = render(try! compile(p, on: occupied))
        XCTAssertEqual(text, InstallTests.goldenStepList,
                       "the step list changed:\n\(text)")
    }
}

extension InstallTests {
    /// The step list for the plan in `testTheStepListIsWhatItWasLastTimeSomebodyLookedAtIt`.
    /// Regenerate deliberately, never by pasting whatever the test printed.
    static let goldenStepList = """
1. clear any existing partition table [destructive] [may fail]
   $ gpart destroy -F ada0
2. create the GPT [destructive]
   $ gpart create -s gpt ada0
3. add the EFI system partition [destructive]
   $ gpart add -a 1m -s 260M -t efi -l abyssesp ada0
4. add swap [destructive]
   $ gpart add -a 1m -s 2048M -t freebsd-swap -l abyssswap ada0
5. add the pool partition [destructive]
   $ gpart add -a 1m -t freebsd-zfs -l abysszfs ada0
6. format the EFI partition [destructive]
   $ newfs_msdos -F 32 -c 1 /dev/gpt/abyssesp
7. create the pool [destructive]
   $ zpool create -f -o altroot=/mnt -o cachefile=/tmp/abyss-install-zpool.cache -O compress=lz4 -O atime=off -O mountpoint=none abyss /dev/gpt/abysszfs
8. create abyss/ROOT
   $ zfs create -o mountpoint=none abyss/ROOT
9. create abyss/ROOT/default
   $ zfs create -o mountpoint=/ -o canmount=noauto abyss/ROOT/default
10. mount the new root
   $ zfs mount abyss/ROOT/default
11. create abyss/home
   $ zfs create -o mountpoint=/home abyss/home
12. create abyss/tmp
   $ zfs create -o mountpoint=/tmp -o exec=on -o setuid=off abyss/tmp
13. create abyss/usr
   $ zfs create -o mountpoint=/usr -o canmount=off abyss/usr
14. create abyss/usr/ports
   $ zfs create -o setuid=off abyss/usr/ports
15. create abyss/usr/src
   $ zfs create abyss/usr/src
16. create abyss/var
   $ zfs create -o mountpoint=/var -o canmount=off abyss/var
17. create abyss/var/audit
   $ zfs create -o exec=off -o setuid=off abyss/var/audit
18. create abyss/var/crash
   $ zfs create -o exec=off -o setuid=off abyss/var/crash
19. create abyss/var/log
   $ zfs create -o exec=off -o setuid=off abyss/var/log
20. create abyss/var/mail
   $ zfs create -o atime=on abyss/var/mail
21. create abyss/var/tmp
   $ zfs create -o setuid=off abyss/var/tmp
22. mark the boot environment
   $ zpool set bootfs=abyss/ROOT/default abyss
23. extract base.txz
   $ tar -xpf /usr/freebsd-dist/base.txz -C /mnt
24. extract kernel.txz
   $ tar -xpf /usr/freebsd-dist/kernel.txz -C /mnt
25. make the ESP mount point
   $ mkdir -p /mnt/boot/efi
26. mount the EFI partition
   $ mount -t msdosfs /dev/gpt/abyssesp /mnt/boot/efi
27. make EFI/BOOT
   $ mkdir -p /mnt/boot/efi/EFI/BOOT
28. install the boot loader
   $ cp /mnt/boot/loader.efi /mnt/boot/efi/EFI/BOOT/BOOTX64.efi
29. make /boot/zfs
   $ mkdir -p /mnt/boot/zfs
30. write the pool cache
   $ zpool set cachefile=/tmp/abyss-install-zpool.cache abyss
31. install the pool cache
   $ cp /tmp/abyss-install-zpool.cache /mnt/boot/zfs/zpool.cache
32. write loader.conf
   > /mnt/boot/loader.conf (644)
     | # Written by the AbyssBSD installer.
     | zfs_load="YES"
     | vfs.root.mountfrom="zfs:abyss/ROOT/default"
     | boot_serial="YES"
     | comconsole_speed="115200"
     | console="comconsole,vidconsole"
     | kern.geom.label.disk_ident.enable="0"
     | hw.pci.enable_pcie_hp="0"
33. write rc.conf
   > /mnt/etc/rc.conf (644)
     | # Written by the AbyssBSD installer.
     | zfs_enable="YES"
     | hostname="jaguar"
     | ifconfig_DEFAULT="DHCP"
     | keymap="us.kbd"
34. write fstab
   > /mnt/etc/fstab (644)
     | # Device	Mountpoint	FStype	Options	Dump	Pass#
     | /dev/gpt/abyssswap	none	swap	sw	0	0
35. set the time zone to America/Chicago
   $ cp /mnt/usr/share/zoneinfo/America/Chicago /mnt/etc/localtime
36. set the root password
   $ pw -R /mnt usermod root -H 0
   < (on stdin, kept out of argv)
37. create the account jkane
   $ pw -R /mnt useradd -n jkane -m -s /bin/sh -H 0 -c 'J Kane' -G wheel,operator
   < (on stdin, kept out of argv)
38. unmount the EFI partition [may fail]
   $ umount /mnt/boot/efi
39. export the pool
   $ zpool export abyss

"""

    /// PHASE16 P16.1: a machine that installs the desktop starts the
    /// authenticator — for every account, administrator or not.
    func testTheAuthenticatorStartsWheneverTheDesktopIsInstalled() {
        let desktop = InstallPlan(disk: "ada0", sets: ["base.txz", InstallPlan.desktopSet],
                                  accounts: [Account(name: "guest", passwordHash: "$6$g")])
        XCTAssertTrue(rcConf(desktop).contains("abyss_loginwindow_enable=\"YES\""), rcConf(desktop))
        let plain = InstallPlan(disk: "ada0", sets: ["base.txz"],
                                accounts: [Account(name: "guest", passwordHash: "$6$g")])
        XCTAssertFalse(rcConf(plain).contains("abyss_loginwindow"), "a plain FreeBSD gets no desktop services")
    }
}
