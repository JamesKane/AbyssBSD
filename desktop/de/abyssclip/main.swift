// `abyssclip` — the clipboard, from a shell (PHASE9.md P9.1).
//
// A tool and a test vehicle, in that order. `abyssgrab` is the precedent: a
// small binary that does one desktop thing through our own client runtime, so
// the thing can be driven by a script instead of only by a person.
//
//   abyssclip copy [TEXT]     put TEXT (or stdin) on the clipboard, and hold it
//   abyssclip paste           print what is on the clipboard
//
// **`copy` has to stay running, and that is the protocol rather than a
// shortcoming.** A Wayland selection is not data the compositor stores — it is a
// promise by the source client to write bytes into a descriptor when somebody
// asks. The owner exiting *is* the clipboard being emptied, which is why every
// desktop has a clipboard manager and why this prints a line before it waits:
// a caller needs to know the offer is live before it pastes.

import Surface

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array(s.utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func die(_ s: String) -> Never { emit(2, "abyssclip: \(s)\n"); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first, verb == "copy" || verb == "paste" else {
    die("usage: abyssclip copy [TEXT] | abyssclip paste")
}

guard let display = Display() else {
    die("cannot connect to a Wayland compositor — is WAYLAND_DISPLAY set?")
}
// One roundtrip for the registry, a second because the data device's own events
// (the selection we may already have been given) arrive after we bind it.
display.roundtrip()
display.roundtrip()

guard let clip = display.clipboard else {
    die("this compositor offers no wl_data_device_manager, so there is no clipboard")
}

switch verb {
case "copy":
    var text = args.count > 1 ? args[1..<args.count].joined(separator: " ") : ""
    if args.count <= 1 {
        var buf = [UInt8](repeating: 0, count: 4096)
        var all: [UInt8] = []
        while true {
            let n = buf.withUnsafeMutableBytes { read(0, $0.baseAddress, 4096) }
            if n <= 0 { break }
            all.append(contentsOf: buf[0..<n])
        }
        text = String(decoding: all, as: UTF8.self)
    }
    guard clip.writeText(text) else { die("the compositor refused the selection") }
    // **Say so before waiting.** A caller that pastes too early gets the
    // previous clipboard and no error, which is the kind of race that reads as
    // a flaky test rather than as a missing synchronisation point (§2.31).
    emit(1, "abyssclip: offering \(text.utf8.count) bytes\n")
    display.run()

case "paste":
    guard let s = clip.readText() else {
        // Empty is an answer. Exit 2 so a caller can tell "nothing is on the
        // clipboard" from "this failed", the way `ventsctl` already does.
        emit(2, "abyssclip: the clipboard is empty\n")
        exit(2)
    }
    emit(1, s)

default: die("unreachable")
}
