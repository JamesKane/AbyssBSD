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
//                          the default shell is desktop + menubar + dock.
//     --without NAME       drop one of the default components (repeatable).
//     --binary PATH        the shell binary for the default components
//                          (default: $ABYSS_APP_BINARY, else AquaDemo beside us).
//     --runtime-dir DIR    where the control socket lives ($ABYSS_RUNTIME_DIR).
//     --max-restarts N     consecutive failures tolerated per component (5).
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
var explicitComponents: [(String, String)] = []
var without: Set<String> = []
var binary = ProcessInfoEnv("ABYSS_APP_BINARY")
var runtimeDir = ProcessInfoEnv("ABYSS_RUNTIME_DIR")
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
    case "--binary":      binary = next("a path")
    case "--runtime-dir": runtimeDir = next("a directory")
    case "--max-restarts":
        guard let n = Int(next("a number")), n >= 0 else { fail("--max-restarts wants a number") }
        maxRestarts = n
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
        usage: anchor [--compositor CMD] [--display NAME] [--component NAME=CMD]
                      [--without NAME] [--binary PATH] [--runtime-dir DIR]
                      [--max-restarts N]
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
    // The default session, in stacking order: the desktop underneath, then the
    // menu bar, then the Dock — the same three `abyss/session.sh` runs.
    let scenes = [("desktop", "wallpaper"), ("menubar", "menubar"), ("dock", "dock")]
    guard access(shellBinary, X_OK) == 0 else {
        fail("no shell binary at \(shellBinary) (build it, or pass --binary)")
    }
    for (name, scene) in scenes where !without.contains(name) {
        var env = ["AQUA_SCENE": scene, "ABYSS_APP_BINARY": shellBinary]
        if let d = display { env["WAYLAND_DISPLAY"] = d }
        specs.append(ComponentSpec(name: name, argv: [shellBinary], env: env))
    }
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
