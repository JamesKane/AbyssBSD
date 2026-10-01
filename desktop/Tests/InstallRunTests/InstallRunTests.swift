// InstallRun tests — the doing half.
//
// Two things are worth testing here and they are different in kind. The
// **parsers** are pure functions over text, and the text is captured from a real
// FreeBSD machine rather than invented, because a parser checked against output
// somebody wrote by hand is a parser checked against an assumption. The
// **runner** is real processes, which is fine on any machine: `echo` and `false`
// exist everywhere, and a step list of harmless commands exercises exactly the
// same code path as one that repartitions a disk.
//
// What is NOT here is an install. That needs a disk, and it is
// `abyss/tests/live-install.sh`.

import XCTest
import CurrentIPC
@testable import Install
@testable import InstallRun
@testable import InstallWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class InstallRunTests: XCTestCase {

    // MARK: - Captured from the FreeBSD build VM, verbatim

    /// `geom disk list` — note `descr: (null)` (virtio) and a CD with no media.
    static let geomText = """
    Geom name: vtbd0
    Providers:
    1. Name: vtbd0
       Mediasize: 85899345920 (80G)
       Sectorsize: 512
       Mode: r3w3e7
       descr: (null)
       ident: (null)
       rotationrate: unknown
       fwsectors: 63
       fwheads: 16

    Geom name: vtbd1
    Providers:
    1. Name: vtbd1
       Mediasize: 69632 (68K)
       Sectorsize: 512
       Mode: r0w0e0
       descr: (null)
       ident: (null)

    Geom name: cd0
    Providers:
    1. Name: cd0
       Mediasize: 0 (0B)
       Sectorsize: 2048
       Mode: r0w0e0

    """

    /// `mount -p` — the first column is a *device* for msdosfs and a *dataset*
    /// for ZFS, which is the whole reason the pool map is needed.
    static let mountText = """
    zroot/ROOT/default\t/\t\t\tzfs\trw,nfsv4acls \t0 0
    devfs\t\t\t/dev\t\t\tdevfs\trw\t\t0 0
    /dev/gpt/efiboot0\t/boot/efi\t\tmsdosfs\trw\t\t2 2
    zroot/home\t\t/home\t\t\tzfs\trw,nfsv4acls \t0 0
    zroot/var/log\t\t/var/log\t\tzfs\trw,noexec,nosuid,nfsv4acls \t0 0
    """

    /// `glabel status -s` — without this, `/dev/gpt/efiboot0` cannot be traced
    /// to a disk and vtbd0 would look free.
    static let labelText = """
    gpt/bootfs  N/A  vtbd0p1
    gptid/c1eea66a-cc1b-11f0-067b-ff9d86f8dced  N/A  vtbd0p1
    gpt/efiboot0  N/A  vtbd0p2
    gpt/swapfs  N/A  vtbd0p3
    gpt/config-drive  N/A  vtbd0s4
    iso9660/CIDATA  N/A  vtbd1
    """

    /// `zpool list -Hv zroot` — the pool's own line first, then its vdevs,
    /// distinguished only by a leading tab.
    static let zpoolText = """
    zroot\t78.5G\t12.2G\t66.3G\t-\t-\t5%\t15%\t1.00x\tONLINE\t-
    \tvtbd0p5\t79.0G\t12.2G\t66.3G\t-\t-\t5%\t15.5%\t-\tONLINE
    """

    private func realMachine() -> DiskInventory {
        inventory(geom: Self.geomText, mounts: Self.mountText, labels: Self.labelText,
                  poolVdevs: ["zroot": parseZpoolVdevs(Self.zpoolText)])
    }

    // MARK: - Parsing a real machine

    func testTheDisksAndTheirSizesComeOutOfGeom() {
        let disks = parseGeomDiskList(Self.geomText)
        XCTAssertEqual(disks.map(\.name), ["vtbd0", "vtbd1", "cd0"])
        XCTAssertEqual(disks[0].bytes, 85_899_345_920)
        XCTAssertEqual(disks[2].bytes, 0, "an empty CD drive is a disk of no size")
        // "(null)" is what virtio reports; showing that to a person is worse
        // than showing nothing.
        XCTAssertEqual(disks[0].descr, "")
    }

    func testAZFSRootIsTracedToItsDiskThroughThePool() throws {
        // `mount -p` says the root is `zroot/ROOT/default` — a dataset, not a
        // device. Only the pool's vdev list connects that to vtbd0, and getting
        // this wrong means offering the user the disk they are running from.
        let inv = realMachine()
        let vtbd0 = try XCTUnwrap(inv.disk(named: "vtbd0"))
        XCTAssertTrue(vtbd0.holdsRunningRoot)
        XCTAssertTrue(vtbd0.mountedAt.contains("/"))
        XCTAssertTrue(vtbd0.mountedAt.contains("/home"))
    }

    func testAGptLabelMountIsTracedToItsDisk() throws {
        // /dev/gpt/efiboot0 names no disk at all. Without glabel it resolves to
        // nothing and the disk holding /boot/efi looks free.
        XCTAssertEqual(diskOf(provider: "/dev/gpt/efiboot0",
                              labels: parseLabelComponents(Self.labelText),
                              disks: ["vtbd0", "vtbd1", "cd0"]), "vtbd0")
        XCTAssertTrue(try XCTUnwrap(realMachine().disk(named: "vtbd0"))
                        .mountedAt.contains("/boot/efi"))
    }

    func testTheOtherDisksAreLeftAlone() throws {
        let inv = realMachine()
        // vtbd1 is the cloud-init seed: iso9660-labelled but not mounted.
        XCTAssertEqual(try XCTUnwrap(inv.disk(named: "vtbd1")).mountedAt, [])
        XCTAssertFalse(try XCTUnwrap(inv.disk(named: "vtbd1")).holdsRunningRoot)
        XCTAssertEqual(try XCTUnwrap(inv.disk(named: "cd0")).mountedAt, [])
        XCTAssertEqual(inv.importedPools, ["zroot"])
    }

    func testALongerDiskNameIsNotClaimedByAShorterOne() {
        // `ada1` must not swallow `ada10p1`, which it does with a naive prefix
        // match — and the consequence is telling somebody the wrong disk is busy.
        XCTAssertEqual(diskOf(provider: "ada10p1", labels: [:],
                              disks: ["ada1", "ada10"]), "ada10")
        XCTAssertEqual(diskOf(provider: "ada1p1", labels: [:],
                              disks: ["ada1", "ada10"]), "ada1")
    }

    func testAVdevKindIsNotADevice() {
        // A mirrored pool lists `mirror-0` as a parent of the real providers.
        let text = "tank\t1T\t-\t-\t-\nmirror-0\t1T\t-\nt\tada0p3\t1T\t-\n\tada1p3\t1T\t-"
        XCTAssertFalse(parseZpoolVdevs(text).contains("mirror-0"))
    }

    func testTheEraseConfirmationSurvivesTheWire() {
        // **A guard that stops at the socket is one that silently never lifts —
        // and worse, one that looks like it did.** The person says "erase it" in
        // the unprivileged half; the privileged half is where that permission is
        // spent, and the two are different processes.
        for erase in [true, false] {
            var m = Msg()
            Wire.encode(InstallPlan(disk: "ada0", eraseExistingData: erase), into: &m)
            XCTAssertEqual(Wire.decodePlan(m).eraseExistingData, erase)
        }
    }

    func testAPlanFromAnOlderClientDefaultsToNotErasing() {
        // No `erase` key at all: the safe direction is the one that refuses.
        var m = Msg()
        m.set("disk", "ada0")
        XCTAssertFalse(Wire.decodePlan(m).eraseExistingData)
    }

    func testEveryFactARefusalIsMadeOfSurvivesTheWire() {
        // **The GUI judges disks against whatever crossed this socket.** Four
        // fields did not, so every disk arrived looking empty: no objection on
        // any row, and an erase sheet that could never open. The service refused
        // correctly the whole time — which is why nothing was ever eaten, and
        // also why nothing noticed.
        let inv = DiskInventory(disks: [
            Disk(name: "nda1", bytes: 931 << 30, description: "Samsung 990 PRO",
                 mountedAt: ["/data"], holdsRunningRoot: false,
                 existingPools: ["zroot", "tank"],
                 partitionKinds: ["efi", "freebsd-swap", "freebsd-zfs"],
                 freeBytes: 728_576, hasPartitionTable: true),
        ], importedPools: ["zroot"],
           machine: MachineIdentity(maker: "Micro-Star", product: "MS-7D25"))

        var m = Msg()
        Wire.encode(inv, into: &m)
        let back = Wire.decodeInventory(m)
        XCTAssertEqual(back, inv, "the inventory is not what was sent")
        // ...and spelled out, because `Equatable` passing is not the same as the
        // fields being there when somebody adds a fifth.
        let d = back.disk(named: "nda1")!
        XCTAssertEqual(d.existingPools, ["zroot", "tank"])
        XCTAssertEqual(d.partitionKinds, ["efi", "freebsd-swap", "freebsd-zfs"])
        XCTAssertEqual(d.freeBytes, 728_576)
        XCTAssertTrue(d.hasPartitionTable)
        XCTAssertEqual(back.machine?.product, "MS-7D25")
    }

    func testADiskWithNothingOnItSurvivesTheWireAsEmptyNotAsMissing() {
        // The empty case has to round-trip too, or "no partitions" and "the
        // sender was old" become the same value.
        let inv = DiskInventory(disks: [Disk(name: "ada0", bytes: 1 << 30)])
        var m = Msg(); Wire.encode(inv, into: &m)
        let d = Wire.decodeInventory(m).disk(named: "ada0")!
        XCTAssertEqual(d.partitionKinds, [])
        XCTAssertFalse(d.hasPartitionTable)
    }

    // MARK: - What is on a disk, and where it is not

    /// `gpart show`, captured from the bring-up machine on 2026-09-05. Three
    /// disks, three shapes: a GPT full of Windows, an **MBR** whose rows carry an
    /// extra `[active]`, and a GPT full of FreeBSD. Invented text would not have
    /// contained the MBR row that breaks a naive column split.
    static let gpartText = """
    =>        34  1953525101  nda0  GPT  (932G)
              34        2014        - free -  (1.0M)
            2048      204800     1  efi  (100M)
          206848       32768     2  ms-reserved  (16M)
          239616  1951543296     3  ms-basic-data  (931G)
      1951782912     1738752     4  ms-recovery  (849M)
      1953521664        3471        - free -  (1.7M)

    =>       63  468862065  ada0  MBR  (224G)
             63       1985        - free -  (993K)
           2048     204800     1  ntfs  [active]  (100M)
         206848  467603877     2  ntfs  (223G)
      467810725       1627        - free -  (814K)
      467812352    1046528     3  !39  (511M)
      468858880       3248        - free -  (1.6M)

    =>        40  1953525095  nda1  GPT  (932G)
              40      532480     1  efi  (260M)
          532520        1024     2  freebsd-boot  (512K)
          533544         984        - free -  (492K)
          534528     4194304     3  freebsd-swap  (2.0G)
         4728832  1948794880     4  freebsd-zfs  (929G)
      1953523712        1423        - free -  (712K)
    """

    func testGpartShowIsParsedIntoContentsAndGaps() {
        let l = parseGpartShow(Self.gpartText)
        XCTAssertEqual(l["nda0"]?.scheme, "GPT")
        XCTAssertEqual(l["nda0"]?.kinds, ["efi", "ms-reserved", "ms-basic-data", "ms-recovery"])
        XCTAssertEqual(l["nda1"]?.kinds, ["efi", "freebsd-boot", "freebsd-swap", "freebsd-zfs"])
        XCTAssertEqual(l.keys.sorted(), ["ada0", "nda0", "nda1"])
    }

    func testAnMBRRowsExtraActiveFlagIsNotReadAsAPartitionType() {
        // `2048  204800  1  ntfs  [active]  (100M)` — a naive parse that took a
        // fixed column would report the type of the boot partition as
        // "[active]". Only the MBR disk on that machine has this shape.
        XCTAssertEqual(parseGpartShow(Self.gpartText)["ada0"]?.scheme, "MBR")
        XCTAssertEqual(parseGpartShow(Self.gpartText)["ada0"]?.kinds, ["ntfs", "ntfs", "!39"])
    }

    func testTheLargestGapIsContiguousAndNotATotal() {
        // An install needs room in one piece. nda0's gaps are 2014 and 3471
        // sectors; the answer is 3471, not 5485.
        XCTAssertEqual(parseGpartShow(Self.gpartText)["nda0"]?.largestFreeSectors, 3471)
        XCTAssertEqual(parseGpartShow(Self.gpartText)["nda1"]?.largestFreeSectors, 1423)
    }

    func testEveryDiskOnTheBringUpMachineIsFull() {
        // The finding this redesign came from: three disks, ~2 TB between them,
        // and the largest contiguous gap anywhere is 1.7 MiB. Not one of them
        // can take an install without destroying something — which is a fact
        // about that machine, and the installer now says so instead of offering
        // them as clean targets.
        let l = parseGpartShow(Self.gpartText)
        for d in ["nda0", "nda1", "ada0"] {
            let bytes = (l[d]?.largestFreeSectors ?? 0) * 512
            XCTAssertLessThan(bytes, 4 << 20, "\(d) has \(bytes) bytes free")
        }
    }

    func testADiskWithNoTableParsesAsNothingRatherThanFailing() {
        XCTAssertTrue(parseGpartShow("").isEmpty)
        XCTAssertTrue(parseGpartShow("gpart: No such geom: ada9.").isEmpty)
    }

    func testSectorSizeComesFromTheDiskAndNotFromAnAssumption() {
        // `gpart show` counts in the provider's sectors. Assuming 512 on a 4Kn
        // disk under-reports free space eightfold.
        let text = """
        Geom name: nda0
        Providers:
        1. Name: nda0
           Mediasize: 1000204886016 (932G)
           Sectorsize: 4096
           descr: WD_BLACK SN850X 1000GB
        """
        XCTAssertEqual(parseGeomDiskList(text).first?.sectorBytes, 4096)
    }

    // MARK: - Pools that are here but not imported

    /// `zpool import`, captured verbatim in the build VM on a machine carrying
    /// three pool shapes at once — a mirror, a single device, and one on a
    /// partition. Invented text would only have exercised the shape I happened
    /// to imagine, which is this file's standing rule.
    static let zpoolImportText = """
      pool: capmirror
        id: 15841513621478346893
     state: ONLINE
    action: The pool can be imported using its name or numeric identifier.
    config:

    \tcapmirror   ONLINE
    \t  mirror-0  ONLINE
    \t    md0     ONLINE
    \t    md1     ONLINE

      pool: capsingle
        id: 2816878795490912526
     state: ONLINE
    action: The pool can be imported using its name or numeric identifier.
    config:

    \tcapsingle   ONLINE
    \t  md2       ONLINE

      pool: abyssp52
        id: 3911584180507105418
     state: ONLINE
    action: The pool can be imported using its name or numeric identifier.
    config:

    \tabyssp52    ONLINE
    \t  vtbd2p3   ONLINE
    """

    /// The scratch disk, captured from the same machine: an installed system
    /// that nothing has mounted. This is the live-medium case in miniature.
    static let geomWithScratchText = geomText + """

    Geom name: vtbd2
    Providers:
    1. Name: vtbd2
       Mediasize: 12884901888 (12G)
       Sectorsize: 512
       Mode: r0w0e0
       descr: (null)
       ident: (null)
       rotationrate: unknown
       fwsectors: 63
       fwheads: 16

    """

    static let labelWithScratchText = labelText + """

    gpt/abyssp52esp  N/A  vtbd2p1
    gpt/abyssp52swap  N/A  vtbd2p2
    gpt/abyssp52zfs  N/A  vtbd2p3
    """

    func testImportablePoolsAreParsedIntoTheirDevices() {
        let got = parseImportablePools(Self.zpoolImportText)
        XCTAssertEqual(got["capmirror"]?.sorted(), ["md0", "md1"],
                       "a mirror's two leaves are both real devices")
        XCTAssertEqual(got["capsingle"], ["md2"])
        XCTAssertEqual(got["abyssp52"], ["vtbd2p3"])
        XCTAssertEqual(got.keys.sorted(), ["abyssp52", "capmirror", "capsingle"])
    }

    func testTheVdevKindRowIsNotMistakenForADevice() {
        // `mirror-0` is a structural row of the config tree. Taking it for a
        // device would attribute the pool to a disk that does not exist.
        XCTAssertFalse(parseImportablePools(Self.zpoolImportText)["capmirror"]!
                        .contains("mirror-0"))
        XCTAssertTrue(isVdevTypeNode("mirror-0"))
        XCTAssertTrue(isVdevTypeNode("raidz2-1"))
        XCTAssertTrue(isVdevTypeNode("logs"))
        // ...and a real device whose name merely starts the same way is not one.
        XCTAssertFalse(isVdevTypeNode("mirrordisk0"))
        XCTAssertFalse(isVdevTypeNode("da0"))
        XCTAssertFalse(isVdevTypeNode("vtbd2p3"))
    }

    func testAScanThatFoundNothingParsesAsNothing() {
        // "No pools" is the answer that lets an install proceed, so it has to be
        // reachable — and distinguishable from a parse that went wrong.
        XCTAssertTrue(parseImportablePools("").isEmpty)
        XCTAssertTrue(parseImportablePools("no pools available to import").isEmpty)
    }

    func testAnUnimportedPoolIsAttributedToItsDisk() {
        // The live-medium case, end to end: the target disk carries somebody's
        // whole installed system, and NOTHING else in the inventory says so.
        let inv = inventory(geom: Self.geomWithScratchText, mounts: Self.mountText,
                            labels: Self.labelWithScratchText,
                            poolVdevs: ["zroot": parseZpoolVdevs(Self.zpoolText)],
                            importablePools: parseImportablePools(Self.zpoolImportText))
        let target = inv.disk(named: "vtbd2")
        XCTAssertEqual(target?.existingPools, ["abyssp52"], "vtbd2p3 belongs to vtbd2")
        XCTAssertEqual(target?.mountedAt, [], "and it is not mounted —")
        XCTAssertEqual(target?.holdsRunningRoot, false, "— nor is it the running root.")
        XCTAssertFalse(inv.importedPools.contains("abyssp52"),
                       "scanning must not make it look imported")
    }

    /// A kernel with no ZFS has no imported pools — and `zpool` is not asked,
    /// because asking makes it try to load the module, which a non-root caller
    /// cannot (the Q8B, 2026-10-01). With ZFS present, a failing `zpool list`
    /// still fails the probe: that is a machine whose pools we could not see.
    func testNoZFSMeansNoPoolsAndAFailingZpoolStillFails() throws {
        var asked = false
        XCTAssertEqual(try importedPoolNames(zfsPresent: false, list: { asked = true; return "zroot\n" }), [])
        XCTAssertFalse(asked, "zpool must not be run where there is no ZFS")
        XCTAssertEqual(try importedPoolNames(zfsPresent: true, list: { "zroot\nbackup\n" }), ["zroot", "backup"])
        XCTAssertThrowsError(try importedPoolNames(zfsPresent: true, list: {
            throw ProbeError.commandFailed("zpool list -H -o name", "internal error")
        }))
    }

    func testTheProbeRefusesLoudlyWhereItCannotWork() throws {
        // Not a skip. An installer whose disk discovery quietly does nothing on
        // the machine you develop on is one that ships broken.
        #if os(Linux)
        XCTAssertThrowsError(try probeMachine()) { e in
            guard case ProbeError.notSupported(let why) = e else {
                return XCTFail("expected notSupported, got \(e)")
            }
            XCTAssertTrue(why.contains("Linux"), why)
            XCTAssertTrue(why.contains("geom"), "it should say what it could not find: \(why)")
        }
        #else
        // On the target it must actually work, and find the disk we booted from.
        let inv = try probeMachine()
        XCTAssertFalse(inv.disks.isEmpty, "no disks found on a running FreeBSD")
        XCTAssertTrue(inv.disks.contains(where: \.holdsRunningRoot),
                      "nothing claims to hold the running root, so nothing would be refused")
        #endif
    }

    // MARK: - Who may command an installer

    func testTheKernelIsAskedWhoIsCalling() {
        var sv: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, sockStreamForTest, 0, &sv), 0)
        defer { close(sv[0]); close(sv[1]) }
        XCTAssertEqual(peerUID(of: sv[0]), geteuid())
        XCTAssertTrue(Authority(allowed: geteuid()).admits(sv[0]).ok)
    }

    func testAnotherUserIsRefusedAndToldWhy() {
        var sv: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, sockStreamForTest, 0, &sv), 0)
        defer { close(sv[0]); close(sv[1]) }
        let verdict = Authority(allowed: geteuid() &+ 1).admits(sv[0])
        XCTAssertFalse(verdict.ok)
        XCTAssertTrue(verdict.why.contains("\(geteuid())"), verdict.why)
    }

    func testAMechanismThatCannotIdentifyTheCallerSaysNo() {
        // A closed descriptor cannot name anybody. Failing *open* here would be
        // worse than having no check at all, because it would look like one.
        let bad: Int32 = -1
        XCTAssertNil(peerUID(of: bad))
        XCTAssertFalse(Authority(allowed: geteuid()).admits(bad).ok)
    }

    func testAnUnauthorisedCallerIsRefusedBeforeItsRequestIsEvenRead() {
        // There is no method on an installer that a caller who may not command
        // it should get to attempt, so the check is at the connection and not
        // per method.
        var sv: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, sockStreamForTest, 0, &sv), 0)
        defer { close(sv[0]); close(sv[1]) }
        let service = InstallService(authority: Authority(allowed: geteuid() &+ 1),
                                     dryRun: true,
                                     machine: { self.realMachine() })
        var request = Msg()
        request.set("method", "install")
        Wire.encode(InstallPlan(disk: "vtbd1"), into: &request)
        try? Current.send(request, on: sv[1])

        let note = service.serve(sv[0])
        XCTAssertTrue(note.hasPrefix("refused a caller"), note)
        XCTAssertEqual(service.installsRun, 0, "an install was started for a refused caller")
        let reply = try? Current.receive(on: sv[1])
        XCTAssertEqual(reply?.bool("ok"), false)
        XCTAssertTrue((reply?.string("error") ?? "").contains("may not command"), "\(reply as Any)")
    }

    // MARK: - The protocol

    func testAPlanSurvivesTheWire() {
        let p = InstallPlan(disk: "ada0", poolName: "tank", espBytes: 300 << 20,
                            swapBytes: 0, sets: ["base.txz"], distDirectory: "/d",
                            mountpoint: "/mnt", hostname: "h", timezone: "UTC",
                            keymap: "us.kbd", rootPasswordHash: "$6$r",
                            accounts: [Account(name: "a", fullName: "A Person",
                                               passwordHash: "$6$a",
                                               groups: ["wheel", "operator"],
                                               shell: "/bin/sh")])
        var m = Msg()
        Wire.encode(p, into: &m)
        XCTAssertEqual(Wire.decodePlan(m), p)
    }

    func testTheMachineSurvivesTheWire() {
        let inv = realMachine()
        var m = Msg()
        Wire.encode(inv, into: &m)
        XCTAssertEqual(Wire.decodeInventory(m), inv)
    }

    func testEveryProgressEventSurvivesTheWire() {
        let events: [RunEvent] = [
            .starting(index: 3, total: 41, what: "create the GPT", destructive: true),
            .ok(index: 3),
            .failed(index: 4, what: "add swap", why: "Device busy", ignored: true),
            .finished(ok: false, error: "it did not work"),
        ]
        for e in events { XCTAssertEqual(Wire.event(from: Wire.message(for: e)), e) }
        // And something that is not an event decodes as one rather than as
        // garbage — the client uses exactly this to tell a refusal apart from
        // progress.
        var notAnEvent = Msg()
        notAnEvent.set("ok", false)
        XCTAssertNil(Wire.event(from: notAnEvent))
    }

    func testCheckRefusesTheDiskYouAreRunningFromOverTheWire() {
        var sv: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, sockStreamForTest, 0, &sv), 0)
        defer { close(sv[0]); close(sv[1]) }
        let service = InstallService(authority: Authority(allowed: geteuid()),
                                     dryRun: true, machine: { self.realMachine() })
        var request = Msg()
        request.set("method", "check")
        Wire.encode(InstallPlan(disk: "vtbd0", rootPasswordHash: "$6$x"), into: &request)
        try? Current.send(request, on: sv[1])
        _ = service.serve(sv[0])
        let reply = try? Current.receive(on: sv[1])
        XCTAssertEqual(reply?.bool("ok"), false)
        XCTAssertEqual(reply?.uint64("problems.count"), 1)
        XCTAssertTrue((reply?.string("problem.0") ?? "").contains("running from"),
                      "\(reply?.string("problem.0") ?? "")")
        XCTAssertNil(reply?.string("render"), "a refused plan must not come with a step list")
    }

    // MARK: - Running steps

    func testTheStepsRunInOrderAndEveryOneIsReported() {
        let steps = [
            Step.run(["echo", "one"], what: "the first", onFailure: "no"),
            Step.run(["echo", "two"], what: "the second", onFailure: "no"),
        ]
        var events: [RunEvent] = []
        let failure = execute(steps) { events.append($0) }
        XCTAssertNil(failure)
        XCTAssertEqual(events, [
            .starting(index: 0, total: 2, what: "the first", destructive: false),
            .ok(index: 0),
            .starting(index: 1, total: 2, what: "the second", destructive: false),
            .ok(index: 1),
            .finished(ok: true, error: ""),
        ])
    }

    func testItStopsAtTheFirstRealFailure() throws {
        // An installer that carries on past a failed `gpart add` finishes with a
        // confident summary and a machine that will not boot.
        let steps = [
            Step.run(["false"], what: "the one that fails",
                     onFailure: "the partition could not be created"),
            Step.run(["echo", "should not happen"], what: "the one after", onFailure: "no"),
        ]
        var events: [RunEvent] = []
        // `XCTUnwrap` rather than `!`: a force-unwrap kills the whole test
        // process, so one broken thing hides every test after it — which is
        // exactly what an injected fault revealed here.
        let failure = try XCTUnwrap(execute(steps) { events.append($0) })
        XCTAssertTrue(failure.contains("the partition could not be created"), failure)
        XCTAssertFalse(events.contains(.starting(index: 1, total: 2,
                                                 what: "the one after", destructive: false)),
                       "it kept going after a failure")
    }

    func testAStepThePlanAllowedToFailDoesNotStopTheInstall() {
        // `gpart destroy` on a disk with no partition table at all is a success
        // for our purposes, and the plan is what says so.
        let steps = [
            Step.run(["false"], what: "clear the old table", onFailure: "no", mayFail: true),
            Step.run(["echo", "carried on"], what: "the one after", onFailure: "no"),
        ]
        var events: [RunEvent] = []
        XCTAssertNil(execute(steps) { events.append($0) })
        XCTAssertTrue(events.contains { if case .failed(_, _, _, let ignored) = $0 {
            return ignored }; return false })
        XCTAssertTrue(events.contains(.ok(index: 1)))
    }

    func testWhatACommandSaidIsWhatTheUserIsTold() throws {
        // The plan's sentence, with the kernel's underneath it. A failure
        // reported as "exited 1" is a failure nobody can act on.
        let steps = [Step.run(["sh", "-c", "echo 'Device busy' >&2; exit 1"],
                              what: "add swap", onFailure: "the swap partition failed")]
        let failure = try XCTUnwrap(execute(steps) { _ in })
        XCTAssertTrue(failure.contains("the swap partition failed"), failure)
        XCTAssertTrue(failure.contains("Device busy"), failure)
    }

    func testACommandThatDoesNotExistFailsLikeAnyOther() throws {
        let failure = try XCTUnwrap(
            execute([Step.run(["abyss-no-such-command-anywhere"],
                              what: "run nothing", onFailure: "it is not there")]) { _ in })
        XCTAssertTrue(failure.contains("it is not there"), failure)
    }

    func testStdinReachesTheCommandAndStaysOutOfArgv() {
        // This is how a password hash gets to `pw` without every process on the
        // machine being able to read it out of `ps`.
        let steps = [Step.run(["sh", "-c", "read line; test \"$line\" = secret"],
                              what: "feed a secret", onFailure: "the hash did not arrive",
                              stdin: "secret")]
        XCTAssertNil(execute(steps) { _ in })
        // ...and without it, the same command fails, so the test is not passing
        // for some other reason.
        let noStdin = [Step.run(["sh", "-c", "read line; test \"$line\" = secret"],
                                what: "feed nothing", onFailure: "no hash")]
        XCTAssertNotNil(execute(noStdin) { _ in })
    }

    func testAStepNeverInheritsTheInstallersOwnStdin() {
        // A command that decides to ask a question would otherwise hang the
        // install forever with nothing on screen to say why.
        let steps = [Step.run(["sh", "-c", "read line; echo \"$line\""],
                              what: "try to ask", onFailure: "it read something",
                              mayFail: true)]
        var events: [RunEvent] = []
        _ = execute(steps) { events.append($0) }
        XCTAssertTrue(events.contains(.finished(ok: true, error: "")),
                      "a command that reads stdin did not get EOF")
    }

    func testAFileStepWritesTheContentAndTheMode() throws {
        let dir = "/tmp/abyss-installrun-\(getpid())"
        XCTAssertEqual(mkdir(dir, 0o755), 0)
        defer { unlink(dir + "/loader.conf"); rmdir(dir) }
        let steps = [Step(.write(path: dir + "/loader.conf",
                                 contents: "zfs_load=\"YES\"\n", mode: 0o644),
                          what: "write loader.conf", onFailure: "could not write it")]
        XCTAssertNil(execute(steps) { _ in })
        var st = stat()
        XCTAssertEqual(stat(dir + "/loader.conf", &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o644, "the mode the plan asked for was not applied")
        let fd = open(dir + "/loader.conf", O_RDONLY)
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 64) }
        XCTAssertEqual(String(decoding: buf[0..<max(0, n)], as: UTF8.self), "zfs_load=\"YES\"\n")
    }

    func testWritingWhereThereIsNoDirectoryFailsRatherThanInventingOne() throws {
        // The plan makes its directories explicitly. A runner that quietly
        // mkdir -p's would hide a step list that forgot to.
        let steps = [Step(.write(path: "/tmp/abyss-no-such-dir-\(getpid())/x",
                                 contents: "x", mode: 0o644),
                          what: "write into nowhere", onFailure: "the directory is missing")]
        let failure = try XCTUnwrap(execute(steps) { _ in })
        XCTAssertTrue(failure.contains("the directory is missing"), failure)
    }

    func testADryRunReportsEverythingAndDoesNothing() {
        // Same events, no side effects — which is what lets a caller be
        // developed, and its confirmations exercised, against a machine it is
        // not touching.
        let witness = "/tmp/abyss-dryrun-\(getpid())"
        unlink(witness)
        let steps = [
            Step.run(["sh", "-c", "touch \(witness)"], what: "leave a trace",
                     onFailure: "no", destructive: true),
            Step(.write(path: witness + ".2", contents: "x", mode: 0o644),
                 what: "write a file", onFailure: "no"),
        ]
        var wet: [RunEvent] = []
        var dry: [RunEvent] = []
        XCTAssertNil(execute(steps, dryRun: true) { dry.append($0) })
        XCTAssertNotEqual(access(witness, F_OK), 0, "a dry run touched the disk")
        XCTAssertNotEqual(access(witness + ".2", F_OK), 0, "a dry run wrote a file")
        XCTAssertNil(execute(steps, dryRun: false) { wet.append($0) })
        defer { unlink(witness); unlink(witness + ".2") }
        XCTAssertEqual(access(witness, F_OK), 0, "the control did not run either")
        XCTAssertEqual(dry, wet, "a dry run must be indistinguishable from the outside")
    }
}

/// `SOCK_STREAM` imports as `__socket_type` on Linux and `Int32` on the BSDs
/// (HANDOFF §2.32) — the same one-line fork `CurrentIPC` carries.
#if canImport(Glibc) && os(Linux)
let sockStreamForTest = Int32(SOCK_STREAM.rawValue)
#else
let sockStreamForTest = SOCK_STREAM
#endif
