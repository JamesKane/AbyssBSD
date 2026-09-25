import XCTest
@testable import AquaDraw

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// PHASE11 P11.2: a theme is a file, and the file is strict.
final class ThemeTests: XCTestCase {
    private var aquaINI: String {
        let here = URLlessPath(#filePath)
        return ThemeLoader.readFile(here + "/../../themes/aqua/theme.ini") ?? ""
    }
    private func URLlessPath(_ p: String) -> String {
        String(p[..<p.lastIndex(of: "/")!])
    }

    /// The shipped Aqua theme and the compiled fallback are the same values —
    /// so whichever one draws, Jaguar is what appears, and neither can drift.
    func testTheShippedAquaFileIsTheCompiledJaguar() throws {
        XCTAssertFalse(aquaINI.isEmpty, "themes/aqua/theme.ini is missing")
        let t = try ThemeLoader.parse(aquaINI)
        XCTAssertEqual(t.name, "Aqua")
        XCTAssertEqual(t.tokens, ThemeTokens.jaguar)
        XCTAssertTrue(t.warnings.isEmpty, "\(t.warnings)")
    }

    /// Every token is set by the file, not left to the fallback: a token the
    /// file forgot would still look right today and silently stop being data.
    func testTheAquaFileSetsEveryToken() {
        let c = Set(aquaINI.split(separator: "\n").compactMap { l -> String? in
            guard let eq = l.firstIndex(of: "="), !l.hasPrefix("#") else { return nil }
            return l[..<eq].trimmingCharacters(in: .whitespaces)
        })
        for (k, _) in ThemeTokens.colorKeys { XCTAssertTrue(c.contains(k), "colour \(k) not in the file") }
        for (k, _) in ThemeTokens.metricKeys { XCTAssertTrue(c.contains(k), "metric \(k) not in the file") }
        for (k, _) in ThemeTokens.fontKeys { XCTAssertTrue(c.contains(k), "font \(k) not in the file") }
    }

    func testColourForms() {
        let none: (String) -> Color? = { _ in nil }
        XCTAssertEqual(ThemeLoader.color("#3f6fdf", lookup: none), Color(hex: 0x3f6fdf))
        XCTAssertEqual(ThemeLoader.color("#74a6ee/0.85", lookup: none), Color(hex: 0x74a6ee, a: 0.85))
        XCTAssertEqual(ThemeLoader.color("0 0 0 0.035", lookup: none), Color(0, 0, 0, 0.035))
        XCTAssertEqual(ThemeLoader.color("0.62 0.66 0.72", lookup: none), Color(0.62, 0.66, 0.72))
        for bad in ["#3f6fd", "#zzzzzz", "#3f6fdf/2", "1 2 3", "0 0", "red", "0.5 0.5 x"] {
            XCTAssertNil(ThemeLoader.color(bad, lookup: none), bad)
        }
    }

    /// `color-mix(in oklch, …)`: the ends are exact, and the midpoint of black
    /// and white is OKLab L = 0.5 — sRGB ≈ 0.389, not the 0.5 a naive RGB mix
    /// would give. Plan Neo's derived colours depend on this being the maths
    /// the design used.
    func testOKLCHMixing() {
        let black = Color(0, 0, 0), white = Color(1, 1, 1)
        let mid = ThemeLoader.mixOKLCH(black, white, 0.5)
        XCTAssertEqual(mid.r, 0.3885, accuracy: 0.002)
        XCTAssertEqual(mid.r, mid.g, accuracy: 1e-6)
        let mag = Color(hex: 0xff2bd6)
        let a = ThemeLoader.mixOKLCH(mag, white, 0), b = ThemeLoader.mixOKLCH(mag, white, 1)
        XCTAssertEqual(a.r, mag.r, accuracy: 1e-3); XCTAssertEqual(a.g, mag.g, accuracy: 1e-3)
        XCTAssertEqual(b.r, 1, accuracy: 1e-3); XCTAssertEqual(b.b, 1, accuracy: 1e-3)
        // A hue survives mixing towards white (the achromatic end takes the
        // other end's hue): 86% magenta is still magenta, only lighter.
        let tint = ThemeLoader.mixOKLCH(mag, white, 0.14)
        XCTAssertGreaterThan(tint.r, tint.g); XCTAssertGreaterThan(tint.b, tint.g)
    }

    func testMixesMayNameOtherTokensAndSchemesOverride() throws {
        let t = try ThemeLoader.parse("""
        [theme]
        name = Test
        [colors]
        menuHighlight = #ff2bd6
        menuTextOnHighlight = mix(menuHighlight, #000000, 0.9)
        [colors.daylight]
        menuHighlight = #b0008f
        [parameters]
        bevel = 1 0 3
        [metrics]
        titleBarHeight = 24 * bevel
        """, scheme: "daylight", overrides: ["bevel": 2])
        XCTAssertEqual(t.schemes, ["daylight"])
        XCTAssertEqual(t.tokens.menuHighlight, Color(hex: 0xb0008f), "the scheme overrides the base")
        XCTAssertEqual(t.tokens.titleBarHeight, 48, "a metric times a parameter")
        XCTAssertLessThan(t.tokens.menuTextOnHighlight.r, 0.2, "mixed from the scheme's own token")
        XCTAssertEqual(t.tokens.menuText, ThemeTokens.jaguar.menuText, "what a file does not set stays Jaguar's")
    }

    /// Strict, and it says why — a misspelt token must not quietly draw Jaguar's
    /// value in a theme that otherwise looks right.
    func testEveryMistakeIsRefusedByName() {
        func problems(_ s: String, scheme: String? = nil) -> [String] {
            do { _ = try ThemeLoader.parse(s, scheme: scheme); return [] }
            catch let e as ThemeError { return e.problems } catch { return ["\(error)"] }
        }
        XCTAssertEqual(problems("[colors]\nmenuHighlite = #ffffff"),
                       ["[colors] menuHighlite is not a token (misspelt?)"])
        XCTAssertEqual(problems("[colors]\nmenuHighlight = blue"),
                       ["[colors] menuHighlight = blue: not a colour"])
        XCTAssertEqual(problems("[metrics]\ntitleBarHeight = tall"),
                       ["[metrics] titleBarHeight = tall: want a number, or \"number * parameter\""])
        XCTAssertEqual(problems("[metrics]\ntitleBarHeight = 2 * glow"),
                       ["[metrics] titleBarHeight = 2 * glow: want a number, or \"number * parameter\""],
                       "a parameter the theme does not declare")
        XCTAssertEqual(problems("[widgets]\nx = 1"), ["[widgets] is not a section a theme has"])
        XCTAssertEqual(problems("[colors]\nmenuHighlight = #ffffff", scheme: "neon"),
                       ["there is no scheme neon (the theme has: none)"])
        let cycle = problems("[colors]\nmenuText = mix(menuBorder, #000000, 0.5)\nmenuBorder = mix(menuText, #ffffff, 0.5)")
        XCTAssertTrue(cycle.contains { $0.contains("refers to itself") }, "\(cycle)")
    }

    func testParametersAreBoundedAndOverridable() throws {
        let t = try ThemeLoader.parse("[parameters]\nglow = 0.6 0 1", overrides: ["glow": 4, "blur": 1])
        XCTAssertEqual(t.parameters, [ThemeParameter(name: "glow", value: 1, min: 0, max: 1)])
        XCTAssertTrue(t.warnings.contains { $0.contains("clamped") })
        XCTAssertTrue(t.warnings.contains { $0.contains("no parameter blur") })
        XCTAssertThrowsError(try ThemeLoader.parse("[parameters]\nglow = 0.6 1 0"), "min above max")
    }

    func testAMissingOrRefusedThemeFallsBackToJaguarAndSaysSo() throws {
        let dir = NSTemporaryDirectoryPath() + "/abyss-theme-\(getpid())"
        mkdir(dir, 0o700); mkdir(dir + "/aqua", 0o700)
        defer { unlink(dir + "/aqua/theme.ini"); rmdir(dir + "/aqua"); rmdir(dir) }
        setenv("ABYSS_THEME_DIR", dir, 1)
        setenv("ABYSS_CONFIG_DIR", dir, 1)   // no appearance.ini: the choice is aqua
        defer { unsetenv("ABYSS_THEME_DIR"); unsetenv("ABYSS_CONFIG_DIR"); Theme.use(.jaguar) }
        let f = fopen(dir + "/aqua/theme.ini", "w")!
        fputs("[colors]\nmenuHighlight = #000001\n", f); fclose(f)
        guard case .loaded(let t, let path) = ThemeLoader.loadCurrent() else { return XCTFail("did not load") }
        XCTAssertEqual(path, dir + "/aqua/theme.ini")
        XCTAssertEqual(Theme.menuHighlight, Color(hex: 0x000001), "Theme.x reads the loaded theme")
        XCTAssertEqual(t.tokens.menuHighlight, Color(hex: 0x000001))

        let g = fopen(dir + "/aqua/theme.ini", "w")!
        fputs("[colors]\nmenuHighlite = #000001\n", g); fclose(g)
        guard case .refused = ThemeLoader.loadCurrent() else { return XCTFail("a bad theme was not refused") }
        XCTAssertEqual(Theme.current, .jaguar, "refused means Jaguar, not half a theme")
    }

    /// The compiled Jaguar lists are the shipped file, byte for byte — as the
    /// compiled tokens are the shipped theme.ini — so whichever draws, it is
    /// the same Jaguar.
    func testTheCompiledJaguarListsAreTheShippedFile() throws {
        let here = URLlessPath(#filePath)
        let file = try XCTUnwrap(ThemeLoader.readFile(here + "/../../themes/aqua/draw/aqua.dl"))
        XCTAssertEqual(JaguarLists.source + "\n", file,
                       "themes/aqua/draw/aqua.dl changed: run abyss/tools/gen-jaguar-lists.sh")
        XCTAssertGreaterThan(JaguarLists.file.lists.count, 20)
    }

    /// A theme's draw/ is strict as its theme.ini is, and what it does not ship
    /// stays Jaguar's.
    func testDrawListsLoadStrictlyAndFallBackPerList() throws {
        let dir = NSTemporaryDirectoryPath() + "/abyss-lists-\(getpid())"
        mkdir(dir, 0o700); mkdir(dir + "/draw", 0o700)
        func write(_ name: String, _ text: String) {
            let f = fopen(dir + "/draw/" + name, "w")!; fputs(text, f); fclose(f)
        }
        defer {
            for n in ["a.dl", "b.dl", "c.dl"] { unlink(dir + "/draw/" + n) }
            rmdir(dir + "/draw"); rmdir(dir); Theme.use(.jaguar)
        }
        XCTAssertNil(try ThemeLoader.loadLists(dir + "/nowhere").0, "no draw/ is not an error: all Jaguar")

        write("a.dl", "list pill\n  rect 0 0 w h\n  fill #ff0000\nend\nlist sparkle\n  rect 0 0 w h\nend\n")
        let (lists, warnings) = try ThemeLoader.loadLists(dir)
        XCTAssertEqual(warnings, ["list sparkle (draw/a.dl) is not one the toolkit draws"])
        Theme.use(.jaguar, lists: lists)
        XCTAssertEqual(Theme.lists["pill"]?.steps.count, 2, "the theme's pill replaces Jaguar's")
        XCTAssertNotNil(Theme.lists["button"], "and the button it does not ship stays Jaguar's")

        write("b.dl", "list tab\n  frobnicate\nend\n")
        write("c.dl", "list pill\nend\n")
        XCTAssertThrowsError(try ThemeLoader.loadLists(dir)) { e in
            XCTAssertEqual((e as? ThemeError)?.problems, [
                "draw/b.dl line 2: frobnicate is not an op (rect ellipse circle path fill stroke bevel innershadow glow rules text push pop clip)",
                "draw/c.dl: list pill is also in draw/a.dl",
            ])
        }
    }

    private func NSTemporaryDirectoryPath() -> String {
        getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp"
    }
}

private extension Substring {
    func trimmingCharacters(in _: CharacterSetStub) -> String { String(self).trimmingSpaces }
}
private enum CharacterSetStub { case whitespaces }
