import XCTest
@testable import Aqua
@testable import AquaDraw
import MenuModel

/// PHASE14 P14.1: System Preferences is an application — one layout for paint
/// and hit-test, honest pages, and a vocabulary.
final class SystemPreferencesTests: XCTestCase {
    func testTheCatalogueIsWhatTheThemeCanDraw() {
        let ids = PrefCatalogue.all.map(\.id)
        XCTAssertEqual(ids.count, 25)
        XCTAssertEqual(Set(ids).count, ids.count, "pane ids are unique")
        for id in ids { XCTAssertNotNil(Theme.lists["icon." + id], "no icon.\(id) in the icon set") }
        XCTAssertEqual(PrefCatalogue.toolbar.map(\.id), ["displays", "sound", "network", "startupDisk"])
    }

    /// §2.9: every point of every cell is hit as that cell, and cells answer
    /// only while the grid is showing.
    func testEveryCellIsHitWhereItIsDrawn() {
        let l = prefsLayout(w: 760, h: 620)
        XCTAssertEqual(l.cells.count, PrefCatalogue.all.count)
        var m = PrefsModel()
        for c in l.cells {
            XCTAssertEqual(prefsHit(l, m, x: c.icon.x + c.icon.w / 2, y: c.icon.y + c.icon.h / 2), .pane(c.pane))
            XCTAssertEqual(prefsHit(l, m, x: c.labelCenterX, y: c.labelTop + 4), .pane(c.pane), "the label too")
        }
        for (i, a) in l.cells.enumerated() {
            for b in l.cells[(i + 1)...] {
                XCTAssertFalse(a.hit.x < b.hit.x + b.hit.w && b.hit.x < a.hit.x + a.hit.w
                               && a.hit.y < b.hit.y + b.hit.h && b.hit.y < a.hit.y + a.hit.h,
                               "\(a.pane) overlaps \(b.pane)")
            }
        }
        XCTAssertEqual(prefsHit(l, m, x: l.showAll.x + 20, y: l.showAll.y + 10), .showAll)
        let net = l.toolbarItems.first { $0.pane == "network" }!
        m.view = .pane("sound")
        XCTAssertEqual(prefsHit(l, m, x: net.hit.x + 30, y: net.hit.y + 10), .pane("network"), "the toolbar works on a page")
        let desktop = l.cells.first { $0.pane == "desktop" }!
        XCTAssertNil(prefsHit(l, m, x: desktop.icon.x + 5, y: desktop.icon.y + 5), "the grid is not there on a page")
    }

    func testAPageIsTitledAndHonest() {
        var m = PrefsModel()
        XCTAssertEqual(m.title, "System Preferences")
        m.view = .pane("network")
        XCTAssertEqual(m.title, "Network")
        XCTAssertEqual(m.note(for: "network"), "This pane cannot change anything yet.")
        m.notes["network"] = "the settings service is not running"
        XCTAssertEqual(m.note(for: "network"), "the settings service is not running")
    }

    func testTheKeyboardWalksThePanesInReadingOrder() {
        var m = PrefsModel()
        m.moveFocus(1); XCTAssertEqual(m.focus, "desktop")
        m.moveFocus(1); XCTAssertEqual(m.focus, "dock")
        m.moveFocus(-5); XCTAssertEqual(m.focus, "desktop", "clamped at the first")
        m.moveFocus(7); XCTAssertEqual(m.focus, "cdsDvds", "down a row is the next section's first")
        m.moveFocus(100); XCTAssertEqual(m.focus, "universalAccess", "clamped at the last")
    }

    func testTheVocabulary() {
        let mb = systemPreferencesMenuBar()
        XCTAssertTrue(mb.conflictingKeys.isEmpty, "\(mb.conflictingKeys)")
        XCTAssertEqual(mb.verb(for: .cmd("l")), PrefsVerb.showAll)
        XCTAssertEqual(mb.verb(for: .cmd("q")), PrefsVerb.quit)
        let view = mb.menus.first { $0.title == "View" }!
        XCTAssertEqual(view.commands.compactMap { PrefsVerb.paneID($0.verb) }, PrefCatalogue.all.map(\.id),
                       "the View menu lists every pane, in the grid's order")
    }
}
