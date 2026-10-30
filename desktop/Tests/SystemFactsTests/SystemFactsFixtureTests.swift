// SystemFacts' cross-language fixtures (docs/RUST.md §3.3). Swift is the
// specification: this test writes the corpus (ABYSS_WIRE_UPDATE=1) and checks
// it; de/systemfacts/tests checks the Rust half against the same files.
//
// abyss/tests/wire/facts/<case>.in is what a command said (pciconf -lv,
// kldstat, ofwdump, swapinfo) or, for the formatters, numbers one line each;
// <case>.txt's first line is the operation, then its answer.

import XCTest
@testable import SystemFacts

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class SystemFactsFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/SystemFactsTests/SystemFactsFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "facts"])
        return p.joined(separator: "/")
    }()

    static let amd = """
    vgapci0@pci0:3:0:0:\tclass=0x030000 rev=0xc1 hdr=0x00 vendor=0x1002 device=0x73df subvendor=0x1849 subdevice=0x5219
        vendor     = 'Advanced Micro Devices, Inc. [AMD/ATI]'
        device     = 'Navi 22 [Radeon RX 6700/6700 XT/6750 XT / 6800M/6850M XT]'
        class      = display
        subclass   = VGA
    hdac0@pci0:3:0:1:\tclass=0x040300 rev=0x00 hdr=0x00 vendor=0x1002 device=0xab28 subvendor=0x1849 subdevice=0xab28
        vendor     = 'Advanced Micro Devices, Inc. [AMD/ATI]'
        device     = 'Navi 21/23 HDMI/DP Audio Controller'
        class      = multimedia
        subclass   = HDA

    """

    /// (name, op, input).
    static func cases() -> [(String, String, String)] {
        [
            ("pci-vm", "pci", """
            vgapci0@pci0:0:1:0:\tclass=0x030000 rev=0x02 hdr=0x00 vendor=0x1234 device=0x1111 subvendor=0x1af4 subdevice=0x1100
                class      = display
                subclass   = VGA
            virtio_pci0@pci0:0:2:0:\tclass=0x020000 rev=0x00 hdr=0x00 vendor=0x1af4 device=0x1000 subvendor=0x1af4 subdevice=0x0001
                vendor     = 'Red Hat, Inc.'
                device     = 'Virtio network device'
                class      = network
            """),
            ("pci-amd", "pci", amd),
            ("pci-two", "pci", amd + """
            vgapci1@pci0:0:2:0:\tclass=0x030000 rev=0x0c hdr=0x00 vendor=0x8086 device=0x4680
                vendor     = 'Intel Corporation'
                device     = 'AlderLake-S GT1 [UHD Graphics 770]'
                class      = display
            none0@pci0:9:0:0:\tclass=0x030200 rev=0xa1 hdr=0x00 vendor=0x10de device=0x2484
                vendor     = 'NVIDIA Corporation'
                device     = 'GA104 [GeForce RTX 3070]'
                class      = display
                subclass   = 3D
            vgapci2@pci0:0:3:0:\tclass=0x030000 rev=0x00 hdr=0x00 vendor=0x1af4 device=0x1050
                vendor     = 'Red Hat, Inc.'
                device     = 'Virtio 1.0 GPU'
                class      = display
            vgapci3@pci0:0:4:0:\tclass=0x030000
                vendor     = '  Matrox  Electronics'
                device     = 'G200eR2'
            vgapci4@pci0:0:5:0:\tclass=0x030000 vendor=0x102b
                vendor     = 'nobody'
            """),
            ("pci-quotes", "pci", "vgapci0@pci0:0:1:0:\tvendor=0x1 device=0x2\n    vendor = 'A 'odd' one'\n    device = 'x'\n    device = 'only one\n"),
            ("pci-empty", "pci", ""),
            ("pci-crlf", "pci", amd.replacingOccurrences(of: "\n", with: "\r\n")),
            ("drm-msm", "drm", " 1   80 0xffff000000000000  2b4e9a8 kernel\n 7    1 0xffff0000ab000000   400000 msm.ko\n"),
            ("drm-amd", "drm", " 1 1 0 0 kernel\n 9 1 0 0 amdgpu.ko\n10 1 0 0 drm.ko\n"),
            ("drm-two", "drm", " 9 1 0 0 i915kms.ko\n10 1 0 0 msm.ko\n"),
            ("drm-none", "drm", " 1 80 0x0 1 kernel\n 2 1 0 0 zfs.ko\n"),
            ("ofw-q8b", "ofw", "Node 0x38:\n  model:\n    'Radxa Dragon Q8B'\n"),
            ("ofw-empty-first", "ofw", "Node 0x38:\n  model:\n    ''\n    'Second'\n"),
            ("ofw-none", "ofw", ""),
            ("swap-one", "swap", "Device          1K-blocks     Used    Avail Capacity\n/dev/gpt/swapfs   1048576        0  1048576     0%\n"),
            ("swap-total", "swap", """
            Device          1K-blocks     Used    Avail Capacity
            /dev/ada0p3       2097152   524288  1572864    25%
            /dev/ada1p3       2097152        0  2097152     0%
            Total             4194304   524288  3670016    13%
            """),
            ("swap-two-no-total", "swap", "Device 1K-blocks Used Avail Capacity\n/dev/a 1 0 1 0%\n/dev/b 2 0 2 0%\n"),
            ("swap-none", "swap", "Device          1K-blocks     Used    Avail Capacity\n"),
            ("swap-garbage", "swap", "/dev/a lots 0 1 0%\n"),
            ("swap-short", "swap", "/dev/a 1\n"),
            ("swap-tabs", "swap", "/dev/a\t\t2048\t1024\t1024\t50%\n"),
            ("bytes", "bytes", "0\n1\n1023\n1024\n1536\n1048575\n1048576\n16706928640\n1099511627776\n1125899906842624\n18446744073709551615\n"),
            ("usage", "usage", "0 0\n1073741824 4294967296\n1 3\n2 3\n5 0\n9 4\n18446744073709551615 18446744073709551615\n"),
            ("uptime", "uptime", "-5\n0\n59\n60\n61\n3600\n3661\n86399\n86400\n90360\n184860\n9223372036854775807\n"),
            ("frequency", "frequency", "0\n800\n999\n1000\n1005\n1004\n2710\n3999\n-5\n"),
            ("memory", "memory", "4096 4080261 2282077 364488 23\n4096 10 20 0 0\n16384 1000 1 1 1\n4096 10 10 0 0\n"),
            ("sample", "sample", ""),
        ]
    }

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

    static func run(_ op: String, _ input: String) -> String {
        var out = op + "\n"
        let lines = input.split(separator: "\n").map(String.init)
        func nums(_ l: String) -> [String] { l.split(separator: " ").map(String.init) }
        switch op {
        case "pci": for d in FactParse.pciDisplays(input) { out += "display \(q(d))\n" }
        case "drm": out += "driver " + (FactParse.drmDriver(kldstat: input).map(q) ?? "none") + "\n"
        case "ofw": out += "model " + (FactParse.ofwModel(input).map(q) ?? "none") + "\n"
        case "swap": out += FactParse.swap(swapinfo: input).map { "swap \($0.used) \($0.total)\n" } ?? "swap none\n"
        case "bytes": for l in lines { out += "bytes \(l) \(q(FactFormat.bytes(UInt64(l)!)))\n" }
        case "usage":
            for l in lines {
                let n = nums(l)
                out += "usage \(l) \(q(FactFormat.usage(used: UInt64(n[0])!, total: UInt64(n[1])!)))\n"
            }
        case "uptime": for l in lines { out += "uptime \(l) \(q(FactFormat.uptime(seconds: Int64(l)!)))\n" }
        case "frequency": for l in lines { out += "frequency \(l) \(q(FactFormat.frequency(mhz: Int64(l)!)))\n" }
        case "memory":
            for l in lines {
                let n = nums(l).map { UInt64($0)! }
                out += "memory \(l) \(FactParse.memoryUsed(pageSize: n[0], pages: n[1], free: n[2], inactive: n[3], laundry: n[4]))\n"
            }
        case "sample": out += SystemFacts.sample.text
        default: out += "no operation\n"
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

    func testTheFixturesAreWhatSwiftReads() {
        let dir = Self.dir
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/facts".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for (name, op, input) in Self.cases() {
                write("\(dir)/\(name).in", input)
                write("\(dir)/\(name).txt", Self.run(op, input))
            }
        }
        for (name, _, _) in Self.cases() {
            guard let input = read("\(dir)/\(name).in"), let txt = read("\(dir)/\(name).txt") else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            XCTAssertEqual(Self.run(String(txt.prefix { $0 != "\n" }), input), txt, name)
        }
    }
}
