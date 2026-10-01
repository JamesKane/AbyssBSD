// The Setup Assistant (PHASE16 P16.7): its pages, its words, and setup.ini.

import XCTest
@testable import Aqua
@testable import AquaDraw
import PoolConfig
import Vents

final class SetupAssistantTests: XCTestCase {
    func testThePagesInOrderAndTheirButtons() {
        var m = SetupModel(themes: [], theme: "aqua", fullName: "Ada", connection: "")
        XCTAssertFalse(m.canGoBack, "nothing before Welcome")
        XCTAssertEqual(m.continueLabel, "Continue")
        m.forward(); m.forward(); m.forward()
        XCTAssertEqual(m.page, .done)
        XCTAssertEqual(m.continueLabel, "Start Using AbyssBSD")
        m.forward()
        XCTAssertEqual(m.page, .done, "nothing after All Set")
        m.back()
        XCTAssertEqual(m.page, .appearance)
    }

    func testTheConnectionInASentence() {
        let lo = Vents.Network.Interface(name: "lo0", up: true, loopback: true, link: .unknown,
                                         ipv4: [.init(address: "127.0.0.1", prefix: 8)], mac: nil)
        let em = Vents.Network.Interface(name: "em0", up: true, loopback: false, link: .up,
                                         ipv4: [.init(address: "192.168.1.5", prefix: 24)], mac: nil)
        XCTAssertEqual(SetupModel.connection([lo, em]), "This computer is connected through em0 (192.168.1.5).")
        XCTAssertEqual(SetupModel.connection([lo]), "This computer is not connected to a network.")
    }

    func testSetupIsDoneOnceSaid() throws {
        var t = Array("/tmp/abyss-setup.XXXXXX".utf8CString)
        let dir = t.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
        defer { _ = unlink(dir + "/setup.ini"); _ = rmdir(dir) }
        XCTAssertFalse(SetupState.done(configDir: dir), "a new account has not been through it")
        try SetupState.markDone(skipped: true, configDir: dir)
        XCTAssertTrue(SetupState.done(configDir: dir), "skipped counts as said")
    }
}
