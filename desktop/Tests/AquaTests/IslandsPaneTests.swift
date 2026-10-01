import XCTest
@testable import Aqua
import PoolConfig

/// The Islands pane (PHASE13 P13.7): what a click writes, and the keys shown
/// as they are bound.
final class IslandsPaneTests: XCTestCase {
    func testKeysReadAsAMacMenuShowsThem() {
        XCTAssertEqual(IslandsKeys.pretty("Ctrl+Alt+Shift+1"), "⌃⌥⇧1")
        XCTAssertEqual(IslandsKeys.pretty("Ctrl+Left"), "⌃←")
        XCTAssertEqual(IslandsKeys.pretty("F3"), "F3")
        XCTAssertEqual(IslandsKeys.pretty("Ctrl+Alt+minus"), "⌃⌥−")
    }

    func testTheKeysAreShownAsBoundWithKeysIniOverTheDefaults() {
        var table = DesktopKeys.defaults
        let shown = Dictionary(IslandsKeys.shown(table), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(shown["Show island N"], "⌃1…9")
        XCTAssertEqual(shown["New shoal from window"], "⌃⌥N", "the letter N, which is why numbers are not shown as N")
        XCTAssertEqual(shown["Next / previous island"], "⌃← / ⌃→")
        XCTAssertEqual(shown["…and go with it"], "⌃⌥⇧1…9")
        XCTAssertEqual(shown["Ebb: this island"], "F3")
        XCTAssertEqual(shown["Recall shoal N"], "⌃⇧1…9")
        // A keys.ini row rebinding Ebb, as DesktopKeys.effective lays it over.
        table.removeAll { $0.0 == "F3" }
        table.append(("F4", "ebb island"))
        XCTAssertEqual(Dictionary(IslandsKeys.shown(table), uniquingKeysWith: { a, _ in a })["Ebb: this island"], "F4")
        table.removeAll { $0.1 == "shoal strip" }
        XCTAssertEqual(Dictionary(IslandsKeys.shown(table), uniquingKeysWith: { a, _ in a })["Show the shoals strip"], "none")
    }

    func testAClickChangesOneThingAndKeepsTheRest() {
        let c = IslandsConfig(count: 4, names: ["Home", "Mail"], animate: true, slideMs: 300)
        let six = IslandsWrite.next(.count(6), from: c)
        XCTAssertEqual(six.count, 6); XCTAssertEqual(six.names, ["Home", "Mail"]); XCTAssertEqual(six.slideMs, 300)
        XCTAssertFalse(IslandsWrite.next(.slide, from: c).animate)
        XCTAssertEqual(IslandsWrite.next(.count(40), from: c).count, IslandsConfig.maxCount)
    }
}
