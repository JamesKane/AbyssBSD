import XCTest
@testable import Aqua

final class AquaTests: XCTestCase {
    func testColorHex() {
        let c = Color(hex: 0xFF8040)
        XCTAssertEqual(c.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(c.g, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(c.b, 64.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(c.a, 1.0, accuracy: 0.001)
    }

    func testColorWithAlpha() {
        let c = Color(hex: 0x000000).with(a: 0.5)
        XCTAssertEqual(c.a, 0.5, accuracy: 0.001)
    }

    func testRectContains() {
        let r = Rect(10, 10, 100, 50)
        XCTAssertTrue(r.contains(20, 20))
        XCTAssertTrue(r.contains(10, 10))     // edge inclusive
        XCTAssertTrue(r.contains(110, 60))    // far edge inclusive
        XCTAssertFalse(r.contains(5, 5))
        XCTAssertFalse(r.contains(200, 200))
    }
}
