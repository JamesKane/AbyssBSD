// Vents — sysctl, the OSS mixer, and the battery, behind small Swift types.
//
// A Swift rewrite of the sibling's `vents` (read as the spec, never linked).
// The rule throughout: **when a facility isn't there, say so, don't invent a
// reading.** A desktop with no sound card should hide its volume item, not show
// a confident 0%. Every accessor is therefore optional, and the menu bar decides
// what to draw from what actually answered.

import CVents

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension Vents {

    // MARK: - sysctl

    /// The kernel environment — **a different namespace from sysctl**, and the
    /// only place the machine says what it is.
    ///
    /// `smbios.system.maker` and `smbios.system.product` are what distinguish a
    /// MacPro6,1 from an MSI desktop, and they are not in the sysctl tree:
    /// `sysctl -aN | grep smbios` finds only `dev.smbios.*`, which are device
    /// nodes. Phase 12 needs this so a Mac Pro's loader tunable stops being
    /// written to every machine we install (PHASE4 §5.2).
    public enum Kenv {
        /// Whether this platform has a kernel environment at all (false on
        /// Linux, where the bridge is a stub).
        public static var isSupported: Bool { av_sysctl_supported() != 0 }

        /// A kenv variable, or nil if it is not set.
        ///
        /// FreeBSD's `kenv(2)` caps a value at `KENV_MVALLEN`; 1024 is
        /// comfortably above it and this is not a hot path.
        public static func string(_ name: String) -> String? {
            var buf = [CChar](repeating: 0, count: 1024)
            let n = buf.withUnsafeMutableBufferPointer {
                av_kenv_read(name, $0.baseAddress, $0.count)
            }
            guard n >= 0 else { return nil }
            return String(cString: buf)
        }

        /// What this machine calls itself: maker and product, trimmed, with
        /// the quotes `kenv` reports stripped.
        ///
        /// Returns nil when either is missing rather than half an answer — a
        /// machine identified as `Apple Inc.` with no model is not identified.
        public static func machine() -> (maker: String, product: String)? {
            guard let mk = string("smbios.system.maker").map(unquote),
                  let pr = string("smbios.system.product").map(unquote),
                  !mk.isEmpty, !pr.isEmpty
            else { return nil }
            return (mk, pr)
        }

        /// `kenv` renders values with surrounding quotes; the value does not
        /// contain them.
        static func unquote(_ s: String) -> String {
            var v = Substring(s)
            while v.first == " " { v = v.dropFirst() }
            while v.last == " " { v = v.dropLast() }
            if v.count >= 2, v.first == "\"", v.last == "\"" {
                v = v.dropFirst().dropLast()
            }
            return String(v)
        }
    }

    public enum Sysctl {
        /// Whether this platform answers sysctl at all (false on Linux, where
        /// the bridge is a stub).
        public static var isSupported: Bool { av_sysctl_supported() != 0 }

        /// Raw bytes of a sysctl, or nil if it doesn't exist.
        public static func raw(_ name: String) -> [UInt8]? {
            let size = av_sysctl_read(name, nil, 0)
            guard size >= 0 else { return nil }
            if size == 0 { return [] }
            var buf = [UInt8](repeating: 0, count: Int(size))
            let n = buf.withUnsafeMutableBufferPointer {
                av_sysctl_read(name, $0.baseAddress, Int(size))
            }
            guard n >= 0 else { return nil }
            return Array(buf[0..<Int(n)])
        }

        /// A string sysctl (`kern.ostype`), without its trailing NUL.
        public static func string(_ name: String) -> String? {
            guard var b = raw(name) else { return nil }
            if b.last == 0 { b.removeLast() }
            return String(decoding: b, as: UTF8.self)
        }

        /// An integer sysctl, stored as a 4- or 8-byte native-endian value.
        public static func int(_ name: String) -> Int64? {
            guard let b = raw(name) else { return nil }
            switch b.count {
            case 4:
                let v = b.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
                return Int64(v)
            case 8:
                return b.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
            default:
                return nil      // present but not a number: not our business to guess
            }
        }

        /// A best-effort human-readable value, for a caller that doesn't know
        /// the type (a CLI, a debug dump).
        ///
        /// **Printable bytes win over the integer reading**, and that ordering
        /// is the whole point: a sysctl API is untyped, and `kern.ostype` is
        /// `"FreeBSD\0"` — *exactly eight bytes*, which reads as a perfectly
        /// plausible Int64 (19231843050418758). Asking "is it a number?" first
        /// turns every 4- or 8-character string into nonsense.
        public static func display(_ name: String) -> String? {
            guard let bytes = raw(name) else { return nil }
            let body = bytes.last == 0 ? Array(bytes.dropLast()) : bytes
            let printable = body.allSatisfy { $0 == 0x09 || $0 == 0x0a || (0x20..<0x7f).contains($0) }
            if !body.isEmpty && printable {
                var s = String(decoding: body, as: UTF8.self)
                while s.hasSuffix("\n") || s.hasSuffix(" ") { s.removeLast() }
                return s
            }
            switch bytes.count {
            case 4, 8: return int(name).map(String.init)
            default:   return "<\(bytes.count) bytes>"
            }
        }
    }

    // MARK: - Volume (OSS)

    /// OSS packs a stereo level into one int: low byte left, next byte right,
    /// each 0...100. Pure, so the packing is testable anywhere.
    public struct VolumeLevel: Equatable, Sendable {
        public let left: UInt8
        public let right: UInt8

        public init(left: UInt8, right: UInt8) {
            self.left = min(left, 100)
            self.right = min(right, 100)
        }
        public init(_ both: UInt8) { self.init(left: both, right: both) }

        public init(encoded: Int32) {
            self.init(left: UInt8(truncatingIfNeeded: encoded & 0xff),
                      right: UInt8(truncatingIfNeeded: (encoded >> 8) & 0xff))
        }

        public var encoded: Int32 { Int32(left) | (Int32(right) << 8) }

        /// One number for a UI that shows a single bar.
        public var mono: UInt8 { left }
    }

    /// An open OSS mixer device.
    public final class Mixer {
        private let fd: Int32

        /// Open `/dev/mixer` (then `/dev/mixer0`), or nil when there is no
        /// mixer — which is the normal answer on a machine with no sound card,
        /// and always on Linux.
        public init?(path: String? = nil) {
            let f = path == nil ? av_mixer_open(nil) : av_mixer_open(path!)
            guard f >= 0 else { return nil }
            self.fd = f
        }

        public func level() -> VolumeLevel? {
            var v: Int32 = 0
            guard av_mixer_get_volume(fd, &v) == 0 else { return nil }
            return VolumeLevel(encoded: v)
        }

        /// Set the level, returning what the kernel actually applied — the OSS
        /// write ioctl reads back, and a card may not honour every step.
        @discardableResult
        public func setLevel(_ want: VolumeLevel) -> VolumeLevel? {
            var v = want.encoded
            guard av_mixer_set_volume(fd, &v) == 0 else { return nil }
            return VolumeLevel(encoded: v)
        }

        deinit { close(fd) }
    }

    // MARK: - Battery (ACPI via sysctl)

    public struct Battery: Equatable, Sendable {
        /// Charge remaining, 0...100. `nil` when the kernel says -1, which is
        /// what it reports while it doesn't yet know.
        public let percent: Int?
        /// Minutes remaining, when the kernel offers an estimate.
        public let minutesRemaining: Int?
        /// `hw.acpi.battery.state` is a bitfield; bit 1 means discharging.
        public let isCharging: Bool

        public init(percent: Int?, minutesRemaining: Int?, isCharging: Bool) {
            self.percent = percent; self.minutesRemaining = minutesRemaining; self.isCharging = isCharging
        }

        /// Read the battery, or nil on a machine that has none — a desktop, or
        /// a VM. The status item is then simply absent, which is honest.
        public static func read() -> Battery? {
            guard let life = Sysctl.int("hw.acpi.battery.life") else { return nil }
            let pct: Int? = life < 0 ? nil : Int(life)
            let time = Sysctl.int("hw.acpi.battery.time").map(Int.init)
            let state = Sysctl.int("hw.acpi.battery.state") ?? 0
            return Battery(percent: pct,
                           minutesRemaining: (time ?? -1) < 0 ? nil : time,
                           isCharging: (state & 0x2) == 0)
        }

        /// What the menu bar shows: "84%", or "—" before the kernel knows.
        public var label: String {
            guard let p = percent else { return "—" }
            return "\(p)%"
        }
    }
}
