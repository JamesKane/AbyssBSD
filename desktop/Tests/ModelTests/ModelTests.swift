// Model tests (PHASE18 P18.7): the wire's JSON and HTTP, the session's budget
// and transcript, and the tier a machine gets.

import XCTest
@testable import Model
#if canImport(Glibc)
import Glibc
#endif

final class ModelTests: XCTestCase {
    // MARK: - JSON

    func testJSONRoundTripsWhatTheWireCarries() throws {
        let text = #"{"model":"m","messages":[{"role":"user","content":"hi \"there\"\n"}],"tools":[{"type":"function","function":{"name":"menu.activate","parameters":{"type":"object"}}}],"temperature":0.2,"n":1,"stream":false,"x":null}"#
        let j = try JSON.parse(text)
        XCTAssertEqual(j["messages"]?[0]?["content"]?.string, "hi \"there\"\n")
        XCTAssertEqual(j["temperature"]?.number, 0.2)
        XCTAssertEqual(j["n"]?.int, 1)
        XCTAssertEqual(j["stream"]?.bool, false)
        XCTAssertEqual(j["x"], .null)
        XCTAssertEqual(j.text, text, "keys keep their order; whole numbers have no fraction")
        XCTAssertEqual(try JSON.parse(j.text), j)
    }

    func testJSONEscapesAndUnicode() throws {
        XCTAssertEqual(try JSON.parse(#""\u00e9\ud83d\ude00\t\/""#).string, "é😀\t/")
        XCTAssertEqual(JSON.string("a\u{1}b").text, #""a\u0001b""#)
        XCTAssertEqual(try JSON.parse(JSON.string("😀 é \u{0} ").text).string, "😀 é \u{0} ")
    }

    func testJSONRefusesWhatIsNotJSON() {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "\"\\x\"", "1 2", "\"a\nb\"", "\"\\ud800\""] {
            XCTAssertThrowsError(try JSON.parse(bad), bad)
        }
        let deep = String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000)
        XCTAssertThrowsError(try JSON.parse(deep), "nesting is limited, so a hostile body cannot exhaust the stack")
    }

    func testJSONSettingReplacesInPlace() {
        let j = JSON.object([("a", .number(1)), ("b", .number(2))]).setting("a", .string("x")).setting("c", .null)
        XCTAssertEqual(j.text, #"{"a":"x","b":2,"c":null}"#)
    }

    // MARK: - HTTP

    func testARequestIsReadWhenAllOfItHasArrived() throws {
        let body = #"{"messages":[]}"#
        let raw = Array("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        XCTAssertNil(try HTTP.request(Array(raw.prefix(20))), "a head not yet complete")
        XCTAssertNil(try HTTP.request(Array(raw.dropLast(3))), "a body not yet complete")
        let r = try HTTP.request(raw)!
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/v1/chat/completions")
        XCTAssertEqual(r.header("content-length"), "\(body.utf8.count)")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), body)
    }

    func testRequestsItWillNotTake() {
        XCTAssertThrowsError(try HTTP.request(Array("GARBAGE\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTP.request(Array("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTP.request(Array("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)))
    }

    func testAResponseRoundTrips() throws {
        let r = HTTPResponse(status: 429, reason: "Too Many Requests", json: .object([("e", .number(1))]))
        let back = try HTTP.response(r.bytes)
        XCTAssertEqual(back.status, 429)
        XCTAssertEqual(String(decoding: back.body, as: UTF8.self), #"{"e":1}"#)
    }

    func testABackendURL() {
        let b = HTTPBackend(url: "http://127.0.0.1:8080")!
        XCTAssertEqual(b.name, "http://127.0.0.1:8080/v1/chat/completions")
        XCTAssertEqual(HTTPBackend(url: "http://h:9/x/y")?.name, "http://h:9/x/y")
        XCTAssertNil(HTTPBackend(url: "https://api.example.com"), "remote providers are a later pass")
        XCTAssertNil(HTTPBackend(url: "http://nohost"))
    }

    // MARK: - the session

    func reply(_ text: String, tokens: Int, tool: String? = nil) -> JSON {
        var msg: [(String, JSON)] = [("role", .string("assistant")), ("content", .string(text))]
        if let tool {
            msg.append(("tool_calls", .array([.object([("id", .string("c1")), ("type", .string("function")),
                ("function", .object([("name", .string(tool)), ("arguments", .string("{}"))]))])])))
        }
        return .object([("id", .string("r")), ("object", .string("chat.completion")),
                        ("choices", .array([.object([("index", .number(0)), ("message", .object(msg))])])),
                        ("usage", .object([("prompt_tokens", .number(Double(tokens - 10))), ("completion_tokens", .number(10)),
                                           ("total_tokens", .number(Double(tokens)))]))])
    }

    func post(_ s: ModelSession, _ body: String) -> HTTPResponse {
        s.handle(HTTPRequest(method: "POST", path: "/v1/chat/completions", headers: [], body: Array(body.utf8)))
    }

    func transcript() -> (Int32, () -> [JSON]) {
        var name = Array("/tmp/abyss-model-test-XXXXXX".utf8CString)
        let fd = mkstemp(&name)
        let path = String(cString: name)
        unlink(path)
        return (fd, {
            lseek(fd, 0, SEEK_SET)
            var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536)
            while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; out += buf[0..<n] }
            return String(decoding: out, as: UTF8.self).split(separator: "\n").compactMap { try? JSON.parse(String($0)) }
        })
    }

    func testRepliesPassThroughAndTokensAreCounted() throws {
        let (fd, lines) = transcript()
        let s = ModelSession(id: "s1", budget: 1000,
                             backend: StubBackend(replies: [reply("calling", tokens: 120, tool: "menu.activate"), reply("done", tokens: 80)]),
                             transcript: fd, clock: { 1000 })
        let r1 = post(s, #"{"messages":[{"role":"user","content":"save it"}]}"#)
        XCTAssertEqual(r1.status, 200)
        let j1 = try JSON.parse(r1.body)
        XCTAssertEqual(j1["choices"]?[0]?["message"]?["tool_calls"]?[0]?["function"]?["name"]?.string, "menu.activate",
                       "tool calls pass through unchanged")
        _ = post(s, #"{"messages":[{"role":"user","content":"and?"}]}"#)
        XCTAssertEqual(s.used, 200)
        let l = lines()
        XCTAssertEqual(l.map { $0["kind"]?.string ?? "?" }, ["request", "reply", "request", "reply"])
        XCTAssertEqual(l[1]["used"]?.int, 120)
        XCTAssertEqual(l[3]["used"]?.int, 200)
        XCTAssertEqual(l[0]["request"]?["messages"]?[0]?["content"]?.string, "save it", "the transcript keeps what was asked")
        XCTAssertTrue(l.allSatisfy { $0["session"]?.string == "s1" })
    }

    /// The stop is at the next call: a reply that crosses the budget is
    /// delivered (it was already paid for), and the call after it is refused,
    /// with the reason, and sent nowhere.
    func testTheBudgetStopsTheNextCallWithItsReason() throws {
        let (fd, lines) = transcript()
        let stub = StubBackend(replies: [reply("a", tokens: 300)])
        let s = ModelSession(id: "s2", budget: 500, backend: stub, transcript: fd)
        XCTAssertEqual(post(s, #"{"messages":[]}"#).status, 200)
        XCTAssertEqual(post(s, #"{"messages":[]}"#).status, 200, "300 used of 500: still allowed")
        XCTAssertEqual(s.used, 600)
        let r = post(s, #"{"messages":[]}"#)
        XCTAssertEqual(r.status, 429)
        let j = try JSON.parse(r.body)
        XCTAssertEqual(j["error"]?["type"]?.string, "budget")
        XCTAssertEqual(j["error"]?["message"]?.string, "the session's budget of 500 tokens is spent (600 used)")
        XCTAssertEqual(stub.calls, 2, "the refused call reached no backend")
        XCTAssertEqual(lines().last?["kind"]?.string, "refused")
        XCTAssertEqual(lines().last?["reason"]?.string, "budget")
    }

    func testWhatItRefusesAndWhy() throws {
        let (fd, _) = transcript()
        let s = ModelSession(id: "s3", budget: 10, backend: StubBackend(replies: [reply("x", tokens: 11)]), transcript: fd)
        XCTAssertEqual(post(s, "not json").status, 400)
        XCTAssertEqual(post(s, #"{"model":"m"}"#).status, 400, "no messages")
        let st = post(s, #"{"messages":[],"stream":true}"#)
        XCTAssertEqual(st.status, 400)
        XCTAssertEqual(try JSON.parse(st.body)["error"]?["message"]?.string, "streaming is not offered yet: ask with stream false")
        XCTAssertEqual(s.handle(HTTPRequest(method: "GET", path: "/etc/passwd", headers: [], body: [])).status, 404)
        XCTAssertEqual(s.handle(HTTPRequest(method: "GET", path: "/v1/models", headers: [], body: [])).status, 200)
        XCTAssertEqual(s.used, 0, "refusals cost nothing")
        XCTAssertEqual((s.backend as! StubBackend).calls, 0, "and send nothing")
    }

    func testABackendThatFailsIsA502AndIsLogged() throws {
        let (fd, lines) = transcript()
        let s = ModelSession(id: "s4", budget: 10, backend: StubBackend(replies: []), transcript: fd)
        XCTAssertEqual(post(s, #"{"messages":[]}"#).status, 502)
        XCTAssertEqual(lines().map { $0["kind"]?.string ?? "?" }, ["request", "failed"])
    }

    // MARK: - tiers

    func testVRAMFromTheBootMessages() {
        let box = """
        drmn0: VRAM: 12272M 0x0000008000000000 - 0x00000082FEFFFFFF (12272M used)
        <6>[drm] Detected VRAM RAM=12272M, BAR=256M
        <6>[drm] amdgpu: 12272M of VRAM memory ready
        <6>[drm] amdgpu: 65446M of GTT memory ready.
        """
        XCTAssertEqual(MachineMemory.vram(fromBootMessages: box), 12272)
        XCTAssertNil(MachineMemory.vram(fromBootMessages: "no gpu here\n"))
    }

    func testTheTierIsByVRAM() {
        XCTAssertEqual(ModelTier.choose(.init(vramMiB: 12272, ramMiB: 131072)), .gpu12, "the 12700KF's 6750 XT")
        XCTAssertEqual(ModelTier.choose(.init(vramMiB: nil, ramMiB: 131072)), .cpu, "RAM alone does not make a GPU tier")
        XCTAssertEqual(ModelTier.choose(.init(vramMiB: 4096, ramMiB: 16384)), .cpu)
        XCTAssertEqual(ModelTier.choose(.init(vramMiB: 8192, ramMiB: 16384)), .gpu8)
        XCTAssertEqual(ModelTier.choose(.init(vramMiB: 24576, ramMiB: 65536)), .gpu24)
        XCTAssertEqual(ModelTier.gpu12.proposed.model, "Granite-4.2-8B")
        XCTAssertEqual(ModelTier.gpu12.proposed.quant, "Q4_K_M", "Q8 left the desktop 775 MiB on 12 GB")
        XCTAssertEqual(ModelTier.gpu8.proposed.context, 8192, "8B Q4 at 16K is 7.7 GB: no room on 8 GB")
        XCTAssertEqual(ModelTier.cpu.proposed.model, "MiniCPM5-2B")
    }
}
