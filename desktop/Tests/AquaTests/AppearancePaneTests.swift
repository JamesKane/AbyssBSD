// General pane tests — choosing the theme (PHASE14 P14.2).
//
// The pane offers what is installed, lays out one row per choice (one layout
// for paint and hit-test, §2.9), and writes exactly the choice made: a new
// theme starts from its own defaults, a scheme or a setting keeps the rest.

import XCTest
@testable import Aqua
@testable import AquaDraw

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class AppearancePaneTests: XCTestCase {

    private var dir = ""

    override func setUp() {
        var t = Array("/tmp/abyss-pane-XXXXXX".utf8CString)
        dir = t.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
        func theme(_ id: String, _ body: String) {
            mkdir(dir + "/" + id, 0o700)
            let f = fopen(dir + "/\(id)/theme.ini", "w")!; fputs(body, f); fclose(f)
        }
        theme("aqua", "[theme]\nname = Aqua\n")
        theme("zeta", "[theme]\nname = Zeta\ndefault_scheme = dark\n[parameters]\nglow = 0.5 0 1\nwidth = 2 1 4\n[colors.dark]\nmenuHighlight = #000001\n[colors.light]\nmenuHighlight = #000002\n")
        theme("broken", "[colors]\nmenuHighlite = #000001\n")
    }

    override func tearDown() {
        for id in ["aqua", "zeta", "broken"] { unlink(dir + "/\(id)/theme.ini"); rmdir(dir + "/" + id) }
        rmdir(dir)
    }

    func testTheCatalogueOffersWhatParsesAquaFirst() {
        let t = AppearanceCatalogue.installed(dirs: [dir])
        XCTAssertEqual(t.map(\.id), ["aqua", "zeta"], "a theme that does not parse is not offered")
        let z = t[1]
        XCTAssertEqual(z.name, "Zeta")
        XCTAssertEqual(z.schemes, ["dark", "light"])
        XCTAssertEqual(z.defaultScheme, "dark")
        XCTAssertEqual(z.parameters.map(\.name), ["glow", "width"])
        XCTAssertTrue(t[0].schemes.isEmpty)
    }

    /// One row per choice, each hit where it is drawn, none overlapping — and
    /// the schemes and settings are the chosen theme's.
    func testEveryRowIsHitWhereItIsDrawnAndNoneOverlap() {
        let themes = AppearanceCatalogue.installed(dirs: [dir])
        let choice = AppearanceChoice(theme: "zeta", scheme: nil, parameters: [:])
        let l = appearanceLayout(body: Rect(0, 100, 760, 500), themes: themes, choice: choice)
        XCTAssertEqual(l.themes.map(\.value), ["aqua", "zeta"])
        XCTAssertEqual(l.schemes.map(\.value), ["dark", "light"])
        XCTAssertEqual(l.parameters.map(\.value), ["glow", "width"])
        func hit(_ r: Rect) -> AppearanceHit? {
            appearanceHit(l, themes: themes, choice: choice, x: r.x + r.w / 2, y: r.y + r.h / 2)
        }
        for r in l.themes { XCTAssertEqual(hit(r.control), .theme(r.value)) }
        for r in l.schemes { XCTAssertEqual(hit(r.control), .scheme(r.value)) }
        let rows = l.themes + l.schemes + l.parameters
        for (i, a) in rows.enumerated() {
            for b in rows[(i + 1)...] {
                let overlap = a.hit.x < b.hit.x + b.hit.w && b.hit.x < a.hit.x + a.hit.w
                    && a.hit.y < b.hit.y + b.hit.h && b.hit.y < a.hit.y + a.hit.h
                XCTAssertFalse(overlap, "\(a.value) overlaps \(b.value)")
            }
        }
        // Aqua has one look: no schemes to offer, and no settings.
        let aqua = appearanceLayout(body: Rect(0, 100, 760, 500), themes: themes,
                                    choice: AppearanceChoice(theme: "aqua", scheme: nil, parameters: [:]))
        XCTAssertTrue(aqua.schemes.isEmpty)
        XCTAssertTrue(aqua.parameters.isEmpty)
    }

    /// A setting's track spans its bounds, clamped at both ends.
    func testASliderSpansItsParametersBounds() {
        let p = ThemeParameter(name: "width", value: 2, min: 1, max: 4)
        let track = Rect(100, 0, 150, 20)
        XCTAssertEqual(appearanceValue(p, track: track, x: 100), 1)
        XCTAssertEqual(appearanceValue(p, track: track, x: 250), 4)
        XCTAssertEqual(appearanceValue(p, track: track, x: 175), 2.5)
        XCTAssertEqual(appearanceValue(p, track: track, x: 0), 1, "clamped")
        XCTAssertEqual(appearanceValue(p, track: track, x: 999), 4, "clamped")
    }

    /// What each choice writes.
    func testANewThemeStartsFromItsDefaultsAndTheRestKeepsWhatWasChosen() {
        let now = AppearanceChoice(theme: "zeta", scheme: "light", parameters: ["glow": 0.2])
        XCTAssertEqual(AppearanceWrite.next(.theme("aqua"), from: now),
                       AppearanceChoice(theme: "aqua", scheme: nil, parameters: [:]),
                       "another theme's scheme and settings are not this one's")
        XCTAssertEqual(AppearanceWrite.next(.theme("zeta"), from: now), now, "the same theme changes nothing")
        XCTAssertEqual(AppearanceWrite.next(.scheme("dark"), from: now),
                       AppearanceChoice(theme: "zeta", scheme: "dark", parameters: ["glow": 0.2]))
        XCTAssertEqual(AppearanceWrite.next(.parameter("width", 2.4567), from: now).parameters,
                       ["glow": 0.2, "width": 2.46], "to two places, as shown")
    }

    func testAValueIsShownToTwoPlaces() {
        XCTAssertEqual(twoPlaces(0.6), "0.60")
        XCTAssertEqual(twoPlaces(1), "1.00")
        XCTAssertEqual(twoPlaces(2.456), "2.46")
        XCTAssertEqual(twoPlaces(0.05), "0.05")
    }
}
