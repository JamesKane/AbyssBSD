// Vents' cross-language fixtures (docs/RUST.md §3.3). Swift is the
// specification: this test writes the corpus (ABYSS_WIRE_UPDATE=1) and checks
// it; de/vents/tests checks the Rust half against the same files.
//
// abyss/tests/wire/vents/<case>.in is what the machine said (devd lines,
// cvents' sndstat and mixer lines, route(8), /proc/net/route, resolv.conf,
// ifconfig, a sysctl's bytes in hex); <case>.txt's first line is the parser,
// then what it read.

import XCTest
@testable import Vents

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class VentsFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/VentsTests/VentsFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "vents"])
        return p.joined(separator: "/")
    }()

    /// (name, op, input).
    static func cases() -> [(String, String, String)] {
        [
            ("devd-real", "devd", """
            !system=DEVFS subsystem=CDEV type=CREATE cdev=md0
            !system=GEOM subsystem=DEV type=CREATE cdev=md0
            !system=DEVFS subsystem=CDEV type=DESTROY cdev=md0
            +ugen0.2 at port=2 ... on uhub0
            -ugen0.2 at port=2 on uhub0
            ? at bus=0 on pci0
            !system=CAM subsystem=periph type=error device=cd0 serial="QM00005" cam_status="0x4cc" scsi_status=2 scsi_sense="70 02 3a 00" CDB="00 00 00 00 00 00 "
            !system=IFNET subsystem=vtnet0 type=LINK_UP
            something devd never sends
            """),
            ("devd-odd", "devd", "!\n!key\n!=value\n!a=b=c d=\"\" e=\"unterminated\n!  spaced   out=1\t\ttab=2\n+\n-\t\tdev0 x\n+md0 at\r\n"),
            ("sndstat", "sndstat", """
            dev\t0\tpcm0\tDummy Audio Device\tdsp0\t1\t1\t0
            chan\t0\tdsp0.play.0\t-1\t<UNUSED>\t45\t45
            chan\t0\tdsp0.virtual_play.0\t31118\tplayer\t30\t30
            chan\t0\tdsp0.virtual_play.1\t31119\tmpv\t80\t75
            chan\t0\tdsp0.record.0\t-1\t<UNUSED>\t45\t45
            chan\t0\tdsp0.virtual_record.0\t4242\tobs\t50\t50
            dev\t1\tpcm1\tUSB Headset\tdsp1\t1\t0\t0
            chan\t9\tdsp9.play.0\t7\tlost\t1\t1
            dev\t-1\tvdsp\tVirtual OSS\tvdsp\t1\t1\t1
            dev\tx\tpcmx\tNo unit\tdspx\t1\t1\t0
            chan\t1\tdsp1.play.0\tnot-a-pid\tcmd\tloud\t9
            dev\t2\tpcm2\tShort
            """),
            ("controls", "controls", "ctl\tvol\t75\t70\t0\t0\nctl\tpcm\t40\t40\t1\t0\nctl\trec\t75\t75\t0\t1\ngarbage\nctl\tbad\tx\t1\t0\t0\nctl\tshort\t1\t1\t0\n"),
            ("route-get", "route", """
               route to: default
            destination: default
                   mask: default
                gateway: 10.0.2.2
                    fib: 0
              interface: vtnet0
                  flags: <UP,GATEWAY,DONE,STATIC>
            """),
            ("route-none", "route", "route: route has not been found\n"),
            ("route-tabs", "route", "gateway:\t192.168.1.1 \ninterface:\tem0\t\n"),
            ("proc-route", "procroute", """
            Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask
            enp77s0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF
            enp77s0\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000
            """),
            ("proc-route-none", "procroute", "Iface\tDestination\tGateway\nlo\t00000000\t00000000\t0001\n"),
            ("resolv", "resolv", "# generated\nsearch example.org\nnameserver 10.0.2.3\nnameserver\t9.9.9.9\noptions edns0\n  nameserver   ::1  \nnameserver\n"),
            ("ifconfig-wlan", "ifconfig", """
            wlan0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
            \tether 00:11:22:33:44:55
            \tinet 192.168.1.40 netmask 0xffffff00 broadcast 192.168.1.255
            \tssid "Café Wi-Fi" channel 6 (2437 MHz 11g) bssid 00:11:22:33:44:55
            \tregdomain FCC country US authmode WPA2/802.11i privacy ON
            \tstatus: associated
            """),
            ("ifconfig-plain", "ifconfig", "wlan1: flags=8802<BROADCAST,SIMPLEX,MULTICAST>\n\tssid lab channel 1 (2412 MHz 11g)\n\tstatus: no carrier\n"),
            ("ifconfig-empty-ssid", "ifconfig", "\tssid \"\" channel x bssid\n\tstatus:\n"),
            ("sysctl-bytes", "display", """
            46726565425344000
            08000000
            0800000000000000
            010203
            61207661 6c756520 0a00
            09610a62
            00
            ff00
            74657874
            """.replacingOccurrences(of: " ", with: "")),
            ("volume", "volume", "0\n10\n2570\n16737380\n-1\n25700\n100\n"),
            ("activity-formats", "formats", "0\n1023\n524288\n13107200\n1288490189\n1073741824\n"),
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

    static func b(_ v: Bool) -> String { v ? "1" : "0" }

    /// The bytes a sysctl's hex spells.
    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = [], h = Array(hex.utf8)[...]
        while h.count >= 2 { out.append(UInt8(String(decoding: h.prefix(2), as: UTF8.self), radix: 16)!); h = h.dropFirst(2) }
        return out
    }

    static func run(_ op: String, _ input: String) -> String {
        var out = op + "\n"
        let lines = input.split(separator: "\n").map(String.init)
        switch op {
        case "devd":
            for l in input.split(separator: "\n", omittingEmptySubsequences: false) {
                let e = Vents.Event(String(l))
                out += "event \(e.kind) \(q(e.raw)) device=\(e.device.map(q) ?? "none") summary=\(q(e.summary))"
                    + e.fields.map { " \(q($0.key))=\(q($0.value))" }.joined() + "\n"
            }
        case "sndstat":
            for d in Vents.Sound.parseSndstat(input) {
                out += "device \(d.unit) \(q(d.name)) \(q(d.description)) \(q(d.devnode)) play=\(b(d.playback)) rec=\(b(d.recording)) user=\(b(d.fromUser))\n"
                for c in d.channels {
                    out += "  channel \(q(c.name)) pid=\(c.pid.map(String.init) ?? "none") \(q(c.command)) \(c.left):\(c.right) playback=\(b(c.isPlayback))\n"
                }
                out += "  playing" + d.playing.map { " \($0.pid!)" }.joined() + "\n"
            }
        case "controls":
            for c in Vents.Sound.parseControls(input) {
                out += "control \(q(c.name)) \(c.left):\(c.right) level=\(c.level) muted=\(b(c.muted)) rec=\(b(c.recordable))\n"
            }
        case "route":
            out += Vents.Network.parseRouteGet(input).map { "router \(q($0.address)) \(q($0.interface))\n" } ?? "router none\n"
        case "procroute":
            out += Vents.Network.parseProcRoute(input).map { "router \(q($0.address)) \(q($0.interface))\n" } ?? "router none\n"
        case "resolv":
            out += "dns" + Vents.Network.parseResolvConf(input).map { " " + q($0) }.joined() + "\n"
        case "ifconfig":
            let s = Vents.Wifi.parseIfconfig(input, interface: "wlan0")
            out += "wifi exists=\(b(s.exists)) associated=\(b(s.associated)) ssid=\(s.ssid.map(q) ?? "none")"
                + " bssid=\(s.bssid.map(q) ?? "none") channel=\(s.channel.map(String.init) ?? "none")\n"
        case "display":
            for l in lines { out += "display \(l) \(q(Vents.Sysctl.displayBytes(bytes(l))))\n" }
        case "volume":
            for l in lines {
                let v = Vents.VolumeLevel(encoded: Int32(l)!)
                out += "volume \(l) \(v.left):\(v.right) encoded=\(v.encoded)\n"
            }
        case "formats":
            for l in lines { out += "bytes \(l) \(q(ProcessTable.formatBytes(UInt64(l)!)))\n" }
            for p in [0.0, 0.05, 0.15, 3.14159, 99.95, 100, 250.04] { out += "percent \(p) \(q(ProcessTable.formatPercent(p)))\n" }
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
            _ = mkdir(String(dir.dropLast("/vents".count)), 0o755)   // abyss/tests/wire
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
