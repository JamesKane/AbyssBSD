// dbusprobe — drive the DBus library against a real bus (PHASE8.md P8.1).
//
//   dbusprobe hello                  connect, authenticate, print our unique name
//   dbusprobe serve <name> [seconds] own <name> and answer Ping/Echo until told
//   dbusprobe portal-open <dir>      call FileChooser.OpenFile and await Response
//   dbusprobe portal-save <dir> <n>  ... SaveFile, suggesting the name <n>
//   dbusprobe portal-open-late <dir> ... but subscribe only AFTER the call
//
// The point of `serve` is that the CLIENT is GLib's `gdbus` — somebody
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

// The portal client — in two flavours, because the portal API has two ways to
// hang and only one of them is visible from each.
//
// `portal-open` / `portal-save` are the MODERN client: it derives the Request
// path from the spec's own words rather than from anything the server told it —
// "SENDER is the caller's unique name, with the initial ':' removed and all '.'
// replaced by '_', and TOKEN is the handle_token the caller provided" — then
// subscribes to that path **before** calling, and afterwards asserts the handle
// it was given is the one it predicted. Derive it differently on the server side
// and this match rule covers a path nothing is ever emitted on.
//
// `portal-open-late` is the OLD client, the one `handle_token` was added to the
// spec to rescue: it calls first, subscribes to whatever handle came back, and
// only then waits. It hangs if the server emits `Response` before its method
// return is on the wire — a different bug, invisible to the modern client, and
// the specific reason abyss-dbus queues the picker out of the method handler.
case "portal-open", "portal-save", "portal-open-late":
    guard args.count >= 2 else { die("\(mode) needs a directory") }
    let dir = args[1]
    let late = mode == "portal-open-late"
    let saveName = mode == "portal-save" ? (args.count >= 3 ? args[2] : "Untitled.txt") : nil

    let token = "abyssprobe1"
    var who = conn.uniqueName
    if who.hasPrefix(":") { who.removeFirst() }
    who = String(who.map { $0 == "." ? "_" : $0 })
    let expected = late ? "" : "/org/freedesktop/portal/desktop/request/\(who)/\(token)"
    if !late { out("expect-handle=\(expected)") }

    var watching = expected
    var response: UInt32?
    var uris: [String] = []
    conn.onMessage = { msg in
        guard msg.type == .signal, msg.interface == "org.freedesktop.portal.Request",
              msg.member == "Response", msg.path == watching else { return }
        guard case .uint32(let code)? = msg.body.first else { return }
        response = code
        guard msg.body.count >= 2, case .array(_, let entries) = msg.body[1] else { return }
        for entry in entries {
            guard case .dictEntry(.string("uris"), .variant(.array(_, let list))) = entry
            else { continue }
            for item in list { if case .string(let u) = item { uris.append(u) } }
        }
    }

    do {
        if !late {
            // BEFORE the call. This is the whole point of the mode.
            try conn.addMatch("type='signal',interface='org.freedesktop.portal.Request',"
                              + "member='Response',path='\(expected)'")
            out("subscribed")
        }

        // `current_folder` is `ay` and "expected to be terminated by a nul byte"
        // — a byte array, not a string, and the NUL is part of the value.
        let folder = DBusValue.array("y", Array(dir.utf8).map { DBusValue.byte($0) }
                                          + [DBusValue.byte(0)])
        // The old client sends no token; the server has to invent one, and the
        // only path this client can watch is the one it is handed back.
        var options: [(String, DBusValue)] = [("current_folder", folder)]
        if !late { options.insert(("handle_token", .string(token)), at: 0) }
        if let n = saveName { options.append(("current_name", .string(n))) }

        let reply = try conn.call(.methodCall(
            destination: "org.freedesktop.portal.Desktop",
            path: "/org/freedesktop/portal/desktop",
            interface: "org.freedesktop.portal.FileChooser",
            member: mode == "portal-save" ? "SaveFile" : "OpenFile",
            body: [.string(""), .string("Pick a file"), .options(options)]))
        guard case .objectPath(let handle)? = reply.body.first else {
            die("OpenFile returned no handle")
        }
        out("handle=\(handle)")
        if late {
            watching = handle
            try conn.addMatch("type='signal',interface='org.freedesktop.portal.Request',"
                              + "member='Response',path='\(handle)'")
            out("subscribed-after-the-call")
        } else {
            guard handle == expected else {
                die("the handle we were given (\(handle)) is not the one the spec says"
                    + " to expect (\(expected)) — a client that pre-subscribed would hang")
            }
            out("handle-matches-prediction")
        }
    } catch {
        die("\(error)")
    }

    // The picker is a human interaction; wait a generous while for it.
    var t = timespec(); clock_gettime(CLOCK_MONOTONIC, &t)
    let until = Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 + 90
    while response == nil {
        clock_gettime(CLOCK_MONOTONIC, &t)
        if Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 >= until {
            die("no Response signal arrived on \(watching) within 90s"
                + (late ? " — was it emitted before the method return reached us?" : ""))
        }
        do { try conn.readAndDispatch(timeoutMs: 200) } catch { die("\(error)") }
    }
    out("response=\(response!)")
    for u in uris { out("uri=\(u)") }
    exit(response! == 0 ? 0 : 2)

default:
    die("unknown mode '\(mode)'")
}
