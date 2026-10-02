// Agent presence (PHASE18 P18.13b): what an Agent window says of its session,
// and how the Dock, the menu bar and the island menu show it.

import XCTest
@testable import Aqua
import Surface
import MenuModel
#if canImport(Glibc)
import Glibc
#endif

final class AgentPresenceTests: XCTestCase {
    func p(_ pid: Int32, _ s: AgentState, _ about: String = "") -> AgentPresence { AgentPresence(pid: pid, state: s, about: about) }

    func testTheStateFollowsThePhaseAndTheRequester() {
        XCTAssertNil(agentPresenceState(phase: .starting, requester: nil), "no session yet")
        XCTAssertNil(agentPresenceState(phase: .ended, requester: .budget("x")), "none any more")
        XCTAssertEqual(agentPresenceState(phase: .ready, requester: nil), .idle)
        XCTAssertEqual(agentPresenceState(phase: .asking, requester: nil), .working)
        XCTAssertEqual(agentPresenceState(phase: .asking, requester: .host("a.org", url: "https://a.org/")), .waiting)
        XCTAssertEqual(agentPresenceState(phase: .ready, requester: .budget("spent")), .waiting,
                       "the budget's requester comes up after the answer: still waiting")
        XCTAssertEqual(agentPresenceAbout(requester: .write(app: "TextEdit", verb: "file.save", title: "Save"), asked: "q"),
                       "Allow TextEdit to write?")
        XCTAssertEqual(agentPresenceAbout(requester: nil, asked: "what is due?"), "what is due?")
    }

    func testAFileSaysItAndReadsBack() {
        let a = p(42, .waiting, "Allow it to reach\nexample.org?")
        XCTAssertEqual(a.text, "waiting\nAllow it to reach example.org?\n", "one line of what, always")
        XCTAssertEqual(AgentPresence.parse(pid: 42, a.text), p(42, .waiting, "Allow it to reach example.org?"))
        XCTAssertNil(AgentPresence.parse(pid: 1, "sleeping\n"), "not a state")
        XCTAssertNil(AgentPresence.parse(pid: 1, ""))
    }

    func testWaitingFirstAndTheBadge() {
        let all = [p(3, .idle), p(1, .working), p(5, .waiting), p(2, .waiting)]
        XCTAssertEqual(AgentPresence.sort(all).map(\.pid), [2, 5, 1, 3])
        XCTAssertEqual(AgentBadge(all), .waiting(2))
        XCTAssertEqual(AgentBadge([p(1, .working), p(2, .idle)]), .working)
        XCTAssertEqual(AgentBadge([p(2, .idle)]), .none, "idle is the running mark alone")
        XCTAssertEqual(AgentBadge([]), .none)
    }

    func testTheMenuBarItem() {
        XCTAssertNil(menuBarAgentLabel([]), "no session, no item")
        XCTAssertEqual(menuBarAgentLabel([p(1, .idle)]), "Agent")
        XCTAssertEqual(menuBarAgentLabel([p(1, .idle), p(2, .working)]), "Agent: Working")
        XCTAssertEqual(menuBarAgentLabel([p(1, .waiting), p(2, .working)]), "Agent: Waiting")
        XCTAssertEqual(menuBarAgentLabel([p(1, .waiting), p(2, .waiting)]), "Agent: 2 Waiting")

        let m = AgentMenu.build([p(7, .idle, "hello"), p(9, .waiting, "Allow it to reach a.org?")])
        XCTAssertEqual(m.commands.map(\.verb), ["agent.go.9", "agent.go.7", "system.agent"])
        XCTAssertEqual(m.commands.first?.title, "Waiting for you: Allow it to reach a.org?")
        XCTAssertEqual(AgentMenu.pid("agent.go.9"), 9)
        XCTAssertNil(AgentMenu.pid("island.window.9"))
        let long = AgentMenu.build([p(1, .working, String(repeating: "x", count: 80))]).commands[0].title
        XCTAssertEqual(long.count, "Working: ".count + 48, "a long question is cut, with …")
    }

    func testTheIslandMenuSaysWhichWindowWaits() {
        let ws = [MenuBarFocus.IslandWindow(id: 1, display: "D", island: 1, appID: "org.abyssbsd.agent", title: "Agent", pid: 50),
                  MenuBarFocus.IslandWindow(id: 2, display: "D", island: 1, appID: "org.abyssbsd.agent", title: "Agent", pid: 51),
                  MenuBarFocus.IslandWindow(id: 3, display: "D", island: 1, appID: "galculator", title: "Calculator", pid: 52)]
        let m = IslandMenu.build(display: "D", active: 1, count: 1, names: [], windows: ws,
                                 agents: [p(51, .waiting), p(50, .idle)])
        let rows = m.commands.filter { $0.verb.hasPrefix("island.window.") }.map { $0.title.trimmingSpaces }
        XCTAssertEqual(rows, ["Agent — Idle", "Agent — Waiting for you", "Calculator"])
        let unknown = IslandMenu.build(display: "D", active: 1, count: 1, names: [],
                                       windows: [MenuBarFocus.IslandWindow(id: 1, display: "D", island: 1, appID: "a", title: "A")],
                                       agents: [p(0, .waiting)])
        XCTAssertEqual(unknown.commands.last { $0.verb.hasPrefix("island.window.") }?.title.trimmingSpaces, "A",
                       "a window whose pid is not known is never matched")
    }

    func testTheDirectory() throws {
        var t = Array("/tmp/abyss-presence-XXXXXX".utf8CString)
        let rt = String(cString: mkdtemp(&t)!)
        let old = getenv("ABYSS_RUNTIME_DIR").map { String(cString: $0) }
        setenv("ABYSS_RUNTIME_DIR", rt, 1)
        defer {
            if let old { setenv("ABYSS_RUNTIME_DIR", old, 1) } else { unsetenv("ABYSS_RUNTIME_DIR") }
            _ = system("rm -rf '\(rt)'")
        }
        let me = getpid()
        AgentPresenceIO.publish(p(me, .working, "q"))
        XCTAssertEqual(AgentPresenceIO.read(), [p(me, .working, "q")])
        AgentPresenceIO.publish(p(me, .waiting, "Allow?"))
        XCTAssertEqual(AgentPresenceIO.read(), [p(me, .waiting, "Allow?")], "replaced, not added")
        // A window killed outright cannot withdraw: its file goes when read.
        let gone: Int32 = 999_999
        AgentPresenceIO.publish(p(gone, .waiting))
        XCTAssertEqual(AgentPresenceIO.read().map(\.pid), [me])
        XCTAssertNotEqual(access(rt + "/agents/\(gone)", F_OK), 0, "the dead process's file is removed")
        XCTAssertNotEqual(access(rt + "/agents/.\(me).tmp", F_OK), 0, "nothing left aside")
        AgentPresenceIO.withdraw()
        XCTAssertEqual(AgentPresenceIO.read(), [])
    }
}
