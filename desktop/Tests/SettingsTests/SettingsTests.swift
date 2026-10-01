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

    // MARK: - Power profiles (P14.8b)

    /// The profile, powerd's own flags cleared so the profile chooses its mode,
    /// then applied as boot would.
    func testAPowerProfileCompilesToItsVariableClearedFlagsAndAStart() throws {
        let steps = try Settings.compile(.powerProfile(PowerProfilePlan(profile: .powerSaver)))
        XCTAssertEqual(steps, [
            .rcConf(key: "power_profile", value: "power-saver"),
            .rcConf(key: "powerd_flags", value: nil),
            .service(name: "power_profile", action: "start", mayFail: false),
        ])
    }

    /// powerd turned on under a profile runs with no flags, so the profile keeps
    /// choosing its mode; the per-source modes are not written.
    func testPowerdUnderAProfileRunsWithNoFlags() throws {
        let steps = try Settings.compile(.energy(EnergyPlan(powerd: true, onAC: .maximum, modesFromProfile: true)))
        XCTAssertEqual(steps[1], .rcConf(key: "powerd_flags", value: nil))
        var m = Msg()
        let plan = SettingsPlan.energy(EnergyPlan(powerd: true, modesFromProfile: true))
        SettingsWire.encode(plan, into: &m)
        XCTAssertEqual(try SettingsWire.decodePlan(m).get(), plan)
    }

    /// Read back through `sysrc -n`, which answers from the defaults: a profile
    /// is a plan; no variable at all is upstream FreeBSD, and is said in words.
    func testAPowerProfileIsReadBackOrTheBaseIsSaidToLackThem() {
        XCTAssertEqual(Settings.current(kind: "power-profile", values: ["power_profile": "performance"]),
                       .powerProfile(PowerProfilePlan(profile: .performance)))
        XCTAssertNil(Settings.unavailable(kind: "power-profile", values: ["power_profile": "balanced"]))
        XCTAssertNil(Settings.current(kind: "power-profile", values: [:]))
        XCTAssertEqual(Settings.unavailable(kind: "power-profile", values: [:]),
                       "this FreeBSD offers no power profiles — its rc.d/power_profile is the older AC-line script")
        XCTAssertEqual(Settings.unavailable(kind: "power-profile", values: ["power_profile": "NONE"]),
                       "power profiles are turned off on this machine (power_profile=NONE)")
        XCTAssertNotNil(Settings.unavailable(kind: "power-profile", values: ["power_profile": "turbo"]))
        XCTAssertNil(Settings.unavailable(kind: "energy", values: [:]))
        XCTAssertEqual(Settings.keys(for: "power-profile")?.map(\.key), ["power_profile"])
    }

    func testAPlanCrossesTheWireIntact() throws {
        for plan in [SettingsPlan.energy(EnergyPlan(powerd: true, onAC: .minimum, onBattery: .hiadaptive)),
                     .powerProfile(PowerProfilePlan(profile: .performance))] {
            var m = Msg()
            SettingsWire.encode(plan, into: &m)
            XCTAssertEqual(try SettingsWire.decodePlan(m).get(), plan)
        }
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
        XCTAssertEqual(refusal([("kind", "displays")]), "there is no displays plan (there is: energy, network, power-profile, sound, wifi)")
        XCTAssertEqual(refusal([("kind", "power-profile"), ("power-profile", "turbo")]),
                       "a power-profile plan must name power-saver, balanced or performance")
        XCTAssertEqual(refusal([("kind", "sound")]), "a sound plan must say which device is the default")
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

    // MARK: - Sound (P14.6b)

    func testTheDefaultDeviceCompilesToSysctlConfThenSysctl() throws {
        let steps = try Settings.compile(.sound(SoundPlan(defaultUnit: 1)))
        XCTAssertEqual(steps, [.setVar(.sysctlConf, key: "hw.snd.default_unit", value: "1"),
                               .tool(argv: ["sysctl", "hw.snd.default_unit=1"], mayFail: false)])
        XCTAssertEqual(steps[0].command { "/etc/" + $0.rawValue }, [], "sysrc cannot edit sysctl.conf; no command pretends to")
        let r = Settings.render(steps)
        XCTAssertTrue(r.contains("set hw.snd.default_unit=\"1\" in sysctl.conf\n   (the helper edits the file itself)"), r)
        XCTAssertTrue(r.contains("$ sysctl hw.snd.default_unit=1"), r)
        XCTAssertThrowsError(try Settings.compile(.sound(SoundPlan(defaultUnit: -1))))
    }

    func testSysctlConfIsEditedLineByLine() {
        let conf = "# kernel settings\nsecurity.bsd.see_other_uids=0\n hw.snd.default_unit = 0  # the card\nkern.foo=1\nhw.snd.default_unit=3\n"
        let set = Settings.editSysctlConf(conf, key: "hw.snd.default_unit", value: "1")
        XCTAssertEqual(set, "# kernel settings\nsecurity.bsd.see_other_uids=0\nhw.snd.default_unit=1\nkern.foo=1\n",
                       "the first assignment replaced in place, the later one (which would win) dropped, the rest kept")
        XCTAssertEqual(Settings.sysctlConfValue(conf, key: "hw.snd.default_unit"), "3", "the last one wins, as in sysctl(8)")
        XCTAssertEqual(Settings.sysctlConfValue(set, key: "hw.snd.default_unit"), "1")
        XCTAssertEqual(Settings.editSysctlConf("#x\n", key: "hw.snd.default_unit", value: "2"), "#x\nhw.snd.default_unit=2\n")
        XCTAssertEqual(Settings.editSysctlConf("", key: "a.b", value: "2"), "a.b=2\n")
        XCTAssertEqual(Settings.editSysctlConf(set, key: "hw.snd.default_unit", value: nil),
                       "# kernel settings\nsecurity.bsd.see_other_uids=0\nkern.foo=1\n")
        XCTAssertEqual(Settings.editSysctlConf("#hw.snd.default_unit=5\n", key: "hw.snd.default_unit", value: "1"),
                       "#hw.snd.default_unit=5\nhw.snd.default_unit=1\n", "a comment is not an assignment")
        XCTAssertNil(Settings.sysctlConfValue("#hw.snd.default_unit=5\n", key: "hw.snd.default_unit"))
    }

    func testTheDefaultDeviceIsReadBackAndCrossesTheWire() throws {
        XCTAssertEqual(Settings.keys(for: "sound")?.map(\.key), ["hw.snd.default_unit"])
        XCTAssertEqual(Settings.current(kind: "sound", values: ["hw.snd.default_unit": "2"]), .sound(SoundPlan(defaultUnit: 2)))
        XCTAssertNil(Settings.current(kind: "sound", values: [:]))
        var m = Msg()
        SettingsWire.encode(.sound(SoundPlan(defaultUnit: 1)), into: &m)
        XCTAssertEqual(try SettingsWire.decodePlan(m).get(), .sound(SoundPlan(defaultUnit: 1)))
        var typed = Msg(); typed.set("kind", "sound"); typed.set("sound.default", "pcm3")
        XCTAssertEqual(try SettingsWire.decodePlan(typed).get(), .sound(SoundPlan(defaultUnit: 3)), "pcm3 is how a person says it")
        var bad = Msg(); bad.set("kind", "sound"); bad.set("sound.default", "speakers")
        guard case .failure(let why) = SettingsWire.decodePlan(bad) else { return XCTFail("speakers was accepted") }
        XCTAssertEqual(why.message, "speakers is not a sound device (pcm0, pcm1 …)")
    }

    /// The edit is the helper's own code, not a tool — so it runs for real on
    /// both platforms, into a staged copy, and the tool after it is skipped.
    func testSysctlConfIsWrittenWholeAndTheSysctlSkippedWhenWriteOnly() throws {
        let dir = scratch(), sc = dir + "/sysctl.conf"
        defer { for f in [sc, sc + ".abyss-staged"] { unlink(f) }; rmdir(dir) }
        let f = fopen(sc, "w")!; fputs("# kernel\nkern.foo=1\n", f); fclose(f)
        chmod(sc, 0o600)
        var events: [SettingsEvent] = []
        let ok = Runner.apply(try Settings.compile(.sound(SoundPlan(defaultUnit: 1))), path: { _ in sc },
                              dryRun: false, writeOnly: true) { events.append($0) }
        XCTAssertTrue(ok, "\(events)")
        XCTAssertEqual(read(sc), "# kernel\nkern.foo=1\nhw.snd.default_unit=1\n")
        XCTAssertNil(read(sc + ".abyss-staged"))
        var st = stat(); stat(sc, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "the file keeps its mode")
        XCTAssertEqual(events.filter { if case .skipped = $0 { return true }; return false }.count, 1,
                       "write-only: the sysctl is skipped, and said to be")
    }

    // MARK: - Wi-Fi keys (P14.5)

    func testSHA1AndHMACAreTheStandardOnes() {
        func hex(_ b: [UInt8]) -> String { b.map { WifiKey.hex($0) }.joined() }
        XCTAssertEqual(hex(WifiKey.sha1(Array("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hex(WifiKey.sha1([])), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hex(WifiKey.sha1(Array(String(repeating: "a", count: 1000).utf8))),
                       "291e9a6c66994949b57ba5e650361e98fc36b1ba", "more than one block")
        // RFC 2202, test case 2.
        XCTAssertEqual(hex(WifiKey.hmacSHA1(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))),
                       "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
    }

    /// IEEE 802.11i-2004, Annex H.4 — the PSK wpa_passphrase(8) would print.
    func testAPassphraseBecomesTheKeyWPAUses() {
        XCTAssertEqual(WifiKey.psk(passphrase: "password", ssid: "IEEE"),
                       "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e")
        XCTAssertEqual(WifiKey.psk(passphrase: "ThisIsAPassword", ssid: "ThisIsASSID"),
                       "0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af")
        XCTAssertNil(WifiKey.psk(passphrase: "short", ssid: "x"), "WPA wants 8 to 63 characters")
        XCTAssertNil(WifiKey.psk(passphrase: String(repeating: "x", count: 64), ssid: "x"))
        XCTAssertTrue(WifiKey.isPSK("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"))
        XCTAssertFalse(WifiKey.isPSK("password"))
    }

    // MARK: - Wi-Fi (P14.5b)

    private let key = "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"

    func testJoiningCompilesToTheNetworkTheRadioAndARestart() throws {
        let steps = try Settings.compile(.wifi(WifiPlan(device: "iwn0", action: .join(ssid: "Café Wi-Fi", psk: key))))
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps[1], .rcConf(key: "wlans_iwn0", value: "wlan0"))
        XCTAssertEqual(steps[2], .rcConf(key: "ifconfig_wlan0", value: "WPA DHCP"))
        XCTAssertEqual(steps[3], .service(name: "netif", action: ["restart", "wlan0"], mayFail: false))
        XCTAssertEqual(steps[0].description, "add network \"Café Wi-Fi\" to wpa_supplicant.conf")
        let r = Settings.render(steps)
        XCTAssertFalse(r.contains(key), "the key is never in what a person or the journal reads: \(r)")
        let forget = try Settings.compile(.wifi(WifiPlan(device: "iwn0", action: .forget(ssid: "Café Wi-Fi"))))
        XCTAssertEqual(forget.map(\.description), ["forget network \"Café Wi-Fi\" in wpa_supplicant.conf",
                                                   "run wpa_cli -i wlan0 reconfigure"])
    }

    func testAWifiPlanIsRefusedInWords() {
        func why(_ w: WifiPlan) -> [String] { Settings.problems(.wifi(w)).map(\.message) }
        XCTAssertEqual(why(WifiPlan(device: "iwn0", action: .join(ssid: "x", psk: "password"))),
                       ["the network key is not a WPA key (64 hex digits)"], "a passphrase is not a key")
        XCTAssertEqual(why(WifiPlan(device: "lo", action: .join(ssid: "x", psk: nil))), ["lo is not a wireless device's name"])
        XCTAssertEqual(why(WifiPlan(device: "iwn0", interface: "em0", action: .forget(ssid: "x"))),
                       ["em0 is not a wlan interface (wlan0, wlan1 …)"])
        XCTAssertEqual(why(WifiPlan(device: "iwn0", action: .join(ssid: String(repeating: "x", count: 33), psk: nil))),
                       ["a network's name is 1 to 32 bytes, not 33"])
        XCTAssertEqual(why(WifiPlan(device: "iwn0", action: .join(ssid: "Open Net", psk: nil))), [])
    }

    func testWpaSupplicantConfIsEditedByNetwork() {
        let hand = "# by hand\nctrl_interface=/var/run/wpa_supplicant\nnetwork={\n\tssid=\"Home\"\n\tpsk=\"hunter22\"\n}\nnetwork={\n\tssid=\"Work\"\n\tkey_mgmt=NONE\n}\n"
        XCTAssertEqual(WpaConf.networks(hand), ["Home", "Work"])
        // Joining Home again replaces the hand-written block where it was, in hex.
        let joined = WpaConf.edit(hand, ssid: "Home", body: "ssid=\(WpaConf.hex("Home"))\npsk=\(key)")
        XCTAssertEqual(WpaConf.networks(joined), ["Home", "Work"])
        XCTAssertFalse(joined.contains("hunter22"), "the old passphrase went with the old block")
        XCTAssertTrue(joined.contains("\tssid=486f6d65\n\tpsk=\(key)"), joined)
        XCTAssertTrue(joined.hasPrefix("# by hand\n"), "the rest of the file is kept")
        // A name that would break out of quotes is only ever hex.
        let evil = "a\"\n}\nnetwork={ssid=\"x"
        let e = WpaConf.edit("", ssid: evil, body: "ssid=\(WpaConf.hex(evil))\nkey_mgmt=NONE")
        XCTAssertEqual(WpaConf.networks(e), [evil])
        XCTAssertEqual(e.split(separator: "\n").filter { $0.hasPrefix("network={") }.count, 1, e)
        XCTAssertTrue(e.hasPrefix("ctrl_interface=/var/run/wpa_supplicant\n"), "wpa_cli needs the socket")
        // Forgetting removes only that network.
        XCTAssertEqual(WpaConf.networks(WpaConf.edit(joined, ssid: "Home", body: nil)), ["Work"])
        XCTAssertEqual(WpaConf.unhex("486f6d65"), "Home")
        XCTAssertNil(WpaConf.unhex("48z"))
    }

    func testAScanIsReadByItsBSSIDsAndEachNetworkOnce() {
        let scan = """
        SSID/MESH ID                      BSSID              CHAN RATE    S:N     INT CAPS
        abyss-lab                         00:98:9a:98:96:97    1   11M   10:10    100 EP   RSN
        Café Wi-Fi 5G                     aa:bb:cc:dd:ee:01   36   54M  -61:-95   100 EP   RSN HTCAP WME
        Café Wi-Fi 5G                     aa:bb:cc:dd:ee:02   40   54M  -48:-95   100 EP   RSN HTCAP WME
        Library                           aa:bb:cc:dd:ee:03    6   54M  -70:-95   100 E    WME
        """
        let n = WifiScan.parse(scan)
        XCTAssertEqual(n.map(\.ssid), ["abyss-lab", "Café Wi-Fi 5G", "Library"], "strongest first; one row per network")
        XCTAssertEqual(n[1].bssid, "aa:bb:cc:dd:ee:02", "the strongest access point of the two")
        XCTAssertEqual(n[1].channel, 40)
        XCTAssertTrue(n[0].secured)
        XCTAssertFalse(n[2].secured, "no privacy, no RSN: open")
        XCTAssertEqual(WifiScan.parse("SSID/MESH ID  BSSID  CHAN\n"), [])
    }

    func testWifiCrossesTheWire() throws {
        var m = Msg()
        let plan = SettingsPlan.wifi(WifiPlan(device: "wtap1", action: .join(ssid: "abyss-lab", psk: key)))
        SettingsWire.encode(plan, into: &m)
        XCTAssertEqual(try SettingsWire.decodePlan(m).get(), plan)
        var k = Msg()
        SettingsWire.encode(WifiKnown(device: "wtap1", interface: "wlan0", networks: ["a", "b c"]), into: &k)
        XCTAssertEqual(SettingsWire.decodeKnown(k), WifiKnown(device: "wtap1", interface: "wlan0", networks: ["a", "b c"]))
        var sc = Msg()
        let nets = [WifiNetwork(ssid: "x y", bssid: "00:11:22:33:44:55", channel: 6, signal: -48, secured: true)]
        SettingsWire.encode(nets, into: &sc)
        XCTAssertEqual(SettingsWire.decodeScan(sc), nets)
    }

    /// wpa_supplicant.conf is the helper's own edit, like sysctl.conf: real on
    /// both platforms, into a staged copy — and a new one is root's alone.
    func testWpaSupplicantConfIsWrittenWholeAndPrivately() throws {
        let dir = scratch(), rc = dir + "/rc.conf", wpa = dir + "/wpa_supplicant.conf"
        defer { for f in [rc, wpa, rc + ".abyss-staged", wpa + ".abyss-staged"] { unlink(f) }; rmdir(dir) }
        let f = fopen(rc, "w")!; fputs("hostname=\"abyss\"\n", f); fclose(f)
        var events: [SettingsEvent] = []
        let ok = Runner.apply(try Settings.compile(.wifi(WifiPlan(device: "wtap1", action: .join(ssid: "abyss-lab", psk: key)))),
                              path: { $0 == .wpaSupplicant ? wpa : rc }, dryRun: false, writeOnly: true) { events.append($0) }
        #if os(FreeBSD)
        XCTAssertTrue(ok, "\(events)")
        XCTAssertTrue(read(rc)?.contains("wlans_wtap1=\"wlan0\"") ?? false, read(rc) ?? "")
        #else
        XCTAssertFalse(ok, "sysrc is FreeBSD's; the plan stops at rc.conf")
        #endif
        _ = ok
        if let text = read(wpa) {
            XCTAssertEqual(WpaConf.networks(text), ["abyss-lab"])
            var st = stat(); stat(wpa, &st)
            XCTAssertEqual(st.st_mode & 0o777, 0o600, "a file of network keys is root's alone")
        } else {
            #if os(FreeBSD)
            XCTFail("wpa_supplicant.conf was not written")
            #endif
        }
    }

    // MARK: Quitting a process (P15.7)

    /// What may be asked: never init, never an unnamed pid; Quit is TERM and
    /// Force Quit is KILL; and the plan crosses the wire whole — the start
    /// time and name are what let the helper refuse a reused pid.
    func testASignalPlanRefusesInitAndCompilesToKill() throws {
        func why(_ p: SignalPlan) -> String? { Settings.problems(.signal(p)).first?.message }
        XCTAssertNotNil(why(SignalPlan(pid: 1, force: false, started: 5, name: "init")))
        XCTAssertNotNil(why(SignalPlan(pid: 0, force: false, started: 5, name: "kernel")))
        XCTAssertNotNil(why(SignalPlan(pid: 500, force: false, started: 5, name: "")))
        let quit = SignalPlan(pid: 4242, force: false, started: 1_700_000_000, name: "sleep")
        XCTAssertNil(why(quit))
        XCTAssertEqual(try Settings.compile(.signal(quit)), [.tool(argv: ["kill", "-s", "TERM", "4242"], mayFail: false)])
        var force = quit; force.force = true
        XCTAssertEqual(try Settings.compile(.signal(force)), [.tool(argv: ["kill", "-s", "KILL", "4242"], mayFail: false)])
        var m = Msg()
        SettingsWire.encode(.signal(force), into: &m)
        XCTAssertEqual(try SettingsWire.decodePlan(m).get(), .signal(force))
    }
}
