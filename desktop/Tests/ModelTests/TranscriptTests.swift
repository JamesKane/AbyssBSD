// Reading a transcript back for a person (PHASE18 P18.11b), from lines in
// the shapes abyss-model and abyss-vocab write.

import XCTest
@testable import Model

final class TranscriptTests: XCTestCase {
    let text = #"""
    {"t":1790962210.1,"session":"s","kind":"vocabulary","event":"given","app":"TextEdit","service":"menus.textedit.7"}
    {"t":1790962211,"session":"s","kind":"request","budget":500,"request":{"messages":[{"role":"system","content":"sys"},{"role":"user","content":"save my note"}]}}
    {"t":1790962212,"session":"s","kind":"reply","budget":500,"reply":{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"activate","arguments":"{\"app\":\"TextEdit\",\"verb\":\"file.save\"}"}}]}}]},"tokens":300,"used":300}
    {"t":1790962212.5,"session":"s","kind":"vocabulary","event":"asked","app":"TextEdit","verb":"file.save","title":"Save"}
    {"t":1790962220,"session":"s","kind":"vocabulary","event":"permitted","app":"TextEdit"}
    {"t":1790962220.2,"session":"s","kind":"vocabulary","event":"activate","app":"TextEdit","verb":"file.save","arguments":{},"result":"ok"}
    not json: a line cut short by a crash
    {"t":1790962221,"session":"s","kind":"request","budget":500,"request":{"messages":[{"role":"system","content":"sys"},{"role":"user","content":"save my note"},{"role":"assistant","content":null},{"role":"tool","content":"ok"}]}}
    {"t":1790962222,"session":"s","kind":"reply","budget":500,"reply":{"choices":[{"message":{"role":"assistant","content":"Saved."}}]},"tokens":250,"used":550}
    {"t":1790962230,"session":"s","kind":"request","budget":500,"request":{"messages":[{"role":"system","content":"sys"},{"role":"user","content":"save my note"},{"role":"user","content":"and again"}]}}
    {"t":1790962230.1,"session":"s","kind":"refused","budget":500,"reason":"budget","message":"the session's budget of 500 tokens is spent (550 used)"}
    {"t":1790962240,"session":"s","kind":"raised","budget":500,"by":500,"used":550}
    {"t":1790962241,"session":"s","kind":"vocabulary","event":"taken","app":"TextEdit"}
    {"t":1790962242,"session":"s","kind":"vocabulary","event":"refused","app":"Grab","reason":"not given"}
    """#

    func testTheDigestSaysItInSentences() {
        let d = Transcript.digest(Transcript.lines(text)).map { String($0.dropFirst(10)) }   // the clock: HH:MM:SS + two spaces
        XCTAssertEqual(d, [
            "You gave the agent TextEdit",
            "You asked: save my note",
            #"  The agent called activate({"app":"TextEdit","verb":"file.save"})"#,
            "The agent asked to write with TextEdit (Save)",
            "You allowed TextEdit to write for the agent",
            "  TextEdit ran file.save: ok",
            "The agent answered: Saved.",
            "You asked: and again",
            "Stopped: the session's budget of 500 tokens is spent (550 used)",
            "You allowed 500 more tokens",
            "You took TextEdit back",
            "Refused: Grab was not given to the agent",
        ])
    }

    func testTheClockIsLocalTime() {
        let d = Transcript.digest(Transcript.lines(text))
        XCTAssertTrue(d.allSatisfy { $0.count > 10 && $0[$0.index($0.startIndex, offsetBy: 2)] == ":" }, "every line starts with HH:MM:SS")
    }

    func testTheSummary() {
        let s = Transcript.summary(id: "20261002-173010-agent-23133-1", lines: Transcript.lines(text))
        XCTAssertEqual(s.agentClass, "agent")
        XCTAssertEqual(s.started, "2026-10-02 17:30")
        XCTAssertEqual(s.questions, 2, "the same question resent with the conversation is one question")
        XCTAssertEqual(s.tokens, 550)
        XCTAssertEqual(s.given, [], "TextEdit was taken back")
        XCTAssertEqual(s.line, "2026-10-02 17:30 · agent · 2 questions · 550 tokens")
    }

    func testAnIDWithAHyphenatedClass() {
        XCTAssertEqual(Transcript.parseID("20261002-090000-my-agent-1-2").agentClass, "my-agent")
        XCTAssertEqual(Transcript.parseID("odd").started, "odd")
    }
}
