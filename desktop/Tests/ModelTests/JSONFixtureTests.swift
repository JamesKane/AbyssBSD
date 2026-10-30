// JSON's cross-language fixtures (docs/RUST.md §3.3). Swift is the
// specification: this test writes the corpus (ABYSS_WIRE_UPDATE=1) and checks
// it; de/model/tests checks the Rust half against the same files.
//
// abyss/tests/wire/json/<case>.in is JSON text off the wire; its .txt is
// `json`, then what it parsed to, written back (`parsed <text>`), or why not
// (`malformed <offset> "<why>"`). `numbers.in` is doubles by bit pattern, and
// its .txt each one as the wire writes it: transcripts in the two languages
// are then the same bytes.

import XCTest
@testable import Model

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class JSONFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/ModelTests/JSONFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "json"])
        return p.joined(separator: "/")
    }()

    static func cases() -> [(String, String)] {
        [
            ("chat-request", #"{"model":"m","messages":[{"role":"user","content":"hi \"there\"\n"}],"tools":[{"type":"function","function":{"name":"menu.activate","parameters":{"type":"object"}}}],"temperature":0.2,"n":1,"stream":false,"x":null}"#),
            ("chat-reply", """
             {
               "id": "c1", "choices": [ { "index": 0, "message": { "role": "assistant", "content": null,
                 "tool_calls": [ { "id": "t1", "type": "function",
                   "function": { "name": "describe", "arguments": "{\\"app\\":\\"TextEdit\\"}" } } ] },
                 "finish_reason": "tool_calls" } ],
               "usage": { "prompt_tokens": 1200, "completion_tokens": 34, "total_tokens": 1234 }
             }\t\r

            """),
            ("escapes", #"["\u00e9\ud83d\ude00\t\/", "\b\f\n\r\"\\", "\u0000\u001f\u007f", "é raw ✓"]"#),
            ("numbers-parsed", "[0, -0, 1, -1, 0.5, 1e3, 1E-3, 2.5e+2, 123456789012345678, 1e400, -1e400, 0.1, 9007199254740993]"),
            ("duplicate-keys", #"{"a":1,"b":2,"a":3}"#),
            ("empty-containers", " [ { } , [ ] , \"\" ] "),
            ("deep-127", String(repeating: "[", count: 127) + String(repeating: "]", count: 127)),
            ("deep-128", String(repeating: "[", count: 128) + String(repeating: "]", count: 128)),
            ("empty", ""),
            ("open-object", "{"),
            ("trailing-comma", "[1,]"),
            ("missing-colon", #"{"a" 1}"#),
            ("tru", "tru"),
            ("bad-escape", #""\x""#),
            ("two-values", "1 2"),
            ("raw-newline", "\"a\nb\""),
            ("lone-high", #""\ud800""#),
            ("lone-low", #""\udc00""#),
            ("bad-low", #""\ud800\u0041""#),
            ("short-escape", #""\u12""#),
            ("key-not-string", "{1:2}"),
            ("object-unclosed", #"{"a":1"#),
            ("array-junk", "[1 2]"),
            ("minus-only", "-"),
            ("dot-only", "."),
            ("exponent-only", "1e"),
            ("invalid-utf8", "\"\u{FFFD}\""),
            // What Swift's own number and hex parsers accept, and JSON does not.
            ("plus-one", "+1"),
            ("leading-zero", "01"),
            ("leading-dot", ".5"),
            ("trailing-dot", "1."),
            ("signed-escape", #""\u+abc""#),
        ]
    }

    /// Doubles by bit pattern: whole and not, at every edge of Swift's
    /// `Double.description`.
    static let numbers: [UInt64] = [
        0.0, -0.0, 1, -1, 0.2, 0.1 + 0.2, 1.5, -2.25, 42, 1e3, 123456.789, 8.999e15, 9e15, 9.007199254740991e15,
        9_007_199_254_740_992, 9_007_199_254_740_993, 1e16, 1.5e16, 1e17, 1e21, 1e22, 1e100, 1.7976931348623157e308,
        0.001, 0.0001, 0.00011, 0.000099999, 0.00001, 1.5e-7, 5e-324, 2.2250738585072014e-308, -1e-5,
        1.0 / 3, 2.0 / 3, 100.5, 1e15 + 0.5, .infinity, -.infinity, .nan,
        9_007_199_254_740_994, 9_007_199_254_741_000, 9.5e15, 9.999999999999998e15, 1e16 - 2, 1.2e16, -1e16, -9.5e15,
        0.00010000000000000002, 0.000099999999999999991,
    ].map(\.bitPattern)

    static func q(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default:
                if u.value < 0x20 || u.value == 0x7f { out += "\\u{\(String(u.value, radix: 16))}" }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func run(_ bytes: [UInt8]) -> String {
        do { return "json\nparsed \(try JSON.parse(bytes).text)\n" } catch let e as JSON.ParseError {
            return "json\nmalformed \(e.offset) \(q(e.why))\n"
        } catch { return "json\n\(error)\n" }
    }

    static func numberText() -> String {
        "numbers\n" + numbers.map { "number 0x" + String($0, radix: 16) + " " + JSON.number(Double(bitPattern: $0)).text + "\n" }.joined()
    }

    func write(_ path: String, _ bytes: [UInt8]) {
        guard let f = fopen(path, "wb") else { return XCTFail("fopen \(path)") }
        defer { fclose(f) }
        _ = bytes.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, bytes.count, f) }
    }

    func read(_ path: String) -> [UInt8]? {
        guard let f = fopen(path, "rb") else { return nil }
        defer { fclose(f) }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { fread($0.baseAddress, 1, 65536, f) }
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return out
    }

    func testTheFixturesAreWhatSwiftReadsAndWrites() {
        let dir = Self.dir
        // Invalid UTF-8 is written as bytes, not as the text above.
        func bytes(_ name: String, _ text: String) -> [UInt8] {
            name == "invalid-utf8" ? [0x22, 0xff, 0xfe, 0x22] : Array(text.utf8)
        }
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/json".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for (name, text) in Self.cases() {
                write("\(dir)/\(name).in", bytes(name, text))
                write("\(dir)/\(name).txt", Array(Self.run(bytes(name, text)).utf8))
            }
            write("\(dir)/numbers.in", Array(Self.numbers.map { "0x" + String($0, radix: 16) + "\n" }.joined().utf8))
            write("\(dir)/numbers.txt", Array(Self.numberText().utf8))
        }
        for (name, _) in Self.cases() {
            guard let input = read("\(dir)/\(name).in"), let txt = read("\(dir)/\(name).txt") else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            XCTAssertEqual(Self.run(input), String(decoding: txt, as: UTF8.self), name)
        }
        XCTAssertEqual(read("\(dir)/numbers.txt").map { String(decoding: $0, as: UTF8.self) }, Self.numberText())
    }
}
