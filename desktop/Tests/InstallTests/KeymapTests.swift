// Keymap tests — one choice, read by the console and by the desktop.
//
// The installer writes a `kbdmap` name to rc.conf; `undertow` reads it back and
// needs an XKB layout (HANDOFF §2.70). These test the table and the reader; the
// XKB half, which needs xkbcommon, is in UndertowTests.

import XCTest
@testable import Install

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class KeymapTests: XCTestCase {

    private var dir = ""

    override func setUp() {
        var template = Array("/tmp/abyss-keymap-XXXXXX".utf8CString)
        dir = template.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
    }

    override func tearDown() {
        for f in ["rc.conf", "rc.conf.local"] { unlink(dir + "/" + f) }
        rmdir(dir)
    }

    private func write(_ name: String, _ text: String) -> String {
        let path = dir + "/" + name
        let f = fopen(path, "w")!
        fputs(text, f)
        fclose(f)
        return path
    }

    // MARK: - Reading rc.conf

    func testTheInstallersOwnLineIsRead() {
        let rc = write("rc.conf", "# Written by the AbyssBSD installer.\nzfs_enable=\"YES\"\nkeymap=\"uk.kbd\"\n")
        XCTAssertEqual(Keymaps.configured(rcConf: [rc]), "uk.kbd")
    }

    func testTheLastAssignmentWinsAndQuotingIsOptional() {
        XCTAssertEqual(Keymaps.lastAssignment("keymap", in: "keymap=us.kbd\nkeymap='de.kbd'\n"), "de.kbd")
        XCTAssertEqual(Keymaps.lastAssignment("keymap", in: "  keymap=fr.kbd   # the console too\n"), "fr.kbd")
        XCTAssertNil(Keymaps.lastAssignment("keymap", in: "#keymap=\"uk.kbd\"\nkeymapx=\"uk.kbd\"\n"),
                     "a comment, and a longer name, are not the setting")
    }

    func testRcConfLocalIsReadAfterRcConf() {
        let rc = write("rc.conf", "keymap=\"uk.kbd\"\n")
        let local = write("rc.conf.local", "keymap=\"de.kbd\"\n")
        XCTAssertEqual(Keymaps.configured(rcConf: [rc, local]), "de.kbd")
    }

    func testNoFileNoSettingAndNOAllMeanNone() {
        XCTAssertNil(Keymaps.configured(rcConf: [dir + "/absent"]), "Linux has no rc.conf at all")
        XCTAssertNil(Keymaps.configured(rcConf: [write("rc.conf", "hostname=\"abyss\"\n")]))
        XCTAssertNil(Keymaps.configured(rcConf: [write("rc.conf", "keymap=\"NO\"\n")]),
                     "NO is /etc/defaults/rc.conf's way of saying none")
    }

    // MARK: - Translating

    func testEveryOfferedLayoutTranslatesExactly() {
        for k in Keymaps.offered {
            let t = Keymaps.xkb(forKbdmap: k.kbdmap)
            XCTAssertEqual(t?.keymap, k, k.kbdmap)
            XCTAssertEqual(t?.exact, true, k.kbdmap)
        }
        XCTAssertEqual(Keymaps.xkb(forKbdmap: "uk.kbd")?.keymap.layout, "gb",
                       "XKB calls the United Kingdom gb")
    }

    func testAHandWrittenNameIsGuessedFromItsPrefix() {
        XCTAssertEqual(Keymaps.xkb(forKbdmap: "de.acc.kbd")?.keymap.layout, "de")
        XCTAssertEqual(Keymaps.xkb(forKbdmap: "uk.macbook.kbd")?.keymap.layout, "gb")
        XCTAssertEqual(Keymaps.xkb(forKbdmap: "de.acc.kbd")?.exact, false)
        XCTAssertNil(Keymaps.xkb(forKbdmap: "german"), "not a kbdmap name at all")
    }

    /// **Every name offered must be a file FreeBSD ships.** The list once
    /// offered `dvorak.kbd` and `colemak.kbd`; neither exists, and rc.conf would
    /// have named a console keymap that could not load. Only checkable where the
    /// keymaps are — so on FreeBSD, and the guest runs this.
    func testEveryOfferedNameIsAKeymapFreeBSDShips() throws {
        let keymaps = "/usr/share/vt/keymaps"
        var st = stat()
        guard stat(keymaps, &st) == 0 else { throw XCTSkip("no \(keymaps) here; FreeBSD only") }
        for k in Keymaps.offered {
            XCTAssertEqual(stat(keymaps + "/" + k.kbdmap, &st), 0, "\(k.kbdmap) is not in \(keymaps)")
        }
    }
}
