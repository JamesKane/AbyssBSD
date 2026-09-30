// Vents — devd(8), how a FreeBSD desktop learns about hotplug, power and media
// without udev or acpid.
//
// devd publishes newline-delimited events on `/var/run/devd.pipe`; a client just
// connects and reads. The first byte is the event type:
//
//   +ugen0.2 at ...          a device attached
//   -ugen0.2 at ...          a device detached
//   !system=DEVFS ...        a notify, carrying key=value fields
//   ?  at ...                a device with no matching driver
//
// The parsing is pure and the socket half is thin, deliberately: the parser is
// what has edge cases, and it can be tested against captured real events on any
// platform.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Vents {}

extension Vents {

    /// One line from devd.
    public struct Event: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case notify     // !  — key=value fields
            case attach     // +  — a device arrived
            case detach     // -  — a device went away
            case nomatch    // ?  — no driver claimed it
            case unknown
        }

        public let kind: Kind
        /// The line with its type byte and line ending removed.
        public let raw: String
        /// `key=value` pairs; notify events only.
        public let fields: [(key: String, value: String)]

        public static func == (a: Event, b: Event) -> Bool {
            a.kind == b.kind && a.raw == b.raw
                && a.fields.count == b.fields.count
                && zip(a.fields, b.fields).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        }

        public init(_ line: String) {
            var s = line
            while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
            let k: Kind
            switch s.first {
            case "!": k = .notify
            case "+": k = .attach
            case "-": k = .detach
            case "?": k = .nomatch
            default:  k = .unknown
            }
            self.kind = k
            self.raw = k == .unknown ? s : String(s.dropFirst())
            self.fields = k == .notify ? Event.parseFields(self.raw) : []
        }

        /// The device name of an attach/detach — the first token.
        public var device: String? {
            switch kind {
            case .attach, .detach:
                return raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            default:
                return nil
            }
        }

        /// A notify field.
        public func value(_ key: String) -> String? {
            fields.first(where: { $0.key == key })?.value
        }

        /// One readable line, for logs.
        public var summary: String {
            switch kind {
            case .attach:  return "attach \(device ?? "?")"
            case .detach:  return "detach \(device ?? "?")"
            case .notify:  return "notify \(raw)"
            case .nomatch: return "nomatch \(raw)"
            case .unknown: return "event \(raw)"
            }
        }

        /// Split `key=value` pairs, honouring the double quotes devd puts around
        /// values that contain spaces:
        ///
        ///     system=CAM device=cd0 cam_status="0x4cc" CDB="00 00 00 "
        ///
        /// Splitting on whitespace alone would chop that CDB value into pieces
        /// and lose the field — real devd output on the build VM looks exactly
        /// like this.
        static func parseFields(_ s: String) -> [(key: String, value: String)] {
            var out: [(key: String, value: String)] = []
            var key = ""
            var value = ""
            var inValue = false
            var quoted = false

            func flush() {
                if !key.isEmpty { out.append((key, value)) }
                key = ""; value = ""; inValue = false; quoted = false
            }

            for ch in s {
                if quoted {
                    if ch == "\"" { quoted = false } else { value.append(ch) }
                    continue
                }
                switch ch {
                case "=" where !inValue:
                    inValue = true
                case "\"" where inValue && value.isEmpty:
                    quoted = true
                case " ", "\t":
                    flush()
                default:
                    if inValue { value.append(ch) } else { key.append(ch) }
                }
            }
            flush()
            return out
        }
    }

    /// A connection to devd's event socket.
    ///
    /// `fd` is pollable, so hotplug folds into a component's existing run loop
    /// through `Display.addFileDescriptor` — the same hook the config watcher
    /// and the menu-bar clock use (HANDOFF §2.18). No thread, no polling.
    public final class Devd {
        public let fd: Int32
        private var pending = ""

        /// The stream socket devd publishes on. (There is also a seqpacket
        /// variant; the stream one is the portable, long-standing interface.)
        public static let defaultPath = "/var/run/devd.pipe"

        /// Connect, or return nil when devd isn't running (or isn't a thing, as
        /// on Linux) — the caller then simply has no hotplug, rather than an
        /// error to handle.
        public init?(path: String = Devd.defaultPath) {
            let s = socket(AF_UNIX, ventsSockStream, 0)
            guard s >= 0 else { return nil }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
                close(s)
                return nil
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let rc = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0 else {
                close(s)
                return nil
            }
            self.fd = s
        }

        /// Read whatever devd has queued and return the complete events.
        ///
        /// A partial line is held back until its newline arrives: devd writes
        /// whole events, but a stream socket may still split one across two
        /// reads, and half an event parsed as a whole one is a silent lie.
        public func read(max: Int = 64 * 1024) -> [Event] {
            var buf = [UInt8](repeating: 0, count: max)
            let n = buf.withUnsafeMutableBufferPointer {
                Glibc.read(fd, $0.baseAddress, max)
            }
            guard n > 0 else { return [] }
            pending += String(decoding: buf[0..<n], as: UTF8.self)

            var events: [Event] = []
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[pending.startIndex..<nl])
                pending = String(pending[pending.index(after: nl)...])
                if !line.isEmpty { events.append(Event(line)) }
            }
            return events
        }

        deinit { close(fd) }
    }
}

// SOCK_STREAM imports as a different type per platform (see CurrentIPC).
#if canImport(Glibc) && os(Linux)
let ventsSockStream = Int32(SOCK_STREAM.rawValue)
#else
let ventsSockStream = Int32(SOCK_STREAM)
#endif
