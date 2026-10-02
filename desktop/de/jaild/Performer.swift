// JailPerformer — carries steps out, as root (PHASE18 P18.2).
//
// It decides nothing: the steps are `JailSteps`', and the first one that fails
// stops the run with its reason. What it did is returned either way, so the
// service can undo a half-built root with the same teardown as a whole one.

import CJail
import Spawn

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct JailPerformer {
    public var commands: JailCommands
    public var log: (String) -> Void

    public init(commands: JailCommands = JailCommands(), log: @escaping (String) -> Void) {
        self.commands = commands
        self.log = log
    }

    public struct Failure: Error, CustomStringConvertible {
        public let step: JailStep
        public let why: String
        public var description: String { "\(step): \(why)" }
    }

    /// Perform `steps` in order; throw at the first that fails.
    public func perform(_ steps: [JailStep]) throws {
        for step in steps {
            if let why = perform(step) { throw Failure(step: step, why: why) }
        }
    }

    /// Perform every step, failures and all, and return the failures —
    /// teardown, which must get as far as it can.
    @discardableResult
    public func performAll(_ steps: [JailStep]) -> [Failure] {
        steps.compactMap { s in perform(s).map { Failure(step: s, why: $0) } }
    }

    /// One step; nil when it worked, the reason when not.
    func perform(_ step: JailStep) -> String? {
        switch step {
        case let .mkdir(path, uid, gid, mode):
            if let why = mkdirs(path) { return why }
            if chown(path, uid_t(uid), gid_t(gid)) != 0 { return "chown: \(errText())" }
            if chmod(path, mode_t(mode)) != 0 { return "chmod: \(errText())" }
            return nil
        case let .dataset(name, mountpoint):
            if Spawn.run([commands.zfs, "list", "-H", "-o", "name", name], stderr: .merge).succeeded { return nil }
            return run([commands.zfs, "create", "-p", "-o", "mountpoint=\(mountpoint)", name])
        case let .run(argv):
            return run(argv)
        case let .write(path, contents, mode):
            return write(path, Array(contents.utf8), mode: mode)
        case let .copyIfPresent(source, target):
            let fd = open(source, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return errno == ENOENT ? nil : "\(source): \(errText())" }
            var bytes: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                bytes += buf[0..<n]
            }
            close(fd)
            return write(target, bytes, mode: 0o644)
        case let .remove(path):
            return unlink(path) == 0 || errno == ENOENT ? nil : "unlink: \(errText())"
        case let .rmdir(path):
            return rmdir(path) == 0 || errno == ENOENT ? nil : "rmdir: \(errText())"
        }
    }

    func run(_ argv: [String]) -> String? {
        let r = Spawn.run(argv, stderr: .merge, limit: 4096)
        if r.succeeded { return nil }
        let said = r.stdoutText.split(separator: "\n").last.map(String.init) ?? ""
        return "\(argv.joined(separator: " ")) exited \(r.code)\(said.isEmpty ? "" : ": \(said)")"
    }

    func mkdirs(_ path: String) -> String? {
        var made = ""
        for part in path.split(separator: "/") {
            made += "/" + part
            if mkdir(made, 0o755) != 0 && errno != EEXIST { return "mkdir \(made): \(errText())" }
        }
        return nil
    }

    func write(_ path: String, _ bytes: [UInt8], mode: UInt16) -> String? {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, mode_t(mode))
        guard fd >= 0 else { return "\(path): \(errText())" }
        defer { close(fd) }
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBufferPointer { Glibc_write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return "\(path): \(errText())" }
            off += n
        }
        return fchmod(fd, mode_t(mode)) == 0 ? nil : "\(path): \(errText())"
    }

    /// The host's mount points, as the kernel has them (`getmntinfo`) — never
    /// parsed from `mount -p`, which prints a path with spaces as it is
    /// (HANDOFF §2.127).
    public func mounted() -> [String] {
        var size = 1 << 16
        while size <= 1 << 24 {
            var buf = [CChar](repeating: 0, count: size)
            let n = ap_mount_points(&buf, size)
            if n >= 0 {
                return buf[0..<Int(n)].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            }
            guard errno == ERANGE else { return [] }
            size *= 4
        }
        return []
    }
}

func errText() -> String { String(cString: strerror(errno)) }

#if canImport(Glibc)
@inline(__always) func Glibc_write(_ fd: Int32, _ p: UnsafePointer<UInt8>?, _ n: Int) -> Int { Glibc.write(fd, p, n) }
#else
@inline(__always) func Glibc_write(_ fd: Int32, _ p: UnsafePointer<UInt8>?, _ n: Int) -> Int { Darwin.write(fd, p, n) }
#endif
