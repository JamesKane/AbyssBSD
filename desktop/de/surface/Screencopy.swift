// Screencopy — wlr-screencopy-unstable-v1: ask the compositor to copy an
// output's contents into a buffer we supply (PHASE7.md P7.5).
//
// This is the protocol `grim` uses under every screenshot in docs/screenshots/,
// and using it is what lets the screenshot portal be an ordinary Wayland client
// rather than compositor code. (A Swift compositor — Phase 6 — will have to
// implement the server half, or the portal will need a compositor-owned path
// then; PHASE7.md §6.6.)
//
// The handshake, and why each step exists:
//
//   capture_output(overlay_cursor, output)  → a frame object
//   ← buffer(format, w, h, stride)          the buffer the compositor will take
//   ← linux_dmabuf(...)                     (v3; we don't do dmabuf)
//   ← buffer_done                           (v3) "that's all the types"
//   copy(buffer)                            our wl_shm buffer, exactly as asked
//   ← flags(y_invert)                       the copy may be bottom-up
//   ← ready(timestamp) | failed
//
// **The compositor dictates the buffer**, which is why `ShmBuffer` had to grow
// stride and format parameters: a screenshot is the one place in this codebase
// that cannot pick its own pixel layout.
//
// Capture is synchronous — it runs its own bounded pump loop rather than the
// Display run loop, so a one-shot grabber is a straight-line program and a
// compositor that never answers times out instead of hanging forever.

import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// zwlr_screencopy_frame_v1.flags.y_invert. Spelled out rather than reached
// through the imported C enum, whose Swift shape (struct? OptionSet? raw Int32?)
// varies with how the scanner declares it.
private let kScreencopyFlagYInvert: UInt32 = 1

/// A captured frame, normalised: tightly packed native-endian ARGB8888, rows
/// top-down, alpha forced opaque. That is `CAIRO_FORMAT_ARGB32`'s layout, so a
/// caller can hand `pixels` straight to cairo — the format zoo lives in here.
public struct ScreenCapture: Sendable {
    public let width: Int
    public let height: Int
    /// Bytes per row: always `width * 4` after normalisation.
    public var stride: Int { width * 4 }
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public enum ScreencopyError: Error, CustomStringConvertible {
    case unsupported                    // the compositor offers no screencopy
    case noOutput(Int)
    case failed(String)
    case timedOut
    case unsupportedFormat(UInt32)

    public var description: String {
        switch self {
        case .unsupported:
            return "the compositor does not offer wlr-screencopy"
        case .noOutput(let i):
            return "there is no output \(i) to capture"
        case .failed(let why):
            return why
        case .timedOut:
            return "the compositor never finished the copy"
        case .unsupportedFormat(let f):
            return "the compositor offered a pixel format we can't read (0x"
                + String(f, radix: 16) + ")"
        }
    }
}

/// The `wl_shm` / DRM fourcc formats we can normalise. wl_shm numbers ARGB8888
/// and XRGB8888 0 and 1; every other format *is* its DRM fourcc.
enum CapturedFormat: UInt32 {
    case argb8888 = 0
    case xrgb8888 = 1
    case abgr8888 = 0x3432_4241     // fourcc 'AB24'
    case xbgr8888 = 0x3432_4258     // fourcc 'XB24'
    /// **Three bytes a pixel, and what a GPU renderer hands you** (U.3):
    /// wlroots' GLES2 renderer offers screencopy `BG24`, and until this case
    /// existed every screenshot on a machine with a GPU failed — the harness
    /// runs pixman, which offers XRGB8888, so nothing here could see it.
    /// In memory `BG24` is R,G,B and `RG24` is B,G,R.
    case bgr888 = 0x3432_4742       // fourcc 'BG24'
    case rgb888 = 0x3432_4752       // fourcc 'RG24'

    /// Whether red and blue are the other way round from cairo's ARGB32.
    var swapsRedAndBlue: Bool { self == .abgr8888 || self == .xbgr8888 || self == .bgr888 }
    var bytesPerPixel: Int { self == .bgr888 || self == .rgb888 ? 3 : 4 }
}

/// Pixel normalisation, kept pure so it can be tested without a compositor.
///
/// Handles the three things a screencopy caller must not get wrong: the
/// compositor's stride is its own business (and is *not* `width * 4`), the copy
/// may be bottom-up (`y_invert`), and the channel order may be BGR.
public enum ScreenPixels {
    /// Convert a raw captured frame to tightly packed native-endian ARGB8888,
    /// top-down, opaque. Returns nil if `raw` is too small for the geometry or
    /// the format isn't one we read.
    public static func normalise(_ raw: [UInt8], format: UInt32,
                                 width: Int, height: Int, stride: Int,
                                 yInvert: Bool) -> [UInt8]? {
        guard let fmt = CapturedFormat(rawValue: format),
              width > 0, height > 0, stride >= width * fmt.bytesPerPixel,
              raw.count >= stride * height
        else { return nil }
        let bpp = fmt.bytesPerPixel

        let outStride = width * 4
        var out = [UInt8](repeating: 0, count: outStride * height)
        let swap = fmt.swapsRedAndBlue
        for y in 0..<height {
            // y_invert means the compositor wrote the bottom row first.
            let src = (yInvert ? (height - 1 - y) : y) * stride
            let dst = y * outStride
            for x in 0..<width {
                let s = src + x * bpp, d = dst + x * 4
                // In memory a little-endian ARGB8888 pixel is B,G,R,A — which
                // is cairo's ARGB32 byte order too, so the common case is a
                // straight copy.
                out[d + 0] = raw[swap ? s + 2 : s + 0]
                out[d + 1] = raw[s + 1]
                out[d + 2] = raw[swap ? s + 0 : s + 2]
                // The X formats carry no alpha at all, and a compositor is free
                // to leave that byte as garbage even in the A formats. A
                // screenshot is opaque by definition, so say so — otherwise the
                // PNG comes out mysteriously transparent.
                out[d + 3] = 0xFF
            }
        }
        return out
    }
}

/// The in-flight state of one `capture_output`, owned across the callbacks.
private final class CaptureSession {
    var format: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var stride: UInt32 = 0
    var haveBuffer = false
    var bufferDone = false
    var yInvert = false
    var ready = false
    var failure: String?

    var settled: Bool { ready || failure != nil }
}

public extension Display {
    /// Whether the compositor offers wlr-screencopy.
    var canCaptureScreen: Bool { screencopy != nil }

    /// Capture output `index` (registry order). Blocks until the compositor
    /// finishes the copy, or `timeoutMs` elapses.
    ///
    /// `overlayCursor` composites the pointer into the frame; a portal
    /// screenshot leaves it off, because under a headless test compositor there
    /// is no cursor and a real one shouldn't appear in a document.
    func captureOutput(_ index: Int = 0, overlayCursor: Bool = false,
                       timeoutMs: Int = 5000) throws -> ScreenCapture {
        guard let manager = screencopy else { throw ScreencopyError.unsupported }
        guard let output = output(at: index) else { throw ScreencopyError.noOutput(index) }

        // A frame is a PER-REQUEST object, unlike every other proxy in this
        // module — so its listener must not go into `Display.listenerStorage`,
        // which is only freed when the connection is. A process that captured
        // once a second would grow that array forever. It is allocated here and
        // freed here instead, and the ordering is the load-bearing part:
        //
        // `defer` runs in reverse, so declaring the allocation BEFORE the frame
        // means the frame is destroyed FIRST and the listener freed after. Get
        // that backwards and libwayland is left holding a pointer into freed
        // memory — HANDOFF §2.2, and the exact shape of the §2.35 crash.
        let listener = UnsafeMutablePointer<zwlr_screencopy_frame_v1_listener>
            .allocate(capacity: 1)
        defer { listener.deinitialize(count: 1); listener.deallocate() }

        guard let frame = opt(aw_screencopy_capture_output(
            raw(manager), overlayCursor ? 1 : 0, raw(output)))
        else { throw ScreencopyError.failed("the compositor refused to open a frame") }
        defer { aw_screencopy_frame_destroy(raw(frame)) }

        // Passed unretained: `session` is a strong local for the whole function,
        // and the frame is destroyed before it returns — so the owner outlives
        // the proxy, which is when §2.2 says not to retain.
        let session = CaptureSession()

        // Bound at v3, so every one of the seven events needs a slot — a NULL
        // one aborts the client the moment it's dispatched (HANDOFF §2.3).
        var fl = zwlr_screencopy_frame_v1_listener()
        fl.buffer = { data, _, format, width, height, stride in
            guard let data else { return }
            let s = Unmanaged<CaptureSession>.fromOpaque(data).takeUnretainedValue()
            s.format = format; s.width = width; s.height = height; s.stride = stride
            s.haveBuffer = true
        }
        fl.linux_dmabuf = { _, _, _, _, _ in }      // we only do wl_shm
        fl.buffer_done = { data, _ in
            guard let data else { return }
            Unmanaged<CaptureSession>.fromOpaque(data).takeUnretainedValue().bufferDone = true
        }
        fl.flags = { data, _, flags in
            guard let data else { return }
            let s = Unmanaged<CaptureSession>.fromOpaque(data).takeUnretainedValue()
            s.yInvert = flags & kScreencopyFlagYInvert != 0
        }
        fl.damage = { _, _, _, _, _, _ in }         // only sent for copy_with_damage
        fl.ready = { data, _, _, _, _ in
            guard let data else { return }
            Unmanaged<CaptureSession>.fromOpaque(data).takeUnretainedValue().ready = true
        }
        fl.failed = { data, _ in
            guard let data else { return }
            Unmanaged<CaptureSession>.fromOpaque(data).takeUnretainedValue()
                .failure = "the compositor could not copy that output"
        }
        listener.initialize(to: fl)
        _ = aw_add_listener(raw(frame), UnsafeRawPointer(listener),
                            Unmanaged.passUnretained(session).toOpaque())

        // 1. Wait to be told which buffer to make. Below v3 there is no
        //    buffer_done and the wl_shm `buffer` event is guaranteed, so it is
        //    itself the signal to proceed.
        let wantsBufferDone = screencopyVersion >= 3
        let described = { wantsBufferDone ? session.bufferDone : session.haveBuffer }
        guard pump(until: { described() || session.settled }, timeoutMs: timeoutMs) else {
            throw ScreencopyError.timedOut
        }
        if let why = session.failure { throw ScreencopyError.failed(why) }
        guard session.haveBuffer else {
            throw ScreencopyError.failed("the compositor offered no wl_shm buffer")
        }
        guard CapturedFormat(rawValue: session.format) != nil else {
            throw ScreencopyError.unsupportedFormat(session.format)
        }

        // 2. Make exactly the buffer it asked for and hand it over.
        guard let buffer = ShmBuffer(display: self,
                                     width: Int32(session.width),
                                     height: Int32(session.height),
                                     stride: Int32(session.stride),
                                     format: session.format)
        else { throw ScreencopyError.failed("could not allocate the capture buffer") }
        defer { buffer.destroy() }
        aw_screencopy_frame_copy(raw(frame), raw(buffer.wlBuffer))

        // 3. Wait for the copy.
        guard pump(until: { session.settled }, timeoutMs: timeoutMs) else {
            throw ScreencopyError.timedOut
        }
        if let why = session.failure { throw ScreencopyError.failed(why) }

        let rawPixels = [UInt8](UnsafeRawBufferPointer(start: buffer.data,
                                                       count: buffer.length))
        guard let pixels = ScreenPixels.normalise(
            rawPixels, format: session.format,
            width: Int(session.width), height: Int(session.height),
            stride: Int(session.stride), yInvert: session.yInvert)
        else { throw ScreencopyError.unsupportedFormat(session.format) }

        return ScreenCapture(width: Int(session.width), height: Int(session.height),
                             pixels: pixels)
    }

    /// Dispatch until `done` or the deadline. The same prepare_read / poll /
    /// read_events discipline as `run()` (HANDOFF §2.14) — including that a
    /// successful `prepare_read` must always be resolved, or the next iteration
    /// deadlocks — but bounded, and without touching the caller's run loop.
    func pump(until done: () -> Bool, timeoutMs: Int) -> Bool {
        pumpWayland(display, until: done, timeoutMs: timeoutMs)
    }
}

/// `Display.pump`, for any connection — DisplayConfigurator has its own.
func pumpWayland(_ display: OpaquePointer, until done: () -> Bool, timeoutMs: Int) -> Bool {
    let wlfd = wl_display_get_fd(display)
    let deadline = monoMs() + Int64(timeoutMs)
    while !done() {
        while wl_display_prepare_read(display) != 0 {
            if wl_display_dispatch_pending(display) == -1 { return false }
            if done() { return true }
        }
        wl_display_flush(display)
        let remaining = deadline - monoMs()
        if remaining <= 0 { wl_display_cancel_read(display); return false }

        var pfd = pollfd(fd: wlfd, events: Int16(POLLIN), revents: 0)
        let pr = withUnsafeMutablePointer(to: &pfd) {
            poll($0, 1, Int32(min(remaining, Int64(Int32.max))))
        }
        if pr > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
            if wl_display_read_events(display) == -1 { return false }
            if wl_display_dispatch_pending(display) == -1 { return false }
        } else {
            wl_display_cancel_read(display)
            if pr == 0 { return false }      // the deadline, not a signal
        }
    }
    return true
}

func monoMs() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
}
