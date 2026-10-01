// The Accounts pane's plan (PHASE16 P16.6a): what it refuses, and that a
// password hash goes to `pw` on stdin — never argv, the journal or the pane.

import XCTest
import CurrentIPC
@testable import Settings
@testable import SettingsWire

final class AccountsPlanTests: XCTestCase {
    let hash = "$6$salt$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ./abcdefgh"

    func testNamesTheSystemOwnsAndNamesPwRefusesAreRefused() {
        func refused(_ n: String) -> Bool {
            !Settings.problems(.accounts(AccountPlan(.add(name: n, fullName: "", passwordHash: hash, admin: false)))).isEmpty
        }
        XCTAssertFalse(refused("ada"))
        XCTAssertFalse(refused("grace-h_2"))
        for bad in ["", "Ada", "1ada", "ada smith", "ada:x", "_loginwindow", "root", "toor", "abyss",
                    "averyveryverylongname"] {
            XCTAssertTrue(refused(bad), "\(bad) should be refused")
        }
        let plain = Settings.problems(.accounts(AccountPlan(.add(name: "ada", fullName: "", passwordHash: "hunter2", admin: false))))
        XCTAssertEqual(plain.first?.message, "the password did not arrive hashed")
        XCTAssertFalse(Settings.problems(.accounts(AccountPlan(.add(name: "ada", fullName: "Ada:L", passwordHash: hash, admin: false)))).isEmpty)
    }

    func testTheHashGoesOnStdinAndIsNeverSaid() throws {
        let steps = try Settings.compile(.accounts(AccountPlan(.add(name: "ada", fullName: "Ada Lovelace",
                                                                     passwordHash: hash, admin: true))))
        XCTAssertEqual(steps.count, 1)
        guard case .pw(let args, let input, _) = steps[0] else { return XCTFail("not a pw step") }
        XCTAssertEqual(input, hash)
        XCTAssertFalse(args.contains(hash), "the hash is not in argv")
        XCTAssertFalse(steps[0].command(path: { _ in "" }).joined(separator: " ").contains(hash))
        XCTAssertFalse(steps[0].description.contains(hash), "nor in what the journal and the pane say")
        XCTAssertEqual(steps[0].description, "create the account ada, an administrator")
        XCTAssertTrue(args.contains("wheel,operator,audio,video"))
        XCTAssertEqual(Array(steps[0].command(path: { _ in "" }).prefix(3)), ["pw", "-R", SettingsStep.pwRoot])
        let user = try Settings.compile(.accounts(AccountPlan(.add(name: "bob", fullName: "", passwordHash: hash, admin: false))))
        guard case .pw(let a2, _, _) = user[0] else { return XCTFail() }
        XCTAssertTrue(a2.contains("audio,video") && !a2.joined().contains("wheel"), "a standard user is not an administrator")
    }

    func testDeletingKeepsTheHomeUnlessAsked() throws {
        let keep = try Settings.compile(.accounts(AccountPlan(.delete(name: "ada", removeHome: false))))
        guard case .pw(let a, nil, _) = keep[0] else { return XCTFail() }
        XCTAssertEqual(a, ["userdel", "-n", "ada"])
        let gone = try Settings.compile(.accounts(AccountPlan(.delete(name: "ada", removeHome: true))))
        guard case .pw(let b, nil, _) = gone[0] else { return XCTFail() }
        XCTAssertEqual(b, ["userdel", "-n", "ada", "-r"])
        XCTAssertFalse(Settings.problems(.accounts(AccountPlan(.delete(name: "root", removeHome: false)))).isEmpty)
    }

    func testAutomaticLoginReplacesTheLoginWindowAndBack() throws {
        let on = try Settings.compile(.accounts(AccountPlan(.autoLogin("ada"))))
        XCTAssertEqual(on, [.rcConf(key: "abyss_desktop_enable", value: "YES"),
                            .rcConf(key: "abyss_desktop_user", value: "ada"),
                            .rcConf(key: "abyss_loginwindow_flags", value: nil)])
        let off = try Settings.compile(.accounts(AccountPlan(.autoLogin(nil))))
        XCTAssertEqual(off, [.rcConf(key: "abyss_desktop_enable", value: nil),
                             .rcConf(key: "abyss_desktop_user", value: nil),
                             .rcConf(key: "abyss_loginwindow_flags", value: "--greeter")])
    }

    func testTheWireCarriesEachAction() {
        for plan in [AccountPlan(.add(name: "ada", fullName: "Ada", passwordHash: hash, admin: true)),
                     AccountPlan(.delete(name: "ada", removeHome: true)),
                     AccountPlan(.autoLogin("ada")), AccountPlan(.autoLogin(nil))] {
            var m = Msg(); m.set("method", "apply")
            SettingsWire.encode(.accounts(plan), into: &m)
            guard case .success(.accounts(let back)) = SettingsWire.decodePlan(m) else { return XCTFail("\(plan)") }
            XCTAssertEqual(back, plan)
        }
    }
}
