// dbusprobe — drive the DBus library against a real bus (PHASE8.md P8.1).
//
//   dbusprobe hello                  connect, authenticate, print our unique name
//   dbusprobe serve <name> [seconds] own <name> and answer Ping/Echo until told
//
// The point of `serve` is that the CLIENT is `dbus-send` or `gdbus` — somebody
// else's encoder. A marshaller tested only against its own parser round-trips
// beautifully and is still wrong (HANDOFF §2.37).

import DBus

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
func die(_ s: String) -> Never { emit(2, "dbusprobe: \(s)"); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { die("usage: dbusprobe hello|serve <name> [seconds]") }

let conn = DBusConnection()
do { try conn.connect() } catch { die("\(error)") }

switch mode {
case "hello":
    out("unique-name=\(conn.uniqueName)")

case "serve":
    guard args.count >= 2 else { die("serve needs a bus name") }
    let name = args[1]
    let seconds = args.count >= 3 ? (Double(args[2]) ?? 5.0) : 5.0
    do {
        let code = try conn.requestName(name)
        // 1 == PRIMARY_OWNER. Anything else means somebody else has the name,
        // and a portal that is not the primary owner is a portal nobody calls.
        guard code == 1 else { die("could not own \(name): RequestName returned \(code)") }
    } catch { die("\(error)") }
    out("owning=\(name)")

    conn.handle("org.abyssbsd.Probe", "Ping") { call in
        .methodReturn(to: call, body: [.string("pong")])
    }
    // Echo takes every type the portal API actually uses, so a real client's
    // encoder exercises our reader rather than our own writer doing both jobs.
    conn.handle("org.abyssbsd.Probe", "Echo") { call in
        .methodReturn(to: call, body: call.body)
    }
    conn.handle("org.freedesktop.DBus.Introspectable", "Introspect") { call in
        .methodReturn(to: call, body: [.string("""
        <node><interface name="org.abyssbsd.Probe">\
        <method name="Ping"><arg type="s" direction="out"/></method>\
        <method name="Echo"><arg type="v" direction="in"/>\
        <arg type="v" direction="out"/></method></interface></node>
        """)])
    }
    out("ready")

    var ts = timespec(); clock_gettime(CLOCK_MONOTONIC, &ts)
    let deadline = Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9 + seconds
    while true {
        clock_gettime(CLOCK_MONOTONIC, &ts)
        if Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9 >= deadline { break }
        do { try conn.readAndDispatch(timeoutMs: 200) } catch { die("\(error)") }
    }
    out("done")

default:
    die("unknown mode '\(mode)'")
}
