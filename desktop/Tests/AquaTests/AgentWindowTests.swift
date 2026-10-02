// The Agent window (PHASE18 P18.8b): what a reply adds to the conversation,
// where the controls are, and the menu's enablement as the session goes.

import XCTest
@testable import Aqua
import MenuModel

final class AgentWindowTests: XCTestCase {
    func testATurnShowsTheToolCallsBeforeTheAnswer() {
        XCTAssertEqual(agentTurn(question: "due monday?", calls: ["list_directory({})", "read_file({})"], answer: "The plumber."),
                       "You: due monday?\n  › list_directory({})\n  › read_file({})\nAgent: The plumber.\n\n")
        XCTAssertEqual(agentTurn(question: "hi", calls: [], answer: "Hello."), "You: hi\nAgent: Hello.\n\n")
    }

    func testTheLayoutKeepsTheFieldAndButtonAtTheBottom() {
        for (w, h) in [(560.0, 460.0), (900.0, 700.0), (300.0, 200.0)] {
            let l = AgentLayout(w: w, h: h)
            XCTAssertEqual(l.field.y + l.field.h, h - 12, "\(w)x\(h)")
            XCTAssertEqual(l.ask.y, l.field.y)
            XCTAssertEqual(l.ask.x + l.ask.w, w - 10)
            XCTAssertLessThan(l.field.x + l.field.w, l.ask.x, "the field stops before the button")
            XCTAssertLessThan(l.conversation.y + l.conversation.h, l.statusBaseline - 10, "the conversation is above the status")
            XCTAssertGreaterThanOrEqual(l.conversation.h, 40)
        }
    }

    func testTheMenusSayWhatTheyDo() {
        let verbs = agentMenuBar().menus.flatMap { $0.items }.compactMap { item -> String? in
            if case .command(let c) = item { return c.verb }; return nil
        }
        XCTAssertEqual(verbs, [AgentVerb.about, AgentVerb.quit, AgentVerb.ask, AgentVerb.question, AgentVerb.clear, AgentVerb.minimize])
        XCTAssertEqual(agentMenuBar().verb(for: .cmd("q")), AgentVerb.quit)
        XCTAssertEqual(agentMenuBar().verb(for: .cmd("k")), AgentVerb.clear)
    }
}
