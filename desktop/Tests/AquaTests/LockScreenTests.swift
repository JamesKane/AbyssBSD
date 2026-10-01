// The lock screen's model (PHASE16 P16.2b): what typing does to the field,
// what each of the authenticator's answers does to the screen, the countdown,
// and the shake — everything but the drawing and the socket.

import XCTest
@testable import Aqua
import Surface
import Login

final class LockScreenTests: XCTestCase {
    private func key(_ text: String, _ sym: UInt32 = 0, mods: KeyModifiers = []) -> KeyEvent {
        KeyEvent(keysym: sym == 0 ? UInt32(text.unicodeScalars.first?.value ?? 0) : sym,
                 text: text, pressed: true, modifiers: mods)
    }
    private func type(_ m: inout LockModel, _ s: String) {
        for c in s { _ = m.key(key(String(c))) }
    }

    func testTypingFillsTheFieldWithBulletsPerCharacterAndReturnAsks() {
        var m = LockModel()
        type(&m, "pässwd")
        XCTAssertEqual(m.bullets, "••••••", "one bullet per character, not per UTF-8 byte")
        XCTAssertEqual(m.typed, Array("pässwd".utf8))
        XCTAssertFalse(m.key(key("", KeySym.backspace)))
        XCTAssertEqual(m.typed, Array("pässw".utf8))
        XCTAssertTrue(m.key(key("\r", KeySym.enter)), "Return asks")
        XCTAssertTrue(m.key(key("\r", 0xff8d)), "so does the keypad's Enter")
    }

    func testBackspaceTakesAWholeCharacterAndEscapeClears() {
        var m = LockModel()
        type(&m, "aé")
        _ = m.key(key("", KeySym.backspace))
        XCTAssertEqual(m.typed, Array("a".utf8), "é is two bytes and one character")
        type(&m, "bc")
        _ = m.key(key("", KeySym.escape))
        XCTAssertEqual(m.typed, [])
    }

    func testShortcutsAndControlCharactersAreNotTyped() {
        var m = LockModel()
        _ = m.key(key("c", mods: .control))
        _ = m.key(key("q", mods: .command))
        _ = m.key(key("\t", KeySym.tab))
        _ = m.key(KeyEvent(keysym: 0x61, text: "a", pressed: false))
        XCTAssertEqual(m.typed, [], "⌃C, ⌘Q, Tab and a key release type nothing")
    }

    func testAskingTakesThePasswordAndClosesTheField() {
        var m = LockModel()
        type(&m, "secret")
        XCTAssertEqual(m.takeForAsking(), Array("secret".utf8))
        XCTAssertEqual(m.typed, [], "the model's copy is gone once it is handed over")
        XCTAssertEqual(m.phase, .asking)
        type(&m, "more")
        XCTAssertEqual(m.typed, [], "nothing is typed while the answer is awaited")
        XCTAssertFalse(m.key(key("\r", KeySym.enter)), "and Return asks nothing twice")
    }

    func testARefusalShakesAndReopensTheField() {
        var m = LockModel()
        _ = m.takeForAsking()
        m.answer(.refused, now: 1_000)
        XCTAssertEqual(m.phase, .typing)
        XCTAssertEqual(m.status, "The password is incorrect.")
        XCTAssertNotEqual(m.shakeOffset(now: 1_000 + 100_000_000), 0, "it is shaking")
        XCTAssertEqual(m.shakeOffset(now: 1_000 + LockModel.shakeNs), 0, "and then still")
        XCTAssertEqual(m.shakeOffset(now: 1_000 + 100_000_000), 0, "for good")
        type(&m, "x")
        XCTAssertEqual(m.status, "", "typing again clears the complaint")
    }

    func testAWaitClosesTheFieldAndCountsDown() {
        var m = LockModel()
        _ = m.takeForAsking()
        m.answer(.wait(4_000), now: 0)
        XCTAssertEqual(m.phase, .waiting(4_000_000_000))
        XCTAssertEqual(m.status, "Too many attempts. Try again in 4 seconds.")
        type(&m, "abc")
        XCTAssertFalse(m.key(key("\r", KeySym.enter)))
        XCTAssertEqual(m.typed, [], "the field is closed while waiting")
        m.tick(now: 3_100_000_000)
        XCTAssertEqual(m.status, "Too many attempts. Try again in 1 second.")
        m.tick(now: 4_000_000_000)
        XCTAssertEqual(m.phase, .typing)
        XCTAssertEqual(m.status, "")
    }

    func testFailingClosed() {
        var m = LockModel()
        _ = m.takeForAsking()
        m.answer(.unavailable("PAM is broken"), now: 0)
        XCTAssertEqual(m.phase, .typing)
        XCTAssertEqual(m.status, "Your password cannot be checked: PAM is broken")
        _ = m.takeForAsking()
        m.answer(nil, error: "The authenticator is not running.", now: 0)
        XCTAssertEqual(m.phase, .typing, "no answer is not a yes")
        XCTAssertEqual(m.status, "The authenticator is not running.")
        _ = m.takeForAsking()
        m.answer(.accepted, now: 0)
        XCTAssertEqual(m.phase, .unlocked, "only an accepted answer unlocks")
    }
}
