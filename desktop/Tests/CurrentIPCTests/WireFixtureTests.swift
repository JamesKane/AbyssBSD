// CurrentIPC's cross-language fixtures (docs/RUST.md §3.3): the bytes of
// messages, on disk, that the Swift and the Rust halves must both decode to
// the same fields and encode back to the same bytes, and the malformed
// frames both must refuse. Swift is the specification, so this test writes
// the corpus (ABYSS_WIRE_UPDATE=1) and checks it; de/currentipc/tests
// checks the Rust half against the same files.
//
// abyss/tests/wire/current/<case>.bin is a packed message body; <case>.txt
// what it decodes to, one field a line (names and strings in hex, so the
// format needs no escaping), after `fds N`, how many descriptors arrive
// with it; a `decode-only` line marks bytes `pack` would not produce (bad
// UTF-8, decoded leniently). <case>.err marks bytes both must refuse.

import XCTest
@testable import CurrentIPC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class WireFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/CurrentIPCTests/WireFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "current"])
        return p.joined(separator: "/")
    }()

    /// The corpus: name, message (fd fields hold indices into the arriving
    /// descriptors), how many arrive.
    static func valid() -> [(String, Msg, Int)] {
        var cases: [(String, Msg, Int)] = []
        cases.append(("empty", Msg(), 0))

        var every = Msg()
        every.set("method", "Frame.Present")
        every.set("seq", UInt64(42))
        every.set("damage", true)
        every.set("rect", bytes: [0, 1, 2, 0x7f, 0x80, 0xff])
        every.set("buffer", fd: 0)
        cases.append(("every-kind", every, 1))

        var uni = Msg()
        uni.set("naïve-ключ", "日本語 ✓ 🌊 Ünïcödé")
        cases.append(("unicode", uni, 0))

        var empties = Msg()
        empties.set("", "")
        empties.set("e", bytes: [])
        cases.append(("empty-values", empties, 0))

        var ext = Msg()
        ext.set("max", UInt64.max)
        ext.set("zero", UInt64(0))
        ext.set("high-bit", UInt64(1) << 63)
        ext.set("no", false)
        cases.append(("extremes", ext, 0))

        var repl = Msg()
        repl.set("a", UInt64(1))
        repl.set("b", "two")
        repl.set("a", "three")                 // replaced in place, keeps its slot
        cases.append(("replace-in-place", repl, 0))

        var two = Msg()
        two.set("first", fd: 0)
        two.set("between", "x")
        two.set("second", fd: 1)
        cases.append(("two-fds", two, 2))

        var quit = Msg()
        quit.set("method", "Session.Quit")
        quit.set("reason", "user asked")
        cases.append(("session-quit", quit, 0))

        var long = Msg()
        long.set("text", String(repeating: "abcdefghij", count: 7000))   // 70 KB, a u32 length
        long.set("blob", bytes: (0..<300).map { UInt8($0 & 0xff) })
        cases.append(("long-values", long, 0))
        return cases
    }

    /// Bytes `pack` does not make, decoded the lenient way.
    static func decodeOnly() -> [(String, [UInt8], Int)] {
        // One field, name "k\xff\xfe" (invalid UTF-8), string value "v\xc3".
        let bad: [UInt8] = Array("ABYM".utf8) + [1, 0, 1, 0, 3, 0x6b, 0xff, 0xfe, 1, 0, 0, 0, 2, 0x76, 0xc3]
        // A duplicate name on the wire: the second replaces the first in place.
        let dup: [UInt8] = Array("ABYM".utf8) + [1, 0, 2,
            0, 1, 0x61, 2, 0, 0, 0, 0, 0, 0, 0, 1,
            0, 1, 0x61, 3, 1]
        return [("lenient-utf8", bad, 0), ("duplicate-name", dup, 0)]
    }

    /// Bytes both halves must refuse.
    static func malformed() -> [(String, [UInt8], Int)] {
        let head = Array("ABYM".utf8) + [1]
        return [
            ("bad-magic", Array("ABYX".utf8) + [1, 0, 0], 0),
            ("bad-version", Array("ABYM".utf8) + [2, 0, 0], 0),
            ("short-header", Array("ABY".utf8), 0),
            ("missing-field", head + [0, 1], 0),
            ("unknown-kind", head + [0, 1, 0, 1, 0x6b, 9], 0),
            ("fd-index-past-arrivals", head + [0, 1, 0, 1, 0x66, 5, 0], 0),
            ("fd-index-past-two", head + [0, 1, 0, 1, 0x66, 5, 2], 2),
            ("string-past-end", head + [0, 1, 0, 1, 0x73, 1, 0, 0, 0, 9, 0x61], 0),
            ("name-past-end", head + [0, 1, 0, 200, 0x61], 0),
            ("uint64-short", head + [0, 1, 0, 1, 0x6e, 2, 0, 0, 0], 0),
        ]
    }

    // MARK: the text form

    static func hex(_ b: [UInt8]) -> String {
        b.isEmpty ? "-" : b.map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
    }

    /// `fds` are the descriptors the message was unpacked with: an fd
    /// field's value is written as its index among them.
    static func dump(_ m: Msg, fds: [Int32], decodeOnly: Bool) -> String {
        var out = ""
        if decodeOnly { out += "decode-only\n" }
        out += "fds \(fds.count)\n"
        for (name, value) in m.fields {
            let n = hex(Array(name.utf8))
            switch value {
            case .string(let s):
                out += "# string \(name.debugDescription) = \(s.count > 60 ? String(s.prefix(60)) + "…" : s)\n"
                out += "string \(n) \(hex(Array(s.utf8)))\n"
            case .uint64(let v): out += "uint64 \(n) \(v)\n"
            case .bool(let b): out += "bool \(n) \(b ? 1 : 0)\n"
            case .bytes(let b): out += "bytes \(n) \(hex(b))\n"
            case .fd(let f): out += "fd \(n) \(fds.firstIndex(of: f) ?? -1)\n"
            }
        }
        return out
    }

    func openFDs(_ n: Int) -> [Int32] {
        (0..<n).map { _ in open("/dev/null", O_RDONLY) }
    }

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
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/current".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for (name, msg, n) in Self.valid() {
                let fds = openFDs(n)
                defer { fds.forEach { close($0) } }
                // The case's fd fields hold indices; give them the real ones.
                var m = Msg()
                for (k, v) in msg.fields {
                    if case .fd(let i) = v { m.set(k, fd: fds[Int(i)]) } else { m.set(k, v) }
                }
                try write("\(dir)/\(name).bin", m.pack())
                try write("\(dir)/\(name).txt", Array(Self.dump(m, fds: fds, decodeOnly: false).utf8))
            }
            for (name, bytes, n) in Self.decodeOnly() {
                let fds = openFDs(n)
                defer { fds.forEach { close($0) } }
                let m = try Msg.unpack(bytes, fds: fds)
                try write("\(dir)/\(name).bin", bytes)
                try write("\(dir)/\(name).txt", Array(Self.dump(m, fds: fds, decodeOnly: true).utf8))
            }
            for (name, bytes, n) in Self.malformed() {
                try write("\(dir)/\(name).bin", bytes)
                try write("\(dir)/\(name).err", Array("malformed\nfds \(n)\n".utf8))
            }
        }

        // Check every case on disk, whoever wrote it.
        var checked = 0
        for (name, _, _) in Self.valid() + Self.decodeOnly().map({ ($0.0, Msg(), 0) }) {
            guard let bin = read("\(dir)/\(name).bin"),
                  let txt = read("\(dir)/\(name).txt").map({ String(decoding: $0, as: UTF8.self) }) else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            let lines = txt.split(separator: "\n").map(String.init)
            let n = Int(lines.first(where: { $0.hasPrefix("fds ") })?.dropFirst(4) ?? "0") ?? 0
            let fds = openFDs(n)
            defer { fds.forEach { close($0) } }
            let m = try Msg.unpack(bin, fds: fds)
            XCTAssertEqual(Self.dump(m, fds: fds, decodeOnly: lines.contains("decode-only")), txt,
                           "\(name): decoding the bytes")
            if !lines.contains("decode-only") {
                XCTAssertEqual(m.pack(), bin, "\(name): encoding the fields")
            }
            checked += 1
        }
        for (name, _, _) in Self.malformed() {
            guard let bin = read("\(dir)/\(name).bin"),
                  let err = read("\(dir)/\(name).err").map({ String(decoding: $0, as: UTF8.self) }) else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            let n = Int(err.split(separator: "\n").first(where: { $0.hasPrefix("fds ") })?.dropFirst(4) ?? "0") ?? 0
            let fds = openFDs(n)
            defer { fds.forEach { close($0) } }
            XCTAssertThrowsError(try Msg.unpack(bin, fds: fds), "\(name): accepted") { e in
                guard case CurrentError.malformed = e else { return XCTFail("\(name): \(e), not malformed") }
            }
            checked += 1
        }
        XCTAssertEqual(checked, Self.valid().count + Self.decodeOnly().count + Self.malformed().count)
    }
}
