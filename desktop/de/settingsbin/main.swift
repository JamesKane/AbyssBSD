// abyss-settings — System Preferences' privileged half (PHASE14 P14.3).
//
//   abyss-settings --uid N [--dry-run] [--once] [--service NAME]
//                  [--rc-conf PATH] [--resolvconf PATH] [--sysctl-conf PATH] [--journal PATH]
//                  [--admin-group NAME] [--write-only]
//
// Root, commanded by an unprivileged pane, as `abyss-install` is — and for the
// same reasons arranged the same way: no toolkit, no display, no event loop,
// one connection at a time, and nothing decided here that a plan did not say.
//
// `--uid` is the session's user; the socket is handed to that uid alone and the
// service asks the kernel who called, then whether they are an administrator
// (§6.1). `--rc-conf` and `--journal` are for tests that must not change the
// machine they run on; on an installed system they are the defaults.

import CurrentIPC
import SettingsRun

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}

var allowed: UInt32?
var dryRun = false, once = false
var serviceName = "settings", rcConf = "/etc/rc.conf", journal = "/var/log/abyss-settings.log"
var resolvconf = "/etc/resolvconf.conf", writeOnly = false, sysctlConf = "/etc/sysctl.conf"
var wpaConf = "/etc/wpa_supplicant.conf"
var adminGroup = "wheel"
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
@MainActor func value(_ flag: String) -> String {
    i += 1
    guard i < args.count else { emit(2, "abyss-settings: \(flag) needs a value"); exit(2) }
    return args[i]
}
while i < args.count {
    switch args[i] {
    case "--uid":
        guard let n = UInt32(value("--uid")) else { emit(2, "abyss-settings: --uid needs a number"); exit(2) }
        allowed = n
    case "--dry-run": dryRun = true
    case "--once": once = true
    case "--service": serviceName = value("--service")
    case "--rc-conf": rcConf = value("--rc-conf")
    case "--resolvconf": resolvconf = value("--resolvconf")
    case "--sysctl-conf": sysctlConf = value("--sysctl-conf")
    case "--wpa-conf": wpaConf = value("--wpa-conf")
    case "--write-only": writeOnly = true
    case "--journal": journal = value("--journal")
    case "--admin-group": adminGroup = value("--admin-group")
    case "-h", "--help":
        emit(1, "usage: abyss-settings --uid N [--dry-run] [--once] [--service NAME]"
             + " [--rc-conf PATH] [--resolvconf PATH] [--sysctl-conf PATH] [--wpa-conf PATH] [--journal PATH]"
             + " [--admin-group NAME] [--write-only]")
        exit(0)
    default:
        emit(2, "abyss-settings: unknown option '\(args[i])'"); exit(2)
    }
    i += 1
}
// **Nobody by default.** The installer admits its own uid when told nothing;
// this helper has no reason to exist except for a person's session, so it says
// whose, or it does not start.
guard let uid = allowed else {
    emit(2, "abyss-settings: --uid is required — whose session may change the machine?")
    exit(2)
}

signal(SIGPIPE, SIG_IGN)
let service = SettingsService(authority: Authority(allowed: uid, adminGroup: adminGroup),
                              dryRun: dryRun, rcConf: rcConf, resolvconf: resolvconf,
                              journal: journal, writeOnly: writeOnly, sysctlConf: sysctlConf,
                              wpaConf: wpaConf)
let server: Current.Server
do { server = try Current.Server(service: serviceName) } catch {
    emit(2, "abyss-settings: cannot bind the settings service: \(error)"); exit(1)
}
// The socket opens to exactly that uid; the peer check then confirms the
// caller is it, and an administrator (the installer's two locks, PHASE5 §4.4).
if uid != geteuid(), chown(server.path, uid_t(uid), gid_t(bitPattern: -1)) != 0 {
    emit(2, "abyss-settings: cannot hand \(server.path) to uid \(uid): \(String(cString: strerror(errno)))")
    exit(1)
}
emit(2, "settings: serving \(server.path) for uid \(uid), administrators in \(adminGroup)"
     + (dryRun ? " (dry run — nothing will be written)" : "")
     + (writeOnly ? " (write only — files are written, the machine is left as it is)" : "")
     + (service.platformRefusal.map { " — \($0)" } ?? "")
     + (geteuid() == 0 || dryRun || rcConf != "/etc/rc.conf" ? "" : " — NOT running as root"))

while true {
    guard let client = try? server.accept() else { continue }
    let note = service.serve(client) { emit(2, "settings: \($0)") }
    emit(2, "settings: \(note)")
    close(client)
    if once { break }
}
server.shutdownAndUnlink()
