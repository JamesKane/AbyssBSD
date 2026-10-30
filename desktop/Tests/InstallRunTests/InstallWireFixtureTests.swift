// InstallWire's cross-language fixtures (docs/RUST.md §3.3). Swift is the
// specification: this test writes the corpus (ABYSS_WIRE_UPDATE=1) and checks
// it; de/installwire/tests checks the Rust half against the same files.
//
// abyss/tests/wire/install/<case>.bin is a packed message, and <case>.txt
// names its decoder (check, inventory, event) and then what it read. `check`
// is a plan and the machine it is checked against, in one message: the plan,
// the inventory, every refusal and, when there are none, the step list as
// `render` prints it. So a Swift installer and a Rust `abyss-install` (or the
// other way about) agree on what is run at somebody's disk, not only on what
// the message says. A `decode-only` line marks bytes the encoder would not
// produce.
//
// <case>.in is rc.conf text or keymap names; <case>.txt's first line is the
// operation (keymap, xkb), then its result.

import XCTest
import CurrentIPC
@testable import Install
@testable import InstallWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class InstallWireFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/InstallRunTests/InstallWireFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "install"])
        return p.joined(separator: "/")
    }()

    struct Case {
        let name: String
        let decoder: String
        let bytes: [UInt8]
        var decodeOnly = false
    }

    // MARK: the corpus

    static let gib: UInt64 = 1 << 30
    static let mib: UInt64 = 1 << 20
    static let admin = Account(name: "jkane", fullName: "J Kane", passwordHash: "$6$fake", groups: ["wheel"])
    static let macPro = MachineIdentity(maker: "Apple Inc.", product: "MacPro6,1")
    static let ordinary = DiskInventory(disks: [Disk(name: "ada0", bytes: 64 * gib, description: "QEMU HARDDISK")])
    static let desktopSets = ["base.txz", "kernel.txz", InstallPlan.desktopSet]

    static func disk(_ d: Disk, imported: [String] = [], machine: MachineIdentity? = nil) -> DiskInventory {
        DiskInventory(disks: [d], importedPools: imported, machine: machine)
    }

    static func checks() -> [(String, InstallPlan, DiskInventory)] {
        let good = InstallPlan(disk: "ada0", accounts: [admin])
        let occupied = Disk(name: "ada0", bytes: 64 * gib, description: "QEMU HARDDISK",
                            partitionKinds: ["efi", "ntfs"], freeBytes: mib, hasPartitionTable: true)
        let roomy = Disk(name: "ada0", bytes: 512 * gib, description: "Samsung",
                         partitionKinds: ["efi", "ntfs"], freeBytes: 200 * gib, hasPartitionTable: true)
        let guest = Account(name: "guest", passwordHash: "$6$g")
        return [
            ("check-ordinary", good, ordinary),
            ("check-golden", InstallPlan(disk: "ada0", hostname: "jaguar", timezone: "America/Chicago",
                                         keymap: "us.kbd", rootPasswordHash: "$6$root",
                                         accounts: [Account(name: "jkane", fullName: "J Kane", passwordHash: "$6$user",
                                                            groups: ["wheel", "operator"])],
                                         eraseExistingData: true),
             disk(occupied, machine: macPro)),
            ("check-free-space", good, disk(roomy, machine: MachineIdentity(maker: "Micro-Star", product: "MS-7D25"))),
            ("check-blank", InstallPlan(disk: "ada0", poolName: "tank", swapBytes: 0, timezone: "Europe/London",
                                        rootPasswordHash: "$6$r"),
             disk(Disk(name: "ada0", bytes: 16 * gib))),
            ("check-desktop", InstallPlan(disk: "ada0", sets: desktopSets, accounts: [guest, admin]), ordinary),
            ("check-desktop-autologin", InstallPlan(disk: "ada0", sets: desktopSets, accounts: [guest, admin],
                                                    autoLogin: true), ordinary),
            ("check-desktop-no-admin", InstallPlan(disk: "ada0", sets: desktopSets, rootPasswordHash: "$6$r",
                                                   accounts: [guest], autoLogin: true), ordinary),
            ("check-quoting", InstallPlan(disk: "ada0", mountpoint: "/mnt x",
                                          accounts: [Account(name: "jo", fullName: "Jo O'Neil", passwordHash: "$6$j",
                                                             groups: ["wheel"], shell: "/usr/local/bin/zsh"),
                                                     Account(name: "zoe", fullName: "Zoë", passwordHash: "$6$z")]),
             ordinary),
            ("check-decomposed-name", InstallPlan(disk: "ada0",
                                                  accounts: [Account(name: "zoe", fullName: "Zoe\u{308}",
                                                                     passwordHash: "$6$z", groups: ["wheel"])]),
             ordinary),
            // The hostname is not checked, and goes into rc.conf as it came.
            ("check-hostname-injection", InstallPlan(disk: "ada0", hostname: "x\"\nabyss_desktop_user=\"root",
                                                     accounts: [admin]), ordinary),
            ("check-running-root", good, disk(Disk(name: "ada0", bytes: 64 * gib, mountedAt: ["/", "/home"],
                                                   holdsRunningRoot: true))),
            ("check-mounted", good, disk(Disk(name: "ada0", bytes: 64 * gib, mountedAt: ["/media/photos"]))),
            ("check-full", good, disk(Disk(name: "ada0", bytes: 64 * gib, description: "Samsung",
                                           existingPools: ["zroot"], partitionKinds: ["efi", "freebsd-swap", "freebsd-zfs"],
                                           freeBytes: 2 * mib, hasPartitionTable: true))),
            ("check-full-unnamed", good, disk(Disk(name: "ada0", bytes: 64 * gib, freeBytes: 0, hasPartitionTable: true))),
            ("check-erase-root", InstallPlan(disk: "ada0", accounts: [admin], eraseExistingData: true),
             disk(Disk(name: "ada0", bytes: 64 * gib, holdsRunningRoot: true, partitionKinds: ["efi"],
                       hasPartitionTable: true))),
            ("check-everything-wrong", InstallPlan(disk: "ada0p1", poolName: "mirror", espBytes: 260 * mib + 1,
                                                   swapBytes: 3, sets: ["kernel.txz"], distDirectory: "dist", mountpoint: "mnt"),
             ordinary),
            ("check-base-not-first", InstallPlan(disk: "ada0", sets: ["kernel.txz", "base.txz"], accounts: [admin]), ordinary),
            ("check-no-such-disk", InstallPlan(disk: "ada9", accounts: [admin]), ordinary),
            ("check-no-disks", InstallPlan(disk: "ada0", accounts: [admin]), DiskInventory(disks: [])),
            ("check-no-disk", InstallPlan(disk: "", accounts: [admin]), ordinary),
            ("check-too-small", InstallPlan(disk: "ada0", poolName: "zroot", accounts: [admin]),
             disk(Disk(name: "ada0", bytes: 3 * gib), imported: ["zroot"])),
            ("check-nobody", InstallPlan(disk: "ada0", accounts: [guest]), ordinary),
            ("check-pool-c9x", InstallPlan(disk: "ada0", poolName: "c9x", accounts: [admin]), ordinary),
            ("check-pool-digit", InstallPlan(disk: "ada0", poolName: "9lives", accounts: [admin]), ordinary),
            ("check-pool-slash", InstallPlan(disk: "ada0", poolName: "a/b", accounts: [admin]), ordinary),
            ("check-pool-empty", InstallPlan(disk: "ada0", poolName: "", accounts: [admin]), ordinary),
            ("check-pool-unicode", InstallPlan(disk: "ada0", poolName: "école", accounts: [admin]), ordinary),
            ("check-slice", InstallPlan(disk: "da0s1a", accounts: [admin]), ordinary),
        ]
    }

    static func valid() -> [Case] {
        var cases: [Case] = checks().map { name, plan, inv in
            var m = Msg(); Wire.encode(plan, into: &m); Wire.encode(inv, into: &m)
            return Case(name: name, decoder: "check", bytes: m.pack())
        }
        let inventories: [(String, DiskInventory)] = [
            ("inventory-machine", DiskInventory(disks: [
                Disk(name: "nda1", bytes: 931 << 30, description: "Samsung 990 PRO", mountedAt: ["/data"],
                     existingPools: ["zroot", "tank"], partitionKinds: ["efi", "freebsd-swap", "freebsd-zfs"],
                     freeBytes: 728_576, hasPartitionTable: true),
                Disk(name: "vtbd0", bytes: 85_899_345_920, mountedAt: ["/", "/boot/efi"], holdsRunningRoot: true),
                Disk(name: "cd0", bytes: 0),
            ], importedPools: ["zroot"], machine: MachineIdentity(maker: "Micro-Star", product: "MS-7D25"))),
            ("inventory-empty", DiskInventory(disks: [])),
            ("inventory-unicode", DiskInventory(disks: [Disk(name: "da0", bytes: UInt64.max, description: "Clé USB \"Ü\"\n")],
                                                machine: MachineIdentity(maker: "Ünïcode", product: "✓"))),
        ]
        for (name, inv) in inventories {
            var m = Msg(); Wire.encode(inv, into: &m)
            cases.append(Case(name: name, decoder: "inventory", bytes: m.pack()))
        }
        let events: [(String, RunEvent)] = [
            ("starting", .starting(index: 3, total: 41, what: "create the GPT", destructive: true)),
            ("starting-safe", .starting(index: 0, total: 1, what: "mount the new root", destructive: false)),
            ("ok", .ok(index: 3)),
            ("failed", .failed(index: 4, what: "add swap", why: "gpart: Device busy\n", ignored: true)),
            ("failed-fatal", .failed(index: 5, what: "create the pool", why: "", ignored: false)),
            ("finished", .finished(ok: false, error: "it did not work")),
            ("finished-ok", .finished(ok: true, error: "")),
        ]
        cases += events.map { Case(name: "event-" + $0.0, decoder: "event", bytes: Wire.message(for: $0.1).pack()) }
        return cases
    }

    static func handBuilt() -> [Case] {
        var cases: [Case] = []
        func only(_ name: String, _ decoder: String, _ build: (inout Msg) -> Void) {
            var m = Msg(); build(&m)
            cases.append(Case(name: name, decoder: decoder, bytes: m.pack(), decodeOnly: true))
        }
        func disk(_ m: inout Msg) {
            m.set("disks.count", UInt64(1)); m.set("disk.0.name", "ada0"); m.set("disk.0.bytes", 64 * gib)
        }
        only("check-older-client", "check") { m in
            m.set("disk", "ada0"); m.set("rootpw", "$6$r"); disk(&m)
        }
        only("check-empty", "check") { _ in }
        only("check-sparse-sets", "check") { m in
            m.set("disk", "ada0"); m.set("rootpw", "$6$r"); disk(&m)
            m.set("sets.count", UInt64(4))
            m.set("set.0", "base.txz"); m.set("set.1", UInt64(7)); m.set("set.3", "abyss.tzst"); m.set("set.4", "past.txz")
            m.set("set.01", "leading zero")
        }
        only("check-accounts", "check") { m in
            m.set("disk", "ada0"); disk(&m)
            m.set("accounts.count", UInt64(3))
            m.set("account.0.full", "no name, so not an account")
            m.set("account.1.name", "ada"); m.set("account.1.groups", ",wheel,,operator,")
            m.set("account.2.name", "bob"); m.set("account.2.hash", "$6$b"); m.set("account.2.shell", "/bin/csh")
            m.set("account.2.groups", "")
        }
        only("check-flags", "check") { m in
            m.set("disk", "ada0"); m.set("rootpw", "$6$r"); disk(&m)
            m.set("erase", UInt64(2)); m.set("autologin", true)
            m.set("esp", "big"); m.set("swap", UInt64(0))
        }
        only("check-count-short", "check") { m in
            m.set("disk", "ada0"); m.set("rootpw", "$6$r")
            m.set("disks.count", UInt64(1)); m.set("disk.0.name", "ada1"); m.set("disk.1.name", "ada0")
            m.set("sets.count", UInt64(1)); m.set("set.0", "base.txz"); m.set("set.1", "kernel.txz")
        }
        only("inventory-sparse", "inventory") { m in
            m.set("disks.count", UInt64(3))
            m.set("disk.0.bytes", UInt64(5))
            m.set("disk.1.name", "ada1"); m.set("disk.1.mounted", ",/a,,/b,"); m.set("disk.1.root", UInt64(1))
            m.set("disk.1.table", true); m.set("disk.1.kinds", "efi,,ntfs")
            m.set("disk.2.name", UInt64(2))
            m.set("pools.count", UInt64(2)); m.set("pool.1", "tank"); m.set("pool.2", "past")
        }
        only("inventory-half-machine", "inventory") { m in
            m.set("machine.maker", "Apple Inc."); m.set("machine.product", "")
        }
        only("inventory-no-maker", "inventory") { m in m.set("machine.product", "MacPro6,1") }
        only("event-unknown", "event") { $0.set("event", "progress"); $0.set("index", UInt64(1)) }
        only("event-empty", "event") { _ in }
        only("event-not-text", "event") { $0.set("event", UInt64(1)) }
        only("event-defaults", "event") { $0.set("event", "starting") }
        only("event-refusal", "event") { $0.set("ok", false); $0.set("error", "no") }
        return cases
    }

    /// Text in: (name, op line, input).
    static func texts() -> [(String, String, String)] {
        [
            ("keymap-installer", "keymap", "# Written by the AbyssBSD installer.\nzfs_enable=\"YES\"\nkeymap=\"uk.kbd\"\n"),
            ("keymap-last-wins", "keymap", "keymap=us.kbd\nkeymap='de.kbd'\n"),
            ("keymap-comment", "keymap", "  keymap=fr.kbd   # the console too\n"),
            ("keymap-tab", "keymap", "\tkeymap=it.kbd\tx\n"),
            ("keymap-not-it", "keymap", "#keymap=\"uk.kbd\"\nkeymapx=\"uk.kbd\"\n"),
            ("keymap-guessed", "keymap", "keymap=\"de.acc.kbd\"\n"),
            ("keymap-unterminated", "keymap", "keymap=\"uk.kbd\n"),
            ("keymap-empty", "keymap", "keymap=\nhostname=x\n"),
            ("keymap-no", "keymap", "keymap=\"NO\"\n"),
            ("keymap-none", "keymap", ""),
            ("keymap-crlf", "keymap", "keymap=uk.kbd\r\nhostname=x\r\n"),
            ("xkb-names", "xkb", "uk.kbd\nus.dvorak.kbd\ncolemak.acc.kbd\nde.acc.kbd\nuk.macbook.kbd\n.kbd\n..fr.kbd\ngerman\nkbd\n"),
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

    static func text(_ p: InstallPlan) -> String {
        var out = "plan \(q(p.disk)) pool=\(q(p.poolName)) esp=\(p.espBytes) swap=\(p.swapBytes) dist=\(q(p.distDirectory))"
            + " mountpoint=\(q(p.mountpoint)) hostname=\(q(p.hostname)) timezone=\(q(p.timezone)) keymap=\(q(p.keymap))"
            + " rootpw=\(q(p.rootPasswordHash)) erase=\(b(p.eraseExistingData)) autologin=\(b(p.autoLogin))\n"
        for s in p.sets { out += "set \(q(s))\n" }
        for a in p.accounts {
            out += "account \(q(a.name)) \(q(a.fullName)) \(q(a.passwordHash)) groups=\(list(a.groups)) shell=\(q(a.shell))\n"
        }
        return out
    }

    static func text(_ inv: DiskInventory) -> String {
        var out = ""
        for d in inv.disks {
            out += "disk \(q(d.name)) bytes=\(d.bytes) descr=\(q(d.description)) mounted=\(list(d.mountedAt))"
                + " root=\(b(d.holdsRunningRoot)) pools=\(list(d.existingPools)) kinds=\(list(d.partitionKinds))"
                + " free=\(d.freeBytes) table=\(b(d.hasPartitionTable))\n"
        }
        for p in inv.importedPools { out += "pool \(q(p))\n" }
        out += inv.machine.map { "machine \(q($0.maker)) \(q($0.product))\n" } ?? "machine none\n"
        return out
    }

    static func text(_ e: RunEvent?) -> String {
        switch e {
        case nil: return "none"
        case .starting(let i, let n, let what, let d)?: return "starting \(i) \(n) \(q(what)) destructive=\(b(d))"
        case .ok(let i)?: return "ok \(i)"
        case .failed(let i, let what, let why, let ignored)?: return "failed \(i) \(q(what)) \(q(why)) ignored=\(b(ignored))"
        case .finished(let ok, let error)?: return "finished \(b(ok)) \(q(error))"
        }
    }

    /// What `decoder` reads from `bin`, and the bytes the encoder makes of
    /// that (nil when it read nothing to encode).
    static func decode(_ decoder: String, _ bin: [UInt8]) -> (String, [UInt8]?) {
        var out = decoder + "\n"
        guard let m = try? Msg.unpack(bin) else { return (out + "malformed\n", nil) }
        switch decoder {
        case "check":
            let p = Wire.decodePlan(m), inv = Wire.decodeInventory(m)
            out += text(p) + text(inv)
            let refusals = problems(p, on: inv)
            for r in refusals { out += "problem \(q(r.message))\n" }
            if refusals.isEmpty, let steps = try? compile(p, on: inv) { out += "steps\n" + render(steps) }
            var e = Msg(); Wire.encode(p, into: &e); Wire.encode(inv, into: &e)
            return (out, e.pack())
        case "inventory":
            let inv = Wire.decodeInventory(m)
            var e = Msg(); Wire.encode(inv, into: &e)
            return (out + text(inv), e.pack())
        case "event":
            let e = Wire.event(from: m)
            return (out + text(e) + "\n", e.map { Wire.message(for: $0).pack() })
        default:
            return (out + "no decoder\n", nil)
        }
    }

    static func text(xkb name: String) -> String {
        guard let (k, exact) = Keymaps.xkb(forKbdmap: name) else { return "xkb \(q(name)) none\n" }
        return "xkb \(q(name)) layout=\(q(k.layout)) variant=\(q(k.variant)) exact=\(b(exact))"
            + " name=\(q(Keymaps.displayName(forKbdmap: name)))\n"
    }

    /// `op` applied to `input`.
    static func run(_ op: String, _ input: String) -> String {
        var out = op + "\n"
        switch op {
        case "keymap":
            guard let v = Keymaps.lastAssignment("keymap", in: input) else { return out + "assignment none\n" }
            out += "assignment \(q(v))\n" + text(xkb: v)
        case "xkb":
            for name in input.split(separator: "\n") { out += text(xkb: String(name)) }
        default:
            out += "no operation\n"
        }
        return out
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

    func readText(_ path: String) -> String? { read(path).map { String(decoding: $0, as: UTF8.self) } }

    // MARK: the test

    func testTheFixturesAreWhatSwiftReadsAndWrites() throws {
        let dir = Self.dir
        let cases = Self.valid() + Self.handBuilt()
        let texts = Self.texts()
        XCTAssertEqual(Set(cases.map(\.name) + texts.map(\.0)).count, cases.count + texts.count, "case names are unique")
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/install".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for c in cases {
                let (txt, _) = Self.decode(c.decoder, c.bytes)
                try write("\(dir)/\(c.name).bin", c.bytes)
                try write("\(dir)/\(c.name).txt", Array(((c.decodeOnly ? "decode-only\n" : "") + txt).utf8))
            }
            for (name, op, input) in texts {
                try write("\(dir)/\(name).in", Array(input.utf8))
                try write("\(dir)/\(name).txt", Array(Self.run(op, input).utf8))
            }
        }

        // Check every case on disk, whoever wrote it.
        for c in cases {
            guard let bin = read("\(dir)/\(c.name).bin"), let txt = readText("\(dir)/\(c.name).txt") else {
                XCTFail("\(c.name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            let decodeOnly = txt.hasPrefix("decode-only\n")
            let expected = decodeOnly ? String(txt.dropFirst("decode-only\n".count)) : txt
            let (got, encoded) = Self.decode(String(expected.prefix { $0 != "\n" }), bin)
            XCTAssertEqual(got, expected, "\(c.name): decoding the bytes")
            if !decodeOnly {
                XCTAssertEqual(encoded, bin, "\(c.name): encoding what was decoded")
            }
        }
        for (name, _, _) in texts {
            guard let input = readText("\(dir)/\(name).in"), let txt = readText("\(dir)/\(name).txt") else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            XCTAssertEqual(Self.run(String(txt.prefix { $0 != "\n" }), input), txt, name)
        }
    }
}
