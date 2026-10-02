// Crash Reporter (PHASE18 P18.9b): what it says, and which buttons it offers.

import XCTest
@testable import Aqua
import MenuModel

final class CrashReportTests: XCTestCase {
    func testItSaysWhatHappenedAndWhatCanBeDone() {
        let n = CrashNotice(id: 2, app: "galculator", signal: "SIGSEGV", core: true)
        XCTAssertEqual(n.headline, "The application galculator has unexpectedly quit.")
        XCTAssertEqual(n.detail, "It ran confined, so nothing else was affected. It was killed by SIGSEGV; an agent can read what it left and say why.")
        XCTAssertEqual(n.question, "Why did galculator crash?")
        let none = CrashNotice(id: 3, app: "sh", signal: "SIGKILL", core: false)
        XCTAssertEqual(none.detail, "It ran confined, so nothing else was affected. It was killed by SIGKILL, and left nothing to read.")
    }

    func testAskIsTheDefaultWhenThereIsACore() {
        let l = CrashReportLayout(choices: [.close, .ask], w: 480, h: 180)
        XCTAssertEqual(l.buttons.map { $0.0 }, [.close, .ask])
        let ask = l.buttons[1].1
        XCTAssertEqual(ask.x + ask.w, 460, "right-aligned, 20 from the edge")
        XCTAssertEqual(l.hit(ask.x + 5, ask.y + 5), .ask)
        XCTAssertEqual(l.hit(l.buttons[0].1.x + 5, l.buttons[0].1.y + 5), .close)
        XCTAssertNil(l.hit(5, 5))
        XCTAssertLessThan(l.buttons[0].1.x + l.buttons[0].1.w, ask.x, "the buttons do not overlap")
    }

    func testTheMenuOffersTheSameTwoThings() {
        let verbs = CrashReport.menuBar().menus.flatMap { $0.items }.compactMap { item -> String? in
            if case .command(let c) = item { return c.verb }; return nil
        }
        XCTAssertEqual(verbs, [CrashVerb.ask, CrashVerb.close])
    }
}
