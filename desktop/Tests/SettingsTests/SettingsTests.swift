// Settings tests — the helper's thinking half, and the runner's promise
// (PHASE14 P14.3).
//
// As `de/install`'s: a plan is a value, its steps are a value, and every
// refusal runs on a machine with no rc.conf to change. The runner's one
// promise — a plan that fails half-way leaves rc.conf exactly as it was — is
// tested where it can be: on FreeBSD by a real apply to a scratch file, and on
// Linux, where `sysrc` does not exist, by the failure that proves it.

import XCTest
import CurrentIPC
@testable import Settings
@testable import SettingsWire
@testable import SettingsRun

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class SettingsTests: XCTestCase {

    // MARK: - Plans compile to exact steps

    func testPowerdOnCompilesToItsVariablesAndARestart() throws {
        let steps = try Settings.compile(.energy(EnergyPlan(powerd: true, onAC: .maximum, onBattery: .adaptive)))
        XCTAssertEqual(steps, [
            .rcConf(key: "powerd_enable", value: "YES"),
            .rcConf(key: "powerd_flags", value: "-a max -b adaptive"),
            .service(name: "powerd", action: "onerestart", mayFail: false),
        ])
        XCTAssertEqual(steps[1].command(rcConf: "/etc/rc.conf"),
                       ["sysrc", "-f", "/etc/rc.conf", "powerd_flags=-a max -b adaptive"])
    }

    /// Off: stopping what may not be running is allowed to fail, and the
    /// policy is removed rather than left behind for the next person to find.
    func testPowerdOffRemovesItsPolicyAndMayFailToStop() throws {
        let steps = try Settings.compile(.energy(EnergyPlan(powerd: false)))
        XCTAssertEqual(steps, [
            .rcConf(key: "powerd_enable", value: "NO"),
            .rcConf(key: "powerd_flags", value: nil),
            .service(name: "powerd", action: "onestop", mayFail: true),
        ])
        XCTAssertEqual(steps[1].command(rcConf: "/x"), ["sysrc", "-f", "/x", "-x", "powerd_flags"])
        XCTAssertTrue(Settings.render(steps).contains("$ sysrc -f /etc/rc.conf powerd_enable=NO"))
    }

    func testTheMachinesPowerdIsReadBackAsAPlan() {
        XCTAssertEqual(EnergyPlan.from(enable: "YES", flags: "-a max -b min"),
                       EnergyPlan(powerd: true, onAC: .maximum, onBattery: .minimum))
        XCTAssertEqual(EnergyPlan.from(enable: "NO", flags: ""), EnergyPlan(powerd: false))
        XCTAssertEqual(EnergyPlan.from(enable: nil, flags: nil), EnergyPlan(powerd: false),
                       "unset is FreeBSD's default: off")
        XCTAssertEqual(EnergyPlan.from(enable: "YES", flags: "-a turbo -i 50"), EnergyPlan(powerd: true),
                       "flags it does not understand are not guessed at")
    }

    // MARK: - The wire refuses what it does not understand

    func testAPlanCrossesTheWireIntact() throws {
        let plan = SettingsPlan.energy(EnergyPlan(powerd: true, onAC: .minimum, onBattery: .hiadaptive))
        var m = Msg()
        SettingsWire.encode(plan, into: &m)
        XCTAssertEqual(try SettingsWire.decodePlan(m).get(), plan)
    }

    func testTheWireRefusesInWordsRatherThanGuessing() {
        func refusal(_ fields: [(String, String)], powerd: Bool? = true) -> String? {
            var m = Msg()
            for (k, v) in fields { m.set(k, v) }
            if let p = powerd { m.set("energy.powerd", p) }
            if case .failure(let r) = SettingsWire.decodePlan(m) { return r.message }
            return nil
        }
        XCTAssertEqual(refusal([]), "the request names no kind of plan")
        XCTAssertEqual(refusal([("kind", "sound")]), "there is no sound plan (there is: energy, network)")
        XCTAssertEqual(refusal([("kind", "energy")], powerd: nil), "an energy plan must say whether powerd runs")
        XCTAssertTrue(refusal([("kind", "energy"), ("energy.ac", "turbo")])?.hasPrefix("powerd has no mode turbo") ?? false)
    }

    func testEventsCrossTheWireIntact() {
        let events: [SettingsEvent] = [
            .starting(index: 1, total: 3, what: "set x"), .ok(index: 1),
            .failed(index: 2, what: "stop", why: "not running", ignored: true),
            .finished(ok: false, error: "because"),
        ]
        for e in events { XCTAssertEqual(SettingsWire.decodeEvent(SettingsWire.encode(e)), e) }
    }

    // MARK: - Who may change the machine

    func testAnAdministratorIsAMemberOfTheGroupAndNobodyElseIs() {
        let me = getuid()
        guard let gr = getgrgid(getgid()), let name = gr.pointee.gr_name.map({ String(cString: $0) }) else {
            return XCTFail("no group for this process")
        }
        XCTAssertTrue(Authority.isMember(uid: me, of: name), "a user's primary group counts")
        XCTAssertFalse(Authority.isMember(uid: me, of: "abyss-no-such-group-\(getpid())"))
    }

    /// **On Linux the helper refuses, and says why** (§6.4) — a positive control,
    /// not a skip; on FreeBSD it does not.
    func testTheHelperRefusesAMachineThatIsNotFreeBSD() {
        let s = SettingsService(authority: Authority(allowed: getuid()))
        #if os(FreeBSD)
        XCTAssertNil(s.platformRefusal)
        #else
        XCTAssertTrue(s.platformRefusal?.contains("not FreeBSD") ?? false)
        #endif
    }

    // MARK: - The runner's promise

    private func scratch() -> String {
        var t = Array("/tmp/abyss-settings-XXXXXX".utf8CString)
        return t.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
    }
    private func read(_ path: String) -> String? {
        guard let f = fopen(path, "r") else { return nil }
        defer { fclose(f) }
        var out = "", buf = [CChar](repeating: 0, count: 4096)
        while fgets(&buf, 4096, f) != nil { out += String(cString: buf) }
        return out
    }

    /// Dry run: every step reported, nothing written — not even a staged copy.
    func testADryRunReportsEveryStepAndWritesNothing() throws {
        let dir = scratch(), rc = dir + "/rc.conf"
        defer { unlink(rc); rmdir(dir) }
        let original = "hostname=\"abyss\"\n"
        let f = fopen(rc, "w")!; fputs(original, f); fclose(f)
        var events: [SettingsEvent] = []
        let ok = Runner.apply(try Settings.compile(.energy(EnergyPlan(powerd: true))),
                              rcConf: rc, dryRun: true) { events.append($0) }
        XCTAssertTrue(ok)
        XCTAssertEqual(events.filter { if case .ok = $0 { return true }; return false }.count, 3)
        XCTAssertEqual(read(rc), original)
        XCTAssertNil(read(rc + ".abyss-staged"))
    }

    /// The promise: a plan that fails half-way leaves rc.conf exactly as it
    /// was, and no staged copy behind. On FreeBSD, a real apply to a scratch
    /// file shows the other half — the change lands, all of it.
    func testRcConfIsReplacedWholeOrNotAtAll() throws {
        let dir = scratch(), rc = dir + "/rc.conf"
        defer { unlink(rc); unlink(rc + ".abyss-staged"); rmdir(dir) }
        let original = "hostname=\"abyss\"\npowerd_flags=\"-a max\"\n"
        let f = fopen(rc, "w")!; fputs(original, f); fclose(f)
        var events: [SettingsEvent] = []
        let ok = Runner.apply(try Settings.compile(.energy(EnergyPlan(powerd: false))),
                              rcConf: rc, dryRun: false) { events.append($0) }
        XCTAssertNil(read(rc + ".abyss-staged"), "a staged copy was left behind")
        #if os(FreeBSD)
        XCTAssertTrue(ok, "\(events)")
        let now = read(rc) ?? ""
        XCTAssertTrue(now.contains("powerd_enable=\"NO\""), now)
        XCTAssertFalse(now.contains("powerd_flags"), "the policy was not removed: \(now)")
        XCTAssertTrue(now.contains("hostname=\"abyss\""), "the rest of rc.conf was not kept: \(now)")
        #else
        // No sysrc here: the first write fails, and the file is untouched.
        XCTAssertFalse(ok)
        XCTAssertEqual(read(rc), original, "a failed plan changed rc.conf")
        guard case .finished(false, let why)? = events.last else { return XCTFail("\(events)") }
        XCTAssertTrue(why.contains("sysrc: not found"), why)
        #endif
    }

    /// **The reason for staging.** A plan whose second write fails must leave
    /// the first one unwritten too: on FreeBSD the second variable's name is
    /// one `sysrc` refuses, after the first write has succeeded in the staged
    /// copy. A runner that wrote straight into rc.conf passes the test above
    /// and fails this one.
    func testAPlanThatFailsHalfWayLeavesRcConfAsItWas() {
        let dir = scratch(), rc = dir + "/rc.conf"
        defer { unlink(rc); unlink(rc + ".abyss-staged"); rmdir(dir) }
        let original = "hostname=\"abyss\"\n"
        let f = fopen(rc, "w")!; fputs(original, f); fclose(f)
        var events: [SettingsEvent] = []
        let ok = Runner.apply([.rcConf(key: "abyss_first", value: "1"),
                               .rcConf(key: "not a variable", value: "x")],
                              rcConf: rc, dryRun: false) { events.append($0) }
        XCTAssertFalse(ok, "\(events)")
        XCTAssertEqual(read(rc), original, "the first write reached rc.conf though the plan failed")
        XCTAssertNil(read(rc + ".abyss-staged"), "a staged copy was left behind")
        #if os(FreeBSD)
        XCTAssertTrue(events.contains(.ok(index: 0)), "the first write did succeed, in the staged copy")
        #endif
    }

    // MARK: - Network (P14.4)

    private func ip(_ s: String) -> IPv4 { IPv4(s)! }

    func testAnIPv4AddressIsParsedStrictly() {
        XCTAssertEqual(IPv4("192.168.1.10")?.description, "192.168.1.10")
        for bad in ["192.168.1", "192.168.1.256", "192.168.01.1", "1.2.3.4.5", "a.b.c.d", "", " 1.2.3.4"] {
            XCTAssertNil(IPv4(bad), bad)
        }
        XCTAssertEqual(IPv4("255.255.255.0")?.prefixLength, 24)
        XCTAssertEqual(IPv4("255.255.254.0")?.prefixLength, 23)
        XCTAssertNil(IPv4("255.0.255.0")?.prefixLength, "not contiguous: not a mask")
        XCTAssertEqual(IPv4.mask(prefix: 20).description, "255.255.240.0")
    }

    func testAManualAddressCompilesToIfconfigRouterNameServersAndARestart() throws {
        let plan = NetworkPlan(interface: "em0",
                               ipv4: .manual(address: ip("10.0.0.5"), prefix: 24, router: ip("10.0.0.1")),
                               dns: [ip("1.1.1.1"), ip("9.9.9.9")])
        XCTAssertEqual(try Settings.compile(.network(plan)), [
            .rcConf(key: "ifconfig_em0", value: "inet 10.0.0.5 netmask 255.255.255.0"),
            .rcConf(key: "defaultrouter", value: "10.0.0.1"),
            .setVar(.resolvconf, key: "name_servers", value: "1.1.1.1 9.9.9.9"),
            .service(name: "netif", action: ["restart", "em0"], mayFail: false),
            .service(name: "routing", action: ["restart"], mayFail: false),
            .tool(argv: ["resolvconf", "-u"], mayFail: false),
        ])
    }

    func testDHCPDropsTheRouterAndTheNameServersAPersonSet() throws {
        let steps = try Settings.compile(.network(NetworkPlan(interface: "igc0", ipv4: .dhcp)))
        XCTAssertEqual(Array(steps.prefix(3)), [
            .rcConf(key: "ifconfig_igc0", value: "SYNCDHCP"),
            .rcConf(key: "defaultrouter", value: nil),
            .setVar(.resolvconf, key: "name_servers", value: nil),
        ])
        XCTAssertEqual(steps[2].command(path: { "/x/\($0.rawValue)" }),
                       ["sysrc", "-f", "/x/resolvconf.conf", "-x", "name_servers"])
    }

    /// Each refusal, by its words — a pane shows them as they are.
    func testANetworkPlanIsRefusedInWords() {
        func refused(_ n: NetworkPlan) -> [String] { Settings.problems(.network(n)).map(\.message) }
        func manual(_ a: String, _ p: Int, _ r: String? = nil) -> NetworkPlan {
            NetworkPlan(interface: "em0", ipv4: .manual(address: ip(a), prefix: p, router: r.map(ip)))
        }
        XCTAssertEqual(refused(NetworkPlan(interface: "lo0", ipv4: .dhcp)), ["lo0 is not a wired interface's name"])
        XCTAssertEqual(refused(NetworkPlan(interface: "em", ipv4: .dhcp)), ["em is not a wired interface's name"])
        XCTAssertEqual(refused(NetworkPlan(interface: "", ipv4: .dhcp)), ["no interface is not a wired interface's name"])
        XCTAssertEqual(refused(manual("10.0.0.0", 24)), ["10.0.0.0 is the network's own address, not a host's"])
        XCTAssertEqual(refused(manual("10.0.0.255", 24)), ["10.0.0.255 is the network's broadcast address"])
        XCTAssertEqual(refused(manual("10.0.0.5", 24, "10.0.1.1")),
                       ["the router 10.0.1.1 is not on 10.0.0.5's network (/24) — it could not be reached"])
        XCTAssertEqual(refused(manual("10.0.0.5", 24, "10.0.0.5")), ["the router cannot be this machine's own address"])
        XCTAssertEqual(refused(manual("127.0.0.5", 24)), ["127.0.0.5 cannot be an interface's address"])
        XCTAssertEqual(refused(manual("10.0.0.5", 31)), ["a /31 network is not one a wired interface is given (8 to 30)"])
        XCTAssertEqual(refused(NetworkPlan(interface: "em0", ipv4: .dhcp,
                                           dns: ["1.1.1.1", "1.0.0.1", "8.8.8.8", "9.9.9.9"].map(ip))),
                       ["4 name servers: the resolver uses three at most"])
        XCTAssertTrue(refused(manual("10.0.0.5", 24, "10.0.0.1")).isEmpty)
    }

    func testTheMachinesNetworkIsReadBackAsAPlan() {
        XCTAssertEqual(NetworkPlan.from(interface: "em0", ifconfig: "SYNCDHCP", router: "NO", nameServers: nil),
                       NetworkPlan(interface: "em0", ipv4: .dhcp))
        XCTAssertEqual(NetworkPlan.from(interface: "em0", ifconfig: nil, router: nil, nameServers: "1.1.1.1"),
                       NetworkPlan(interface: "em0", ipv4: .dhcp, dns: [ip("1.1.1.1")]),
                       "an interface rc.conf does not name is on ifconfig_DEFAULT's DHCP")
        XCTAssertEqual(NetworkPlan.from(interface: "em0", ifconfig: "inet 10.0.0.5 netmask 255.255.255.0",
                                        router: "10.0.0.1", nameServers: ""),
                       NetworkPlan(interface: "em0", ipv4: .manual(address: ip("10.0.0.5"), prefix: 24,
                                                                   router: ip("10.0.0.1"))))
        XCTAssertNil(NetworkPlan.from(interface: "em0", ifconfig: "inet6 fe80::1 prefixlen 64", router: nil, nameServers: nil),
                     "a line this cannot show is not guessed at")
    }

    func testANetworkPlanCrossesTheWireAndABadAddressDoesNot() throws {
        let plan = SettingsPlan.network(NetworkPlan(interface: "vtnet0",
            ipv4: .manual(address: ip("192.168.7.9"), prefix: 23, router: ip("192.168.6.1")),
            dns: [ip("192.168.6.1")]))
        var m = Msg()
        SettingsWire.encode(plan, into: &m)
        XCTAssertEqual(try SettingsWire.decodePlan(m).get(), plan)

        var bad = Msg()
        bad.set("kind", "network"); bad.set("network.interface", "em0"); bad.set("network.mode", "manual")
        bad.set("network.address", "10.0.0.5"); bad.set("network.netmask", "255.0.255.0")
        guard case .failure(let r) = SettingsWire.decodePlan(bad) else { return XCTFail("a bad mask crossed") }
        XCTAssertEqual(r.message, "255.0.255.0 is not a subnet mask")
    }

    /// Two files, one promise: both land, or neither.
    func testTwoFilesAreStagedAndReplacedTogether() throws {
        let dir = scratch(), rc = dir + "/rc.conf", rv = dir + "/resolvconf.conf"
        defer { for f in [rc, rv, rc + ".abyss-staged", rv + ".abyss-staged"] { unlink(f) }; rmdir(dir) }
        let rcBefore = "hostname=\"abyss\"\n", rvBefore = "# resolvconf\n"
        var f = fopen(rc, "w")!; fputs(rcBefore, f); fclose(f)
        f = fopen(rv, "w")!; fputs(rvBefore, f); fclose(f)
        let steps = try Settings.compile(.network(NetworkPlan(interface: "em0",
            ipv4: .manual(address: ip("10.0.0.5"), prefix: 24, router: ip("10.0.0.1")), dns: [ip("1.1.1.1")])))
        var events: [SettingsEvent] = []
        let ok = Runner.apply(steps, path: { $0 == .rcConf ? rc : rv }, dryRun: false, writeOnly: true) {
            events.append($0)
        }
        XCTAssertNil(read(rc + ".abyss-staged")); XCTAssertNil(read(rv + ".abyss-staged"))
        #if os(FreeBSD)
        XCTAssertTrue(ok, "\(events)")
        XCTAssertTrue(read(rc)?.contains("ifconfig_em0=\"inet 10.0.0.5 netmask 255.255.255.0\"") ?? false, read(rc) ?? "")
        XCTAssertTrue(read(rc)?.contains("defaultrouter=\"10.0.0.1\"") ?? false)
        XCTAssertTrue(read(rv)?.contains("name_servers=\"1.1.1.1\"") ?? false, read(rv) ?? "")
        XCTAssertEqual(events.filter { if case .skipped = $0 { return true }; return false }.count, 3,
                       "write-only: netif, routing and resolvconf -u are skipped, and said to be")
        #else
        XCTAssertFalse(ok)
        XCTAssertEqual(read(rc), rcBefore); XCTAssertEqual(read(rv), rvBefore)
        #endif
    }
}
