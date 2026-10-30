// PoolConfig's cross-language fixtures (docs/RUST.md §3.3): `.ini` files on
// disk that the Swift and the Rust halves must both read to the same
// Config, and serialize back to the same text. Swift is the specification,
// so this test writes the corpus (ABYSS_WIRE_UPDATE=1) and checks it;
// de/poolconfig/tests/wire_fixtures.rs checks the Rust half against the same
// files.
//
// abyss/tests/wire/pool/<case>.ini is the file as a person (or a program)
// left it; <case>.txt what Pool.load makes of it, one fact a line, every
// string in hex so the format needs no escaping:
//
//     sections <name> <name> …          sectionNames, in order
//     schema_version <n>
//     section <name>                     each section, in sectionNames order
//     key <key> <value> u64 <n|-> i64 <n|-> bool <true|false|->
//                                        pairs(section), in order, with the
//                                        typed reads of that key
//     ini <hex>                          toINI()
//     reparsed same|<hex>                parse(toINI()).toINI()
//
// An empty string is `-`. `#` lines are for people; the Rust side skips
// them. The corpus is chosen where the two languages could differ without
// anyone noticing: Swift splits and trims Characters (grapheme clusters, so
// "\r\n" is one), compares Strings by canonical equivalence, and parses
// integers its own way.

import XCTest
@testable import PoolConfig

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class PoolWireFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/PoolConfigTests/PoolWireFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "pool"])
        return p.joined(separator: "/")
    }()

    /// The corpus: name, what it is about, the file's bytes.
    static func cases() -> [(String, String, [UInt8])] {
        func t(_ s: String) -> [UInt8] { Array(s.utf8) }
        var c: [(String, String, [UInt8])] = []

        c.append(("basic", "the panel.ini shape from the pool briefing", t("""
        schema_version = 1

        [panel]
        bg = #ff202028
        apps = firefox,nautilus
        height = 28
        show_clock = true
        offset = -3

        # a comment, and a blank line follow

        [desktop]
        image = /path/to/wallpaper.png

        """)))
        c.append(("empty", "an empty file is an empty Config", []))
        c.append(("no-final-newline", "the last line has no newline", t("a = 1\nb = 2")))

        // 1. Line splitting.
        c.append(("crlf", "CRLF line ends: \"\\r\\n\" is one Character, so nothing splits", t(
            "schema_version = 2\r\n[s]\r\nk = v\r\nn = 5\r\n")))
        c.append(("crlf-mixed", "LF and CRLF in one file: only the LFs split", t(
            "a = 1\n[s]\r\nb = 2\nc = 3\r\n[t]\nd = 4\r\n\r\ne = 5\n")))
        c.append(("crlf-split-line", "a CRLF in mid-line that is the last thing on it", t(
            "[s]\nk = v\r\n\nj = w\n")))
        c.append(("lone-cr", "a lone \"\\r\" ends nothing; it is trimmed at the ends", t(
            "\r[s]\r\nk = a\rb\n\rj = 2\r\n[t]\r\nx = 1\r\r\ny = 2\r")))
        c.append(("cr-before-crlf", "\"\\r\\r\\n\" is a \"\\r\" and a \"\\r\\n\"", t(
            "[s]\nk = v\r\r\nj = w\n")))

        // 2. Equality and order of names.
        c.append(("unicode-nfc-order", "names in NFC: Swift's order is code-point order", t(
            "[s]\nf = 1\nab = 2\nZ = 3\n\u{E9} = 4\n\u{65E5}\u{672C} = 5\n\u{1F600} = 6\n\u{E4} = 7\n_ = 8\n" +
            "[\u{C9}cole]\nk = 1\n[Ecole]\nk = 2\n[\u{1F30A}]\nk = 3\n")))
        c.append(("unicode-equivalent-keys", "canonically equivalent names are one name to Swift", t(
            "[s]\n\u{E9} = precomposed\ne\u{301} = decomposed\n\u{212A} = kelvin\nK = latin\n" +
            "[caf\u{E9}]\nk = 1\n[cafe\u{301}]\nj = 2\n")))
        c.append(("unicode-nfd-order", "a decomposed name sorts as its NFC form in Swift", t(
            "[s]\nf = 1\na\u{301}b = 2\nab = 3\nb = 4\n")))

        // 3. Numbers and booleans.
        let nums = ["+5", "-0", "-00", "+0", "05", "0x10", "1_000", "", "+", "-", "+-5", "++1", "1-",
                    "18446744073709551615", "18446744073709551616",
                    "9223372036854775807", "9223372036854775808",
                    "-9223372036854775808", "-9223372036854775809", "-1",
                    "000000000000000000000000000042", "-0000000000000000000000000",
                    "\u{FF15}", "1 2", "\u{A0}5", "\u{0B}5", "\u{0C}5", "5\u{301}", "\u{0660}"]
        c.append(("numbers", "UInt64 and Int64 coercions, including the odd ones", t(
            "[n]\n" + nums.enumerated().map { "k\(String($0.offset + 10)) = \($0.element)\n" }.joined() +
            "tab =\t7\t\nspaces =    8    \n")))
        let bools = ["true", "TRUE", "True", "tRuE", "yes", "YES", "Yes", "on", "On", "oN", "ON", "1",
                     "false", "FALSE", "no", "No", "off", "OFF", "0",
                     "y", "t", "2", "true!", "yes yes", "\u{FF34}\u{FF32}\u{FF35}\u{FF25}",
                     "\u{130}", "\u{212A}", "on\u{301}", "o\u{200B}n", "01", "00", "-1"]
        c.append(("booleans", "the bool spellings, mixed case and non-ASCII", t(
            "[b]\n" + bools.enumerated().map { "k\(String($0.offset + 10)) = \($0.element)\n" }.joined())))

        // 4. The rest of the format.
        var lenient = t("[s\u{E9}]\nok = 1\n")
        lenient += [0x6b, 0xff, 0x20, 0x3d, 0x20, 0xc3, 0x28, 0x0a]               // k\xff = \xc3(
        lenient += t("v = ") + [0xe2, 0x82, 0x0a]                                 // a truncated 3-byte
        lenient += t("w = ") + [0xf0, 0x9f, 0x98, 0x20, 0xed, 0xa0, 0x80, 0x20, 0xc0, 0xaf, 0x0a]
        lenient += [0x5b, 0x80, 0x5d, 0x0a] + t("x = 1\n")                        // [\x80]
        lenient += t("y = ") + [0xf4, 0x90, 0x80, 0x80, 0xfe, 0x0a]               // past U+10FFFF
        c.append(("lenient-utf8", "invalid UTF-8 is read leniently, as U+FFFD", lenient))
        c.append(("bom", "a byte-order mark is a character, so the first header is lost", t(
            "\u{FEFF}[s]\nk = v\n[t]\n\u{FEFF}j = w\n")))
        c.append(("bom-key", "a byte-order mark before a key stays on the key", t(
            "\u{FEFF}schema_version = 3\nschema_version2 = 4\n")))
        c.append(("comments", "full-line comments only; an inline # or ; is part of the value", t(
            "# c\n; c\n  # indented\n\t; tabbed\nk = v # not a comment\n;x=1\n#y=2\nz = ; also value\n" +
            "[s] # trailing\nj = 1\n#[t]\nm = 2\n")))
        c.append(("sections", "header spacing, nesting, and lines that are not headers", t(
            "[ spaced ]\na = 1\n[\tTab\t]\nb = 2\n[]\nc = 3\n[ ]\nd = 4\n[a]b]\ne = 5\n[[x]]\nf = 6\n" +
            "[unclosed\ng = 7\n[x] trailing\nh = 8\n  [indented]  \ni = 9\n[k=v]\nj = 10\n[\n]\n[s\r]\nk = 11\n")))
        c.append(("equals", "the first = splits; keys and values are trimmed", t(
            "url = http://x/?a=b&c=d\n=nokey\n = also no key\nempty =\nk==v\n  spaced   =   value with  spaces  \n" +
            "a=b=c\nnoequals\n\t\tk2\t=\tv2\t\n")))
        c.append(("duplicates", "a repeated key replaces; a repeated section continues", t(
            "[s]\nk = 1\nk = 2\n[t]\nx = 1\n[s]\nk = 3\nj = 4\n[]\ntop = 1\n[t]\nx = 2\n")))
        c.append(("before-header", "keys before any header are the default section", t(
            "top = 1\nschema_version = 7\n[s]\nk = v\nschema_version = 9\n")))
        c.append(("empty-sections", "a header with no keys is not a section", t(
            "[empty]\n[also]\n# nothing\n[full]\nk = v\n[empty2]\n\n")))
        c.append(("schema-version", "schema_version coerces like any UInt64", t(
            "schema_version = +9\n[s]\nschema_version = 5\n")))
        c.append(("schema-version-bad", "an unparseable schema_version is 0", t("schema_version = -1\n")))
        c.append(("whitespace", "blank, tab-only and space-only lines", t(
            "\t\n   \n\n\t \t\n[s]\n \t k \t = \t v \t \n")))
        c.append(("control-chars", "a NUL and other controls are ordinary characters", t(
            "[s]\nk = a\u{0}b\n\u{7}bell = 1\nv = x\u{1B}[0m\n")))

        // Swift's Characters around the delimiters: a combining mark joins
        // the ASCII before it, so the pair is not "[", "=", "#" or " ".
        c.append(("graphemes", "combining marks and joiners on the delimiters", t(
            "[\u{301}x]\na = 1\n[y]\u{301}\nb = 2\n[z]\n \u{301}k = v\n\t\u{301}j = w\nm =\u{301} x\n" +
            "x\u{301}= y\n#\u{301} not a comment = 1\n#\u{FE0F}\u{20E3} keycap = 2\n;\u{200D} zwj = 3\n" +
            "o = v \u{301}\np = v\t\u{301}\nq\u{600}= 1\nr = 1\u{600} \n\u{600}[w]\ns = 2\n[w\u{600}]\nt = 3\n")))
        c.append(("greek-question-mark", "U+037E is canonically \";\", so it starts a comment", t(
            "[s]\n\u{37E} greek = 1\nk = \u{37E}\n[t]\n\u{37E}\u{301} = 2\n")))
        c.append(("long", "a long value", t("[s]\nk = " + String(repeating: "abcdefghij", count: 2000) + "\n")))
        return c
    }

    // MARK: the text form

    static func hex(_ s: String) -> String {
        let b = Array(s.utf8)
        return b.isEmpty ? "-" : b.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    static func dump(_ c: Config) -> String {
        func opt<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "-" }
        var out = "sections" + c.sectionNames.map { " " + hex($0) }.joined() + "\n"
        out += "schema_version \(c.schemaVersion)\n"
        for s in c.sectionNames {
            out += "# [\(s.debugDescription)]\n"
            out += "section \(hex(s))\n"
            for (k, v) in c.pairs(s) {
                let shown = v.count > 60 ? String(v.prefix(60)) + "…" : v
                out += "# \(k.debugDescription) = \(shown.debugDescription)\n"
                out += "key \(hex(k)) \(hex(v)) u64 \(opt(c.uint64(s, k))) i64 \(opt(c.int64(s, k))) bool \(opt(c.bool(s, k)))\n"
            }
        }
        let ini = c.toINI()
        out += "ini \(hex(ini))\n"
        let again = Config.parse(ini).toINI()
        out += "reparsed \(again == ini && Array(again.utf8) == Array(ini.utf8) ? "same" : hex(again))\n"
        return out
    }

    func write(_ path: String, _ bytes: [UInt8]) throws {
        guard let f = fopen(path, "wb") else { throw PoolError.io("fopen \(path)") }
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

    // MARK: the test

    func testTheFixturesAreWhatSwiftReadsAndWrites() throws {
        let dir = Self.dir
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/pool".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for (name, about, bytes) in Self.cases() {
                try write("\(dir)/\(name).ini", bytes)
                let c = try Pool.load(name, in: dir)
                try write("\(dir)/\(name).txt", Array(("# \(name): \(about)\n" + Self.dump(c)).utf8))
            }
        }

        // Check every case on disk, whoever wrote it: the .ini is the corpus's,
        // and Pool.load of it is what the .txt says.
        var checked = 0
        for (name, _, bytes) in Self.cases() {
            guard let ini = read("\(dir)/\(name).ini"),
                  let txt = read("\(dir)/\(name).txt").map({ String(decoding: $0, as: UTF8.self) }) else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            XCTAssertEqual(ini, bytes, "\(name): the .ini is not the corpus's")
            let want = txt.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("#") }.joined(separator: "\n")
            let got = Self.dump(try Pool.load(name, in: dir)).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("#") }.joined(separator: "\n")
            XCTAssertEqual(got, want, "\(name): what Pool.load makes of the file")
            checked += 1
        }
        XCTAssertEqual(checked, Self.cases().count)
    }
}
