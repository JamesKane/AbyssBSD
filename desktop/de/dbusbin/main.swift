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

/// Run `abyss-theme palette` (beside this binary) and return what it printed.
func runPalette() -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    #if os(Linux)
    let n = readlink("/proc/self/exe", &buf, buf.count - 1)
    guard n > 0 else { return nil }
    #else
    guard let a0 = CommandLine.arguments.first, a0.contains("/"), let rp = realpath(a0, &buf), rp[0] != 0 else { return nil }
    #endif
    let me = String(cString: buf)
    guard let slash = me.lastIndex(of: "/") else { return nil }
    let tool = String(me[..<slash]) + "/abyss-theme"
    guard access(tool, X_OK) == 0 else { return nil }
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return nil }
    // A struct on Linux, a pointer on FreeBSD.
    #if os(Linux)
    var fa = posix_spawn_file_actions_t()
    #else
    var fa: posix_spawn_file_actions_t? = nil
    #endif
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
    posix_spawn_file_actions_addclose(&fa, fds[0])
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(tool), strdup("palette"), nil]
    defer { for p in argv { free(p) }; posix_spawn_file_actions_destroy(&fa) }
    guard posix_spawn(&pid, tool, &fa, nil, argv, environ) == 0 else { close(fds[0]); close(fds[1]); return nil }
    close(fds[1])
    var out: [UInt8] = [], chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let r = read(fds[0], &chunk, chunk.count)
        if r <= 0 { break }
        out += chunk[0..<r]
    }
    close(fds[0])
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
}

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
    // Qt exports its menus only if this name is owned (P10.7).
    let registrar: AppMenuRegistrar
    do { registrar = try AppMenuRegistrar(connection: conn) } catch {
        die("cannot own \(AppMenuRegistrar.busName): \(error)")
    }
    emit(1, "ready (menus: \(GtkMenuBridge.serviceName))")
    withExtendedLifetime(registrar) {
        while true {
            do { try bridge.step(timeoutMs: 1000) } catch {
                die("the bus connection failed: \(error)")
            }
        }
    }
}

let service = DBusPortalService(connection: conn, portalService: portal)
// What a foreign toolkit is told (P11.10): the loaded theme's palette, from
// `abyss-theme palette` beside this binary — or Aqua's, and said so.
if let text = runPalette(), let s = PortalSettings.from(palette: text) {
    service.settings = s
    let name = text.split(separator: "\n").first { $0.hasPrefix("name = ") }.map { $0.dropFirst(7) } ?? "?"
    emit(2, "abyss-dbus: settings from the theme's palette (\(name))")
} else {
    emit(2, "abyss-dbus: no theme palette (abyss-theme not found or failed) — telling toolkits Aqua's")
}
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
