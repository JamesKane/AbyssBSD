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
//
// The chosen file's contents go to stdout — an already-open descriptor, since a
// sandboxed process cannot create a new one either.
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

var startDir: String?
var args = Array(CommandLine.arguments.dropFirst())
if let first = args.first {
    if first == "-h" || first == "--help" {
        emit(1, "usage: abyssopen [dir]")
        exit(0)
    }
    startDir = first
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

// ---- 3. Ask for a file. We name a directory at most; never a file. -----
var request = Msg()
request.set("method", "file.open")
if let d = startDir { request.set("dir", d) }
note("requested: dir=\(startDir ?? "(none)")")

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
let path = reply.string("path") ?? "(unnamed)"
note("portal: handed us \(path)")

guard let fd = reply.takeFD("file") else {
    die("the reply carried no descriptor")
}

// ---- 4. The control: prove we could NOT have opened it ourselves. ------
// Without this the demo is theatre — reading a file proves nothing unless the
// same path is demonstrably unopenable from in here.
let direct = open(path, O_RDONLY)
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

// ---- 5. Read the file through the capability we were given. ------------
var total = 0
var buf = [UInt8](repeating: 0, count: 4096)
while true {
    let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, 4096) }
    if n <= 0 { break }
    total += n
    _ = buf.withUnsafeBufferPointer { write(1, $0.baseAddress, n) }
}
close(fd)
note("read \(total) bytes through the descriptor the portal handed over")
