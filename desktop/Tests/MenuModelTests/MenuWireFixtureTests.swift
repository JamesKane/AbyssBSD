// MenuWire's cross-language fixtures (docs/RUST.md §3.3): replies and
// requests on disk that the Swift and the Rust halves must decode to the
// same vocabulary and encode back to the same bytes, and the ones both
// must refuse, for the same reason. Swift is the specification, so this
// test writes the corpus (ABYSS_WIRE_UPDATE=1) and checks it;
// de/menuwire/tests checks the Rust half against the same files.
//
// abyss/tests/wire/menu/<case>.bin is a packed message body, and
// <case>.txt names the decoder (describe, validate, activate, result) and
// then what it read: the tree, one line a thing, strings quoted; or
// `malformed "<why>"` / `service "<why>"`, the error. A `decode-only` line
// marks bytes the encoder would not produce. service-names.txt is
// `MenuWire.serviceName` over a list of application names.

import XCTest
import CurrentIPC
import MenuModel
@testable import MenuWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class MenuWireFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/MenuModelTests/MenuWireFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "menu"])
        return p.joined(separator: "/")
    }()

    struct Case {
        let name: String
        let decoder: String
        let bytes: [UInt8]
        var decodeOnly = false
    }

    // MARK: the corpus

    static let fake = MenuBarModel(appName: "Fake", menus: [
        Menu("Fake", [.command(Command("app.about", "About Fake", summary: "Say what this is."))]),
        Menu("File", [
            .command(Command("file.open", "Open", key: .cmd("o"),
                             alternateKeys: [.cmd(.down)], summary: "Open it.")),
            .separator,
            .submenu(Menu("Recent", [
                .submenu(Menu("Older", [
                    .command(Command("file.oldest", "Oldest", key: .cmd("9", [.shift, .option]),
                                     summary: "Three deep.")),
                ])),
            ])),
            .command(Command("file.go", "Go…",
                             arguments: [Argument("path", .path, "Where."),
                                         Argument("times", .integer, "How often.")],
                             summary: "Go somewhere.")),
        ]),
        Menu("Edit", [.command(Command("edit.paste", "Paste", key: .cmd("v"), summary: "Paste."))]),
        Menu("Empty", []),
    ])

    static func fakeEnablement(_ c: Command) -> Enablement {
        c.verb == "edit.paste" ? .disabled("the clipboard is empty") : .enabled
    }

    static let unicode = MenuBarModel(appName: "Café ✓", menus: [
        Menu("Édition", [
            .command(Command("edit.umlaut", "Ü-Taste", key: .cmd("ü", .shift), summary: "Größer.")),
            .command(Command("edit.bracket", "Bracket", key: .cmd("["),
                             alternateKeys: [.cmd(" "), .cmd("ß"),
                                             KeyEquivalent(.tab, [.control]),
                                             KeyEquivalent(.forwardDelete, []),
                                             .cmd(.backspace), .cmd(.up), .cmd(.left),
                                             .cmd(.right), .cmd(.enter), .cmd(.escape)],
                             summary: "Say \"hi\"\nthen\tgo \\ \u{7f}.")),
            .command(Command("edit.every", "Every Type",
                             arguments: ArgumentType.allCases.map { Argument("a-\($0.rawValue)", $0, "日本語") },
                             summary: "", writes: true)),
        ]),
    ])

    static func valid() -> [Case] {
        var cases: [Case] = []
        func add(_ name: String, _ decoder: String, _ m: Msg) {
            cases.append(Case(name: name, decoder: decoder, bytes: m.pack()))
        }
        add("describe-fake", "describe", MenuWire.describeReply(fake, enablement: fakeEnablement))
        let writes = MenuBarModel(appName: "W", menus: [Menu("File", [
            .command(Command("file.save", "Save", summary: "Save.", writes: true)),
            .command(Command("file.close", "Close", summary: "Close.")),
        ])])
        add("describe-writes", "describe", MenuWire.describeReply(writes, enablement: { _ in .enabled }))
        add("describe-empty", "describe",
            MenuWire.describeReply(MenuBarModel(appName: "", menus: []), enablement: { _ in .enabled }))
        add("describe-unicode", "describe",
            MenuWire.describeReply(unicode, enablement: { $0.writes ? .disabled("nothing open — yet") : .enabled }))
        add("describe-no-enablement", "describe", describeReply(fake, states: [:]))

        add("validate-fake", "validate", MenuWire.validateReply(sortedByVerb(fake), enablement: fakeEnablement))
        add("validate-empty", "validate",
            MenuWire.validateReply(MenuBarModel(appName: "", menus: []), enablement: { _ in .enabled }))

        add("activate-args", "activate",
            MenuWire.activateRequest(verb: "file.go",
                                     arguments: ["times": "2", "path": "/tmp/ü x", "zeta": "", "ñ": "\"q\""]))
        add("activate-no-args", "activate", MenuWire.activateRequest(verb: "file.open", arguments: [:]))

        add("result-ok", "result", MenuWire.resultReply(.ok(nil)))
        add("result-ok-value", "result", MenuWire.resultReply(.ok("/tmp/made it")))
        add("result-ok-empty-value", "result", MenuWire.resultReply(.ok("")))
        add("result-refused", "result", MenuWire.resultReply(.refused("Fake has no verb file.nope")))
        return cases
    }

    /// Hand-built bytes: what an encoder would not make, and what both must
    /// refuse.
    static func handBuilt() -> [Case] {
        func describe(_ items: [Msg]) -> [UInt8] {
            var menu = Msg(); menu.set("title", "M"); menu.set("items", bytes: MenuWire.packList(items))
            var m = Msg(); m.set("ok", true); m.set("app", "X")
            m.set("menus", bytes: MenuWire.packList([menu]))
            return m.pack()
        }
        func command(_ extra: (inout Msg) -> Void = { _ in }) -> Msg {
            var c = Msg(); c.set("kind", "command"); c.set("verb", "v"); c.set("title", "T")
            extra(&c)
            return c
        }
        func key(_ name: String, mods: UInt64 = 1, display: String = "x") -> [UInt8] {
            var k = Msg(); k.set("mods", mods); k.set("key", name); k.set("display", display)
            return k.pack()
        }
        func item(_ build: (inout Msg) -> Void) -> Msg { var m = Msg(); build(&m); return m }
        func msg(_ build: (inout Msg) -> Void) -> [UInt8] { item(build).pack() }

        var cases: [Case] = []
        func only(_ name: String, _ decoder: String, _ b: [UInt8]) {
            cases.append(Case(name: name, decoder: decoder, bytes: b, decodeOnly: true))
        }
        // The modifiers are truncated to a byte, the character lowercased,
        // and the display the wire carried is not believed.
        only("describe-key-normalised", "describe",
             describe([command { $0.set("key", bytes: key("char:Q", mods: 0x103, display: "bogus")) }]))
        only("describe-extra-fields", "describe", describe([
            command { $0.set("colour", "red"); $0.set("enabled", true); $0.set("reason", "ignored when enabled") },
            item { $0.set("kind", "separator"); $0.set("title", "a separator has no title") },
        ]))
        // A letter and a combining accent: one Swift Character, two Rust chars.
        only("describe-decomposed-key", "describe",
             describe([command { $0.set("key", bytes: key("char:e\u{301}")) }]))
        only("validate-skips", "validate", msg {
            $0.set("ok", true)
            $0.set("commands", bytes: MenuWire.packList([
                { var c = Msg(); c.set("verb", "no.state"); return c }(),
                { var c = Msg(); c.set("enabled", true); return c }(),
                { var c = Msg(); c.set("verb", "off"); c.set("enabled", false); return c }(),
            ]))
        })

        // Refused.
        only("describe-not-ok", "describe", msg { $0.set("ok", false); $0.set("error", "the clipboard exploded") })
        only("describe-no-ok", "describe", msg { $0.set("app", "X") })
        only("describe-no-verb", "describe", describe([item { $0.set("kind", "command"); $0.set("title", "T") }]))
        only("describe-unknown-kind", "describe", describe([item { $0.set("kind", "spacer") }]))
        only("describe-no-kind", "describe", describe([item { $0.set("title", "T") }]))
        only("describe-bad-key", "describe", describe([command { $0.set("key", bytes: key("hyper")) }]))
        only("describe-two-char-key", "describe", describe([command { $0.set("key", bytes: key("char:ab")) }]))
        only("describe-bad-argument-type", "describe", describe([command {
            $0.set("arguments", bytes: MenuWire.packList([
                { var a = Msg(); a.set("name", "n"); a.set("type", "float"); return a }(),
            ]))
        }]))
        only("describe-garbled-menus", "describe", msg { $0.set("ok", true); $0.set("menus", bytes: [1, 2, 3]) })
        only("validate-not-ok", "validate", msg { $0.set("ok", false) })
        only("result-not-a-result", "result", MenuWire.errorReply("unknown method dance").pack())
        only("result-empty", "result", Msg().pack())
        only("activate-argument-not-text", "activate", msg {
            $0.set("method", "activate"); $0.set("verb", "file.go")
            $0.set("arguments", bytes: { var a = Msg(); a.set("times", UInt64(2)); return a.pack() }())
        })
        return cases
    }

    static let appNames = [
        "Fake", "Text Edit", "TextEdit 2", "Café", "Cafe\u{301}", "a/b.c", "", "日本語",
        "x½", "Ⅻ", "İstanbul", "ΣΊΣΥΦΟΣ", "🌊", "👨‍👩‍👧", "tab\there", "-",
    ]

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

    static func byBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    static func text(_ e: Enablement) -> String {
        switch e {
        case .enabled: return "enabled"
        case .disabled(let why): return "disabled \(q(why))"
        }
    }

    static func text(_ k: KeyEquivalent) -> String {
        "\(k.modifiers.rawValue) \(q(MenuWire.keyName(k.key))) \(q(k.display))"
    }

    static func text(_ menu: Menu, _ states: [String: Enablement], _ indent: String, into out: inout String) {
        for item in menu.items {
            switch item {
            case .command(let c):
                let i = indent + "  "
                out += "\(indent)command \(q(c.verb)) \(q(c.title))\n"
                out += "\(i)summary \(q(c.summary))\n"
                if let k = c.key { out += "\(i)key \(text(k))\n" }
                for k in c.alternateKeys { out += "\(i)alternate \(text(k))\n" }
                for a in c.arguments { out += "\(i)argument \(q(a.name)) \(a.type.rawValue) \(q(a.summary))\n" }
                if c.writes { out += "\(i)writes\n" }
                if let e = states[c.verb] { out += "\(i)\(text(e))\n" }
            case .separator:
                out += "\(indent)separator\n"
            case .submenu(let m):
                out += "\(indent)submenu \(q(m.title))\n"
                text(m, states, indent + "  ", into: &out)
            }
        }
    }

    /// What `decoder` reads from `bin`, and the bytes the encoder makes of
    /// that (nil for an error).
    static func decode(_ decoder: String, _ bin: [UInt8]) -> (String, [UInt8]?) {
        var out = decoder + "\n"
        do {
            let m = try Msg.unpack(bin)
            switch decoder {
            case "describe":
                let d = try MenuWire.decodeDescribe(m)
                out += "app \(q(d.model.appName))\n"
                for menu in d.model.menus {
                    out += "menu \(q(menu.title))\n"
                    text(menu, d.enablement, "  ", into: &out)
                }
                return (out, describeReply(d.model, states: d.enablement).pack())
            case "validate":
                let v = try MenuWire.decodeValidate(m).sorted { byBytes($0.key, $1.key) }
                for (verb, e) in v { out += "\(q(verb)) \(text(e))\n" }
                let model = MenuBarModel(appName: "", menus: [Menu("", v.map { .command(Command($0.key, "", summary: "")) })])
                return (out, MenuWire.validateReply(model, enablement: { c in v.first { $0.key == c.verb }!.value }).pack())
            case "activate":
                guard let verb = m.string("verb") else { throw CurrentError.malformed("activate with no verb") }
                let args = try MenuWire.arguments(of: m)
                out += "verb \(q(verb))\n"
                for (k, v) in args.sorted(by: { byBytes($0.key, $1.key) }) { out += "arg \(q(k)) \(q(v))\n" }
                return (out, MenuWire.activateRequest(verb: verb, arguments: args).pack())
            case "result":
                let r = try MenuWire.decodeResult(m)
                switch r {
                case .ok(nil): out += "ok\n"
                case .ok(let v?): out += "ok \(q(v))\n"
                case .refused(let why): out += "refused \(q(why))\n"
                }
                return (out, MenuWire.resultReply(r).pack())
            default:
                out += "no decoder\n"
            }
        } catch CurrentError.malformed(let why) {
            out += "malformed \(q(why))\n"
        } catch MenuWireError.service(let why) {
            out += "service \(q(why))\n"
        } catch {
            out += "error \(q("\(error)"))\n"
        }
        return (out, nil)
    }

    /// `describeReply`, for a reader that may not know a command's
    /// enablement.
    static func describeReply(_ model: MenuBarModel, states: [String: Enablement]) -> Msg {
        var m = Msg()
        m.set("ok", true)
        m.set("app", model.appName)
        m.set("menus", bytes: MenuWire.packList(model.menus.map { menu in MenuWire.encode(menu, enablement: { c in states[c.verb] }) }))
        return m
    }

    /// One menu of `model`'s commands in verb order: what a decoded
    /// `validate` re-encodes to.
    static func sortedByVerb(_ model: MenuBarModel) -> MenuBarModel {
        MenuBarModel(appName: "", menus: [Menu("", model.commands.sorted { byBytes($0.verb, $1.verb) }.map { .command($0) })])
    }

    static func serviceNames() -> String {
        appNames.map { "\(q($0)) 7 \(q(MenuWire.serviceName(app: $0, pid: 7)))\n" }.joined()
    }

    // MARK: files

    func write(_ path: String, _ bytes: [UInt8]) throws {
        guard let f = fopen(path, "wb") else { throw CurrentError.system(errno, "fopen \(path)") }
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
        let cases = Self.valid() + Self.handBuilt()
        XCTAssertEqual(Set(cases.map(\.name)).count, cases.count, "case names are unique")
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/menu".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for c in cases {
                let (txt, _) = Self.decode(c.decoder, c.bytes)
                try write("\(dir)/\(c.name).bin", c.bytes)
                try write("\(dir)/\(c.name).txt", Array(((c.decodeOnly ? "decode-only\n" : "") + txt).utf8))
            }
            try write("\(dir)/service-names.txt", Array(Self.serviceNames().utf8))
        }

        // Check every case on disk, whoever wrote it.
        for c in cases {
            guard let bin = read("\(dir)/\(c.name).bin"),
                  let txt = read("\(dir)/\(c.name).txt").map({ String(decoding: $0, as: UTF8.self) }) else {
                XCTFail("\(c.name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            let decodeOnly = txt.hasPrefix("decode-only\n")
            let expected = decodeOnly ? String(txt.dropFirst("decode-only\n".count)) : txt
            let decoder = String(expected.prefix { $0 != "\n" })
            let (got, encoded) = Self.decode(decoder, bin)
            XCTAssertEqual(got, expected, "\(c.name): decoding the bytes")
            if !decodeOnly, let encoded {
                XCTAssertEqual(encoded, bin, "\(c.name): encoding what was decoded")
            }
            XCTAssertFalse(!decodeOnly && encoded == nil, "\(c.name): an error case must be decode-only")
        }
        let names = read("\(dir)/service-names.txt").map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(names, Self.serviceNames(), "service-names: run with ABYSS_WIRE_UPDATE=1")
    }
}
