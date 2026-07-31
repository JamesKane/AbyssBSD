// ventsctl — read the machine through the FreeBSD-native bridges.
//
// The sibling shipped three small binaries for this (`sysctl`, `volume`,
// `devd`); one tool with subcommands does the same job and gives
// `abyss/tests/live-vents.sh` something to drive.
//
//   ventsctl sysctl <name>        print a sysctl (string or number)
//   ventsctl volume [percent]     read, or set, the master OSS level
//   ventsctl battery              charge, and whether it's charging
//   ventsctl devd [seconds]       stream devd events (default 5s)
//
// Every subcommand exits 2 when the facility is absent, so a caller can tell
// "no battery in this machine" from "the battery is at 0%".

import Vents

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func out(_ s: String) { emit(1, s) }
func unavailable(_ s: String) -> Never { emit(2, "ventsctl: \(s)"); exit(2) }
func fail(_ s: String) -> Never { emit(2, "ventsctl: \(s)"); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    fail("usage: ventsctl sysctl <name> | volume [pct] | battery | devd [secs]")
}

switch cmd {
case "sysctl":
    guard args.count >= 2 else { fail("sysctl needs a name") }
    guard Vents.Sysctl.isSupported else { unavailable("no sysctl on this platform") }
    let name = args[1]
    // `display` decides string-or-number by looking at the bytes, and puts
    // printable text first: `kern.ostype` is "FreeBSD\0", exactly 8 bytes, so
    // asking "is it an integer?" first prints 19231843050418758.
    guard let value = Vents.Sysctl.display(name) else {
        unavailable("unknown sysctl '\(name)'")
    }
    out(value)

case "volume":
    guard let mixer = Vents.Mixer() else {
        unavailable("no mixer (\(String(cString: strerror(errno))))")
    }
    if args.count >= 2 {
        guard let pct = Int(args[1]), (0...100).contains(pct) else {
            fail("volume wants 0..100")
        }
        guard let applied = mixer.setLevel(Vents.VolumeLevel(UInt8(pct))) else {
            fail("could not set the volume")
        }
        out("volume \(applied.left) \(applied.right)")
    } else {
        guard let level = mixer.level() else { fail("could not read the volume") }
        out("volume \(level.left) \(level.right)")
    }

case "battery":
    guard let b = Vents.Battery.read() else { unavailable("no battery") }
    out("battery \(b.label) \(b.isCharging ? "charging" : "discharging")"
        + (b.minutesRemaining.map { " \($0)min" } ?? ""))

case "devd":
    let seconds = args.count >= 2 ? (Double(args[1]) ?? 5) : 5
    guard let devd = Vents.Devd() else {
        unavailable("devd isn't running (no \(Vents.Devd.defaultPath))")
    }
    out("watching devd for \(Int(seconds))s")
    // Poll the socket the way a shell component would fold it into its run loop.
    let deadline = Date_monotonic() + seconds
    while Date_monotonic() < deadline {
        var p = pollfd(fd: devd.fd, events: Int16(POLLIN), revents: 0)
        let remaining = Int32(max(0, (deadline - Date_monotonic()) * 1000))
        let n = withUnsafeMutablePointer(to: &p) { poll($0, 1, remaining) }
        if n <= 0 { continue }
        for e in devd.read() { out(e.summary) }
    }
    out("done")

default:
    fail("unknown command '\(cmd)'")
}

/// A monotonic seconds reading (this module is Foundation-free, like the rest
/// of `de/`).
func Date_monotonic() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}
