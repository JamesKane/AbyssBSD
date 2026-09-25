// abyss-dbus — the desktop's portal, on the session bus (PHASE8.md P8.2).
//
//   abyss-dbus [--portal SERVICE] [--seconds N] [--once]
//
// Owns `org.freedesktop.portal.Desktop` and answers
// `org.freedesktop.portal.FileChooser.OpenFile` / `SaveFile` by asking
// `abyss-portal` — the same portal, the same Finder, the same picker our own
// apps get. A stock GTK or Qt application talks to this and never learns there
// is anything unusual underneath.
//
// This is a **legacy adapter and nothing more**. It is the only process in the
// system that touches D-Bus; nothing on the frame path knows it exists, and if
// it dies the desktop carries on without a file dialog for foreign apps
// (PHASE8.md §6.3).

import CurrentIPC
import DBusPortal
import DBusMenus

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func die(_ s: String) -> Never { emit(2, "abyss-dbus: \(s)"); exit(1) }

var portal: String?
var seconds: Double = 0            // 0 = until killed
var once = false
// `--menus`: be the GTK menu bridge instead (PHASE10 P10.6) — a process of its
// own, because the portal half blocks while a file dialog is open.
var menus = false
let args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--portal":
        i += 1
        guard i < args.count else { die("--portal needs a service name") }
        portal = args[i]
    case "--seconds":
        i += 1
        guard i < args.count, let n = Double(args[i]) else { die("--seconds needs a number") }
        seconds = n
    case "--once":
        once = true
    case "--menus":
        menus = true
    case "-h", "--help":
        emit(1, "usage: abyss-dbus [--portal SERVICE] [--seconds N] [--once] | --menus")
        exit(0)
    default:
        die("unknown option '\(args[i])'")
    }
    i += 1
}

// A client that hangs up mid-reply must not kill us (HANDOFF §2.33).
signal(SIGPIPE, SIG_IGN)

let conn = DBusConnection()
do {
    try conn.connect()
} catch {
    die("cannot reach the session bus: \(error)"
        + " (is DBUS_SESSION_BUS_ADDRESS set, and is dbus-daemon running?)")
}

if menus {
    let bridge: GtkMenuBridge
    do { bridge = try GtkMenuBridge(connection: conn) } catch {
        die("cannot serve \(GtkMenuBridge.serviceName): \(error)")
    }
    emit(1, "ready (menus: \(GtkMenuBridge.serviceName))")
    while true {
        do { try bridge.step(timeoutMs: 1000) } catch {
            die("the bus connection failed: \(error)")
        }
    }
}

let service = DBusPortalService(connection: conn, portalService: portal)
do {
    try service.attach()
} catch {
    die("\(error)")
}

// stdout, so a supervisor or a test script can wait for the name rather than
// sleep and hope.
emit(1, "ready")

var ts = timespec()
clock_gettime(CLOCK_MONOTONIC, &ts)
let deadline = Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9 + seconds
while true {
    if seconds > 0 {
        clock_gettime(CLOCK_MONOTONIC, &ts)
        if Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9 >= deadline { break }
    }
    do {
        try service.step(timeoutMs: 200)
    } catch {
        die("the bus connection failed: \(error)")
    }
    if once && service.served > 0 { break }
}
emit(1, "done served=\(service.served)")
