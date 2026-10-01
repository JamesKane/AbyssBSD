// The Accounts pane (PHASE16 P16.6a): the New User sheet's typing and
// refusals, what the pane reads from files, and a sheet being modal.

import XCTest
@testable import Aqua
@testable import AquaDraw

final class AccountsPaneTests: XCTestCase {
    func testTheShortNameFollowsTheFullNameUntilTypedItself() {
        var f = NewUserForm()
        f.type("Ada"); f.type(" Lovelace")
        XCTAssertEqual(f.shortName, "ada", "the first word, lower-cased")
        f.backspace()
        XCTAssertEqual(f.shortName, "ada")
        f.tab(); f.backspace(); f.backspace(); f.backspace(); f.type("countess")
        XCTAssertEqual(f.shortName, "countess")
        f.focus = .fullName; f.type("x")
        XCTAssertEqual(f.shortName, "countess", "typed by hand: no longer follows")
        XCTAssertEqual(NewUserForm.suggest("Émile Zola"), "mile", "letters and digits only")
    }

    func testTheSheetSaysWhyItCannotCreateYet() {
        var f = NewUserForm()
        XCTAssertEqual(f.whyNot, "Type a short name.")
        f.type("Grace")
        XCTAssertEqual(f.whyNot, "Type a password.")
        f.focus = .password; f.type("cobol")
        f.focus = .verify; f.type("fortran")
        XCTAssertEqual(f.whyNot, "The passwords do not match.")
        f.backspace(); f.backspace(); f.backspace(); f.backspace(); f.backspace(); f.backspace(); f.backspace()
        f.type("cobol")
        XCTAssertNil(f.whyNot)
        f.tab(); XCTAssertEqual(f.focus, .fullName, "Tab goes round")
    }

    func testThePaneReadsPeopleAdministratorsAndAutomaticLogin() {
        let passwd = """
        root:*:0:0:Charlie &:/root:/bin/sh
        ada:*:1001:1001:Ada Lovelace:/home/ada:/bin/sh
        bob:*:1002:1002::/home/bob:/bin/csh
        _loginwindow:*:1099:1099:Login Window:/nonexistent:/usr/sbin/nologin
        """
        let group = "wheel:*:0:root,ada\naudio:*:43:ada,bob\n"
        let rc = "hostname=\"x\"\nabyss_desktop_enable=\"YES\"\nabyss_desktop_user=\"bob\"\n"
        let s = AccountsPaneState.read(passwd: passwd, group: group, rcConf: rc)
        XCTAssertEqual(s.accounts.map(\.name), ["ada", "bob"])
        XCTAssertEqual(s.accounts.map(\.admin), [true, false])
        XCTAssertEqual(s.autoLogin, "bob")
        XCTAssertNil(AccountsPaneState.read(passwd: passwd, group: group,
                                            rcConf: "abyss_desktop_user=\"bob\"\n").autoLogin,
                     "a user named, but the desktop not enabled: the login window")
    }

    func testASheetIsModal() {
        var s = AccountsPaneState.sample
        let body = Rect(0, 100, 760, 500)
        var l = accountsLayout(body: body, s)
        XCTAssertEqual(accountsHit(l, s, x: l.rows[1].x + 5, y: l.rows[1].y + 5), .row(1))
        s.form = NewUserForm()
        l = accountsLayout(body: body, s)
        XCTAssertNil(accountsHit(l, s, x: l.newUser.x + 5, y: l.newUser.y + 5), "behind the sheet, nothing answers")
        XCTAssertEqual(accountsHit(l, s, x: l.fields[2].x + 5, y: l.fields[2].y + 5), .field(.password))
        XCTAssertEqual(accountsHit(l, s, x: l.confirm.x + 5, y: l.confirm.y + 5), .confirm)
    }
}
