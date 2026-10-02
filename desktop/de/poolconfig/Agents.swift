// Agents, on or off (PHASE18 P18.13).
//
// **Off is one file — absent** (PRODUCT §10; decided 2026-10-02). Without
// `agents.ini` in the config directory there is no Agent menu item, no chord,
// no spend indicator, no Ask the Agent on a crash, no Agent tile, and the
// keeper starts no agent process: the rest of the desktop does not know the
// difference. Everything that would show an agent asks this first.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Agents {
    public static let file = "agents.ini"

    /// Whether agents are on: `agents.ini` exists in `dir` (the config dir).
    public static func on(configDir dir: String? = nil) -> Bool {
        guard let d = dir ?? (try? Pool.configDir()) else { return false }
        return access(d + "/" + file, F_OK) == 0
    }

    /// Turn them on (write the file) or off (remove it). Nil, or why not.
    public static func set(_ on: Bool, configDir dir: String? = nil) -> String? {
        guard let d = dir ?? (try? Pool.configDir()) else { return "no config directory" }
        let path = d + "/" + file
        if !on { return unlink(path) == 0 || errno == ENOENT ? nil : String(cString: strerror(errno)) }
        _ = mkdir(d, 0o700)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd < 0 { return errno == EEXIST ? nil : String(cString: strerror(errno)) }
        let text = "# Agents are on while this file exists (PHASE18 P18.13).\n# Remove it, or turn them off in System Preferences ▸ Agents, and there are none.\n[agents]\n"
        _ = Array(text.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        return nil
    }
}
