// Vents.Sound — the machine's sound devices, their controls, and who is
// playing, without privilege (PHASE14 P14.6).
//
// Three sources, all an ordinary user may read:
//
//   - **/dev/sndstat** (its nvlist): every device, and every channel on it with
//     the pid, command and volume of whoever has it open — which is how the
//     Sound pane can say which applications are playing and how loud each
//     asked to be. It can say, not change: another process's channel volume
//     is set only by that process (§4.3; route (b), `virtual_oss`, is Phase
//     18's).
//   - **/dev/mixerN** through libmixer: each device's controls (`vol`, `pcm`,
//     `rec` …), their levels and mute. The mixer is the user's to change.
//   - **hw.snd.default_unit**: which device `/dev/dsp` means. Changing it is
//     root's (the settings helper, P14.6b).
//
// On Linux there is no OSS: every read here says "no devices", and the pane
// says so, rather than showing ALSA through a door that is not ours.

import CVents

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public extension Vents {
    enum Sound {
        public struct Channel: Equatable, Sendable {
            /// `dsp0.virtual_play.1`
            public let name: String
            /// Who has it open, or nil when nobody does.
            public let pid: Int32?
            public let command: String
            public let left: Int, right: Int
            public var isPlayback: Bool { name.contains("play") }
        }

        public struct Device: Equatable, Sendable {
            public let unit: Int
            /// `pcm0`
            public let name: String
            /// `Dummy Audio Device`, `Realtek ALC897 (Rear Analog)`
            public let description: String
            public let devnode: String
            public let playback: Bool, recording: Bool
            /// A device a user-space server (virtual_oss) added.
            public let fromUser: Bool
            public let channels: [Channel]
            /// Channels someone has open for playback — the applications
            /// playing, with the volume each set for itself.
            public var playing: [Channel] { channels.filter { $0.pid != nil && $0.isPlayback } }
        }

        public struct Control: Equatable, Sendable {
            /// `vol`, `pcm`, `rec` …
            public let name: String
            public let left: Int, right: Int
            public let muted: Bool
            public let recordable: Bool
            /// One number for a slider: the louder side.
            public var level: Int { max(left, right) }
        }

        /// Every device, in the kernel's order. Empty where there are none,
        /// including where there is no OSS at all.
        public static func devices() -> [Device] {
            parseSndstat(read { av_sndstat_read($0, $1) } ?? "")
        }

        /// The unit `/dev/dsp` means, or nil.
        public static func defaultUnit() -> Int? {
            Vents.Sysctl.int("hw.snd.default_unit").map { Int($0) }
        }

        /// A device's controls, or empty when it has no mixer.
        public static func controls(unit: Int) -> [Control] {
            parseControls(read { av_mixer_describe(Int32(unit), $0, $1) } ?? "")
        }

        /// Set a control's level, both sides. Returns false (and the reason in
        /// errno's words) when the device or control does not exist.
        @discardableResult
        public static func set(unit: Int, control: String, left: Int, right: Int) -> String? {
            av_mixer_set(Int32(unit), control, Int32(left), Int32(right)) == 0 ? nil : String(cString: strerror(errno))
        }

        @discardableResult
        public static func set(unit: Int, control: String, muted: Bool) -> String? {
            av_mixer_mute(Int32(unit), control, muted ? 1 : 0) == 0 ? nil : String(cString: strerror(errno))
        }

        // MARK: - Parsers (pure)

        public static func parseSndstat(_ text: String) -> [Device] {
            struct Partial { var fields: [Substring]; var channels: [Channel] }
            var devices: [Partial] = []
            var unitIndex: [Int: Int] = [:]
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                if f.first == "dev", f.count >= 8 {
                    if let u = Int(f[1]) { unitIndex[u] = devices.count }
                    devices.append(Partial(fields: f, channels: []))
                } else if f.first == "chan", f.count >= 7, let u = Int(f[1]), let i = unitIndex[u] {
                    let pid = Int32(f[3]) ?? -1
                    devices[i].channels.append(Channel(name: String(f[2]), pid: pid < 0 ? nil : pid,
                                                       command: pid < 0 ? "" : String(f[4]),
                                                       left: Int(f[5]) ?? 0, right: Int(f[6]) ?? 0))
                }
            }
            return devices.compactMap { p in
                let f = p.fields
                guard let unit = Int(f[1]), unit >= 0 else { return nil }
                return Device(unit: unit, name: String(f[2]), description: String(f[3]), devnode: String(f[4]),
                              playback: f[5] == "1", recording: f[6] == "1", fromUser: f[7] == "1",
                              channels: p.channels)
            }
        }

        public static func parseControls(_ text: String) -> [Control] {
            text.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard f.count >= 6, f[0] == "ctl", let l = Int(f[2]), let r = Int(f[3]) else { return nil }
                return Control(name: String(f[1]), left: l, right: r, muted: f[4] == "1", recordable: f[5] == "1")
            }
        }

        /// Call a C reader with a buffer big enough for any machine's answer.
        private static func read(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int) -> String? {
            var buf = [CChar](repeating: 0, count: 65536)
            let n = buf.withUnsafeMutableBufferPointer { body($0.baseAddress!, $0.count) }
            guard n >= 0 else { return nil }
            return String(cString: buf)
        }
    }
}
