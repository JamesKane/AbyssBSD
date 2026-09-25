// anchor — the AbyssBSD session supervisor.
//
// Starts a compositor (or attaches to a running one), brings the shell up
// against it, keeps the components alive, and tears the session down as a unit.
// The Swift replacement for `abyss/session.sh`; see `de/anchor/` for the logic
// and PHASE3.md P3.6 for the reasoning.
//
// Usage:
//   anchor [options]
//     --compositor CMD     start CMD as the compositor (absolute path). Without
//                          this, attach to $WAYLAND_DISPLAY instead.
//     --display NAME       the Wayland socket to point components at
//                          (default: $WAYLAND_DISPLAY).
//     --component NAME=CMD supervise CMD as NAME (repeatable). Without any,
//                          the default session is started (see below).
//     --without NAME       drop one of the default components (repeatable).
//     --binary PATH        the shell binary for the default components
//                          (default: $ABYSS_APP_BINARY, else AquaDemo beside us).
//     --runtime-dir DIR    where the control socket lives ($ABYSS_RUNTIME_DIR).
//     --dbus-config PATH   dbus-daemon config for the session bus (default:
//                          --session, the system's own).
//     --max-restarts N     consecutive failures tolerated per component (5).
//
// The default session is **bus, portal, bridge, desktop, menubar, dock** — see
// `de/anchor/Session.swift` for the ordering and why it is that one. The point
// of the first three is that one command boots a desktop where a *foreign* app
// — a stock GTK program that has never heard of us — can open a file through
// the Finder (PHASE8.md P8.4).
//
// The session is controlled with `abyssctl status|quit`.

import Anchor
import CurrentIPC
import CPlatform

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func fail(_ msg: String) -> Never {
    let s = "anchor: \(msg)\n"
    let b = Array(s.utf8)
    _ = b.withUnsafeBufferPointer { write(2, $0.baseAddress, b.count) }
    exit(2)
}

/// This binary's directory, so the default components can find AquaDemo beside
/// it without a PATH search.
func selfDirectory() -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = buf.withUnsafeMutableBufferPointer { ap_self_executable($0.baseAddress!, $0.count) }
    guard n > 0 else { return nil }
    let path = String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    guard let slash = path.lastIndex(of: "/") else { return nil }
    return String(path[path.startIndex..<slash])
}

var compositorCmd: String?
var display = ProcessInfoEnv("WAYLAND_DISPLAY")
var menubarDisplay: String? = nil
var explicitComponents: [(String, String)] = []
var mode: SessionMode = .desktop
var without: Set<String> = []
var binary = ProcessInfoEnv("ABYSS_APP_BINARY")
var runtimeDir = ProcessInfoEnv("ABYSS_RUNTIME_DIR")
var dbusConfig: String?
var maxRestarts = 5

func ProcessInfoEnv(_ k: String) -> String? {
    guard let v = getenv(k), v.pointee != 0 else { return nil }
    return String(cString: v)
}

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let a = args[i]
    func next(_ what: String) -> String {
        i += 1
        guard i < args.count else { fail("\(a) needs \(what)") }
        return args[i]
    }
    switch a {
    case "--compositor":  compositorCmd = next("a command")
    case "--display":     display = next("a socket name")
    case "--menubar-display": menubarDisplay = next("a socket name")
    case "--binary":      binary = next("a path")
    case "--runtime-dir": runtimeDir = next("a directory")
    case "--dbus-config": dbusConfig = next("a path")
    case "--max-restarts":
        guard let n = Int(next("a number")), n >= 0 else { fail("--max-restarts wants a number") }
        maxRestarts = n
    case "--mode":
        let m = next("desktop or installer")
        guard let parsed = SessionMode(rawValue: m) else {
            fail("--mode is desktop or installer, not '\(m)'")
        }
        mode = parsed
    case "--without":     without.insert(next("a component name"))
    case "--component":
        let spec = next("NAME=COMMAND")
        guard let eq = spec.firstIndex(of: "="), eq != spec.startIndex else {
            fail("--component wants NAME=COMMAND, got '\(spec)'")
        }
        explicitComponents.append((String(spec[spec.startIndex..<eq]),
                                   String(spec[spec.index(after: eq)...])))
    case "-h", "--help":
        let usage = """
        usage: anchor [--compositor CMD] [--display NAME] [--menubar-display NAME]
                      [--component NAME=CMD]
                      [--without NAME] [--binary PATH] [--runtime-dir DIR]
                      [--dbus-config PATH] [--max-restarts N]
        the default session: bus, portal, bridge, desktop, menubar, dock
        control it with: abyssctl status | abyssctl quit

        """
        let b = Array(usage.utf8)
        _ = b.withUnsafeBufferPointer { write(1, $0.baseAddress, b.count) }
        exit(0)
    default:
        fail("unknown option '\(a)'")
    }
    i += 1
}

// One `current` namespace for the whole session: every component's sockets and
// anchor's own control socket land in the same directory, and children inherit
// it because it is set before they are spawned.
if let dir = runtimeDir {
    setenv("ABYSS_RUNTIME_DIR", dir, 1)
}

// Resolve the shell binary once, here, so a child never has to search $PATH
// after forking.
let shellBinary: String = binary ?? {
    guard let dir = selfDirectory() else {
        fail("cannot find my own directory — pass --binary or set ABYSS_APP_BINARY")
    }
    return dir + "/AquaDemo"
}()

var specs: [ComponentSpec] = []
if explicitComponents.isEmpty {
    guard access(shellBinary, X_OK) == 0 else {
        fail("no shell binary at \(shellBinary) (build it, or pass --binary)")
    }
    guard let dir = try? Current.runtimeDir() else {
        fail("no runtime directory — pass --runtime-dir or set ABYSS_RUNTIME_DIR")
    }
    // Where our own services live: beside this binary, the same rule the shell
    // binary follows, so a build tree and an installed tree both work with no
    // configuration.
    let serviceDir = selfDirectory() ?? "."
    // `dbus-daemon` is somebody else's program, so it is looked up on $PATH —
    // and resolved HERE, in the parent, because a forked child may not go
    // searching (HANDOFF §2.25). A box without one still gets a desktop; it
    // just gets one with no bus, and `plan.notes` says so out loud.
    let dbusDaemon = resolveExecutable("dbus-daemon")

    // Where the compositor's socket will be, when that is knowable: a bare
    // `WAYLAND_DISPLAY` is a name under $XDG_RUNTIME_DIR, and an absolute one is
    // the path itself. Unknowable (no display, or no runtime dir on a FreeBSD
    // box where nothing sets one — HANDOFF §2.31) means no gate rather than a
    // guess.
    func socketPath(_ d: String) -> String? {
        if d.hasPrefix("/") { return d }
        guard let x = ProcessInfoEnv("XDG_RUNTIME_DIR"), !x.isEmpty else { return nil }
        return x + "/" + d
    }
    let compositorSocket: String? = display.flatMap(socketPath)

    let plan = defaultSession(shellBinary: shellBinary,
                              serviceDirectory: serviceDir,
                              dbusDaemon: dbusDaemon,
                              dbusConfig: dbusConfig,
                              runtimeDir: dir,
                              display: display,
                              compositorSocket: compositorSocket,
                              menubarDisplay: menubarDisplay,
                              menubarSocket: menubarDisplay.flatMap(socketPath),
                              mode: mode,
                              without: without)
    // Exported before anything is spawned, so **every** child inherits it —
    // including the applications the shell itself launches later, which is the
    // whole reason the bus comes first (de/anchor/Session.swift).
    if let addr = plan.busAddress {
        setenv("DBUS_SESSION_BUS_ADDRESS", addr, 1)
    }
    for note in plan.notes {
        let b = Array("anchor: \(note)\n".utf8)
        _ = b.withUnsafeBufferPointer { write(2, $0.baseAddress, b.count) }
    }
    specs = plan.components
} else {
    for (name, cmd) in explicitComponents where !without.contains(name) {
        let argv = splitCommand(cmd)
        guard !argv.isEmpty else { fail("component '\(name)' has an empty command") }
        var env: [String: String] = [:]
        if let d = display { env["WAYLAND_DISPLAY"] = d }
        specs.append(ComponentSpec(name: name, argv: argv, env: env))
    }
}
guard !specs.isEmpty else { fail("nothing to supervise") }

var compositorSpec: ComponentSpec?
if let cmd = compositorCmd {
    let argv = splitCommand(cmd)
    guard !argv.isEmpty else { fail("--compositor has an empty command") }
    compositorSpec = ComponentSpec(name: "compositor", argv: argv)
} else if display == nil {
    fail("no --compositor and no $WAYLAND_DISPLAY — nothing to run against")
}

let supervisor = Supervisor(
    compositor: compositorSpec,
    components: specs,
    policy: RestartPolicy(maxConsecutiveFailures: maxRestarts))
exit(supervisor.run())
