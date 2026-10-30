// DBus's cross-language fixtures (docs/RUST.md §3.3). Swift is the
// specification: this test writes the corpus (ABYSS_WIRE_UPDATE=1) and checks
// it; de/dbus/tests checks the Rust half against the same files.
//
// abyss/tests/wire/dbus/<case>.bin is a D-Bus message as it crosses a socket,
// and <case>.txt names its decoder and then what it read:
//
//   message fds=N   the message, decoded with N descriptors (100, 101, ...)
//                   alongside; its header fields, then its body, one value a
//                   line. `malformed "<why>"` is bytes both refuse.
//   frame           how many bytes the stream's first message needs.
//
// A `decode-only` line marks bytes our encoder would not produce: a peer's
// big-endian, a bool of 2, a field we ignore. <case>.in is a bus address;
// its .txt's first line is `address`, then what it names.
//
// The cases Swift cannot survive are not here: an array of `()` loops for
// ever, and variants nested deep enough run its stack out. Rust refuses both
// (de/dbus/src/tests.rs).

import XCTest
@testable import DBus

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class DBusWireFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/DBusTests/DBusWireFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "dbus"])
        return p.joined(separator: "/")
    }()

    struct Case {
        let name: String
        let decoder: String
        let bytes: [UInt8]
        var decodeOnly = false
    }

    // MARK: the corpus

    static func messages() -> [(String, DBusMessage)] {
        var open = DBusMessage.methodCall(
            destination: "org.freedesktop.portal.Desktop", path: "/org/freedesktop/portal/desktop",
            interface: "org.freedesktop.portal.FileChooser", member: "OpenFile",
            body: [.string(""), .string("Open a file"),
                   .options([("handle_token", .string("abyss1")), ("multiple", .bool(false)),
                             ("modal", .bool(true)), ("count", .uint32(3)),
                             ("filters", .array("(sa(us))", [.structure([.string("Images"),
                                 .array("(us)", [.structure([.uint32(0), .string("*.png")]),
                                                 .structure([.uint32(1), .string("image/jpeg")])])])]))])])
        open.serial = 7
        open.sender = ":1.42"
        open.flags = [.noAutoStart]

        var ping = DBusMessage.methodCall(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                          interface: "org.freedesktop.DBus", member: "Hello")
        ping.serial = 1
        ping.flags = [.noReplyExpected, .noAutoStart]

        var fds = DBusMessage(type: .methodReturn)
        fds.serial = 9; fds.replySerial = 3; fds.destination = ":1.7"
        fds.body = [.unixFD(100), .string("between"), .unixFD(101)]

        var call = DBusMessage.methodCall(destination: "d", path: "/p", interface: "i", member: "m")
        call.serial = 11; call.sender = ":1.9"
        var err = DBusMessage.error(to: call, name: "org.freedesktop.DBus.Error.Failed", message: "no \"such\"\nthing")
        err.serial = 12

        var reply = DBusMessage.methodReturn(to: call, body: [.uint32(1)])
        reply.serial = 13

        var addressed = DBusMessage.signal(path: "/org/freedesktop/portal/desktop/request/1_42/abyss1",
                                           interface: "org.freedesktop.portal.Request", member: "Response",
                                           to: ":1.42", body: [.uint32(0), .options([("uris", .variant(.array("s", [.string("file:///home/a/b%20c.png")])))])])
        addressed.serial = 20
        var broadcast = DBusMessage.signal(path: "/org/freedesktop/portal/desktop",
                                           interface: "org.freedesktop.portal.Settings", member: "SettingChanged",
                                           body: [.string("org.freedesktop.appearance"), .string("accent-color"),
                                                  .variant(.structure([.double(0.25), .double(63.0 / 255), .double(1)]))])
        broadcast.serial = 21

        var every = DBusMessage.signal(path: "/a", interface: "i.f", member: "Every")
        every.serial = 0xffff_ffff
        every.body = [.byte(0xfe), .bool(true), .bool(false), .uint16(65535), .int32(-42), .uint32(4_000_000_000),
                      .uint64(0xDEAD_BEEF_CAFE_BABE), .double(-0.0), .double(Double(bitPattern: 0x7ff8_0000_0000_0001)),
                      .double(-1.7976931348623157e308), .string(""), .string("ünïcödé ✓"), .objectPath("/"),
                      .signature("a{sv}(i)"), .array("s", []), .array("t", [.uint64(1), .uint64(2)]),
                      .array("aas", [.array("as", [.array("s", [.string("deep")])]), .array("as", [])]),
                      .structure([.byte(1), .structure([.uint64(2)]), .dictEntry(.string("k"), .int32(3))]),
                      .variant(.variant(.byte(9))), .array("{ys}", [.dictEntry(.byte(1), .string("one"))])]

        var aligned = DBusMessage.signal(path: "/abcde", interface: "i", member: "M")
        aligned.serial = 2
        aligned.body = [.byte(1), .uint64(2), .byte(3), .uint16(4), .byte(5), .uint32(6), .byte(7), .structure([.byte(8)])]

        var empty = DBusMessage(type: .signal)
        empty.serial = 3

        return [("method-call-portal", open), ("method-call-hello", ping), ("method-return-fds", fds),
                ("error", err), ("method-return", reply), ("signal-addressed", addressed),
                ("signal-broadcast", broadcast), ("every-type", every), ("alignment", aligned),
                ("no-fields", empty)]
    }

    /// A message from parts, for bytes our encoder would not write: header
    /// fields as given, then a body the closure writes at its real offset.
    static func raw(type: UInt8 = 4, fields: [(UInt8, DBusValue)],
                    body: (inout Marshaller) -> Void = { _ in }) -> [UInt8] {
        var f = Marshaller(origin: 16)
        for (code, v) in fields { f.align(8); f.byte(code); f.value(.variant(v)) }
        let bodyStart = (16 + f.bytes.count + 7) & ~7
        var b = Marshaller(origin: bodyStart)
        body(&b)
        var out = Marshaller()
        out.byte(UInt8(ascii: "l")); out.byte(type); out.byte(0); out.byte(1)
        out.uint32(UInt32(b.bytes.count)); out.uint32(1); out.uint32(UInt32(f.bytes.count))
        var bytes = out.bytes + f.bytes
        while bytes.count % 8 != 0 { bytes.append(0) }
        return bytes + b.bytes
    }

    static func sig(_ s: String) -> [(UInt8, DBusValue)] {
        [(1, .objectPath("/x")), (2, .string("i.f")), (3, .string("S")), (8, .signature(s))]
    }

    static func handBuilt() -> [Case] {
        var cases: [Case] = []
        func only(_ name: String, _ bytes: [UInt8], fds: Int = 0) {
            cases.append(Case(name: name, decoder: "message fds=\(fds)", bytes: bytes, decodeOnly: true))
        }
        // A big-endian signal, `u` 0x01020304: what a peer may send.
        only("big-endian", [UInt8(ascii: "B"), 4, 0, 1, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 0, 0x37,
                            1, 1, UInt8(ascii: "o"), 0, 0, 0, 0, 2, UInt8(ascii: "/"), UInt8(ascii: "x"), 0, 0, 0, 0, 0, 0,
                            2, 1, UInt8(ascii: "s"), 0, 0, 0, 0, 3, UInt8(ascii: "i"), UInt8(ascii: "."), UInt8(ascii: "f"), 0, 0, 0, 0, 0,
                            3, 1, UInt8(ascii: "s"), 0, 0, 0, 0, 1, UInt8(ascii: "S"), 0, 0, 0, 0, 0, 0, 0,
                            8, 1, UInt8(ascii: "g"), 0, 1, UInt8(ascii: "u"), 0, 0,
                            1, 2, 3, 4])
        only("bool-two", raw(fields: sig("b")) { $0.uint32(2) })
        only("invalid-utf8", raw(fields: sig("s")) { $0.uint32(3); $0.byte(0xff); $0.byte(0xfe); $0.byte(0x41); $0.byte(0) })
        only("ignored-fields", raw(fields: [(0x20, .string("a field nobody knows")), (1, .string("/not/a/path")),
                                            (3, .string("S")), (5, .string("not a serial")), (8, .signature("u"))]) {
            $0.uint32(7)
        })
        only("signature-no-body", raw(fields: sig("s")))
        only("trailing-body", raw(fields: sig("y")) { $0.byte(7); $0.byte(1); $0.byte(2); $0.byte(3) })
        only("declared-fds", raw(fields: sig("u") + [(9, .uint32(3))]) { $0.uint32(0) }, fds: 3)
        only("fd-out-of-range", raw(fields: sig("hh") + [(9, .uint32(2))]) { $0.uint32(0); $0.uint32(1) }, fds: 1)
        only("array-overrun", raw(fields: sig("au")) { $0.uint32(8); $0.uint32(1) })
        only("array-past-message", raw(fields: sig("au")) { $0.uint32(64); $0.uint32(1) })
        only("unsupported-type", raw(fields: sig("Z")) { $0.uint32(0) })
        only("array-no-element", raw(fields: sig("a")) { $0.uint32(0) })
        only("dict-two-of-one", raw(fields: sig("a{s}")) { $0.uint32(6); $0.align(8); $0.string("k") })
        only("truncated-string", raw(fields: sig("s")) { $0.uint32(10); $0.byte(0x61); $0.byte(0x62) })
        only("truncated-uint64", raw(fields: sig("t")) { $0.uint32(1) })
        only("variant-of-two", raw(fields: sig("v")) { $0.signature("ss"); $0.string("a"); $0.string("b") })
        only("struct-unbalanced", raw(fields: sig("(")) { $0.uint64(0) })
        only("struct-empty", raw(fields: sig("()")) { $0.uint64(0) })
        only("close-paren", raw(fields: sig("s)")) { $0.string("a") })
        only("empty-array-of-nothing", raw(fields: sig("a{sss}")) { $0.uint32(0); $0.uint32(0) })
        only("variants-70", raw(fields: sig("v")) { m in
            for _ in 0..<69 { m.signature("v") }
            m.signature("y"); m.byte(5)
        })
        only("variants-63", raw(fields: sig("v")) { m in
            for _ in 0..<62 { m.signature("v") }
            m.signature("y"); m.byte(5)
        })

        // The prologue and the framing.
        var m = DBusMessage.signal(path: "/x", interface: "i.f", member: "Sig", body: [.string("payload")])
        m.serial = 2
        let good = m.encode().bytes
        func patched(_ at: Int, _ b: UInt8) -> [UInt8] { var x = good; x[at] = b; return x }
        only("short", Array(good[0..<15]))
        only("bad-endianness", patched(0, UInt8(ascii: "?")))
        only("type-zero", patched(1, 0))
        only("type-five", patched(1, 5))
        only("fields-past-end", patched(13, 0xff))
        only("body-past-end", patched(4, 0xff))
        cases.append(Case(name: "frame-partial", decoder: "frame", bytes: Array(good[0..<15]), decodeOnly: true))
        cases.append(Case(name: "frame-exact", decoder: "frame", bytes: good, decodeOnly: true))
        cases.append(Case(name: "frame-two", decoder: "frame", bytes: good + good, decodeOnly: true))
        cases.append(Case(name: "frame-prologue-only", decoder: "frame", bytes: Array(good[0..<16]), decodeOnly: true))
        cases.append(Case(name: "frame-big-endian", decoder: "frame",
                          bytes: [UInt8(ascii: "B"), 4, 0, 1, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 0, 0x37], decodeOnly: true))
        return cases
    }

    static func valid() -> [Case] {
        messages().map { name, msg in
            let (bytes, fds) = msg.encode()
            return Case(name: name, decoder: "message fds=\(fds.count)", bytes: bytes)
        }
    }

    static func texts() -> [(String, String)] {
        [("address-path", "unix:path=/run/user/1000/bus"),
         ("address-abstract", "unix:abstract=/tmp/dbus-AbCdEf,guid=1234567890"),
         ("address-guid", "unix:path=/run/bus,guid=deadbeef"),
         ("address-both", "unix:path=/a;unix:abstract=/b"),
         ("address-later", "tcp:host=x,port=1;unix:path=/c,guid=1"),
         ("address-empty-path", "unix:path="),
         ("address-tcp", "tcp:host=localhost,port=1234"),
         ("address-empty", "")]
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

    static func text(_ v: DBusValue) -> String {
        switch v {
        case .byte(let n): return "y \(n)"
        case .bool(let b): return "b \(b ? 1 : 0)"
        case .uint16(let n): return "q \(n)"
        case .int32(let n): return "i \(n)"
        case .uint32(let n): return "u \(n)"
        case .uint64(let n): return "t \(n)"
        case .double(let d): return "d 0x" + String(d.bitPattern, radix: 16)
        case .string(let s): return "s \(q(s))"
        case .objectPath(let s): return "o \(q(s))"
        case .signature(let s): return "g \(q(s))"
        case .unixFD(let fd): return "h \(fd)"
        case .array(let elem, let items): return "a\(elem) [" + items.map(text).joined(separator: ", ") + "]"
        case .structure(let items): return "(" + items.map(text).joined(separator: " ") + ")"
        case .variant(let inner): return "v " + text(inner)
        case .dictEntry(let k, let v): return "{" + text(k) + " " + text(v) + "}"
        }
    }

    static func text(_ m: DBusMessage) -> String {
        let kind = ["", "method_call", "method_return", "error", "signal"][Int(m.type.rawValue)]
        var out = "type \(kind) flags=\(m.flags.rawValue) serial=\(m.serial)\n"
        if let s = m.path { out += "path \(q(s))\n" }
        if let s = m.interface { out += "interface \(q(s))\n" }
        if let s = m.member { out += "member \(q(s))\n" }
        if let s = m.errorName { out += "error-name \(q(s))\n" }
        if let n = m.replySerial { out += "reply-serial \(n)\n" }
        if let s = m.destination { out += "destination \(q(s))\n" }
        if let s = m.sender { out += "sender \(q(s))\n" }
        out += "declared-fds \(m.declaredFDs)\nbody\n"
        for v in m.body { out += text(v) + "\n" }
        return out
    }

    /// What `decoder` reads from `bin`, and the bytes (and descriptors) the
    /// encoder makes of that.
    static func decode(_ decoder: String, _ bin: [UInt8]) -> (String, [UInt8]?) {
        var out = decoder + "\n"
        if decoder == "frame" {
            return (out + (DBusMessage.framedLength(bin).map { "needs \($0)\n" } ?? "needs more\n"), nil)
        }
        let n = Int(decoder.dropFirst("message fds=".count))!
        let fds = (0..<n).map { Int32(100 + $0) }
        do {
            var m = try DBusMessage.decode(bin, fds: fds)
            out += text(m)
            m.fds = []                      // as the bridge does: they are in the body
            let (bytes, sent) = m.encode()
            out += "sends " + sent.map(String.init).joined(separator: " ") + "\n"
            return (out, bytes)
        } catch {
            return (out + "malformed \(q((error as? DBusError)?.message ?? "\(error)"))\n", nil)
        }
    }

    static func address(_ a: String) -> String {
        guard let (p, abstract) = DBusConnection.parseAddress(a) else { return "address\nnone\n" }
        return "address\npath \(q(p)) abstract=\(abstract ? 1 : 0)\n"
    }

    // MARK: files

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

    func readText(_ path: String) -> String? { read(path).map { String(decoding: $0, as: UTF8.self) } }

    // MARK: the test

    func testTheFixturesAreWhatSwiftReadsAndWrites() {
        let dir = Self.dir
        let cases = Self.valid() + Self.handBuilt()
        let texts = Self.texts()
        XCTAssertEqual(Set(cases.map(\.name) + texts.map(\.0)).count, cases.count + texts.count, "case names are unique")
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/dbus".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for c in cases {
                let (txt, _) = Self.decode(c.decoder, c.bytes)
                write("\(dir)/\(c.name).bin", c.bytes)
                write("\(dir)/\(c.name).txt", Array(((c.decodeOnly ? "decode-only\n" : "") + txt).utf8))
            }
            for (name, a) in texts {
                write("\(dir)/\(name).in", Array(a.utf8))
                write("\(dir)/\(name).txt", Array(Self.address(a).utf8))
            }
        }
        for c in cases {
            guard let bin = read("\(dir)/\(c.name).bin"), let txt = readText("\(dir)/\(c.name).txt") else {
                XCTFail("\(c.name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            let decodeOnly = txt.hasPrefix("decode-only\n")
            let expected = decodeOnly ? String(txt.dropFirst("decode-only\n".count)) : txt
            let (got, encoded) = Self.decode(String(expected.prefix { $0 != "\n" }), bin)
            XCTAssertEqual(got, expected, "\(c.name): decoding the bytes")
            if !decodeOnly { XCTAssertEqual(encoded, bin, "\(c.name): encoding what was decoded") }
        }
        for (name, _) in texts {
            guard let a = readText("\(dir)/\(name).in"), let txt = readText("\(dir)/\(name).txt") else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            XCTAssertEqual(Self.address(a), txt, name)
        }
    }
}
