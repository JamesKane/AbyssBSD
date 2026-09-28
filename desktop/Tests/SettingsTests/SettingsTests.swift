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
        XCTAssertEqual(refusal([("kind", "network")]), "there is no network plan (there is: energy)")
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
}
