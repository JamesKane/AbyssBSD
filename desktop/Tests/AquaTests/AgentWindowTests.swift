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

    func testThePiecesAddUpToTheTurn() {
        XCTAssertEqual(agentQuestionLine("q") + agentCallLine("c()") + agentAnswerLine("a"),
                       agentTurn(question: "q", calls: ["c()"], answer: "a"))
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

    /// `agent` in dock.ini pins Agent; and a running Agent that is not pinned
    /// wears its own tile, not the generic one, and leaves when it quits.
    func testTheDockKnowsAgent() {
        let pinned = Dock.items(tokens: ["agent"], library: [])
        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(pinned[0].label, "Agent")
        XCTAssertEqual(pinned[0].appID, "org.abyssbsd.agent")
        XCTAssertEqual(pinned[0].environment["AQUA_SCENE"], "agent")
        XCTAssertEqual(pinned[0].pinToken, "agent")
        let running = Dock.builtin(appID: "org.abyssbsd.agent")
        XCTAssertEqual(running?.label, "Agent")
        XCTAssertNil(running?.pinToken, "running, not pinned")
        if case .agent? = running?.icon {} else { XCTFail("a running Agent wears the generic icon") }
        XCTAssertEqual(Dock.builtin(appID: "org.abyssbsd.terminal")?.label, "Terminal")
        XCTAssertNil(Dock.builtin(appID: "org.mozilla.firefox"), "a bundle's app is the library's to name")
    }

    /// Every built-in can be pinned, wears its own icon running, and is the
    /// app ID its window really gives (System Preferences': `.preferences`).
    func testEveryBuiltinHasATile() {
        for b in Dock.builtins {
            let pinned = Dock.items(tokens: [b.token], library: [])
            XCTAssertEqual(pinned.first?.label, b.label, b.token)
            XCTAssertEqual(pinned.first?.environment["AQUA_SCENE"], b.scene, b.token)
            let running = Dock.builtin(appID: b.appID)
            XCTAssertEqual(running?.label, b.label, b.appID)
            if case .genericApp? = running?.icon { XCTFail("\(b.label) wears the generic icon") }
            XCTAssertNotNil(Theme.lists["dock.icon.\(b.token)"] ?? (b.token == "sysprefs" ? Theme.lists["dock.icon.prefs"] : nil),
                            "\(b.label) has no icon in the theme")
        }
        XCTAssertEqual(Dock.builtin(appID: "org.abyssbsd.preferences")?.label, "System Preferences",
                       "the app ID System Preferences' window gives")
        XCTAssertNil(Dock.builtin(appID: "org.abyssbsd.prefs"))
        XCTAssertEqual(Set(Dock.builtins.map(\.token)).count, Dock.builtins.count)
        XCTAssertEqual(Set(Dock.builtins.map(\.appID)).count, Dock.builtins.count)
    }

    func testThePickersRowsAreWhereTheyAreDrawn() {
        let area = AgentLayout(w: 560, h: 460).conversation
        let l = AgentPickerLayout(in: area, count: 3)
        XCTAssertEqual(l.rows.count, 3)
        XCTAssertEqual(l.hit(l.rows[2].x + 5, l.rows[2].y + 5), 2)
        XCTAssertNil(l.hit(l.panel.x + 2, l.panel.y + 2), "the heading is not a row")
        XCTAssertTrue(l.rows.allSatisfy { $0.y + $0.h <= l.panel.y + l.panel.h }, "every row inside the panel")
        XCTAssertTrue(zip(l.rows, l.rows.dropFirst()).allSatisfy { $0.y + $0.h <= $1.y }, "rows do not overlap")
    }

    func testTheMenusSayWhatTheyDo() {
        let verbs = agentMenuBar().menus.flatMap { $0.items }.compactMap { item -> String? in
            if case .command(let c) = item { return c.verb }; return nil
        }
        XCTAssertEqual(verbs, [AgentVerb.about, AgentVerb.quit, AgentVerb.ask, AgentVerb.question, AgentVerb.clear,
                               AgentVerb.giveApp, AgentVerb.give, AgentVerb.minimize])
        XCTAssertEqual(agentMenuBar().verb(for: .cmd("q")), AgentVerb.quit)
        XCTAssertEqual(agentMenuBar().verb(for: .cmd("k")), AgentVerb.clear)
    }
}
