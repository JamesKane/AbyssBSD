// TextModel's cross-language fixtures (docs/RUST.md §3.3). Swift is the
// specification: this test writes the corpus (ABYSS_WIRE_UPDATE=1) and checks
// it; de/textmodel/tests checks the Rust half against the same files.
//
// abyss/tests/wire/text/<case>.in is an editing script, one command a line;
// <case>.txt is what running it printed: each command after `> `, then what
// it said. A command that changes the model prints the model:
//
//   = "<text>" anchor=L:C caret=L:C dirty=0|1 undo=<name>|none redo=<name>|none
//
// The layout's advances are whole numbers (a tab 4, a cluster from U+1100 on
// 2, any other 1), so x prints the same in both languages.

import XCTest
@testable import TextModel

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class TextModelFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/TextModelTests/TextModelFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "text"])
        return p.joined(separator: "/")
    }()

    static func scripts() -> [(String, String)] {
        [
            ("edit-lines", """
            text "hello\\nworld"
            caret 0 5
            insert " there\\nbig"
            select 0 5 2 0
            backspace
            caret 0 5
            insert "\\n"
            delete
            caret 1 0
            backspace
            replace 0 2 0 99 "LP!"
            replace 9 9 9 9 "end"
            caret 99 99
            caret -1 3
            """),
            ("clusters", """
            text "a\\r\\nb\\rc\\nd"
            clusters
            text "e\\u{301}x\\u{1f1eb}\\u{1f1f7}\\u{1f1e9}\\u{1f1ea}\\u{1f1fa}"
            clusters
            text "\\u{1f469}\\u{200d}\\u{1f469}\\u{200d}\\u{1f467} \\u{1f44d}\\u{1f3fd} 1\\u{fe0f}\\u{20e3} \\u{2764}\\u{fe0f}"
            clusters
            text "\\u{1100}\\u{1161}\\u{11a8} \\u{ac00}\\u{11a8} \\u{d55c}\\u{ae00}"
            clusters
            text "\\u{915}\\u{94d}\\u{937} \\u{e01}\\u{e33} \\u{646}\\u{651}\\u{64e}"
            clusters
            text "a\\u{200d}b \\u{1f3f3}\\u{fe0f}\\u{200d}\\u{1f308} \\t\\u{7f}\\u{0}"
            clusters
            text ""
            clusters
            text "\\n\\n"
            clusters
            """),
            ("typed-accent", """
            text "e"
            caret 0 1
            insert "\\u{301}"
            clusters
            move left
            move left
            undo
            clusters
            """),
            ("motion-words", """
            text "one two, three\\nfour"
            caret 0 0
            move word-right
            move word-right
            move word-right
            move word-right
            move word-left
            move word-left
            move line-start extend
            move right
            move left extend
            move left
            move doc-end
            move doc-start extend
            move line-end
            move right
            move right
            move left
            move left
            text "don't snake_case 42nd café-crème  \\u{3b1}\\u{3b2}\\u{3b3} ..."
            caret 0 0
            move word-right
            move word-right
            move word-right
            move word-right
            move word-right
            move word-right
            move word-right
            move word-left
            move word-left
            move word-left
            target word-left 0 0
            target word-right 0 99
            """),
            ("motion-lines", """
            text "a\\n\\n  b  \\n"
            caret 0 1
            move word-right
            move word-right
            move word-right
            move word-left
            move word-left
            move word-left
            move word-left
            target left 0 0
            target right 3 0
            target line-end 2 1
            """),
            ("ranges", """
            text "one two, three\\n\\nend"
            word 0 0
            word 0 3
            word 0 5
            word 0 7
            word 0 8
            word 0 14
            word 1 0
            word 9 9
            line 0 2
            line 1 0
            line 2 1
            offset 2 1
            offset 9 9
            position 0
            position 15
            position 16
            position 99
            """),
            ("undo-typing", """
            text "abc"
            save
            caret 0 3
            insert " "
            insert "d"
            insert "e"
            insert "f"
            caret 0 0
            insert "X"
            undo
            undo
            redo
            backspace
            backspace
            undo
            select 0 0 0 3
            insert "ABC" paste
            undo
            redo
            undo
            undo
            undo
            undo
            redo
            """),
            ("undo-runs", """
            text "hello world"
            caret 0 5
            insert "!"
            insert "?"
            caret 0 0
            insert "a"
            caret 0 7
            insert "b"
            undo
            undo
            caret 0 11
            backspace
            backspace
            backspace word
            undo
            caret 0 0
            delete
            delete
            delete word
            undo
            select 0 0 0 4
            insert "" cut
            insert "x" other "Replace"
            undo
            undo
            """),
            ("undo-saved", """
            text "a"
            caret 0 1
            insert "b"
            save
            undo
            caret 0 0
            insert "z" other "Change"
            undo
            redo
            save
            insert "q"
            save
            insert "r"
            undo
            """),
            ("undo-multiline", """
            text "one\\ntwo\\nthree"
            select 0 1 2 2
            insert "X\\nY\\nZ\\n" paste
            undo
            redo
            select 1 0 2 0
            backspace
            undo
            caret 2 5
            insert "\\r\\n"
            insert "\\r"
            undo
            """),
            ("find", """
            text "Cat hat\\ncat"
            caret 0 0
            find "cat"
            select 0 0 0 3
            find "cat"
            select 1 0 1 3
            find "cat"
            find "cat" case
            find "hat" backward
            find "dog"
            find ""
            find "t\\nc"
            find "CAT" backward case
            find "Cat hat\\ncat"
            find "Cat hat\\ncat!"
            """),
            ("find-backward-end", """
            text "ab"
            caret 0 2
            find "ab" backward
            text "xx ab"
            caret 0 5
            find "ab" backward
            find "x" backward
            """),
            ("find-unicode", """
            text "Stra\\u{df}e STRASSE \\u{130}stanbul istanbul \\u{3a3}\\u{3c3}\\u{3c2}"
            caret 0 0
            find "stra\\u{df}e"
            find "\\u{130}stanbul" case
            find "i\\u{307}stanbul"
            find "\\u{3c3}"
            find "e\\u{301}"
            text "caf\\u{e9} cafe\\u{301}"
            caret 0 0
            find "e"
            find "\\u{e9}"
            find "e\\u{301}"
            """),
            ("layout", """
            text "the quick brown fox\\n\\nabcdefghij"
            layout 10
            row 0 10
            row 0 19
            x 0 13
            at 1 2
            at 0 99
            at 1 99
            at 9 0
            at -1 3
            vertical 0 3 1 3
            vertical 0 3 -1 3
            vertical 3 5 1 0
            text "abcdefghijklm"
            layout 5
            text "a\\tb\\tc d"
            layout 6
            x 0 3
            text "\\u{4e2d}\\u{6587}\\u{5b57}\\u{7b26}\\u{4e32} ok"
            layout 5
            at 1 1
            at 1 2
            text "e\\u{301}e\\u{301} \\u{1f469}\\u{200d}\\u{1f467}"
            layout 3
            x 0 4
            text "   "
            layout 1
            layout 0
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

    /// The words of a command: a quoted one may hold spaces. (A quoted word
    /// is kept apart rather than marked with a prefix, which a leading
    /// combining mark would join.)
    static func words(_ line: String) -> [String] {
        let u = Array(line.unicodeScalars)
        var out: [String] = [], i = 0
        quoted = [:]
        while i < u.count {
            if u[i] == " " { i += 1; continue }
            var w = String.UnicodeScalarView()
            if u[i] == "\"" {
                i += 1
                while i < u.count, u[i] != "\"" {
                    if u[i] == "\\" {
                        i += 1
                        switch u[i] {
                        case "n": w.append("\n")
                        case "t": w.append("\t")
                        case "r": w.append("\r")
                        case "u":
                            i += 2                                          // u{
                            var hex = ""
                            while u[i] != "}" { hex.unicodeScalars.append(u[i]); i += 1 }
                            w.append(Unicode.Scalar(UInt32(hex, radix: 16)!)!)
                        default: w.append(u[i])
                        }
                    } else { w.append(u[i]) }
                    i += 1
                }
                i += 1
                quoted[out.count] = String(w)
                out.append("\"")
            } else {
                while i < u.count, u[i] != " " { w.append(u[i]); i += 1 }
                out.append(String(w))
            }
        }
        return out
    }

    /// The quoted words of the command being run, by index.
    nonisolated(unsafe) static var quoted: [Int: String] = [:]

    static func pos(_ p: TextPosition) -> String { "\(p.line):\(p.column)" }
    static func range(_ r: TextRange?) -> String { r.map { "\(pos($0.start))-\(pos($0.end))" } ?? "none" }

    static func state(_ m: TextModel) -> String {
        "= \(q(m.text)) anchor=\(pos(m.anchor)) caret=\(pos(m.caret)) dirty=\(m.isDirty ? 1 : 0)"
            + " undo=\(m.undoName.map(q) ?? "none") redo=\(m.redoName.map(q) ?? "none")\n"
    }

    static let motions: [String: TextModel.Motion] = [
        "left": .left, "right": .right, "word-left": .wordLeft, "word-right": .wordRight,
        "line-start": .lineStart, "line-end": .lineEnd, "doc-start": .documentStart, "doc-end": .documentEnd,
    ]

    static func advance(_ c: Character) -> Double {
        c == "\t" ? 4 : c.unicodeScalars.first!.value >= 0x1100 ? 2 : 1
    }

    /// The script run, as text.
    static func run(_ script: String) -> String {
        var out = ""
        var m = TextModel()
        var layout: TextLayout?
        for line in script.split(separator: "\n") {
            out += "> \(line)\n"
            let w = words(String(line))
            func n(_ i: Int) -> Int { Int(w[i])! }
            func p(_ i: Int) -> TextPosition { TextPosition(line: n(i), column: n(i + 1)) }
            func text(_ i: Int) -> String { quoted[i]! }
            func has(_ flag: String) -> Bool { w.dropFirst().contains(flag) }
            switch w[0] {
            case "text": m = TextModel(text(1)); layout = nil; out += state(m)
            case "caret": m.setCaret(p(1), extend: has("extend")); out += state(m)
            case "select": m.select(TextRange(p(1), p(3))); out += state(m)
            case "all": m.selectAll(); out += state(m)
            case "move": m.move(motions[w[1]]!, extend: has("extend")); out += state(m)
            case "insert":
                let kind: TextEdit.Kind
                switch w.count > 2 ? w[2] : "typing" {
                case "paste": kind = .paste
                case "cut": kind = .cut
                case "deleting": kind = .deleting
                case "other": kind = .other(text(3))
                default: kind = .typing
                }
                m.insert(text(1), kind: kind); out += state(m)
            case "replace": m.replace(TextRange(p(1), p(3)), with: text(5)); out += state(m)
            case "backspace": m.deleteBackward(word: has("word")); out += state(m)
            case "delete": m.deleteForward(word: has("word")); out += state(m)
            case "undo": m.undo(); out += state(m)
            case "redo": m.redo(); out += state(m)
            case "save": m.markSaved(); out += state(m)
            case "clusters":
                for (i, l) in m.lines.enumerated() {
                    out += "line \(i):" + l.map { " " + q(String($0)) }.joined() + "\n"
                }
            case "find":
                out += "found " + range(m.find(text(1), backward: has("backward"), ignoringCase: !has("case"))) + "\n"
            case "word": out += "word " + range(m.wordRange(at: p(1))) + "\n"
            case "line": out += "line " + range(m.lineRange(at: p(1))) + "\n"
            case "offset": out += "offset \(m.offset(of: p(1)))\n"
            case "position": out += "position " + pos(m.position(ofOffset: n(1))) + "\n"
            case "target": out += "target " + pos(m.target(of: motions[w[1]]!, from: p(2))) + "\n"
            case "layout":
                let l = TextLayout(m.lines, width: Double(n(1)), advance: advance)
                layout = l
                out += "rows" + l.rows.map { " \($0.line):\($0.start)-\($0.end)" }.joined() + "\n"
            case "row": out += "row \(layout!.row(of: p(1)))\n"
            case "x": out += "x \(Int(layout!.x(of: p(1))))\n"
            case "at": out += "at " + pos(layout!.position(row: n(1), x: Double(n(2)))) + "\n"
            case "vertical":
                out += "vertical " + (layout!.vertical(from: p(1), by: n(3), goalX: Double(n(4))).map(pos) ?? "none") + "\n"
            default: out += "no command\n"
            }
        }
        return out
    }

    // MARK: files

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

    func testTheFixturesAreWhatSwiftDoes() {
        let dir = Self.dir
        let scripts = Self.scripts()
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/text".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for (name, script) in scripts {
                write("\(dir)/\(name).in", script + "\n")
                write("\(dir)/\(name).txt", Self.run(script))
            }
        }
        for (name, _) in scripts {
            guard let script = read("\(dir)/\(name).in"), let txt = read("\(dir)/\(name).txt") else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            XCTAssertEqual(Self.run(script), txt, name)
        }
    }
}
