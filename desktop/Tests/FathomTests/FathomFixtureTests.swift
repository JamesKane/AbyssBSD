// Fathom's cross-language fixtures (docs/RUST.md §3.3). Swift is the
// specification: this test writes the corpus (ABYSS_WIRE_UPDATE=1) and checks
// it; de/fathom/tests checks the Rust half against the same files.
//
// abyss/tests/wire/fathom/<case>.in is captured text a probe reads (kldstat,
// sndstat, undertow's output, ...); <case>.txt's first line is the probe,
// then what it found: `<status> "<detail>"`, a filename, or a rendered report.

import XCTest
@testable import Fathom

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class FathomFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/FathomTests/FathomFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "fathom"])
        return p.joined(separator: "/")
    }()

    static let kldstat = """
    Id Refs Address                Size Name
     1   25 0xffffffff80200000  1f4dcd8 kernel
     2    1 0xffffffff8214e000   620f30 zfs.ko
     3    1 0xffffffff83018000     4250 ichsmb.ko
     4    1 0xffffffff8301d000     2178 smbus.ko

    """

    static let metal = """
    WAYLAND_DISPLAY=wayland-0
    usable=0,0,2560x1440
    wake-late-p99-us=715
    composite-p99-us=9
    margin-us=8000
    missed=45 of 300
    period-us=16666
    vblank-source=hardware
    backend=drm
    verdict ok

    """

    static let margins = """
    missed=58 of 300
    composite-p99-us=12
    period-us=16680
    margin-wake-us=300
    margin-cost-us=12
    margin-commit-us=7000
    margin-vblank-us=nope
    margin-safety-us=400
    margin-pinned=yes
    backend=drm
    vblank-source=hardware
    """

    /// (name, op line, input).
    static func texts() -> [(String, String, String)] {
        [
            ("boot-uefi", "boot", "UEFI\n"),
            ("boot-bios", "boot", "BIOS"),
            ("boot-lower", "boot", " uefi "),
            ("boot-odd", "boot", "something else"),
            ("boot-arm64", "boot \"aarch64\"", ""),
            ("boot-amd64-none", "boot \"amd64\"", ""),
            ("gpu-none", "gpu", ""),
            ("gpu-render-only", "gpu", "renderD128\n"),
            ("gpu-cards", "gpu", "renderD129\ncard1\ncard0\nrenderD128\nby-path\n"),
            ("modules-none", "modules", kldstat),
            ("modules-amdgpu", "modules", kldstat + " 7    1 0xffffffff83400000   b2f000 amdgpu.ko\n 8    3 0xffffffff83100000    5a000 drm.ko\n"),
            ("modules-msm", "modules", " 7    1 0xffff0000ab000000   400000 msm.ko\n 8    2 0xffff0000ac000000   100000 drm.ko"),
            ("modules-blank", "modules", "  \n\t"),
            ("modules-crlf", "modules", (kldstat + " 8    3 0xffffffff83100000    5a000 drm.ko\n").replacingOccurrences(of: "\n", with: "\r\n")),
            ("network-real", "network", "igc0 lo0 em0 lo1\n"),
            ("network-loopback", "network", "lo0"),
            ("network-empty", "network", ""),
            ("wifi-empty", "wifi", ""),
            ("wifi-spaces", "wifi", "   "),
            ("wifi-two", "wifi", "wlan0  wlan1\n"),
            ("audio-none", "audio", "No devices installed.\nNo devices installed from userspace.\n"),
            ("audio-two", "audio", "Installed devices:\npcm0: <Realtek ALC1220 (Rear Analog)> (play/rec) default\n  pcm1: <Realtek ALC1220 (Front Analog)> (play/rec)\nDefault audio device: pcm0\n"),
            ("audio-no-colon", "audio", "pcm7 with no colon\n"),
            ("frame-metal", "frame", metal),
            ("frame-margins", "frame", margins),
            ("frame-tie", "frame", "missed=1 of 300\nmargin-cost-us=5\nmargin-wake-us=5\nmargin-commit-us=5\n"),
            ("frame-zero-margins", "frame", "missed=1 of 300\nmargin-cost-us=0\nmargin-wake-us=-3\n"),
            ("frame-nested", "frame", "missed=45 of 300\nbackend=nested-wayland\nvblank-source=hardware"),
            ("frame-x11", "frame", "missed=45 of 300\nbackend=nested-x11"),
            ("frame-headless", "frame", "missed=0 of 300\nbackend=headless\nvblank-source=nominal"),
            ("frame-drm-nominal", "frame", "missed=3 of 300\nbackend=drm\nvblank-source=nominal"),
            ("frame-old", "frame", "missed=0 of 300\ncomposite-p99-us=9"),
            ("frame-half", "frame", "missed=0 of 300\nvblank-source=hardware"),
            ("frame-no-frames", "frame", "missed=0 of 0\nvblank-source=hardware"),
            ("frame-negative-total", "frame", "missed=0 of -3"),
            ("frame-signed", "frame", "missed=+5 of 300\nbackend=drm\nvblank-source=hardware"),
            ("frame-negative-missed", "frame", "missed=-5 of 300"),
            ("frame-unreadable", "frame", "missed=lots of frames"),
            ("frame-two-words", "frame", "missed=4 of"),
            ("frame-no-count", "frame", "nothing useful here"),
            ("frame-empty", "frame", ""),
            ("frame-odd-lines", "frame", "=x\nmissed=\nmissed=45  of   300 frames\n backend = drm=x \nbackend=drm\nbackend=headless\n"),
            ("machine-full", "machine", "Apple Inc.\nMacPro6,1"),
            ("machine-padded", "machine", "  Micro-Star \n MS-7D25\t"),
            ("machine-no-product", "machine", "Apple Inc.\n"),
            ("machine-no-maker", "machine", "\nMacPro6,1"),
            ("machine-none", "machine", "\n"),
            ("filename-macpro", "filename", "Apple Inc.\nMacPro6,1"),
            ("filename-msi", "filename", "Micro-Star International Co., Ltd.\nMS-7D25"),
            ("filename-unicode", "filename", "Wéird Ünïcode\nMa/chine\\Name"),
            ("filename-long", "filename", "A\n" + String(repeating: "x", count: 200)),
            ("filename-blank", "filename", "   \n  "),
            ("filename-dashes", "filename", "--Big  -- Corp--\n(rev 2)"),
            ("cpu", "cpu 8", "AMD Ryzen 7 9700X 8-Core Processor   "),
            ("cpu-no-cores", "cpu 0", "ARM Cortex-A78"),
            ("cpu-none", "cpu 4", "  "),
            ("memory", "memory", "17135251456"),
            ("memory-small", "memory", "1"),
            ("memory-none", "memory", "0"),
            ("disks", "disks", "nvd0\t1000204886016\tSamsung SSD 980\nada0\t240057409536\t\n"),
            ("disks-none", "disks", ""),
            ("render-mixed", "render", "GPU\tpresent\tcard0 (+ renderD128)\nWi-Fi\tabsent\tno card \u{2014} \u{201C}none\u{201D}\u{2026}\nFrame contract\tunknown\tundertow did not report\n"),
            ("render-complete", "render", "GPU\tabsent\tnone\nNetwork\tpresent\tigc0\n"),
            ("render-folding", "render", "Audio\tpresent\tCaf\u{e9} \u{2018}x\u{2019} \u{2013} \u{2603}\n"),
            ("render-decomposed", "render", "Audio\tpresent\tCafe\u{301}!\n"),
            ("render-empty", "render", ""),
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

    static func text(_ r: ProbeResult) -> String { "\(r.status.rawValue) \(q(r.detail))\n" }

    /// The two lines of a maker-and-product input.
    static func pair(_ input: String) -> (String, String) {
        let l = input.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (l[0], l.count > 1 ? l[1] : "")
    }

    /// `op` applied to `input`.
    static func run(_ op: String, _ input: String) -> String {
        let out = op + "\n"
        let word = String(op.prefix { $0 != " " })
        let arg = op.count > word.count ? String(op.dropFirst(word.count + 1)) : nil
        let lines = input.split(separator: "\n").map(String.init)
        switch word {
        case "boot":
            return out + text(probeBootMethod(input, arch: arg.map { String($0.dropFirst().dropLast()) }))
        case "gpu": return out + text(probeGPU(driEntries: lines))
        case "modules": return out + text(probeModules(kldstat: input))
        case "network": return out + text(probeNetwork(interfaceList: input))
        case "wifi": return out + text(probeWifi(wlanDevices: input))
        case "audio": return out + text(probeAudio(sndstat: input))
        case "frame": return out + text(probeFrameContract(runOutput: input))
        case "machine":
            let (mk, pr) = pair(input)
            return out + text(probeMachine(maker: mk, product: pr))
        case "filename":
            let (mk, pr) = pair(input)
            return out + "file \(q(reportFilename(maker: mk, product: pr)))\n"
        case "cpu": return out + text(probeCPU(model: input, cores: arg.flatMap { Int64($0) }))
        case "memory": return out + text(probeMemory(physBytes: Int64(input)))
        case "disks":
            let facts = lines.map { l -> DiskFact in
                let f = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return DiskFact(name: f[0], bytes: UInt64(f[1])!, model: f.count > 2 ? f[2] : "")
            }
            return out + text(probeDisks(facts))
        case "render":
            let results = lines.map { l -> ProbeResult in
                let f = l.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                return ProbeResult(f[0], ProbeStatus(rawValue: f[1])!, f[2])
            }
            return out + renderText(FathomReport(results))
        default:
            return out + "no operation\n"
        }
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
        let texts = Self.texts()
        XCTAssertEqual(Set(texts.map(\.0)).count, texts.count, "case names are unique")
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/fathom".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for (name, op, input) in texts {
                write("\(dir)/\(name).in", input)
                write("\(dir)/\(name).txt", Self.run(op, input))
            }
        }
        for (name, _, _) in texts {
            guard let input = read("\(dir)/\(name).in"), let txt = read("\(dir)/\(name).txt") else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            XCTAssertEqual(Self.run(String(txt.prefix { $0 != "\n" }), input), txt, name)
        }
    }
}
