import XCTest
@testable import PoolConfig

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class PoolConfigTests: XCTestCase {

    // A fresh, unique temp directory (created), so tests never touch the real
    // ~/.config/abyss and don't collide.
    private func makeTempDir() -> String {
        let base = getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp"
        var template = Array((base + "/poolcfg.XXXXXX").utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buf -> String? in
            mkdtemp(buf.baseAddress!).map { String(cString: $0) }
        }
        return path ?? base
    }

    private func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }

    // MARK: parse + typed coercion

    func testParseSectionsAndTypes() {
        // The panel.ini shape from the pool briefing.
        let ini = """
        schema_version = 1

        [panel]
        bg = #ff202028
        apps = firefox,nautilus
        height = 28
        show_clock = true
        offset = -3

        # a comment, and a blank line follow

        [desktop]
        image = /path/to/wallpaper.png
        """
        let c = Config.parse(ini)

        XCTAssertEqual(c.schemaVersion, 1)
        XCTAssertEqual(c.string("panel", "bg"), "#ff202028")
        XCTAssertEqual(c.string("panel", "apps"), "firefox,nautilus")
        XCTAssertEqual(c.uint64("panel", "height"), 28)
        XCTAssertEqual(c.bool("panel", "show_clock"), true)
        XCTAssertEqual(c.int64("panel", "offset"), -3)
        XCTAssertEqual(c.string("desktop", "image"), "/path/to/wallpaper.png")

        // Absent keys/sections and type mismatches are nil, not crashes.
        XCTAssertNil(c.string("panel", "nope"))
        XCTAssertNil(c.string("nosuch", "key"))
        XCTAssertNil(c.uint64("panel", "bg"))     // "#ff202028" isn't a number
        XCTAssertNil(c.bool("panel", "apps"))     // not a boolean literal
    }

    func testBooleanVariants() {
        let c = Config.parse("""
        [b]
        a = TRUE
        b = on
        c = Yes
        d = 1
        e = off
        f = NO
        g = 0
        h = maybe
        """)
        XCTAssertEqual(c.bool("b", "a"), true)
        XCTAssertEqual(c.bool("b", "b"), true)
        XCTAssertEqual(c.bool("b", "c"), true)
        XCTAssertEqual(c.bool("b", "d"), true)
        XCTAssertEqual(c.bool("b", "e"), false)
        XCTAssertEqual(c.bool("b", "f"), false)
        XCTAssertEqual(c.bool("b", "g"), false)
        XCTAssertNil(c.bool("b", "h"))
    }

    // MARK: serialize

    func testToINIDeterministicAndReparses() {
        var c = Config()
        c.set("", "schema_version", uint64: 1)
        c.set("panel", "height", uint64: 28)
        c.set("panel", "bg", "#ff202028")
        c.set("desktop", "image", "/wall.png")
        c.set("desktop", "show", bool: false)

        let text = c.toINI()
        // Default section first (no header); sections and keys sorted.
        XCTAssertEqual(text, """
        schema_version = 1

        [desktop]
        image = /wall.png
        show = false

        [panel]
        bg = #ff202028
        height = 28

        """)
        // Byte-identical after a round-trip through the parser.
        XCTAssertEqual(Config.parse(text).toINI(), text)
    }

    // MARK: store / load round-trip

    func testStoreLoadRoundTrip() throws {
        let dir = makeTempDir()
        var c = Config()
        c.set("", "schema_version", uint64: 2)
        c.set("desktop", "grad_top", "#ff0a0e16")
        c.set("desktop", "height", uint64: 600)
        c.set("desktop", "enabled", bool: true)
        try c.store("desktop", in: dir)

        XCTAssertTrue(exists(dir + "/desktop.ini"))

        let loaded = try Pool.load("desktop", in: dir)
        XCTAssertEqual(loaded.schemaVersion, 2)
        XCTAssertEqual(loaded.string("desktop", "grad_top"), "#ff0a0e16")
        XCTAssertEqual(loaded.uint64("desktop", "height"), 600)
        XCTAssertEqual(loaded.bool("desktop", "enabled"), true)
        XCTAssertEqual(loaded, c)   // full-config equality
    }

    /// T.2: the session's keyboard layout, as the installer writes it and
    /// undertow reads it; none written is "none", so rc.conf's stands.
    func testKeyboardPrefsRoundTripAndDefaultToNone() throws {
        let dir = makeTempDir()
        XCTAssertEqual(KeyboardPrefs.load(configDir: dir).kbdmap, "")
        try KeyboardPrefs(kbdmap: "de.kbd").store(configDir: dir)
        XCTAssertTrue(exists(dir + "/keyboard.ini"))
        XCTAssertEqual(KeyboardPrefs.load(configDir: dir), KeyboardPrefs(kbdmap: "de.kbd"))
    }

    func testMissingDomainIsEmpty() throws {
        let dir = makeTempDir()
        let c = try Pool.load("does-not-exist", in: dir)
        XCTAssertEqual(c, Config())
        XCTAssertEqual(c.schemaVersion, 0)
    }

    func testAtomicWriteLeavesNoTempOrLockClutter() throws {
        let dir = makeTempDir()
        var c = Config(); c.set("x", "y", "z")
        try c.store("panel", in: dir)
        XCTAssertTrue(exists(dir + "/panel.ini"))
        // The temp file must be gone (renamed into place); the lock may remain
        // as a zero-byte coordination file, but never the .tmp.
        XCTAssertFalse(exists(dir + "/panel.ini.tmp"))
    }

    func testOverwriteReplacesAtomically() throws {
        let dir = makeTempDir()
        var a = Config(); a.set("s", "k", "first")
        try a.store("d", in: dir)
        var b = Config(); b.set("s", "k", "second")
        try b.store("d", in: dir)
        XCTAssertEqual(try Pool.load("d", in: dir).string("s", "k"), "second")
    }

    // MARK: watcher

    func testWatcherWakesOnStore() throws {
        let dir = makeTempDir()
        let watcher = try Pool.Watcher(in: dir)
        // Nothing has changed yet.
        XCTAssertFalse(watcher.drain())

        var c = Config(); c.set("desktop", "bg", "#ff112233")
        try c.store("desktop", in: dir)

        // The atomic store renames a file into the directory — the watcher wakes.
        XCTAssertTrue(try watcher.wait(timeoutMs: 2000),
                      "watcher should wake on an atomic store into its directory")
    }

    /// An edit IN PLACE — what `printf > file` and most editors do — wakes it
    /// on both platforms (HANDOFF §2.124: FreeBSD's kqueue watched only the
    /// directory, which an in-place edit does not change). And a file that
    /// arrives after the watch began is watched too.
    func testWatcherWakesOnAnEditInPlaceOfAnExistingFile() throws {
        let dir = makeTempDir()
        try overwrite(dir + "/jails.ini", "[apps]\nfirefox = app-net\n")
        let watcher = try Pool.Watcher(in: dir)
        XCTAssertFalse(try watcher.wait(timeoutMs: 100))
        try overwrite(dir + "/jails.ini", "[apps]\n")
        XCTAssertTrue(try watcher.wait(timeoutMs: 2000), "an in-place edit of a file that was there did not wake it")
        while watcher.drain() {}

        try overwrite(dir + "/later.ini", "a = 1\n")         // arrives: the directory changes
        XCTAssertTrue(try watcher.wait(timeoutMs: 2000))
        while watcher.drain() {}
        try overwrite(dir + "/later.ini", "a = 2\n")         // and is then edited in place
        XCTAssertTrue(try watcher.wait(timeoutMs: 2000), "an in-place edit of a file that arrived later did not wake it")
    }

    /// Truncate and rewrite, as a shell's `>` does: no rename, no new entry.
    private func overwrite(_ path: String, _ text: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw NSError(domain: "overwrite", code: Int(errno)) }
        defer { close(fd) }
        let b = Array(text.utf8)
        _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
    }

    func testWatcherTimesOutWhenIdle() throws {
        let dir = makeTempDir()
        let watcher = try Pool.Watcher(in: dir)
        XCTAssertFalse(try watcher.wait(timeoutMs: 150),
                       "watcher should time out when nothing changes")
    }
}
