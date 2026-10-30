// Jails' cross-language fixtures (docs/RUST.md §3.3). Swift is the
// specification: this test writes the corpus (ABYSS_WIRE_UPDATE=1) and checks
// it; de/jails/tests checks the Rust half against the same files.
//
// abyss/tests/wire/jails/<case>.in is a jails.ini; <case>.txt's first line is
//
//   classes <user> <uid> <gid> <host home> <pool>|none
//
// then, for every class the file makes, the class, the plan for that person
// in it, and every violation the plan has: so a Swift jaild and a Rust one
// build the same jail from the same row, and refuse the same jails.

import XCTest
@testable import Jails
import PoolConfig

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class JailsFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/JailsTests/JailsFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "jails"])
        return p.joined(separator: "/")
    }()

    /// (name, op line, jails.ini).
    static func cases() -> [(String, String, String)] {
        [
            ("shipped", "classes abyss 1001 1001 /home/abyss none", ""),
            ("shipped-zfs-ufs-home", "classes jo 1002 20 /usr/home/jo zroot", ""),
            ("overrides", "classes abyss 1001 1001 /home/abyss tank", """
            [app]
            devices = dsp
            [editor]
            network = HOST
            wayland = no
            [agent]
            model = local:/m/granite.gguf
            budget = 5000
            [helper]
            agent = yes
            wayland = maybe
            budget = nonsense
            vocabulary = yes
            fetch = true
            [apps]
            galculator = app
            [app-net]
            network = everything
            devices = dri,dsp	dri
            """),
            ("budgets", "classes abyss 1001 1001 /home/abyss none", """
            [plus]
            budget = +5
            [minus]
            budget = -3
            [zero]
            budget = 0
            [big]
            budget = 9223372036854775807
            """),
            ("bad-classes", "classes abyss 1001 1001 /home/abyss none", """
            [odd-device]
            devices = dri mem
            [root]
            system = /
            [etc]
            system = /bin, /etc
            [var]
            system = /bin /var/db /root/tools
            [jails]
            system = /var/run/abyss-jails/1002/app
            [home]
            system = /usr /home/abyss/Documents
            [homes]
            system = /home
            [slash]
            system = /usr/local/ /lib
            [empty]
            system =
            devices =
            """),
            ("combining-home", "classes abyss 1001 1001 /home/abyss none", """
            [sneaky]
            system = /bin /home/abyss/\u{301}docs
            """),
            ("uid-zero", "classes toor 0 0 /root none", "[app]\n"),
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

    static func b(_ v: Bool) -> String { v ? "1" : "0" }
    static func list(_ l: [String]) -> String { "[" + l.map(q).joined(separator: ",") + "]" }

    static func text(_ c: JailClass) -> String {
        "class \(q(c.name)) system=\(list(c.system)) devices=\(list(c.devices)) network=\(c.network.rawValue)"
            + " wayland=\(b(c.wayland)) agent=\(b(c.agent)) budget=\(c.budget) model=\(q(c.model))"
            + " vocabulary=\(b(c.vocabulary)) fetch=\(b(c.fetch))\n"
    }

    static func text(_ p: JailPlan) -> String {
        var out = "plan \(q(p.name)) root=\(q(p.root))\n"
        for m in p.mounts { out += "mount \(m.kind.rawValue) \(q(m.source)) \(q(m.target)) \(m.readOnly ? "ro" : "rw")\n" }
        out += "unhide \(list(p.unhide))\n"
        for d in p.dirs { out += "dir \(q(d.path)) \(d.uid) \(String(d.mode, radix: 8))\n" }
        out += "accounts \(q(p.accounts))\n"
        for f in p.files { out += "file \(q(f.path)) \(q(f.contents))\n" }
        for c in p.copies { out += "copy \(q(c.source)) \(q(c.target))\n" }
        for (k, v) in p.params { out += "param \(q(k))" + (v.map { " " + q($0) } ?? "") + "\n" }
        for (k, v) in p.env { out += "env \(q(k)) \(q(v))\n" }
        out += "home \(q(p.homeSource)) dataset=\(p.homeDataset.map(q) ?? "none")\n"
        return out
    }

    static func run(_ op: String, _ ini: String) -> String {
        let w = op.split(separator: " ").map(String.init)
        let user = JailUser(name: w[1], uid: UInt32(w[2])!, gid: UInt32(w[3])!)
        let pool: String? = w[5] == "none" ? nil : w[5]
        var out = op + "\n"
        for c in JailClass.table(Config.parse(ini)) {
            let p = JailPlan.make(c, for: user, pool: pool)
            out += text(c) + text(p)
            for v in p.violations(for: c, hostHome: w[4]) { out += "violation \(q(v))\n" }
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

    func testTheFixturesAreWhatSwiftMakes() {
        let dir = Self.dir
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/jails".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for (name, op, ini) in Self.cases() {
                write("\(dir)/\(name).in", ini)
                write("\(dir)/\(name).txt", Self.run(op, ini))
            }
        }
        for (name, _, _) in Self.cases() {
            guard let ini = read("\(dir)/\(name).in"), let txt = read("\(dir)/\(name).txt") else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            XCTAssertEqual(Self.run(String(txt.prefix { $0 != "\n" }), ini), txt, name)
        }
    }
}
