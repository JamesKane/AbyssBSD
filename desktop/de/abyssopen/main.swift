// abyssopen — the point of the portal, demonstrated (PHASE7.md P7.3).
//
// This process enters **Capsicum capability mode** and therefore has no
// filesystem and no global namespace at all: it cannot `open` a path, cannot
// create a socket, cannot name any resource. It *then* asks the desktop to let
// the user pick a file. The portal runs the picker, opens the chosen file, and
// hands back the descriptor over SCM_RIGHTS — and this process reads a file it
// could not possibly have opened itself.
//
//     abyssopen [dir]      # pick a file (optionally suggesting a start dir)
//     abyssopen --screenshot
//
// The chosen file's contents go to stdout — an already-open descriptor, since a
// sandboxed process cannot create a new one either.
//
// `--screenshot` is the same claim with a sharper control (PHASE7.md P7.5).
// Capability mode forbids `socket(2)`, so this process cannot connect to the
// compositor — it could not capture the screen if it tried, and there is no
// path it could read a capture from either. It nonetheless ends up holding a
// PNG of the display. The portal named it nothing: the reply carries no path,
// and the file it came from was unlinked before the descriptor was sent.
//
// ORDER MATTERS, and it is the thing most likely to be got wrong (§6.4):
// capability mode forbids `socket(2)` and `connect(2)` as surely as it forbids
// `open(2)`. So the portal connection must be made **before** entering the
// sandbox, and is then the process's only capability apart from stdio. Enter
// first and the demo fails in a way that looks like a broken portal.

import CCapsicum
import CurrentIPC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func note(_ s: String) { emit(2, s) }
func die(_ s: String) -> Never { emit(2, "abyssopen: \(s)"); exit(1) }

// SOCK_STREAM imports as `__socket_type` on Linux and a plain Int32 on the BSDs
// (HANDOFF §2.32); one constant keeps the call site identical.
#if canImport(Glibc) && os(Linux)
let sockStream = Int32(SOCK_STREAM.rawValue)
#else
let sockStream = Int32(SOCK_STREAM)
#endif

/// Where the compositor is listening — resolved exactly as libwayland does, so
/// the control below tries the connection a screen capture would really need.
func compositorSocketPath() -> String {
    let name = getenv("WAYLAND_DISPLAY").map { String(cString: $0) } ?? "wayland-0"
    if name.hasPrefix("/") { return name }
    let runtime = getenv("XDG_RUNTIME_DIR").map { String(cString: $0) } ?? "/tmp"
    return runtime + "/" + name
}

var startDir: String?
var wantScreenshot = false
var args = Array(CommandLine.arguments.dropFirst())
if let first = args.first {
    switch first {
    case "-h", "--help":
        emit(1, "usage: abyssopen [dir] | abyssopen --screenshot")
        exit(0)
    case "--screenshot":
        wantScreenshot = true
    default:
        startDir = first
    }
}

// A peer that vanishes must not kill us with a signal (HANDOFF §2.33).
signal(SIGPIPE, SIG_IGN)

// ---- 1. Connect FIRST. After cap_enter there is no socket(2). ----------
let service = (getenv("ABYSS_PORTAL_SERVICE").map { String(cString: $0) }) ?? "portal"
let sock: Int32
do {
    sock = try Current.connect(service)
} catch {
    die("cannot reach the '\(service)' portal (is the desktop running?): \(error)")
}

// ---- 2. Drop into capability mode. No way back. ------------------------
if ap_sandbox_supported() != 0 {
    guard ap_sandbox_enter() == 0 else {
        die("cap_enter failed: \(String(cString: strerror(errno)))")
    }
    note("sandbox: capability mode entered — no filesystem, no namespace")
} else {
    // Say so plainly rather than implying a confinement we don't have.
    note("sandbox: NOT AVAILABLE on this platform (Capsicum is FreeBSD-only) —"
         + " running unsandboxed; the capability claim is only proven on FreeBSD")
}

// ---- 3. Ask. We name a directory at most; never a file, never a screen. -
var request = Msg()
if wantScreenshot {
    // Nothing accompanies it. There is nothing that *could*.
    request.set("method", "screenshot")
    note("requested: screenshot (no arguments — the request type has no room for any)")
} else {
    request.set("method", "file.open")
    if let d = startDir { request.set("dir", d) }
    note("requested: dir=\(startDir ?? "(none)")")
}

do {
    try Current.send(request, on: sock)
} catch {
    die("could not ask the portal: \(error)")
}

var reply: Msg
do {
    reply = try Current.receive(on: sock)
} catch {
    die("no reply from the portal: \(error)")
}
close(sock)

guard reply.bool("ok") == true else {
    let why = reply.string("error") ?? "unknown"
    note("portal: \(why)")
    exit(why == "cancelled" ? 2 : 1)
}
let path = reply.string("path")
if wantScreenshot {
    let w = reply.uint64("width") ?? 0, h = reply.uint64("height") ?? 0
    note("portal: handed us a \(w)x\(h) screenshot — and no path for it"
         + " (path in reply: \(path ?? "none"))")
} else {
    note("portal: handed us \(path ?? "(unnamed)")")
}

guard let fd = reply.takeFD("file") else {
    die("the reply carried no descriptor")
}

// ---- 4. The control: prove we could NOT have got this ourselves. -------
// Without this the demo is theatre.
if wantScreenshot {
    // A screenshot's control is not a path — the portal gave us none — it is the
    // compositor. To capture the screen ourselves we would have to connect to it.
    //
    // NOTE, because the first version of this got it wrong and FreeBSD said so:
    // **capability mode does not forbid `socket(2)`.** An unnamed socket reaches
    // no global namespace, so creating one is fine. What Capsicum forbids is
    // *naming an address* — `connect(2)` to a path — which is exactly what
    // talking to a Wayland compositor requires. So that is the call to try.
    let socketPath = compositorSocketPath()
    var reached = false
    // Why it did not happen, reported precisely — "connect failed" next to an
    // errno from some earlier call would be worse than saying nothing.
    var why = "the address does not fit in sun_path"
    let s = socket(AF_UNIX, sockStream, 0)
    if s < 0 {
        why = "socket(2): \(String(cString: strerror(errno)))"
    } else {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        if bytes.count < MemoryLayout.size(ofValue: addr.sun_path) {
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            reached = rc == 0
            if !reached { why = String(cString: strerror(errno)) }
        }
        close(s)
    }
    if reached {
        if ap_sandbox_active() == 1 {
            die("connect(2) to the compositor SUCCEEDED inside capability mode"
                + " — the sandbox is not real")
        }
        note("control: connect(2) to \(socketPath) succeeded"
             + " (expected: we are not sandboxed here)")
    } else {
        note("control: connect(2) to \(socketPath) failed — \(why)"
             + " — this process cannot reach the compositor to capture anything")
    }
} else {
    // Reading a file proves nothing unless the same path is demonstrably
    // unopenable from in here.
    let direct = open(path ?? "", O_RDONLY)
    if direct >= 0 {
        close(direct)
        if ap_sandbox_active() == 1 {
            die("open(2) SUCCEEDED inside capability mode — the sandbox is not real")
        }
        note("control: open(2) succeeded (expected: we are not sandboxed here)")
    } else {
        note("control: open(2) on that path failed — \(String(cString: strerror(errno)))"
             + " — this process cannot reach the file by name")
    }
}

// ---- 5. Read through the capability we were given. ---------------------
var total = 0
var head: [UInt8] = []
var buf = [UInt8](repeating: 0, count: 4096)
while true {
    let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, 4096) }
    if n <= 0 { break }
    if head.count < 24 { head += buf[0..<min(n, 24 - head.count)] }
    total += n
    _ = buf.withUnsafeBufferPointer { write(1, $0.baseAddress, n) }
}
close(fd)
note("read \(total) bytes through the descriptor the portal handed over")

// The client checks the bytes ITSELF rather than trusting the portal's word for
// what they are. Deliberately a second, independent read of the same 24 bytes
// `PNGHeader` parses portal-side: an independent check is the only kind worth
// anything, and it is why abyssopen does not link Portal to borrow the parser.
if wantScreenshot {
    let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard head.count >= 24, Array(head[0..<8]) == magic,
          Array(head[12..<16]) == Array("IHDR".utf8) else {
        die("what we were handed is not a PNG")
    }
    func be32(_ at: Int) -> Int {
        (Int(head[at]) << 24) | (Int(head[at + 1]) << 16)
            | (Int(head[at + 2]) << 8) | Int(head[at + 3])
    }
    note("verified: a real PNG, \(be32(16))x\(be32(20)), read through a"
         + " descriptor for a file with no name")
}
