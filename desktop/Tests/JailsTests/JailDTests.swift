// JailD tests (PHASE18 P18.2): the order a root is built and undone in, and
// the wire. Pure; the daemon itself is live-jaild.sh's, in the guest.

import XCTest
@testable import JailD
@testable import Jails
@testable import JailKeeper

final class JailDTests: XCTestCase {
    let me = JailUser(name: "abyss", uid: 1001, gid: 1001)
    let c = JailCommands()

    func steps(_ cls: String = "app", pool: String? = nil) -> (JailPlan, [JailStep]) {
        let p = JailPlan.make(JailClass.shipped.first { $0.name == cls }!, for: me, pool: pool)
        return (p, JailSteps.build(p, user: me))
    }

    func index(_ s: [JailStep], _ match: (JailStep) -> Bool, file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard let i = s.firstIndex(where: match) else { XCTFail("no such step", file: file, line: line); return -1 }
        return i
    }

    func isRun(_ s: JailStep, _ prefix: [String]) -> Bool {
        if case let .run(argv) = s { return Array(argv.prefix(prefix.count)) == prefix }
        return false
    }

    // MARK: - build

    func testTheTmpfsGoesOverTheRootBeforeAnythingIsMadeInIt() {
        let (p, s) = steps()
        let tmpfs = index(s) { isRun($0, [c.mount, "-t", "tmpfs"]) }
        let firstInside = index(s) {
            if case let .mkdir(path, _, _, _) = $0 { return path.hasPrefix(p.root + "/") }
            return false
        }
        XCTAssertLessThan(tmpfs, firstInside)
        XCTAssertEqual(s[0], .mkdir(p.root, uid: 0, gid: 0, mode: 0o755))
    }

    func testTheSystemIsMountedReadOnlyAndNosuidAndTheHomeWritableNosuid() {
        let (p, s) = steps()
        for dir in JailClass.baseSystem {
            XCTAssertTrue(s.contains(.run([c.mount, "-t", "nullfs", "-o", "ro,nosuid", dir, p.root + dir])), dir)
        }
        XCTAssertTrue(s.contains(.run([c.mount, "-t", "nullfs", "-o", "nosuid", p.homeSource, p.root + "/home/abyss"])))
        XCTAssertFalse(s.contains { if case let .run(a) = $0 { return a.contains("rw") }; return false })
    }

    func testDevfsGetsRuleset4AndOnlyTheNamedDevices() {
        let (p, s) = steps("app-gl")
        let dev = p.root + "/dev"
        let mount = index(s) { $0 == .run([self.c.mount, "-t", "devfs", "devfs", dev]) }
        let ruleset = index(s) { $0 == .run([self.c.devfs, "-m", dev, "ruleset", "4"]) }
        let apply = index(s) { $0 == .run([self.c.devfs, "-m", dev, "rule", "applyset"]) }
        let dri = index(s) { $0 == .run([self.c.devfs, "-m", dev, "rule", "apply", "path", "dri/*", "unhide"]) }
        XCTAssertLessThan(mount, ruleset); XCTAssertLessThan(ruleset, apply); XCTAssertLessThan(apply, dri)
        let (_, plain) = steps("app")
        XCTAssertFalse(plain.contains { isRun($0, [c.devfs]) && { if case let .run(a) = $0 { return a.contains("unhide") }; return false }($0) })
    }

    func testTheAccountsAreCompiledAndTheirSecretsDeletedBeforeTheJailExists() {
        let (p, s) = steps()
        let master = p.root + "/etc/master.passwd"
        let write = index(s) { $0 == .write(master, contents: p.accounts, mode: 0o600) }
        let mkdb = index(s) { $0 == .run([self.c.pwdMkdb, "-p", "-d", p.root + "/etc", master]) }
        let rmMaster = index(s) { $0 == .remove(master) }
        let rmSpwd = index(s) { $0 == .remove(p.root + "/etc/spwd.db") }
        XCTAssertLessThan(write, mkdb); XCTAssertLessThan(mkdb, rmMaster); XCTAssertLessThan(mkdb, rmSpwd)
        XCTAssertEqual(Set([rmMaster, rmSpwd]), Set([s.count - 2, s.count - 1]), "the last thing done, so nothing follows it in")
    }

    func testTheHomeIsMadeForThePersonAndADatasetComesFirstWhereThereIsAPool() {
        let (p, s) = steps(pool: "zroot")
        let ds = index(s) { $0 == .dataset("zroot/abyss/jails/abyss/app", mountpoint: p.homeSource) }
        let home = index(s) { $0 == .mkdir(p.homeSource, uid: 1001, gid: 1001, mode: 0o700) }
        XCTAssertLessThan(ds, home)
        let (_, ufs) = steps()
        XCTAssertFalse(ufs.contains { if case .dataset = $0 { return true }; return false })
    }

    func testDirectoriesInsideAreOwnedAsThePlanSays() {
        let (p, s) = steps()
        XCTAssertTrue(s.contains(.mkdir(p.root + "/home/abyss", uid: 1001, gid: 1001, mode: 0o700)))
        XCTAssertTrue(s.contains(.mkdir(p.root + "/run/user", uid: 1001, gid: 1001, mode: 0o700)))
        XCTAssertTrue(s.contains(.mkdir(p.root + "/tmp", uid: 0, gid: 0, mode: 0o1777)))
        XCTAssertTrue(s.contains(.mkdir(p.root + "/usr", uid: 0, gid: 0, mode: 0o755)))
    }

    // MARK: - teardown

    func testTeardownUnmountsDeepestFirstAndOnlyItsOwn() {
        let root = "/var/run/abyss-jails/1001/app"
        let mounted = ["/", "/home", root, root + "/usr", root + "/dev", root + "/home/abyss",
                       root + "/run/granted/1/a.txt", "/var/run/abyss-jails/1001/app-gl", "/var/run/abyss-jails/1001/app-gl/usr"]
        let s = JailSteps.teardown(root: root, mounted: mounted)
        let order = s.compactMap { step -> String? in if case let .run(a) = step { return a.last }; return nil }
        XCTAssertEqual(order.first, root + "/run/granted/1/a.txt")
        XCTAssertEqual(order.last, root, "the tmpfs last")
        XCTAssertEqual(Set(order), Set([root, root + "/usr", root + "/dev", root + "/home/abyss", root + "/run/granted/1/a.txt"]),
                       "nothing of app-gl's (a prefix of the name is not a parent)")
        XCTAssertEqual(s.last, .rmdir(root))
        XCTAssertTrue(s.dropLast().allSatisfy { isRun($0, [c.umount, "-f"]) })
    }

    // MARK: - grants (P18.4)

    func testAGrantIsOneFileInADirectoryOfItsOwnReadOnlyUnlessWritable() {
        let root = "/var/run/abyss-jails/1001/app"
        let ro = JailSteps.grant(root: root, n: 3, source: "/home/abyss/Documents/notes.txt", writable: false)
        XCTAssertEqual(ro, [
            .mkdir(root + "/run/granted/3", uid: 0, gid: 0, mode: 0o755),
            .write(root + "/run/granted/3/notes.txt", contents: "", mode: 0o644),
            .run([c.mount, "-t", "nullfs", "-o", "ro,nosuid", "/home/abyss/Documents/notes.txt", root + "/run/granted/3/notes.txt"]),
        ])
        let rw = JailSteps.grant(root: root, n: 4, source: "/home/abyss/a.txt", writable: true)
        XCTAssertEqual(rw.last, .run([c.mount, "-t", "nullfs", "-o", "nosuid", "/home/abyss/a.txt", root + "/run/granted/4/a.txt"]))
        XCTAssertEqual(JailSteps.grantPath(3, source: "/home/abyss/Documents/notes.txt"), "/run/granted/3/notes.txt")
    }

    func testRevokeUndoesAGrantInReverse() {
        let root = "/r"
        XCTAssertEqual(JailSteps.revoke(root: root, n: 2, source: "/h/x.txt"), [
            .run([c.umount, "-f", "/r/run/granted/2/x.txt"]), .remove("/r/run/granted/2/x.txt"), .rmdir("/r/run/granted/2"),
        ])
    }

    func testAGrantsNameCannotClimb() {
        XCTAssertEqual(JailSteps.grantName("/a/b.txt"), "b.txt")
        XCTAssertEqual(JailSteps.grantName("/"), "file")
        XCTAssertEqual(JailSteps.grantName("/a/.."), "file")
        XCTAssertEqual(JailSteps.grantName("/a/."), "file")
        XCTAssertFalse(JailSteps.grantPath(1, source: "/a/..").contains(".."))
    }

    // MARK: - the session's half (P18.5)

    func testALaunchsFileArgumentsAreThePersonsFilesOnly() {
        let files: [String: String] = ["/home/a/doc.txt": "/home/a/doc.txt", "/home/a/link": "/home/a/real.txt",
                                       "/usr/local/share/x.ui": "/usr/local/share/x.ui"]
        let got = LaunchFiles.indices(["/usr/local/bin/gedit", "--new", "/home/a/doc.txt", "relative.txt",
                                       "/home/a/link", "/usr/local/share/x.ui", "/home/a/missing", "/home/a/doc.txt"],
                                      system: JailClass.baseSystem, resolve: { files[$0] })
        XCTAssertEqual(got.map(\.0), [2, 4, 7], "absolute, existing, outside the system; never argv[0]")
        XCTAssertEqual(got.map(\.1), ["/home/a/doc.txt", "/home/a/real.txt", "/home/a/doc.txt"], "resolved")
    }

    // MARK: - the mount table

    func testMountTableParsesFstabLinesAndFindsLeftRoots() {
        let text = """
        zroot/ROOT/default\t/\tzfs\trw\t0 0
        devfs\t/dev\tdevfs\trw\t0 0
        tmpfs\t/var/run/abyss-jails/1001/app\ttmpfs\trw\t0 0
        /usr\t/var/run/abyss-jails/1001/app/usr\tnullfs\tro\t0 0
        /home/a\\040b\t/mnt/a\\040b\tnullfs\trw\t0 0
        /usr\t/var/run/abyss-jails/1002/app-net/usr\tnullfs\tro\t0 0
        """
        let pts = MountTable.points(text)
        XCTAssertEqual(pts.count, 6)
        XCTAssertEqual(pts[4], "/mnt/a b")
        XCTAssertEqual(MountTable.roots(under: "/var/run/abyss-jails", in: pts),
                       ["/var/run/abyss-jails/1001/app", "/var/run/abyss-jails/1002/app-net"])
        XCTAssertEqual(MountTable.jailName(root: "/var/run/abyss-jails/1002/app-net", base: "/var/run/abyss-jails"), "abyss-1002-app-net")
        XCTAssertNil(MountTable.jailName(root: "/var/run/abyss-jails/x/app", base: "/var/run/abyss-jails"))
    }

    // MARK: - the wire

    func testListsSurviveAnything() {
        let xs = ["zenity", "--text", "a b", "", "x=y\tz"]
        XCTAssertEqual(JailWire.unlist(JailWire.list(xs)), xs)
        XCTAssertEqual(JailWire.unlist([]), [])
    }

    func testTheCallerCannotMoveTheJailsHomeOrRuntime() {
        let plan = [("HOME", "/home/abyss"), ("XDG_RUNTIME_DIR", "/run/user"), ("PATH", "/bin")]
        let env = JailWire.environment(plan: plan, extra: ["HOME=/", "XDG_RUNTIME_DIR=/tmp", "LANG=en_US.UTF-8", "=x", "junk"])
        XCTAssertEqual(env, ["HOME=/home/abyss", "XDG_RUNTIME_DIR=/run/user", "PATH=/bin", "LANG=en_US.UTF-8"])
    }

    func testOnlyTheOwnerMayUseAJail() {
        XCTAssertTrue(JailWire.owns(1001, "abyss-1001-app"))
        XCTAssertFalse(JailWire.owns(1001, "abyss-10011-app"))
        XCTAssertFalse(JailWire.owns(100, "abyss-1001-app"))
        XCTAssertFalse(JailWire.owns(1001, "other-1001-app"))
    }
}
