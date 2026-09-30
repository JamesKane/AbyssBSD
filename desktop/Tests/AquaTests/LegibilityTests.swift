import XCTest
@testable import AquaDraw

/// PHASE11 P11.10: the floor a theme may not go below, measured as WCAG does.
final class LegibilityTests: XCTestCase {
    func testRatiosAreWCAGs() {
        XCTAssertEqual(Legibility.ratio(Color(0, 0, 0), Color(1, 1, 1)), 21, accuracy: 0.01)
        XCTAssertEqual(Legibility.ratio(Color(1, 1, 1), Color(1, 1, 1)), 1, accuracy: 0.001)
        // #767676 on white is the classic "just passes AA" grey.
        XCTAssertGreaterThanOrEqual(Legibility.ratio(Color(hex: 0x767676), Color(1, 1, 1)), 4.5)
        XCTAssertLessThan(Legibility.ratio(Color(hex: 0x777777), Color(1, 1, 1)), 4.5)
    }

    func testTranslucentTextIsMeasuredAsItIsSeen() {
        // White at 20% on white is invisible, whatever its own colour says.
        XCTAssertEqual(Legibility.ratio(Legibility.over(Color(0, 0, 0, 0.2), Color(1, 1, 1)), Color(1, 1, 1)),
                       Legibility.ratio(Color(0.8, 0.8, 0.8), Color(1, 1, 1)), accuracy: 0.001)
    }

    func testUnreadableBodyTextRefusesAndSaysWhy() {
        var t = ThemeTokens.jaguar
        t.bodyText = Color(hex: 0xcccccc)
        let (p, _) = Legibility.check(t)
        XCTAssertTrue(p.contains { $0.hasPrefix("[legibility] bodyText #cccccc on contentBackground #ececec is 1.3") },
                      "\(p)")
        XCTAssertTrue(p.allSatisfy { $0.contains("body text needs 4.5:1") })
        XCTAssertThrowsError(try ThemeLoader.parse("[colors]\nbodyText = #cccccc"), "refused at load")
    }

    func testDimSecondaryTextOnlyWarns() throws {
        let t = try ThemeLoader.parse("[colors]\nsecondaryText = #d0d0d0")
        XCTAssertTrue(t.warnings.contains { $0.hasPrefix("legibility: secondaryText #d0d0d0 on contentBackground") }, "\(t.warnings)")
    }

    func testTargetsAPointerCannotHitRefuse() {
        XCTAssertThrowsError(try ThemeLoader.parse("[metrics]\ntrafficRadius = 4")) { e in
            XCTAssertEqual((e as? ThemeError)?.problems, ["[legibility] a title-bar gadget is 8 pt — a pointer needs 12"])
        }
        XCTAssertThrowsError(try ThemeLoader.parse("[metrics]\nmenu.itemHeight = 12"))
    }

    func testThePaletteIsTheTheme() throws {
        let aqua = ThemePalette.ini(.jaguar, name: "Aqua", scheme: nil)
        XCTAssertTrue(aqua.contains("color-scheme = 2\n"), "light")
        XCTAssertTrue(aqua.contains("accent-color = 0.2471 0.4353 0.8745\n"), "the menu blue the portal always said")
        XCTAssertTrue(aqua.contains("contrast = 0\n"))
        var dark = ThemeTokens.jaguar
        dark.contentBackground = Color(hex: 0x101010); dark.bodyText = Color(1, 1, 1)
        XCTAssertTrue(ThemePalette.ini(dark, name: "x", scheme: nil).contains("color-scheme = 1\n"), "dark")
    }
}
