// The Agents pane (PHASE18 P18.11b): the keeper's grants read, and where the
// rows and Revoke buttons are.

import XCTest
@testable import Aqua
import Model

final class AgentsPaneTests: XCTestCase {
    func testAGrantFromTheKeeper() {
        let g = AgentGrantRow.parse("abyss-1001-app\t3\trw\t/run/granted/3/notes.txt\t/home/ada/notes.txt")
        XCTAssertEqual(g, AgentGrantRow(jail: "abyss-1001-app", n: 3, writable: true, path: "/home/ada/notes.txt"))
        XCTAssertEqual(g?.line, "app — /home/ada/notes.txt (read-write)")
        XCTAssertEqual(AgentGrantRow.parse("abyss-1001-app-net\t1\tro\t/run/granted/1/a b.pdf\t/home/ada/a b.pdf")?.line,
                       "app-net — /home/ada/a b.pdf (read-only)", "a hyphenated class, and a path with a space")
        XCTAssertNil(AgentGrantRow.parse("abyss-1001-app\tnot-a-number\tro\tx\ty"))
        XCTAssertNil(AgentGrantRow.parse("too\tfew"))
    }

    func testRowsAndRevokesAreWhereTheyAreDrawn() {
        let s = AgentsPaneState.sample
        let l = agentsLayout(body: Rect(0, 100, 760, 500), s)
        XCTAssertEqual(l.sessionRows.count, 2)
        XCTAssertEqual(l.revoke.count, 1)
        XCTAssertEqual(agentsHit(l, s, x: l.sessionRows[1].x + 5, y: l.sessionRows[1].y + 5), .session(1))
        XCTAssertEqual(agentsHit(l, s, x: l.revoke[0].x + 5, y: l.revoke[0].y + 5), .revoke(0))
        XCTAssertNil(agentsHit(l, s, x: l.digest.x + 5, y: l.digest.y + 5), "the digest is read, not pressed")
        XCTAssertLessThan(l.sessions.x + l.sessions.w, l.digest.x, "the list and the digest do not overlap")
        XCTAssertLessThan(l.digest.y + l.digest.h, l.grants.y)
    }

    func testAnAnswersLineBreaksAreParagraphs() {
        XCTAssertEqual(agentsDigestParagraphs(["17:33:08  The agent answered: Let me check.\nThen save.", "next"]),
                       ["17:33:08  The agent answered: Let me check.", "Then save.", "next"])
        XCTAssertEqual(agentsDigestParagraphs(["a\n\nb"]), ["a", "b"], "no empty paragraph")
    }

    func testAtMostWhatFits() {
        var s = AgentsPaneState()
        s.sessions = (0..<20).map { TranscriptSummary(id: "\($0)", agentClass: "agent", started: "", questions: 0, tokens: 0, given: []) }
        s.grants = (0..<9).map { AgentGrantRow(jail: "j", n: UInt64($0), writable: false, path: "/p") }
        let l = agentsLayout(body: Rect(0, 100, 760, 500), s)
        XCTAssertEqual(l.sessionRows.count, AgentsLayout.maxSessions)
        XCTAssertEqual(l.revoke.count, AgentsLayout.maxGrants)
    }
}
