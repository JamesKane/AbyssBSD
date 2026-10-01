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

    func testTheDiskPickerShowsADiskThatAlreadyHoldsASystem() {
        // **The live-medium case, at the screen.** From a USB stick the target
        // machine's disk is unmounted and its pool unimported, so every other
        // objection is silent about it — and `objection(to:)` is a whitelist, so
        // the model refusing is not the same as the picker saying so. This is
        // the test that would have caught the whitelist being out of date.
        let inv = DiskInventory(disks: [
            Disk(name: "nvd0", bytes: 900 << 30, description: "Samsung SSD 980",
                 existingPools: ["zroot"], partitionKinds: ["efi", "freebsd-zfs"],
                 freeBytes: 1 << 20, hasPartitionTable: true),
            Disk(name: "da0", bytes: 64 << 30, description: "SanDisk Cruzer"),
        ], importedPools: [])
        var m = InstallerModel(inventory: inv)
        m.accountName = "jkane"; m.accountPassword = "x"; m.accountConfirm = "x"

        let occupied = inv.disk(named: "nvd0")!
        // **The meaning changed when the sheet arrived, and the test with it.**
        // A full disk is no longer un-choosable — it is choosable *after being
        // asked about*, which is the whole point. What must still be true is
        // that the row says what is on it, and that choosing it does not
        // silently take it.
        XCTAssertTrue(m.needsErasing(occupied), "it needs erasing —")
        XCTAssertFalse(m.isBlocked(occupied), "— but nothing makes it impossible")
        XCTAssertTrue(m.objection(to: occupied).contains("zroot"),
                      "and the row names what would be destroyed: \(m.objection(to: occupied))")
        m.enter(.disk)
        m.selection = 0
        XCTAssertFalse(m.chooseSelection(), "it must ask before taking it")
        XCTAssertEqual(m.page, .eraseConfirm(disk: "nvd0"))

        // The positive control: the empty stick beside it is still choosable, so
        // this is a refusal and not a wall.
        XCTAssertEqual(m.objection(to: inv.disk(named: "da0")!), "")
        XCTAssertTrue(m.canChoose(inv.disk(named: "da0")!))
    }

    // MARK: - Asking before destroying somebody else's data

    /// The bring-up machine, as the installer sees it: three disks, all full,
    /// one of them ours and two of them somebody else's.
    private func crowdedMachine() -> DiskInventory {
        DiskInventory(disks: [
            Disk(name: "nda0", bytes: 931 << 30, description: "WD_BLACK SN850X",
                 partitionKinds: ["efi", "ms-reserved", "ms-basic-data", "ms-recovery"],
                 freeBytes: 1_776_128, hasPartitionTable: true),
            Disk(name: "nda1", bytes: 931 << 30, description: "Samsung SSD 990 PRO",
                 existingPools: ["zroot"],
                 partitionKinds: ["efi", "freebsd-boot", "freebsd-swap", "freebsd-zfs"],
                 freeBytes: 728_576, hasPartitionTable: true),
            Disk(name: "da0", bytes: 14 << 30, description: "Kingston DataTraveler",
                 mountedAt: ["/"], holdsRunningRoot: true,
                 partitionKinds: ["efi", "freebsd-ufs"],
                 freeBytes: 0, hasPartitionTable: true),
        ])
    }

    private func atDiskSpoke() -> InstallerModel {
        var m = InstallerModel(inventory: crowdedMachine())
        m.accountName = "jkane"; m.accountPassword = "x"; m.accountConfirm = "x"
        m.enter(.disk)
        return m
    }

    func testAFullDiskAsksInsteadOfDoingNothing() {
        // **The dead end this replaces.** Choosing a full disk used to return
        // false: the row said why and the button did nothing, so on a machine
        // where every disk is full the installer was unusable with nothing to
        // click. Now it opens a sheet, which is where a person can answer.
        var m = atDiskSpoke()
        m.selection = 0                        // nda0 — somebody's Windows
        XCTAssertFalse(m.chooseSelection(), "it must not be chosen yet")
        XCTAssertEqual(m.page, .eraseConfirm(disk: "nda0"))
        XCTAssertEqual(m.disk, "", "nothing is chosen until the sheet is answered")
    }

    func testTheSheetNamesTheDiskAndWhatIsOnIt() {
        // A confirmation that says only "are you sure?" teaches people to click
        // through. This one has to be disagreeable with.
        var m = atDiskSpoke()
        m.selection = 0
        _ = m.chooseSelection()
        XCTAssertTrue(m.eraseWarning.contains("nda0"), m.eraseWarning)
        XCTAssertTrue(m.eraseWarning.contains("ms-basic-data"), m.eraseWarning)
        XCTAssertTrue(m.eraseWarning.contains("cannot be undone"), m.eraseWarning)
        // ...and for our own disk it names the pool, which is more use than a type.
        var n = atDiskSpoke()
        n.selection = 1
        _ = n.chooseSelection()
        XCTAssertTrue(n.eraseWarning.contains("ZFS pool zroot"), n.eraseWarning)
    }

    func testConfirmingTakesTheDiskAndGrantsThePermission() {
        var m = atDiskSpoke()
        m.selection = 1
        _ = m.chooseSelection()
        m.confirmErase()
        XCTAssertEqual(m.disk, "nda1")
        XCTAssertTrue(m.eraseConfirmed)
        XCTAssertEqual(m.page, .hub)
        // And the permission reaches the plan, or it granted nothing.
        XCTAssertTrue(m.plan(passwordHash: "$6$x").eraseExistingData)
    }

    func testCancellingGrantsNothingAndChoosesNothing() {
        var m = atDiskSpoke()
        m.selection = 1
        _ = m.chooseSelection()
        m.cancelErase()
        XCTAssertEqual(m.disk, "")
        XCTAssertFalse(m.eraseConfirmed)
        XCTAssertEqual(m.page, .spoke(.disk), "it goes back to the list, not to the hub")
    }

    func testConsentDoesNotFollowThePersonToAnotherDisk() {
        // **The property that matters most here.** Somebody who agreed to
        // destroy nda1 has not agreed to destroy nda0, and a consent that
        // outlives the thing it was about is not consent.
        var m = atDiskSpoke()
        m.selection = 1
        _ = m.chooseSelection()
        m.confirmErase()
        XCTAssertTrue(m.eraseConfirmed)

        m.enter(.disk)
        m.selection = 0                        // now the other one
        XCTAssertFalse(m.chooseSelection(), "it must ask again")
        XCTAssertEqual(m.page, .eraseConfirm(disk: "nda0"))

        // **What "scoped" means, precisely.** The permission for nda1 is still
        // set, and that is right: nothing about nda1 changed, and withdrawing it
        // for merely *looking* at another disk would silently un-choose a disk
        // the person never changed. What it cannot do is apply to nda0 — so a
        // plan for nda0 carries no permission, and the sheet had to open.
        XCTAssertTrue(m.eraseConfirmed, "nda1's own answer survives being asked about another disk")
        XCTAssertFalse(m.plan(disk: "nda0", passwordHash: "$6$x").eraseExistingData,
                       "a plan built for another disk inherits no permission")
        XCTAssertTrue(m.plan(disk: "nda1", passwordHash: "$6$x").eraseExistingData,
                      "and the disk it WAS given for still has it")

        // Cancelling leaves the earlier choice exactly as it was.
        m.cancelErase()
        XCTAssertEqual(m.disk, "nda1")
        XCTAssertFalse(m.eraseConfirmed, "cancelling withdraws the pending question's consent")
    }

    func testConfirmingASecondDiskMovesTheConsentToIt() {
        var m = atDiskSpoke()
        m.selection = 1
        _ = m.chooseSelection(); m.confirmErase()
        XCTAssertEqual(m.disk, "nda1")

        m.enter(.disk); m.selection = 0
        _ = m.chooseSelection(); m.confirmErase()
        XCTAssertEqual(m.disk, "nda0")
        XCTAssertTrue(m.eraseConfirmed)
        XCTAssertTrue(m.plan(passwordHash: "$6$x").eraseExistingData)
    }

    func testAssigningTheDiskDirectlyAlsoWithdrawsConsent() {
        // The guarantee lives in the setter, not on the screen, because the
        // screen is not the only caller.
        var m = atDiskSpoke()
        m.selection = 1
        _ = m.chooseSelection()
        m.confirmErase()
        m.disk = "nda0"
        XCTAssertFalse(m.eraseConfirmed)
    }

    func testADiskNothingCanMakeInstallableIsStillJustRefused() {
        // The running root is not a question. There is no sentence that makes
        // the stick you booted from a place to install.
        var m = atDiskSpoke()
        m.selection = 2                        // da0, the live medium
        XCTAssertTrue(m.isBlocked(m.installableDisks[2]))
        XCTAssertFalse(m.chooseSelection())
        XCTAssertEqual(m.page, .spoke(.disk), "no sheet — there is nothing to ask")
    }

    func testTheSheetsDefaultButtonIsCancel() {
        // Aqua's default button is the blue one, and on every other screen here
        // that is the affirmative. On a sheet that destroys somebody's Windows
        // the default action must be not doing that.
        var m = atDiskSpoke()
        m.selection = 0
        _ = m.chooseSelection()
        let l = installerLayout(w: 520, h: 380, model: m)
        XCTAssertEqual(l.secondaryLabel, "Cancel")
        XCTAssertTrue(l.primaryLabel.contains("nda0"),
                      "the destructive button names the disk: \(l.primaryLabel)")
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
        XCTAssertEqual(m.status(.keyboard), "U.S. (default)")
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
            sets: ["base.txz", "kernel.txz", "abyss.tzst"],
            distDirectory: "/usr/freebsd-dist",
            hostname: "jaguar",
            timezone: "America/Chicago",
            keymap: "uk.kbd",
            rootPasswordHash: "*",
            accounts: [Account(name: "jkane", fullName: "J Kane",
                               passwordHash: "$6$fake",
                               groups: ["wheel", "operator", "audio"], shell: "/bin/sh")])
        XCTAssertEqual(built, expected)
    }

    func testTheAquaInstallerInstallsThisDesktop() {
        // The thing it exists to install is the thing it is running on. A plan
        // from this GUI that installed a plain FreeBSD would boot to a shell,
        // and the person who clicked "Install" would be entitled to be cross.
        let p = ready().plan(passwordHash: "$6$fake")
        XCTAssertTrue(p.installsDesktop, "the Aqua installer did not install the desktop")
        XCTAssertEqual(p.sets.first, "base.txz", "base still has to be first")
        // And the installed machine therefore starts it — at the login window
        // (PHASE16 §6.2), with jkane's account to log in as.
        XCTAssertTrue(rcConf(p).contains("abyss_loginwindow_greeter=\"YES\""))
        XCTAssertFalse(rcConf(p).contains("abyss_desktop_user"))
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

    /// T.1: the hub and the Keyboard page say the layout's name; rc.conf
    /// still gets the file.
    func testTheKeyboardSpokeSaysTheLayoutsNameNotItsFile() {
        var m = ready()
        XCTAssertEqual(m.status(.keyboard), "U.S. (default)")
        m.enter(.keyboard); m.selection = 6; m.chooseSelection()
        XCTAssertEqual(m.keymap, "us.dvorak.kbd", "the plan keeps the file")
        XCTAssertEqual(m.status(.keyboard), "Dvorak")
        XCTAssertEqual(installerKeymapNames.count, installerKeymaps.count)
        XCTAssertEqual(installerKeymapNames[1], "British")
    }
}
