import XCTest
@testable import Aqua
import MenuWire
import Surface

/// The menu bar's island menu (PHASE13 P13.4): where you are, and where every
/// window is.
final class IslandMenuTests: XCTestCase {
    private func w(_ id: UInt32, _ island: Int, _ title: String, display: String = "DP-1") -> MenuBarFocus.IslandWindow {
        MenuBarFocus.IslandWindow(id: id, display: display, island: island, appID: "org.x.\(id)", title: title)
    }

    func testEveryIslandHasARowAndItsWindowsUnderIt() {
        let m = IslandMenu.build(display: "DP-1", active: 2, count: 3, names: ["1", "Mail", "3"],
                                 windows: [w(7, 1, "Notes"), w(9, 2, "Inbox"), w(4, 1, ""),
                                           w(5, 2, "Elsewhere", display: "HDMI-A-1")])
        let rows: [(String, String)] = m.items.compactMap {
            if case .command(let c) = $0 { return (c.verb, c.title) }; return nil
        }
        XCTAssertEqual(rows.map(\.0), ["island.switch.1", "island.window.7", "island.window.4",
                                       "island.switch.2", "island.window.9", "island.switch.3"],
                       "islands in order, each followed by its own windows — and only this display's")
        XCTAssertEqual(rows[0].1, "    Island 1")
        XCTAssertEqual(rows[3].1, "✓ Mail", "the island shown is ticked, by its name")
        XCTAssertTrue(rows[2].1.hasSuffix("org.x.4"), "a window with no title is called by its application")
    }

    func testAChosenRowSaysWhatItAsksFor() {
        XCTAssertEqual(IslandMenu.action("island.switch.3"), .switchTo(3))
        XCTAssertEqual(IslandMenu.action("island.window.42"), .window(42))
        XCTAssertNil(IslandMenu.action("island.switch.x"))
        XCTAssertNil(IslandMenu.action("system.force-quit"))
    }
}
