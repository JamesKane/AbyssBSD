// Theme switch tests — a theme changed while a process runs (PHASE14 P14.2).
//
// Two tiny themes in a directory of their own, and a config directory the
// choice is written into the way System Preferences will write it. What must
// hold: a changed choice reloads and an unchanged one does not; the watch sees
// a choice another process wrote and ignores every other file; and no mask
// drawn in the old theme survives into the new one (§6.7).

import XCTest
import CCairo
@testable import AquaDraw

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class ThemeSwitchTests: XCTestCase {

    private var themes = ""
    private var config = ""

    private func tempDir(_ name: String) -> String {
        var t = Array("/tmp/abyss-\(name)-XXXXXX".utf8CString)
        return t.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
    }
    private func write(_ path: String, _ text: String) {
        let f = fopen(path, "w")!; fputs(text, f); fclose(f)
    }

    override func setUp() {
        themes = tempDir("themes")
        config = tempDir("config")
        for (name, colour) in [("one", "#000001"), ("two", "#000002")] {
            mkdir(themes + "/" + name, 0o700)
            write(themes + "/\(name)/theme.ini", """
                [colors]
                menuHighlight = \(colour)
                [colors.dim]
                menuHighlight = #000009
                [parameters]
                glow = 0.5 0 1
                """)
        }
        setenv("ABYSS_THEME_DIR", themes, 1)
    }

    override func tearDown() {
        unsetenv("ABYSS_THEME_DIR")
        Theme.use(.jaguar)
        for n in ["one", "two"] { unlink(themes + "/\(n)/theme.ini"); rmdir(themes + "/" + n) }
        rmdir(themes)
        for f in ["appearance.ini", "desktop.ini"] { unlink(config + "/" + f) }
        rmdir(config)
    }

    private func loadedName(_ o: ThemeLoader.Outcome?) -> String? {
        guard case .loaded(_, let path)? = o else { return nil }
        return String(path.split(separator: "/").dropLast().last ?? "")
    }

    func testAChangedChoiceReloadsAndAnUnchangedOneDoesNot() throws {
        try ThemeLoader.store(theme: "one", scheme: nil, configDir: config)
        XCTAssertEqual(loadedName(ThemeLoader.loadCurrent(configDir: config)), "one")
        XCTAssertEqual(Theme.menuHighlight, Color(hex: 0x000001))
        let g = Theme.generation

        XCTAssertNil(ThemeLoader.reloadIfChanged(configDir: config), "nothing changed")
        XCTAssertEqual(Theme.generation, g, "and nothing was reloaded")

        try ThemeLoader.store(theme: "two", scheme: nil, configDir: config)
        XCTAssertEqual(loadedName(ThemeLoader.reloadIfChanged(configDir: config)), "two")
        XCTAssertEqual(Theme.menuHighlight, Color(hex: 0x000002), "Theme.x reads the new theme")
        XCTAssertGreaterThan(Theme.generation, g)

        // A scheme is a change; so is a parameter.
        try ThemeLoader.store(theme: "two", scheme: "dim", configDir: config)
        XCTAssertNotNil(ThemeLoader.reloadIfChanged(configDir: config))
        XCTAssertEqual(Theme.menuHighlight, Color(hex: 0x000009))
        try ThemeLoader.store(theme: "two", scheme: "dim", parameters: ["glow": 0.25], configDir: config)
        XCTAssertNotNil(ThemeLoader.reloadIfChanged(configDir: config))
        XCTAssertEqual(Theme.parameters["glow"], 0.25)
    }

    /// Another process writes the choice (System Preferences, P14.2); this one
    /// is told through a descriptor it can wait on with everything else — and
    /// a write to some other file in the same directory is not a theme change.
    func testTheWatchSeesAChoiceAnotherProcessWroteAndIgnoresOtherFiles() throws {
        try ThemeLoader.store(theme: "one", scheme: nil, configDir: config)
        ThemeLoader.loadCurrent(configDir: config)
        guard let watch = ThemeLoader.Watch(configDir: config) else { return XCTFail("no watch") }

        func readable() -> Bool {
            var p = pollfd(fd: watch.fileDescriptor, events: Int16(POLLIN), revents: 0)
            return poll(&p, 1, 2000) == 1
        }

        write(config + "/desktop.ini", "[desktop]\nx = 1\n")
        XCTAssertTrue(readable(), "the directory changed")
        XCTAssertNil(watch.check(), "but not the appearance")
        XCTAssertEqual(Theme.menuHighlight, Color(hex: 0x000001))

        try ThemeLoader.store(theme: "two", scheme: nil, configDir: config)
        XCTAssertTrue(readable(), "the watch did not see the choice being written")
        XCTAssertEqual(loadedName(watch.check()), "two")
        XCTAssertEqual(Theme.menuHighlight, Color(hex: 0x000002))
    }

    /// **No mask outlives its theme** (PHASE14 §6.7): glows are cached by a
    /// shape's name and halos are shaped from a role's font, and a new theme
    /// may change either. Noise tiles are the same in every theme, and stay.
    func testASwitchForgetsGlowAndHaloMasksButKeepsNoise() {
        func mask() -> OpaquePointer { cairo_image_surface_create(CAIRO_FORMAT_A8, 4, 4)! }
        DrawListRunner.glowCache[.init(shape: "x", w: 4, h: 4, radius: 1, scale: 1)] = mask()
        DrawListRunner.haloCache[.init(s: "x", px: 12, style: 0, role: 0, radius: 1, scale: 1, tracking: 0)] = (mask(), 0, 0)
        _ = DrawListRunner.noisePattern(99, 0.5)
        let noise = DrawListRunner.noiseTiles.count
        XCTAssertFalse(DrawListRunner.glowCache.isEmpty)

        Theme.use(.jaguar)
        XCTAssertTrue(DrawListRunner.glowCache.isEmpty, "a glow from the old theme survived")
        XCTAssertTrue(DrawListRunner.haloCache.isEmpty, "a halo from the old theme survived")
        XCTAssertEqual(DrawListRunner.noiseTiles.count, noise, "noise is not theme-derived")
    }
}
