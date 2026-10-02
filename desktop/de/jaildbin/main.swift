// abyss-jaild — the root half of confinement (PHASE18 P18.2).
//
//   abyss-jaild [--socket PATH] [--classes FILE] [--pool NAME]
//               [--root-base DIR] [--home-base DIR] [--once]
//
// Root. Builds a person's jail of a class and hands them the owning
// descriptor; starts programs in it as them; removes the root when they let
// go. See de/jaild/Service.swift. `--root-base` and `--home-base` move the
// jails somewhere a test can see and remove; `--pool` keeps private homes in
// ZFS datasets (§6.3). FreeBSD only: Linux has no jails, and it says so.

import CurrentIPC
import JailD
import Jails
import PoolConfig

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}

func readFile(_ path: String) -> String? {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = read(fd, &buf, buf.count)
        if n < 0 { return nil }
        if n == 0 { break }
        out += buf[0..<n]
    }
    return String(decoding: out, as: UTF8.self)
}

var socketPath = JailWire.defaultSocket, classesFile: String?, pool: String?, once = false
var layout = JailLayout.standard
let args = Array(CommandLine.arguments.dropFirst())
var i = 0
@MainActor func value(_ flag: String) -> String {
    i += 1
    guard i < args.count else { emit(2, "abyss-jaild: \(flag) needs a value"); exit(2) }
    return args[i]
}
while i < args.count {
    switch args[i] {
    case "--socket": socketPath = value("--socket")
    case "--classes": classesFile = value("--classes")
    case "--pool": pool = value("--pool")
    case "--root-base": layout.rootBase = value("--root-base")
    case "--home-base": layout.homeBase = value("--home-base")
    case "--once": once = true
    case "-h", "--help":
        emit(1, "usage: abyss-jaild [--socket PATH] [--classes FILE] [--pool NAME] [--root-base DIR] [--home-base DIR] [--once]")
        exit(0)
    default:
        emit(2, "abyss-jaild: unknown option '\(args[i])'"); exit(2)
    }
    i += 1
}

#if !os(FreeBSD)
emit(2, "abyss-jaild: this platform has no jails — confinement is FreeBSD's")
exit(1)
#else
guard geteuid() == 0 else { emit(2, "abyss-jaild: must run as root: it mounts and creates jails"); exit(1) }

// The classes: the shipped ones, with a root-owned file's over them. A file
// anyone else could write is not read: what root mounts is not a user's call.
var classes = JailClass.shipped
if let f = classesFile {
    var st = stat()
    if stat(f, &st) == 0 {
        if st.st_uid != 0 || st.st_mode & 0o022 != 0 {
            emit(2, "abyss-jaild: \(f) is not root's alone (owner \(st.st_uid), mode \(String(st.st_mode & 0o777, radix: 8))) — ignored")
        } else if let text = readFile(f) {
            classes = JailClass.table(Config.parse(text))
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let server: Current.Server
// 0666: anyone may ask, for themselves; the kernel says who they are.
do { server = try Current.Server(path: socketPath, mode: 0o666) } catch {
    emit(2, "abyss-jaild: cannot bind \(socketPath): \(error)"); exit(1)
}
emit(2, "jaild: answering at \(socketPath); classes \(classes.map(\.name).joined(separator: ", ")); roots in \(layout.rootBase), homes in \(pool.map { "\($0)/abyss/jails" } ?? layout.homeBase)")
let daemon = JailService(server: server, layout: layout, classes: classes, pool: pool, log: { emit(2, $0) })
daemon.sweep()
daemon.run(once: once)
server.shutdownAndUnlink()
#endif
