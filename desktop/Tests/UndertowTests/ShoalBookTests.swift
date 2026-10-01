import XCTest
@testable import Undertow
import PoolConfig

/// Shoals' rules (PHASE13 P13.6): explicit sets, one shoal per window, kept.
final class ShoalBookTests: XCTestCase {
    func testAWindowIsInOneShoalAtMost() {
        var b = ShoalBook()
        let s1 = b.new(with: "a", display: "D", island: 1)
        XCTAssertEqual(b.shoals[s1].name, "Shoal 1")
        XCTAssertTrue(b.add("b", to: s1))
        let s2 = b.new(with: "c", display: "D", island: 1)
        XCTAssertEqual(b.shoals[s2].name, "Shoal 2")
        XCTAssertTrue(b.add("b", to: s2), "b moves")
        XCTAssertEqual(b.shoals.first { $0.name == "Shoal 1" }?.members, ["a"])
        XCTAssertEqual(b.shoal(of: "b").map { b.shoals[$0].name }, "Shoal 2")
        XCTAssertEqual(b.current.map { b.shoals[$0].name }, "Shoal 2", "add means the shoal last added to")
    }

    func testAShoalLeftEmptyIsGoneAndNumbersAreNotReused() {
        var b = ShoalBook()
        b.new(with: "a", display: "D", island: 1)
        b.new(with: "b", display: "D", island: 1)
        XCTAssertTrue(b.leave("a"))
        XCTAssertEqual(b.shoals.map(\.name), ["Shoal 2"])
        let c = b.new(with: "c", display: "D", island: 1)
        XCTAssertEqual(b.shoals[c].name, "Shoal 3")
        XCTAssertFalse(b.leave("nobody"))
    }

    func testShoalsLiveOnAnIslandAndAreKept() {
        var b = ShoalBook()
        b.new(with: "a", display: "D", island: 2)
        b.add("b/Title with spaces", to: 0)
        b.new(with: "c", display: "D", island: 1)
        XCTAssertEqual(b.onIsland("D", 2), [0])
        XCTAssertEqual(b.onIsland("D", 1), [1])
        XCTAssertEqual(b.onIsland("E", 1), [])
        b.pinned = true
        let again = ShoalBook.from(Config.parse(b.config.toINI()))
        XCTAssertEqual(again.shoals, b.shoals)
        XCTAssertTrue(again.pinned)
    }
}
