// Agent tests (PHASE18 P18.8): the loop's bounds, and its tools.

import XCTest
@testable import Agent
@testable import Model
#if canImport(Glibc)
import Glibc
#endif

final class AgentTests: XCTestCase {
    func completion(_ content: String?, calls: [(String, String)] = [], tokens: Int = 50) -> JSON {
        var msg: [(String, JSON)] = [("role", .string("assistant")), ("content", content.map { .string($0) } ?? .null)]
        if !calls.isEmpty {
            msg.append(("tool_calls", .array(calls.enumerated().map { i, c in
                .object([("id", .string("c\(i)")), ("type", .string("function")),
                         ("function", .object([("name", .string(c.0)), ("arguments", .string(c.1))]))])
            })))
        }
        return .object([("choices", .array([.object([("index", .number(0)), ("message", .object(msg))])])),
                        ("usage", .object([("total_tokens", .number(Double(tokens)))]))])
    }

    let echo = AgentTool(name: "echo", description: "say it back",
                         parameters: .object([("type", .string("object"))])) { a in "echoed \(a["say"]?.string ?? "")" }

    /// A model that plays `replies` in order and records what it was asked.
    final class Script {
        var replies: [(Int, JSON)]
        var asked: [JSON] = []
        init(_ r: [(Int, JSON)]) { replies = r }
        var call: ModelCall {
            { [self] req in
                asked.append(req)
                guard !replies.isEmpty else { throw HTTP.Failure("the script ran out") }
                return replies.removeFirst()
            }
        }
    }

    func testAToolCallIsRunAndItsResultAnswersTheCall() {
        let s = Script([(200, completion(nil, calls: [("echo", #"{"say":"hi"}"#)])), (200, completion("done"))])
        let loop = AgentLoop(system: "sys", tools: [echo], model: s.call)
        let a = loop.ask("go")
        XCTAssertEqual(a, AgentAnswer(text: "done", stop: .answered, calls: [#"echo({"say":"hi"})"#], steps: 2))
        let second = s.asked[1]["messages"]!.array!
        XCTAssertEqual(second.map { $0["role"]?.string ?? "?" }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(second[2]["tool_calls"]?[0]?["id"]?.string, "c0", "the assistant's calls go back as they came")
        XCTAssertEqual(second[3]["tool_call_id"]?.string, "c0", "the result answers that call")
        XCTAssertEqual(second[3]["content"]?.string, "echoed hi")
    }

    /// The person sees each call as it starts: in order, before the answer.
    func testEachCallIsToldAsItStarts() {
        var told: [String] = []
        var answeredWhenTold: [Int] = []
        let s = Script([(200, completion(nil, calls: [("echo", #"{"say":"a"}"#), ("echo", #"{"say":"b"}"#)])),
                        (200, completion("done"))])
        let loop = AgentLoop(system: "sys", tools: [echo], model: s.call)
        loop.onCall = { told.append($0); answeredWhenTold.append(s.asked.count) }
        let a = loop.ask("go")
        XCTAssertEqual(told, [#"echo({"say":"a"})"#, #"echo({"say":"b"})"#])
        XCTAssertEqual(told, a.calls)
        XCTAssertEqual(answeredWhenTold, [1, 1], "told before the model was asked again")
    }

    func testTheRequestOffersTheToolsWithThinkingOff() {
        let s = Script([(200, completion("ok"))])
        _ = AgentLoop(system: "sys", tools: [echo], model: s.call).ask("q")
        XCTAssertEqual(s.asked[0]["tools"]?[0]?["function"]?["name"]?.string, "echo")
        XCTAssertEqual(s.asked[0]["chat_template_kwargs"]?["enable_thinking"]?.bool, false)
        XCTAssertEqual(s.asked[0]["stream"], nil, "abyss-model refuses streaming")
    }

    /// The budget ends the question with abyss-model's own words, and the
    /// loop does not try again.
    func testABudgetRefusalEndsTheQuestion() {
        let refusal = JSON.object([("error", .object([("type", .string("budget")),
                                                       ("message", .string("the session's budget of 500 tokens is spent (600 used)"))]))])
        let s = Script([(200, completion(nil, calls: [("echo", "{}")])), (429, refusal), (200, completion("never"))])
        let a = AgentLoop(system: "sys", tools: [echo], model: s.call).ask("go")
        XCTAssertEqual(a.stop, .budget)
        XCTAssertEqual(a.text, "the session's budget of 500 tokens is spent (600 used)")
        XCTAssertEqual(s.asked.count, 2, "no call after the refusal")
    }

    func testTheStepLimitStopsAModelThatNeverAnswers() {
        let s = Script(Array(repeating: (200, completion(nil, calls: [("echo", "{}")])), count: 10))
        let a = AgentLoop(system: "sys", tools: [echo], maxSteps: 3, model: s.call).ask("go")
        XCTAssertEqual(a.stop, .steps)
        XCTAssertEqual(a.steps, 3)
        XCTAssertEqual(s.asked.count, 3)
        XCTAssertEqual(a.text, "stopped after 3 steps without an answer")
    }

    func testABadCallIsTheModelsToSeeNotACrash() {
        let s = Script([(200, completion(nil, calls: [("rm_rf", "{}"), ("echo", "not json")])), (200, completion("sorry"))])
        let a = AgentLoop(system: "sys", tools: [echo], model: s.call).ask("go")
        XCTAssertEqual(a.stop, .answered)
        let results = s.asked[1]["messages"]!.array!.filter { $0["role"]?.string == "tool" }.map { $0["content"]?.string ?? "" }
        XCTAssertEqual(results, ["error: there is no tool named rm_rf", "error: the arguments are not JSON: not json"])
    }

    func testAnUnreachableModelOrAnOddReplyFails() {
        XCTAssertEqual(AgentLoop(system: "s", tools: [], model: Script([]).call).ask("q").stop, .failed)
        XCTAssertEqual(AgentLoop(system: "s", tools: [], model: Script([(200, .object([]))]).call).ask("q").stop, .failed)
        XCTAssertEqual(AgentLoop(system: "s", tools: [], model: Script([(502, .null)]).call).ask("q").text, "abyss-model said 502")
    }

    func testTheConversationPersistsAcrossQuestions() {
        let s = Script([(200, completion("one")), (200, completion("two"))])
        let loop = AgentLoop(system: "sys", tools: [], model: s.call)
        _ = loop.ask("first")
        _ = loop.ask("second")
        XCTAssertEqual(s.asked[1]["messages"]!.array!.compactMap { $0["content"]?.string }, ["sys", "first", "one", "second"])
    }

    /// End to end through abyss-model's session, budget and all.
    func testTheLoopAgainstAModelSession() {
        let fd = open("/dev/null", O_WRONLY)
        defer { close(fd) }
        let session = ModelSession(id: "a", budget: 100,
                                   backend: StubBackend(replies: [completion(nil, calls: [("echo", "{}")], tokens: 60),
                                                                  completion("done", tokens: 60)]),
                                   transcript: fd)
        let model: ModelCall = { req in
            let r = session.handle(HTTPRequest(method: "POST", path: "/v1/chat/completions", headers: [], body: Array(req.text.utf8)))
            return (r.status, try JSON.parse(r.body))
        }
        let loop = AgentLoop(system: "sys", tools: [echo], model: model)
        XCTAssertEqual(loop.ask("go").stop, .answered, "60 + 60: the second reply crosses 100 and is delivered")
        let a = loop.ask("again")
        XCTAssertEqual(a.stop, .budget, "and the next call is refused")
        XCTAssertEqual(a.text, "the session's budget of 100 tokens is spent (120 used)")
    }

    // MARK: - tools

    /// lldb on one crash: the model picks the command, never the target.
    func testTheLldbToolsTargetIsFixed() throws {
        var t = Array("/tmp/abyss-lldb-XXXXXX".utf8CString)
        let dir = String(cString: mkdtemp(&t)!)
        defer { unlink(dir + "/lldb"); rmdir(dir) }
        let fake = dir + "/lldb"
        let fd = open(fake, O_WRONLY | O_CREAT, 0o755)
        let script = "#!/bin/sh\nfor a in \"$@\"; do printf '[%s]' \"$a\"; done\n"
        _ = Array(script.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        let tool = AgentTools.lldb(core: "/run/granted/1/crasher.core", binary: "/run/granted/2/crasher", lldb: fake)
        XCTAssertEqual(tool.run(.object([("command", .string("bt"))])),
                       "[--batch][--no-lldbinit][-c][/run/granted/1/crasher.core][/run/granted/2/crasher][-o][bt]")
        XCTAssertEqual(tool.run(.object([("command", .string("bt; -c /etc/other.core"))])),
                       "[--batch][--no-lldbinit][-c][/run/granted/1/crasher.core][/run/granted/2/crasher][-o][bt; -c /etc/other.core]",
                       "the command is one argument: it cannot name another core")
        XCTAssertEqual(tool.run(.object([("command", .string("bt")), ("core", .string("/etc/other.core")),
                                         ("binary", .string("/bin/sh"))])),
                       "[--batch][--no-lldbinit][-c][/run/granted/1/crasher.core][/run/granted/2/crasher][-o][bt]",
                       "a model that names another core or binary is not heard")
        XCTAssertEqual(tool.run(.object([])), "error: lldb needs a command")
        XCTAssertTrue(AgentTools.lldb(core: "c", binary: "b", lldb: dir + "/none").run(.object([("command", .string("bt"))])).hasPrefix("error:"))
    }

    func testTheReadingTools() throws {
        var t = Array("/tmp/abyss-agent-XXXXXX".utf8CString)
        let dir = String(cString: mkdtemp(&t)!)
        defer { _ = Spawn_rm(dir) }
        mkdir(dir + "/sub", 0o755)
        let big = String(repeating: "x", count: AgentTools.readLimit + 10)
        for (n, body) in [("a.txt", "hello\n"), ("big.txt", big)] {
            let fd = open(dir + "/" + n, O_WRONLY | O_CREAT, 0o644)
            _ = Array(body.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
        XCTAssertEqual(AgentTools.listDirectory.run(.object([("path", .string(dir))])), "a.txt\nbig.txt\nsub/")
        XCTAssertEqual(AgentTools.readFile.run(.object([("path", .string(dir + "/a.txt"))])), "hello\n")
        let b = AgentTools.readFile.run(.object([("path", .string(dir + "/big.txt"))]))
        XCTAssertTrue(b.hasSuffix("\n(more from offset \(AgentTools.readLimit))"), "a long file is cut, and says where it goes on")
        XCTAssertEqual(AgentTools.readFile.run(.object([("path", .string(dir + "/big.txt")), ("offset", .number(Double(AgentTools.readLimit)))])),
                       String(repeating: "x", count: 10))
        XCTAssertEqual(AgentTools.readFile.run(.object([("path", .string(dir + "/none"))])), "error: \(dir)/none: No such file or directory")
        XCTAssertEqual(AgentTools.listDirectory.run(.object([])), "error: list_directory needs a path")
    }
}

func Spawn_rm(_ dir: String) -> Int32 {
    for n in ["a.txt", "big.txt"] { unlink(dir + "/" + n) }
    rmdir(dir + "/sub")
    return rmdir(dir)
}
