// The installer's model — the hub, its spokes, and the plan they add up to.
//
// The reason these tests exist in this shape: what this GUI produces is a
// program that rewrites somebody's disk, and the interesting claims about it
// ("the button is dead until a disk is chosen", "the plan says what the screens
// said") are claims about a value. None of them needs a compositor, a service or
// a disk, so none of them gets one. `abyss/tests/live-installer.sh` drives the
// same model with a real pointer and a real keyboard.

import XCTest
@testable import Aqua
@testable import Install

final class InstallerTests: XCTestCase {

    /// A machine with one installable disk, one that is in use, and the one we
    /// booted from — the three cases the disk spoke has to tell apart.
    private func machine() -> DiskInventory {
        DiskInventory(disks: [
            Disk(name: "ada0", bytes: 500 << 30, description: "APPLE SSD",
                 mountedAt: ["/", "/home"], holdsRunningRoot: true),
            Disk(name: "ada1", bytes: 256 << 30, description: "Scratch",
                 mountedAt: ["/media/photos"]),
            Disk(name: "ada2", bytes: 128 << 30, description: "Crucial CT128"),
            Disk(name: "da0", bytes: 2 << 30, description: "SanDisk Cruzer"),
        ], importedPools: ["zroot"])
    }

    private func ready() -> InstallerModel {
        var m = InstallerModel(inventory: machine())
        m.disk = "ada2"
        m.accountName = "jkane"
        m.accountFullName = "J Kane"
        m.accountPassword = "hunter2"
        m.accountConfirm = "hunter2"
        return m
    }

    // MARK: - The hub

    func testTheInstallButtonIsDeadUntilTheRequiredSpokesAreAnswered() {
        // The one predicate the whole hub exists to compute.
        var m = InstallerModel(inventory: machine())
        XCTAssertFalse(m.canInstall)
        XCTAssertEqual(m.outstanding, [.disk, .account])

        m.disk = "ada2"
        XCTAssertFalse(m.canInstall, "a disk alone is not enough to install")
        XCTAssertEqual(m.outstanding, [.account])

        m.accountName = "jkane"; m.accountPassword = "hunter2"; m.accountConfirm = "hunter2"
        XCTAssertTrue(m.canInstall)
        XCTAssertEqual(m.outstanding, [])
    }

    func testKeyboardAndTimeZoneAreNotRequiredBecauseTheyHaveRealDefaults() {
        // Require what cannot be guessed; default what can. A US keyboard and
        // UTC are answers, not omissions — and the hub says so rather than
        // leaving the rows blank.
        let m = ready()
        XCTAssertTrue(m.canInstall, "an unvisited keyboard spoke blocked the install")
        XCTAssertEqual(m.status(.keyboard), "US (default)")
        XCTAssertEqual(m.status(.timezone), "UTC (default)")
        XCTAssertTrue(m.complete(.keyboard))
        XCTAssertTrue(m.complete(.timezone))
    }

    func testEverySpokeSaysSomethingIncludingTheOnesThatAreNotDone() {
        // A hub whose incomplete rows are blank tells you there is a problem
        // without telling you what.
        let m = InstallerModel(inventory: machine())
        for spoke in Spoke.allCases {
            let s = m.status(spoke)
            XCTAssertFalse(s.isEmpty, "\(spoke) says nothing when unanswered")
            XCTAssertGreaterThan(s.count, 8, "\(spoke): \(s)")
        }
        XCTAssertEqual(m.status(.disk), "Choose a disk to install onto")
        XCTAssertEqual(m.status(.account), "No account will be created")
    }

    func testTheReadinessLineNamesWhatIsMissingAndThenWhatWillHappen() {
        var m = InstallerModel(inventory: machine())
        XCTAssertTrue(m.readiness.contains("disk"), m.readiness)
        XCTAssertTrue(m.readiness.contains("account"), m.readiness)

        m.disk = "ada2"
        XCTAssertTrue(m.readiness.contains("account"), m.readiness)
        XCTAssertFalse(m.readiness.contains("disk"), "it still asks for a disk we chose")

        // ...and it reads like a sentence somebody wrote. "Choose a installation
        // disk" is what the obvious implementation says, on the one screen where
        // carelessness is the whole product.
        m = InstallerModel(inventory: machine())
        m.accountName = "jkane"; m.accountPassword = "x"; m.accountConfirm = "x"
        XCTAssertEqual(m.readiness, "Choose an installation disk before installing.")

        m = ready()
        // And once it is ready, it says what it is about to do — including the
        // part people skip past.
        XCTAssertTrue(m.readiness.contains("ada2"), m.readiness)
        XCTAssertTrue(m.readiness.lowercased().contains("erase"), m.readiness)
    }

    // MARK: - The disk spoke, which is the one with teeth

    func testEveryDiskIsShownEvenTheOnesThatCannotBeUsed() {
        // A picker that silently omits your disk is one you argue with. Show it,
        // and say why not.
        let m = InstallerModel(inventory: machine())
        XCTAssertEqual(m.installableDisks.map(\.name), ["ada0", "ada1", "ada2", "da0"])
    }

    func testTheDiskYouBootedFromIsShownWithTheReasonAndCannotBeChosen() {
        var m = InstallerModel(inventory: machine())
        let root = m.inventory.disk(named: "ada0")!
        XCTAssertFalse(m.canChoose(root))
        XCTAssertTrue(m.objection(to: root).contains("running from"), m.objection(to: root))

        // ...and clicking it does not take.
        m.enter(.disk)
        m.selection = 0
        XCTAssertFalse(m.chooseSelection())
        XCTAssertEqual(m.disk, "", "the installer accepted the disk it is running from")
        // **And it stays on the list.** Being bounced back to the hub with
        // nothing chosen looks exactly like success and is not — found by the
        // live test, which then could not find the disk list it was clicking.
        XCTAssertEqual(m.page, .spoke(.disk),
                       "a refused choice left the spoke as if it had worked")

        // A choice that does take goes back, and says so.
        m.selection = 2
        XCTAssertTrue(m.chooseSelection())
        XCTAssertEqual(m.disk, "ada2")
        XCTAssertEqual(m.page, .hub)
    }

    func testADiskInUseAndADiskTooSmallEachSayWhy() {
        let m = InstallerModel(inventory: machine())
        let inUse = m.inventory.disk(named: "ada1")!
        XCTAssertTrue(m.objection(to: inUse).contains("in use"), m.objection(to: inUse))
        let tiny = m.inventory.disk(named: "da0")!
        XCTAssertTrue(m.objection(to: tiny).contains("needs at least"), m.objection(to: tiny))
        // And the good one has nothing against it.
        XCTAssertEqual(m.objection(to: m.inventory.disk(named: "ada2")!), "")
    }

    func testAMissingAccountIsNotTheDisksFault() {
        // `problems` reports everything wrong with a plan; the disk spoke must
        // only show the objections that are about the disk, or every row grows
        // a complaint about a password.
        let m = InstallerModel(inventory: machine())   // no account at all
        XCTAssertEqual(m.objection(to: m.inventory.disk(named: "ada2")!), "",
                       "the disk spoke is complaining about something else")
    }

    func testTheChosenDiskIsDescribedByWhatItIsNotByItsName() {
        var m = ready()
        let s = m.status(.disk)
        XCTAssertTrue(s.contains("ada2"), s)
        XCTAssertTrue(s.contains("128.0 GB"), s)
        XCTAssertTrue(s.contains("Crucial"), s)
        // A disk that vanishes between the probe and the hub says so rather
        // than showing a stale size.
        m.inventory = DiskInventory(disks: [])
        XCTAssertTrue(m.status(.disk).contains("no longer there"), m.status(.disk))
        XCTAssertFalse(m.canInstall, "a vanished disk still counted as chosen")
    }

    // MARK: - The account spoke

    func testAPasswordThatDoesNotMatchIsSaidOnTheHubNotSwallowed() {
        var m = ready()
        m.accountConfirm = "hunter3"
        XCTAssertFalse(m.canInstall)
        XCTAssertEqual(m.passwordProblem, "The passwords do not match")
        XCTAssertEqual(m.status(.account), "The passwords do not match",
                       "the hub hid the reason the install is blocked")
    }

    func testAnAccountWithNoPasswordIsRefused() {
        var m = ready()
        m.accountPassword = ""; m.accountConfirm = ""
        XCTAssertFalse(m.canInstall)
        XCTAssertTrue(m.status(.account).contains("no password"), m.status(.account))
    }

    func testTheAccountSaysWhetherItCanAdminister() {
        var m = ready()
        XCTAssertTrue(m.status(.account).contains("administer"), m.status(.account))
        m.accountIsAdministrator = false
        XCTAssertFalse(m.status(.account).contains("administer"), m.status(.account))
    }

    // MARK: - Any order, which is the whole point of a hub

    func testSpokesCanBeVisitedInAnyOrderAndRememberWhereYouLeftOff() {
        var m = InstallerModel(inventory: machine())
        // Time zone first, then disk, then back to time zone.
        m.enter(.timezone); m.selection = 3; m.chooseSelection()
        XCTAssertEqual(m.timezone, installerTimezones[3])
        XCTAssertEqual(m.page, .hub)

        m.enter(.disk); m.selection = 2; m.chooseSelection()
        XCTAssertEqual(m.disk, "ada2")

        m.enter(.keyboard); m.selection = 6; m.chooseSelection()     // dvorak
        XCTAssertEqual(m.keymap, installerKeymaps[6])

        // Returning opens on what is already chosen, not at the top — for every
        // spoke that has a list, not just the ones that came to mind first. An
        // injected fault walked straight through the version of this test that
        // only checked two of them.
        for (spoke, expected) in [(Spoke.timezone, 3), (Spoke.disk, 2), (Spoke.keyboard, 6)] {
            m.enter(spoke)
            XCTAssertEqual(m.selection, expected,
                           "\(spoke) opened at \(m.selection), forgetting the choice already made")
        }
    }

    func testLeavingASpokeWithoutChoosingChangesNothing() {
        var m = ready()
        let before = m.disk
        m.enter(.disk)
        m.selection = 0            // the disk we booted from
        m.back()                   // ...and out again without committing
        XCTAssertEqual(m.disk, before)
        XCTAssertEqual(m.page, .hub)
    }

    // MARK: - The plan, which is the only thing that leaves this screen

    func testThePlanSaysWhatTheScreensSaid() {
        // The claim P5.4 exists to make: what the user chose is what gets run.
        // Compared against a plan built by hand, field by field, because the
        // GUI's whole job is this translation.
        var m = ready()
        m.hostname = "jaguar"
        m.enter(.keyboard); m.selection = 1; m.chooseSelection()      // uk.kbd
        m.enter(.timezone); m.selection = 3; m.chooseSelection()      // America/Chicago

        let built = m.plan(passwordHash: "$6$fake", distDirectory: "/usr/freebsd-dist")
        let expected = InstallPlan(
            disk: "ada2",
            sets: ["base.txz", "kernel.txz", "abyss.txz"],
            distDirectory: "/usr/freebsd-dist",
            hostname: "jaguar",
            timezone: "America/Chicago",
            keymap: "uk.kbd",
            rootPasswordHash: "*",
            accounts: [Account(name: "jkane", fullName: "J Kane",
                               passwordHash: "$6$fake",
                               groups: ["wheel", "operator"], shell: "/bin/sh")])
        XCTAssertEqual(built, expected)
    }

    func testTheAquaInstallerInstallsThisDesktop() {
        // The thing it exists to install is the thing it is running on. A plan
        // from this GUI that installed a plain FreeBSD would boot to a shell,
        // and the person who clicked "Install" would be entitled to be cross.
        let p = ready().plan(passwordHash: "$6$fake")
        XCTAssertTrue(p.installsDesktop, "the Aqua installer did not install the desktop")
        XCTAssertEqual(p.sets.first, "base.txz", "base still has to be first")
        // And the installed machine therefore starts it, for the account made.
        XCTAssertTrue(rcConf(p).contains("abyss_desktop_enable"))
        XCTAssertTrue(rcConf(p).contains("abyss_desktop_user=\"jkane\""))
    }

    func testTheTrialPlanBehindAnObjectionMatchesTheRealOne() {
        // `objection(to:)` compiles a trial plan to ask whether a disk may be
        // used. If that trial differed from the plan actually installed — a
        // different set list, say — a disk could be offered and then refused.
        var m = ready()
        m.disk = ""
        let d = m.inventory.disk(named: "ada2")!
        XCTAssertEqual(m.objection(to: d), "")
        m.disk = "ada2"
        XCTAssertEqual(problems(m.plan(passwordHash: "$6$x"), on: m.inventory), [])
    }

    func testThePlanTheGuiBuildsIsOneTheInstallerWillAccept() {
        // "check said yes" is only worth having if the GUI cannot produce a plan
        // that check refuses. Same predicate, same inventory.
        let m = ready()
        XCTAssertEqual(problems(m.plan(passwordHash: "$6$fake"), on: m.inventory), [])
        XCTAssertNoThrow(try compile(m.plan(passwordHash: "$6$fake"), on: m.inventory))
    }

    func testAnIncompleteHubCannotProduceAnInstallablePlan() {
        // The button being dead and the plan being refused must agree — two
        // mechanisms that disagree is how a GUI ships a bad install.
        var m = InstallerModel(inventory: machine())
        m.disk = "ada2"                             // ...but no account
        XCTAssertFalse(m.canInstall)
        XCTAssertTrue(problems(m.plan(passwordHash: "$6$fake"), on: m.inventory)
                        .contains(.noAdministrator))
    }

    func testRootGetsNoPasswordAndTheUserGetsWheel() {
        // The Mac arrangement, and the reason `noAdministrator` is satisfied:
        // you log in as yourself and elevate, rather than there being a root
        // password on a machine somebody just installed.
        let m = ready()
        let p = m.plan(passwordHash: "$6$fake")
        XCTAssertEqual(p.rootPasswordHash, "*")
        XCTAssertTrue(p.accounts[0].isAdministrator)
    }

    func testNoPlaintextPasswordEverReachesAPlan() {
        // `InstallPlan` is logged, rendered into a golden test and passed
        // between processes. The plaintext stops at this model.
        let m = ready()
        let p = m.plan(passwordHash: "$6$fake")
        XCTAssertFalse(p.accounts.contains { $0.passwordHash.contains("hunter2") })
        XCTAssertFalse(render(try! compile(p, on: m.inventory)).contains("hunter2"))
    }

    func testAMachineWithNoDisksSaysSoRatherThanOfferingNothing() {
        var m = InstallerModel(inventory: DiskInventory(disks: []))
        XCTAssertTrue(m.status(.disk).contains("No disk"), m.status(.disk))
        // ...and when the service could not even look, the hub carries its
        // reason rather than inventing one of its own.
        m.inventoryError = "disk discovery needs FreeBSD's geom(8)"
        XCTAssertEqual(m.status(.disk), "disk discovery needs FreeBSD's geom(8)")
    }
}
