// abyssgrab — capture an output to a PNG (PHASE7.md P7.5).
//
//     abyssgrab <out.png|out.ppm> [--output N] [--cursor]
//
// The screenshot portal's capture step, as its own process — for the same
// reason the file chooser's picker is (PHASE7.md §6.1): it keeps the portal a
// small trusted service that speaks IPC and syscalls, instead of a Wayland
// client that links cairo. `abyss-portal` runs headless, needs no compositor,
// and does not gain one because it grew a screenshot method.
//
// It is also the thing to reach for by hand, the way `ventsctl` and `abyssctl`
// are: `abyssgrab /tmp/shot.png` is a working screenshot tool.
//
// Exit codes are the portal's two-signal contract (PHASE7.md §6.2), matching the
// picker's: 0 wrote the file, 1 could not capture, 2 bad usage.

import CCairo
import Surface

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func die(_ s: String) -> Never { emit(2, "abyssgrab: \(s)"); exit(1) }
func usage(_ s: String) -> Never { emit(2, "abyssgrab: \(s)"); exit(2) }

var outPath: String?
var outputIndex = 0
var cursor = false
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--output":
        i += 1
        guard i < args.count, let n = Int(args[i]), n >= 0 else {
            usage("--output needs a non-negative index")
        }
        outputIndex = n
    case "--cursor":
        cursor = true
    case "-h", "--help":
        emit(1, "usage: abyssgrab <out.png> [--output N] [--cursor]")
        exit(0)
    case let other where other.hasPrefix("-"):
        usage("unknown option '\(other)'")
    case let path:
        guard outPath == nil else { usage("only one output file") }
        outPath = path
    }
    i += 1
}
guard let outPath else { usage("usage: abyssgrab <out.png> [--output N] [--cursor]") }

guard let display = Display() else {
    die("cannot connect to a Wayland compositor (is WAYLAND_DISPLAY set?)")
}
guard display.canCaptureScreen else {
    // Naming the protocol matters: this is the one failure a user can act on,
    // and on a compositor without wlr-screencopy there is nothing to retry.
    die("this compositor does not offer wlr-screencopy — cannot capture the screen")
}
guard display.outputCount > 0 else { die("the compositor advertised no outputs") }

let capture: ScreenCapture
do {
    capture = try display.captureOutput(outputIndex, overlayCursor: cursor)
} catch {
    die("\(error)")
}

// cairo picks its own row stride; it happens to be width*4 for RGB24, but
// copying row by row into cairo's stride means we don't depend on that.
let cairoStride = Int(cairo_format_stride_for_width(CAIRO_FORMAT_RGB24,
                                                    Int32(capture.width)))
guard cairoStride >= capture.stride else { die("cairo rejected a \(capture.width)px row") }

var image = [UInt8](repeating: 0, count: cairoStride * capture.height)
for y in 0..<capture.height {
    let src = y * capture.stride, dst = y * cairoStride
    image.replaceSubrange(dst..<(dst + capture.stride),
                          with: capture.pixels[src..<(src + capture.stride)])
}

// **`.ppm` writes a PPM instead** (PHASE10 P10.4): a header and RGB triples,
// which a shell script can probe with `dd` and `od` and no image library —
// the same format undertow's `--capture` writes (HANDOFF §2.26). The PNG path
// is for people; this one is for assertions on a live desktop.
if outPath.hasSuffix(".ppm") {
    var out = Array("P6\n\(capture.width) \(capture.height)\n255\n".utf8)
    out.reserveCapacity(out.count + capture.width * capture.height * 3)
    for y in 0..<capture.height {
        for x in 0..<capture.width {
            // RGB24 in memory is B, G, R, X on the little-endian hosts we run.
            let i = y * cairoStride + x * 4
            out.append(image[i + 2]); out.append(image[i + 1]); out.append(image[i])
        }
    }
    let fd = open(outPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { die("could not write \(outPath)") }
    let n = out.withUnsafeBufferPointer { write(fd, $0.baseAddress, out.count) }
    close(fd)
    guard n == out.count else { die("short write to \(outPath)") }
    emit(2, "abyssgrab: captured output \(outputIndex) — "
         + "\(capture.width)x\(capture.height) → \(outPath)")
    exit(0)
}

// RGB24 rather than ARGB32: a screenshot is opaque, and cairo would otherwise
// write an alpha channel that only invites premultiplication questions.
let ok = image.withUnsafeMutableBufferPointer { buf -> Bool in
    guard let surface = cairo_image_surface_create_for_data(
        buf.baseAddress, CAIRO_FORMAT_RGB24,
        Int32(capture.width), Int32(capture.height), Int32(cairoStride)),
        cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS
    else { return false }
    defer { cairo_surface_destroy(surface) }
    cairo_surface_mark_dirty(surface)
    return outPath.withCString { cairo_surface_write_to_png(surface, $0) }
        == CAIRO_STATUS_SUCCESS
}
guard ok else { die("could not write \(outPath)") }

emit(2, "abyssgrab: captured output \(outputIndex) — "
     + "\(capture.width)x\(capture.height) → \(outPath)")
