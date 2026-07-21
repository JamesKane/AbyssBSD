// Pool — the module entry points: locate the config directory, load a domain
// (mmap + parse), and the atomic write primitive Config.store uses.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// flock(2) operations. Defined explicitly rather than relying on the LOCK_*
// macros being surfaced through the imported C module.
private let poolLockEx: Int32 = 2   // LOCK_EX
private let poolLockUn: Int32 = 8   // LOCK_UN

public enum Pool {
    /// The config directory: `$ABYSS_CONFIG_DIR`, else `$XDG_CONFIG_HOME/abyss`,
    /// else `$HOME/.config/abyss`. Created (with parents) if absent, matching the
    /// Rust `pool::config_dir`.
    public static func configDir() throws -> String {
        let dir: String
        if let e = getenv("ABYSS_CONFIG_DIR") {
            dir = String(cString: e)
        } else if let x = getenv("XDG_CONFIG_HOME") {
            dir = String(cString: x) + "/abyss"
        } else if let h = getenv("HOME") {
            dir = String(cString: h) + "/.config/abyss"
        } else {
            throw PoolError.noConfigDir
        }
        try makeDirs(dir)
        return dir
    }

    /// Load and parse `<domain>.ini`. A missing or empty file yields an empty
    /// Config (compiled-in defaults apply) rather than an error.
    public static func load(_ domain: String, in dir: String? = nil) throws -> Config {
        let d = try dir ?? configDir()
        let path = d + "/" + domain + ".ini"
        guard let text = try mmapRead(path) else { return Config() }
        return Config.parse(text)
    }

    // MARK: internals

    /// mmap a file read-only+private and return its UTF-8 text; nil if the file
    /// is missing or empty. MAP_PRIVATE means an atomic rename() underneath can't
    /// tear the read (we hold the old inode until munmap).
    static func mmapRead(_ path: String) throws -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw PoolError.io("open \(path): \(errnoString())")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw PoolError.io("fstat \(path)") }
        let size = Int(st.st_size)
        if size == 0 { return nil }
        guard let map = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              map != MAP_FAILED else {
            throw PoolError.io("mmap \(path): \(errnoString())")
        }
        defer { munmap(map, size) }
        let bytes = UnsafeRawBufferPointer(start: map, count: size)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// temp file + fsync + atomic rename over `<domain>.ini`, serialized by an
    /// exclusive lock on `<domain>.ini.lock`. A reader always sees a whole file.
    static func atomicWrite(dir: String, domain: String, bytes: [UInt8]) throws {
        let lockPath = dir + "/" + domain + ".ini.lock"
        let tmpPath = dir + "/" + domain + ".ini.tmp"
        let finalPath = dir + "/" + domain + ".ini"

        let lockfd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o644))
        guard lockfd >= 0 else { throw PoolError.io("open \(lockPath): \(errnoString())") }
        defer { close(lockfd) }
        guard flock(lockfd, poolLockEx) == 0 else { throw PoolError.io("flock: \(errnoString())") }
        defer { _ = flock(lockfd, poolLockUn) }

        let tmpfd = open(tmpPath, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, mode_t(0o644))
        guard tmpfd >= 0 else { throw PoolError.io("open \(tmpPath): \(errnoString())") }
        var committed = false
        defer { if !committed { unlink(tmpPath) } }

        try bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(tmpfd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { close(tmpfd); throw PoolError.io("write \(tmpPath): \(errnoString())") }
                off += n
            }
        }
        if fsync(tmpfd) != 0 { close(tmpfd); throw PoolError.io("fsync: \(errnoString())") }
        close(tmpfd)

        if rename(tmpPath, finalPath) != 0 {
            throw PoolError.io("rename \(tmpPath) -> \(finalPath): \(errnoString())")
        }
        // Best-effort: make the rename itself durable.
        let dfd = open(dir, O_RDONLY | O_CLOEXEC)
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }
        committed = true
    }

    /// mkdir -p: create each path component, tolerating ones that already exist.
    static func makeDirs(_ path: String) throws {
        var partial = ""
        let absolute = path.hasPrefix("/")
        for component in path.split(separator: "/") {
            partial += "/" + component
            let p = absolute ? partial : String(partial.dropFirst())
            if mkdir(p, mode_t(0o700)) != 0 && errno != EEXIST {
                throw PoolError.io("mkdir \(p): \(errnoString())")
            }
        }
    }
}

private func errnoString() -> String {
    String(cString: strerror(errno))
}
