// The vocabulary bridge's cross-language fixtures (docs/RUST.md §3.3). Swift
// is the specification: this test writes the corpus (ABYSS_WIRE_UPDATE=1) and
// checks it; de/vocab/tests checks the Rust half against the same files.
//
// abyss/tests/wire/vocab/<case>.in is a script run against the same fake
// applications in both languages (TextEdit twice, as two launches; Grab;
// Preview). Each command is echoed after `> `, then what the agent was told
// (`reply` and the message's fields, in order) and what the transcript got
// (`log <kind> <fields as JSON>`): the agent's view and the person's, both.
//
//   give <service> | take <app> | permit <app> yes|no | kill <service>
//   request <method> ["app"] ["verb"] ["arguments"]

import XCTest
import CurrentIPC
import MenuModel
@testable import Model
@testable import Vocabulary

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class VocabularyFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/ModelTests/VocabularyFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "vocab"])
        return p.joined(separator: "/")
    }()

    struct Gone: Error, CustomStringConvertible { var description: String { "gone" } }

    final class Apps: MenuCaller {
        var dead: Set<String> = []
        static func model(_ service: String) -> MenuBarModel? {
            let textedit = MenuBarModel(appName: "TextEdit", menus: [
                Menu("File", [.command(Command("file.save", "Save", key: .cmd("s"), summary: "Save the document.", writes: true)),
                              .command(Command("file.open", "Open…", arguments: [Argument("path", .path, "The file.")],
                                               summary: "Open a file.")),
                              .separator,
                              .command(Command("file.close", "Close", summary: "Close the document."))]),
                Menu("Edit", [.command(Command("edit.find", "Find…", arguments: [Argument("text", .string, "What to find."),
                                                                                Argument("case", .bool, "Match case.")],
                                               summary: "Find text."))]),
            ])
            switch service {
            case "menus.textedit.42", "menus.textedit.43": return textedit
            case "menus.grab.7":
                return MenuBarModel(appName: "Grab", menus: [
                    Menu("Capture", [.command(Command("capture.screen", "Screen", summary: "Capture the screen."))]),
                ])
            case "menus.preview.9":
                return MenuBarModel(appName: "Preview", menus: [
                    Menu("Go", [.command(Command("go.page", "Go to Page…", arguments: [Argument("page", .integer, "The page.")],
                                                 summary: "Show a page."))]),
                    Menu("File", [.command(Command("file.export", "Export…", arguments: [Argument("path", .path, "Where.")],
                                                   summary: "Write a copy.", writes: true))]),
                ])
            default: return nil
            }
        }
        func describe(_ service: String) throws -> (model: MenuBarModel, enablement: [String: Enablement]) {
            guard !dead.contains(service), let m = Apps.model(service) else { throw Gone() }
            return (m, ["file.open": .disabled("a document is open"), "go.page": .disabled("no document")])
        }
        func activate(_ service: String, verb: String, arguments: [String: String]) throws -> CommandResult {
            guard !dead.contains(service) else { throw Gone() }
            switch verb {
            case "file.save", "file.close": return .ok(nil)
            case "capture.screen": return .ok("/home/a/Screen.png")
            case "file.export": return .ok("wrote \(arguments["path"] ?? "nothing")")
            default: return .refused("not now")
            }
        }
    }

    static func scripts() -> [(String, String)] {
        [
            ("given-only", """
            request apps
            give menus.textedit.42
            request apps
            request describe "Grab"
            request activate "Grab" "capture.screen"
            request describe ""
            request describe
            request give
            request nothing "TextEdit"
            request describe "TextEdit"
            request describe "TEXTEDIT"
            """),
            ("write-permission", """
            give menus.textedit.42
            request activate "TextEdit" "file.save"
            request activate "TextEdit" "file.close"
            permit TextEdit no
            request activate "TextEdit" "file.save"
            permit textedit yes
            request activate "TextEdit" "file.save"
            request activate "TextEdit" "no.such.verb"
            request activate "TextEdit" ""
            """),
            ("give-and-take", """
            give menus.grab.7
            give menus.textedit.42
            give menus.preview.9
            request apps
            give menus.textedit.43
            request apps
            give menus.grab.7
            request apps
            take textedit
            take TextEdit
            request activate "TextEdit" "file.close"
            take Nobody
            give menus.nothing.1
            request apps
            request activate "Grab" "capture.screen"
            """),
            ("dead-app", """
            give menus.textedit.42
            kill menus.textedit.42
            request describe "TextEdit"
            request activate "TextEdit" "file.save"
            request activate "TextEdit" "file.close"
            request apps
            """),
            ("arguments", """
            give menus.preview.9
            give menus.textedit.42
            request describe "Preview"
            request activate "Preview" "go.page" "page=3"
            request activate "Preview" "file.export" "path=/home/a/b c.pdf"
            permit Preview yes
            request activate "Preview" "file.export" "path=/home/a/b c.pdf\\nz=last\\na==b\\n\\nno equals\\npath=/x \\"quoted\\" é"
            request activate "TextEdit" "edit.find" "text=a=b\\ncase=yes\\n=empty key"
            """),
        ]
    }

    // MARK: the text form

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

    /// A command's words, quoted ones (with \n, \" and \\) apart.
    static func words(_ line: String) -> [String] {
        let u = Array(line.unicodeScalars)
        var out: [String] = [], i = 0
        while i < u.count {
            if u[i] == " " { i += 1; continue }
            var w = String.UnicodeScalarView()
            if u[i] == "\"" {
                i += 1
                while i < u.count, u[i] != "\"" {
                    if u[i] == "\\" {
                        i += 1
                        w.append(u[i] == "n" ? "\n" : u[i])
                    } else { w.append(u[i]) }
                    i += 1
                }
                i += 1
            } else {
                while i < u.count, u[i] != " " { w.append(u[i]); i += 1 }
            }
            out.append(String(w))
        }
        return out
    }

    static func reply(_ m: Msg) -> String {
        var out = "reply"
        for f in m.fields {
            switch f.value {
            case .string(let s): out += " \(f.name)=\(q(s))"
            case .bool(let b): out += " \(f.name)=\(b ? 1 : 0)"
            case .uint64(let n): out += " \(f.name)=\(n)"
            default: out += " \(f.name)=?"
            }
        }
        return out + "\n"
    }

    static func run(_ script: String) -> String {
        var out = ""
        let apps = Apps()
        var logged: [String] = []
        let b = VocabularyBridge(menus: apps) { kind, fields in logged.append("log \(kind) \(JSON.object(fields).text)\n") }
        for line in script.split(separator: "\n") {
            out += "> \(line)\n"
            let w = words(String(line))
            switch w[0] {
            case "give":
                do { out += "given \(q(try b.give(service: w[1])))\n" } catch { out += "not given: \(error)\n" }
            case "take": out += "taken \(b.take(w[1]) ? 1 : 0)\n"
            case "permit": b.permit(w[1], allow: w[2] == "yes")
            case "kill": apps.dead.insert(w[1])
            case "request":
                var m = Msg()
                m.set("method", w[1])
                for (i, k) in ["app", "verb", "arguments"].enumerated() where w.count > i + 2 { m.set(k, w[i + 2]) }
                out += reply(b.handle(m))
            default: out += "no command\n"
            }
            out += logged.joined()
            logged = []
        }
        return out
    }

    func write(_ path: String, _ text: String) {
        guard let f = fopen(path, "wb") else { return XCTFail("fopen \(path)") }
        defer { fclose(f) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, bytes.count, f) }
    }

    func read(_ path: String) -> String? {
        guard let f = fopen(path, "rb") else { return nil }
        defer { fclose(f) }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { fread($0.baseAddress, 1, 65536, f) }
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return String(decoding: out, as: UTF8.self)
    }

    func testTheFixturesAreWhatSwiftSaysAndLogs() {
        let dir = Self.dir
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/vocab".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for (name, script) in Self.scripts() {
                write("\(dir)/\(name).in", script + "\n")
                write("\(dir)/\(name).txt", Self.run(script))
            }
        }
        for (name, _) in Self.scripts() {
            guard let script = read("\(dir)/\(name).in"), let txt = read("\(dir)/\(name).txt") else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            XCTAssertEqual(Self.run(script), txt, name)
        }
    }
}
