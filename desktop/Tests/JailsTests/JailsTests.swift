// Jails tests (PHASE18 P18.1): the classes as data, and the plans made of them.
//
// Each guarantee is checked twice: a sound plan has no violations, and the
// same plan broken in exactly that way is refused (the fault injection lives in
// the test, so a check that stopped checking fails here).

import XCTest
@testable import Jails
import PoolConfig

final class JailsTests: XCTestCase {
    let me = JailUser(name: "abyss", uid: 1001, gid: 1001)
    let hostHome = "/home/abyss"

    func cls(_ n: String) -> JailClass { JailClass.shipped.first { $0.name == n }! }

    // MARK: - classes

    func testTheShippedClasses() {
        XCTAssertEqual(JailClass.shipped.map(\.name), ["app", "app-gl", "app-net"])
        XCTAssertEqual(cls("app").network, .none)
        XCTAssertEqual(cls("app").devices, [])
        XCTAssertEqual(cls("app-gl").devices, ["dri"])
        XCTAssertEqual(cls("app-net").network, .host)
        XCTAssertTrue(JailClass.shipped.allSatisfy { $0.system == JailClass.baseSystem })
    }

    func testAFileSectionOverridesOnlyWhatItSays() {
        let c = Config.parse("""
        [app]
        devices = dsp
        [editor]
        network = host
        wayland = no
        """)
        let t = JailClass.table(c)
        let app = t.first { $0.name == "app" }!
        XCTAssertEqual(app.devices, ["dsp"])
        XCTAssertEqual(app.network, .none, "an override keeps what it does not name")
        XCTAssertEqual(app.system, JailClass.baseSystem)
        let ed = t.first { $0.name == "editor" }!
        XCTAssertEqual(ed.network, .host)
        XCTAssertFalse(ed.wayland)
        XCTAssertEqual(t.filter { $0.name == "app" }.count, 1, "an override replaces, it does not duplicate")
    }

    func testAnUnknownNetworkWordKeepsTheSafeValue() {
        let t = JailClass.table(Config.parse("[app]\nnetwork = everything\n"))
        XCTAssertEqual(t.first { $0.name == "app" }!.network, .none)
    }

    // MARK: - the plan

    func testThePlanForApp() {
        let p = JailPlan.make(cls("app"), for: me)
        XCTAssertEqual(p.name, "abyss-1001-app")
        XCTAssertEqual(p.root, "/var/run/abyss-jails/1001/app")
        XCTAssertEqual(p.mounts.first?.kind, .tmpfs, "the root is a tmpfs, mounted first")
        XCTAssertEqual(p.mounts.filter { $0.kind == .nullfs && $0.readOnly }.map(\.target), JailClass.baseSystem)
        let home = p.mounts.first { $0.target == "/home/abyss" }!
        XCTAssertEqual(home.source, "/var/db/abyss-jails/abyss/app")
        XCTAssertFalse(home.readOnly)
        XCTAssertEqual(p.unhide, [])
        XCTAssertTrue(p.params.contains { $0 == ("ip4", "disable") })
        XCTAssertTrue(p.params.contains { $0 == ("devfs_ruleset", "4") })
        XCTAssertEqual(p.env.first { $0.0 == "XDG_RUNTIME_DIR" }?.1, "/run/user")
        XCTAssertEqual(p.env.first { $0.0 == "WAYLAND_DISPLAY" }?.1, "wayland-0")
        XCTAssertNil(p.homeDataset)
        XCTAssertFalse(p.copies.contains { $0.target == "/etc/resolv.conf" }, "no network, no resolver")
        XCTAssertEqual(p.violations(for: cls("app"), hostHome: hostHome), [])
    }

    func testTheOtherShippedClassesAreSound() {
        let gl = JailPlan.make(cls("app-gl"), for: me, pool: "zroot")
        XCTAssertTrue(gl.unhide.contains("dri/*"))
        XCTAssertEqual(gl.homeDataset, "zroot/abyss/jails/abyss/app-gl")
        XCTAssertEqual(gl.violations(for: cls("app-gl"), hostHome: hostHome), [])
        let net = JailPlan.make(cls("app-net"), for: me)
        XCTAssertTrue(net.params.contains { $0 == ("ip4", "inherit") })
        XCTAssertTrue(net.copies.contains { $0.target == "/etc/resolv.conf" })
        XCTAssertEqual(net.violations(for: cls("app-net"), hostHome: hostHome), [])
    }

    func testEtcKnowsTwoAccountsAndNoPasswords() {
        let p = JailPlan.make(cls("app"), for: me)
        let rows = p.accounts.split(separator: "\n")
        XCTAssertEqual(rows.map { $0.split(separator: ":")[0] }, ["root", "abyss"])
        XCTAssertTrue(rows.allSatisfy { $0.split(separator: ":")[1] == "*" })
        XCTAssertEqual(String(rows[1]), "abyss:*:1001:1001::0:0:abyss:/home/abyss:/bin/sh", "master.passwd form, for pwd_mkdb")
        XCTAssertFalse(p.files.contains { $0.path.contains("passwd") }, "passwd is pwd_mkdb's output, not a file of the plan")
        XCTAssertEqual(p.files.first { $0.path == "/etc/group" }?.contents, "wheel:*:0:root\nabyss:*:1001:\n",
                       "the person is in their own group only, not wheel")
        XCTAssertFalse(p.copies.contains { $0.source.hasPrefix("/etc/pwd") || $0.source.hasPrefix("/etc/spwd") },
                       "pwd.db is built from the generated passwd, not copied from the host's")
    }

    func testTheHomeIsTheOnlyWritableMountAndIsOwnedByThePerson() {
        let p = JailPlan.make(cls("app"), for: me)
        XCTAssertEqual(p.mounts.filter { $0.kind == .nullfs && !$0.readOnly }.map(\.target), ["/home/abyss"])
        let dir = p.dirs.first { $0.path == "/home/abyss" }!
        XCTAssertEqual(dir.uid, 1001)
        XCTAssertEqual(dir.mode, 0o700)
        XCTAssertEqual(p.dirs.first { $0.path == "/run/user" }!.uid, 1001)
        XCTAssertEqual(p.dirs.first { $0.path == "/tmp" }!.mode, 0o1777)
    }

    // MARK: - what no plan may do (each a fault injected into a sound plan)

    func assertRefused(_ p: JailPlan, _ c: JailClass? = nil, _ why: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        let v = p.violations(for: c ?? cls("app"), hostHome: hostHome)
        XCTAssertTrue(v.contains { $0.contains(why) }, "expected a violation containing '\(why)', got \(v)",
                      file: file, line: line)
    }

    func testAWritableSystemMountIsRefused() {
        var p = JailPlan.make(cls("app"), for: me)
        p.mounts[1].readOnly = false
        assertRefused(p, nil, "is writable from inside")
    }

    func testTheRealHomeIsRefusedHoweverItArrives() {
        var p = JailPlan.make(cls("app"), for: me)
        p.mounts.append(JailMount(kind: .nullfs, source: "/home/abyss/Documents", target: "/docs", readOnly: true))
        assertRefused(p, nil, "reaches the person's own home")
        var q = JailPlan.make(cls("app"), for: me)
        q.mounts.append(JailMount(kind: .nullfs, source: "/home", target: "/home2", readOnly: true))
        assertRefused(q, nil, "reaches the person's own home")
    }

    /// FreeBSD's UFS layout puts homes in /usr/home: there, mounting /usr is
    /// mounting every home. The plan must say so, not mount it.
    func testOnUFSWithHomesUnderUsrTheSystemMountIsRefused() {
        let p = JailPlan.make(cls("app"), for: me)
        let v = p.violations(for: cls("app"), hostHome: "/usr/home/abyss")
        XCTAssertTrue(v.contains { $0.contains("/usr reaches the person's own home") }, "\(v)")
    }

    func testAHomeElsewhereIsRefused() {
        var p = JailPlan.make(cls("app"), for: me)
        p.homeSource = "/home/abyss"
        if let i = p.mounts.firstIndex(where: { $0.target == "/home/abyss" }) { p.mounts[i].source = "/home/abyss" }
        assertRefused(p, nil, "is not under /var/db/abyss-jails")
    }

    func testSecretsAreRefused() {
        var p = JailPlan.make(cls("app"), for: me)
        p.copies.append(("/etc/master.passwd", "/etc/master.passwd"))
        assertRefused(p, nil, "/etc/master.passwd is copied into the jail")
        var q = JailPlan.make(cls("app"), for: me)
        q.files.append(("/etc/spwd.db", ""))
        assertRefused(q, nil, "/etc/spwd.db is written into the jail")
        var r = JailPlan.make(cls("app"), for: me)
        r.accounts = r.accounts.replacingOccurrences(of: "abyss:*:", with: "abyss:$6$salt$hash:")
        assertRefused(r, nil, "an account carries a password")
        var s = JailPlan.make(cls("app"), for: me)
        s.accounts = s.accounts.replacingOccurrences(of: ":1001:1001:", with: ":0:1001:")
        assertRefused(s, nil, "abyss has uid 0")
        var t = JailPlan.make(cls("app"), for: me)
        t.accounts = t.accounts.replacingOccurrences(of: "::0:0:abyss", with: ":abyss")
        assertRefused(t, nil, "not in master.passwd form")
    }

    func testANetworklessClassWithAnAddressIsRefused() {
        var p = JailPlan.make(cls("app"), for: me)
        p.params = p.params.map { $0.0 == "ip4" ? ("ip4", "inherit") : $0 }
        assertRefused(p, nil, "has no network, but the jail has an address")
    }

    func testAnotherRulesetOrRuntimeIsRefused() {
        var p = JailPlan.make(cls("app"), for: me)
        p.params = p.params.map { $0.0 == "devfs_ruleset" ? ("devfs_ruleset", "0") : $0 }
        assertRefused(p, nil, "the devfs ruleset is not 4")
        var q = JailPlan.make(cls("app"), for: me)
        q.env = q.env.map { $0.0 == "XDG_RUNTIME_DIR" ? ($0.0, "/var/run/abyss-abyss") : $0 }
        assertRefused(q, nil, "the runtime directory is /var/run/abyss-abyss")
    }

    func testAnUnknownDeviceIsRefusedNotPassedOn() {
        let c = JailClass(name: "odd", devices: ["dri", "mem"])
        let p = JailPlan.make(c, for: me)
        XCTAssertFalse(p.unhide.contains { $0.contains("mem") }, "an unknown device must not reach devfs")
        assertRefused(p, c, "unknown device 'mem'")
    }

    func testAStrangeSystemDirectoryIsRefused() {
        for dir in ["/", "/etc", "/root", "/var/db", "/var/run/abyss-jails/1002/app"] {
            let c = JailClass(name: "odd", system: JailClass.baseSystem + [dir])
            assertRefused(JailPlan.make(c, for: me), c, "\(dir) is not a system directory")
        }
    }

    func testUnderIsComponentWise() {
        XCTAssertTrue(JailPlan.under("/usr/local", "/usr"))
        XCTAssertTrue(JailPlan.under("/usr", "/usr"))
        XCTAssertFalse(JailPlan.under("/usrx", "/usr"))
        XCTAssertTrue(JailPlan.under("/anything", "/"))
    }
}
