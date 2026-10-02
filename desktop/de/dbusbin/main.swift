// abyss-dbus — the desktop's portal, on the session bus (PHASE8.md P8.2).
//
//   abyss-dbus [--portal SERVICE] [--seconds N] [--once]
//              [--bus ADDRESS --jail NAME [--jaild SOCKET]]
//   abyss-dbus --endpoint --listen PATH --services PATH
//
// `--endpoint` is ADE's D-Bus bridge itself (BACKLOG D.1, PRODUCT §5.6):
// applications connect at `--listen` (what DBUS_SESSION_BUS_ADDRESS names),
// ADE's services — this program's portal and menu modes — at `--services`,
// and messages go between the two kinds and never within one. There is no
// bus: no application reaches another through it.
//
// With `--jail` it is a jail's portal (PHASE18 P18.4): on that jail's own bus
// (`--bus`), and a chosen file is granted into the jail by abyss-jaild and
// answered by the path it has there.
//
// Owns `org.freedesktop.portal.Desktop` and answers
// `org.freedesktop.portal.FileChooser.OpenFile` / `SaveFile` by asking
// `abyss-portal` — the same portal, the same Finder, the same picker our own
// apps get. A stock GTK application talks to this and never learns there
// is anything unusual underneath.
//
// This is a **legacy adapter and nothing more**. It is the only process in the
// system that touches D-Bus; nothing on the frame path knows it exists, and if
// it dies the desktop carries on without a file dialog for foreign apps
// (PHASE8.md §6.3).

import CurrentIPC
import DBusPortal
import DBusBridge
import DBusMenus
import JailD
import PoolConfig
import Spawn

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
    // `Spawn.run` (S.3): the per-platform posix_spawn file-actions type lives
    // there now, once. stderr stays ours, as it always did.
    let r = Spawn.run([tool, "palette"], stderr: .inherit)
    return r.stdout.isEmpty ? nil : r.stdoutText
}

var portal: String?
var seconds: Double = 0            // 0 = until killed
var once = false
// `--menus`: be the GTK menu bridge instead (PHASE10 P10.6) — a process of its
// own, because the portal half blocks while a file dialog is open.
var menus = false
var busAddress: String?, jailName: String?, jaildSocket = JailWire.defaultSocket
var endpoint = false, listenPath: String?, servicesPath: String?
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
    case "--endpoint":
        endpoint = true
    case "--listen":
        i += 1
        guard i < args.count else { die("--listen needs a socket path") }
        listenPath = args[i]
    case "--services":
        i += 1
        guard i < args.count else { die("--services needs a socket path") }
        servicesPath = args[i]
    case "--bus":
        i += 1
        guard i < args.count else { die("--bus needs an address") }
        busAddress = args[i]
    case "--jail":
        i += 1
        guard i < args.count else { die("--jail needs a jail's name") }
        jailName = args[i]
    case "--jaild":
        i += 1
        guard i < args.count else { die("--jaild needs a socket path") }
        jaildSocket = args[i]
    case "-h", "--help":
        emit(1, "usage: abyss-dbus [--portal SERVICE] [--seconds N] [--once] [--bus ADDRESS --jail NAME [--jaild SOCKET]] | --menus")
        exit(0)
    default:
        die("unknown option '\(args[i])'")
    }
    i += 1
}

// A client that hangs up mid-reply must not kill us (HANDOFF §2.33).
signal(SIGPIPE, SIG_IGN)
if endpoint {
    guard let listen = listenPath, let services = servicesPath else { die("--endpoint needs --listen and --services") }
    let bridge = BridgeEndpoint(log: { emit(2, $0) })
    do {
        try bridge.listen(services, kind: .service)
        try bridge.listen(listen, kind: .application)
    } catch { die("cannot listen: \(error)") }
    emit(1, "ready (endpoint: applications at \(listen), ADE's services at \(services))")
    bridge.run()
    bridge.shutdown()
    exit(0)
}

let conn = DBusConnection()
do {
    try conn.connect(address: busAddress)
} catch {
    die("cannot reach ADE's D-Bus bridge: \(error)"
        + " (is DBUS_SESSION_BUS_ADDRESS set, and is `abyss-dbus --endpoint` running?)")
}

if menus {
    let bridge: GtkMenuBridge
    do { bridge = try GtkMenuBridge(connection: conn) } catch {
        die("cannot serve \(GtkMenuBridge.serviceName): \(error)")
    }
    // What it watches and what it pushes (P10.9), for the log a test reads.
    bridge.log = { emit(1, "menus-dbus: \($0)") }
    emit(1, "ready (menus: \(GtkMenuBridge.serviceName))")
    while true {
        do { try bridge.step(timeoutMs: 1000) } catch {
            die("the bus connection failed: \(error)")
        }
    }
}

let service = DBusPortalService(connection: conn, portalService: portal)
if let jail = jailName {
    let socket = jaildSocket
    service.grant = { path, fd in
        do { return try JailClient.grant(jail: jail, path: path, file: fd, socket: socket).inside } catch {
            emit(2, "abyss-dbus: \(jail): \(error)")
            return nil
        }
    }
    emit(2, "abyss-dbus: the portal of \(jail): chosen files are granted into it")
}
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

// **Follow the theme** (P14.2): the config directory, drained on every pass of
// the loop below — which wakes at least every 200 ms — and the palette asked
// again when anything in it changed. `update` tells every listening toolkit
// what differs, with SettingChanged; a change to some other file finds nothing
// different and says nothing.
let appearance = try? Pool.Watcher()
@MainActor func followTheme() {
    guard let w = appearance, w.drain() else { return }
    guard let text = runPalette(), let s = PortalSettings.from(palette: text) else { return }
    let n = service.update(settings: s)
    guard n > 0 else { return }
    let name = text.split(separator: "\n").first { $0.hasPrefix("name = ") }.map { $0.dropFirst(7) } ?? "?"
    emit(2, "abyss-dbus: the theme changed (\(name)) — \(n) setting\(n == 1 ? "" : "s") changed")
}

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
    followTheme()
    if once && service.served > 0 { break }
}
emit(1, "done served=\(service.served)")
