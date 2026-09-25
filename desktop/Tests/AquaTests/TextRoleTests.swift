import XCTest
@testable import AquaDraw

/// PHASE11 P11.7: type by role — a family per role, found by name, with the
/// default chain behind each.
final class TextRoleTests: XCTestCase {
    private var fonts: String {
        String(#filePath[..<#filePath.lastIndex(of: "/")!]) + "/../../fonts"
    }

    override func setUpWithError() throws {
        guard Text.available else { throw XCTSkip("no fonts") }
        Text.addFontDirs([fonts])   // once per process; ThemeLoader does it too
    }
    override func tearDown() { Theme.use(.jaguar) }

    private func roles(_ r: [Text.Role: String]) {
        var t = ThemeTokens.jaguar
        t.fontInterface = r[.interface] ?? "Lucida Grande"
        t.fontChrome = r[.chrome] ?? "Lucida Grande"
        t.fontReadout = r[.readout] ?? "Lucida Grande"
        t.fontMono = r[.mono] ?? "Monaco"
        Theme.use(t)
    }

    func testAVendoredFamilyIsFoundByName() {
        roles([.chrome: "Chakra Petch", .readout: "VT323"])
        let c = Text.resolved(.chrome), r = Text.resolved(.readout)
        XCTAssertTrue(c.wanted); XCTAssertEqual(c.family, "Chakra Petch")
        XCTAssertTrue(c.file.hasSuffix("fonts/chakrapetch/ChakraPetch-Regular.ttf"), c.file)
        XCTAssertTrue(r.wanted); XCTAssertTrue(r.file.hasSuffix("VT323-Regular.ttf"), r.file)
    }

    /// A family that is not here is not replaced by whatever fontconfig likes
    /// best: the role draws with the default chain, and says it did.
    func testAMissingFamilyFallsBackToTheDefaultChainNotASubstitute() {
        roles([.chrome: "Lucida Grande"])
        let c = Text.resolved(.chrome), i = Text.resolved(.interface)
        XCTAssertFalse(c.wanted)
        XCTAssertEqual(c.file, i.file, "the default chain's primary, the same as every unmatched role")
        XCTAssertEqual(Text.shape("AbyssBSD", px: 13, role: .chrome).map(\.index),
                       Text.shape("AbyssBSD", px: 13, role: .interface).map(\.index),
                       "Aqua's text is exactly what it was before roles")
    }

    /// Roles change the glyphs, and their width — and a role's metrics are its
    /// own face's.
    func testARoleDrawsInItsOwnFace() {
        roles([.chrome: "Chakra Petch", .readout: "VT323"])
        let plain = Text.width(Text.shape("PLAN NEO 14:07", px: 26, role: .interface))
        let chrome = Text.width(Text.shape("PLAN NEO 14:07", px: 26, role: .chrome))
        let lcd = Text.width(Text.shape("PLAN NEO 14:07", px: 26, role: .readout))
        XCTAssertNotEqual(plain, chrome); XCTAssertNotEqual(chrome, lcd)
        XCTAssertNotEqual(Text.metrics(px: 26, role: .readout).ascent, Text.metrics(px: 26).ascent)
    }

    /// Bold comes from the family's own bold file; a family with no bold keeps
    /// its typeface at regular weight rather than borrowing another's bold.
    func testAStyleTheFamilyLacksKeepsTheFamily() {
        roles([.chrome: "Chakra Petch", .readout: "VT323"])
        let chromeBold = Text.shape("A", px: 20, style: .bold, role: .chrome)
        let chromeReg = Text.shape("A", px: 20, role: .chrome)
        XCTAssertNotEqual(chromeBold.first?.face, chromeReg.first?.face, "Chakra Petch Bold is its own file")
        XCTAssertEqual(Text.shape("A", px: 20, style: .bold, role: .readout).first?.face,
                       Text.shape("A", px: 20, role: .readout).first?.face,
                       "VT323 has no bold: its regular, not Noto Bold")
    }

    /// A codepoint the role's family lacks is drawn from the chain behind it.
    func testTheChainIsBehindEveryRole() {
        roles([.readout: "VT323"])
        let g = Text.shape("1⌘", px: 20, role: .readout)
        XCTAssertEqual(g.count, 2)
        XCTAssertNotEqual(g[0].face, g[1].face, "⌘ is not in VT323; it came from a fallback face")
    }

    func testMonoFallsBackToAFixedPitchFace() {
        roles([:])   // mono = Monaco, not here
        let m = Text.resolved(.mono)
        XCTAssertFalse(m.wanted)
        XCTAssertNotEqual(m.file, Text.resolved(.interface).file, "not the proportional default")
        let i = Text.width(Text.shape("iiii", px: 20, role: .mono))
        let w = Text.width(Text.shape("WWWW", px: 20, role: .mono))
        XCTAssertEqual(i, w, accuracy: 0.5, "fixed pitch")
    }

    func testADrawListNamesARole() throws {
        XCTAssertNoThrow(try DrawListFile(parsing: "list a\n  text \"x\" 0 0 role=readout\nend"))
        XCTAssertThrowsError(try DrawListFile(parsing: "list a\n  text \"x\" 0 0 role=display\nend")) { e in
            XCTAssertEqual((e as? DrawListError)?.message, "display is not a role (interface chrome readout mono)")
        }
    }
}
