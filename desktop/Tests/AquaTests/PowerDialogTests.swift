// The power dialog's questions and arrangement (PHASE16 P16.4b).

import XCTest
@testable import Aqua
@testable import AquaDraw
import Login

final class PowerDialogTests: XCTestCase {
    func testEachQuestionHasItsDefaultLast() {
        XCTAssertEqual(PowerAsk.restart.choices, [.cancel, .restart])
        XCTAssertEqual(PowerAsk.shutDown.choices, [.cancel, .shutDown])
        XCTAssertEqual(PowerAsk.powerKey.choices, [.restart, .sleep, .cancel, .shutDown])
        XCTAssertEqual(PowerAsk.powerKey.question, "Are you sure you want to shut down your computer now?")
        XCTAssertNil(PowerChoice.cancel.action, "Cancel asks the machine nothing")
        XCTAssertEqual(PowerChoice.sleep.action, .sleep)
    }

    func testJaguarsArrangementAndNothingOverlaps() {
        let l = PowerDialogLayout(choices: PowerAsk.powerKey.choices, w: 460, h: 150)
        let at = Dictionary(uniqueKeysWithValues: l.buttons.map { ($0.0.rawValue, $0.1) })
        guard let r = at["Restart"], let s = at["Sleep"], let c = at["Cancel"], let d = at["Shut Down"] else {
            return XCTFail("missing a button: \(at.keys)")
        }
        XCTAssertLessThan(r.x, s.x); XCTAssertLessThan(s.x, c.x); XCTAssertLessThan(c.x, d.x)
        XCTAssertEqual(d.x + d.w, 440, "the default sits at the right edge")
        XCTAssertLessThanOrEqual(s.x + s.w, c.x, "the left pair does not touch the right")
        XCTAssertEqual(l.hit(d.x + 5, d.y + 5), .shutDown)
        XCTAssertNil(l.hit(5, 5))
    }
}
