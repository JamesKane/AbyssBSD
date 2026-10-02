// JailSteps — a plan as the steps that build it, and the steps that undo it
// (PHASE18 P18.2).
//
// Pure: the order is the design, so it is what the tests read. `JailPerformer`
// carries steps out and decides nothing. The order matters in three places:
//
//   - the tmpfs goes over the root *before* anything is made in it, or the
//     directories land on the host's /var/run and are hidden by the mount;
//   - the accounts are compiled by `pwd_mkdb` and then `master.passwd` and
//     `spwd.db` are deleted *before* the jail exists, so nothing inside ever
//     sees them (§4.5);
//   - teardown unmounts the deepest first (a granted file under /run before
//     the tmpfs it sits on), and only then removes the root.

import Jails

public enum JailStep: Equatable, Sendable {
    /// `mkdir -p` on the host, then owner and mode.
    case mkdir(String, uid: UInt32, gid: UInt32, mode: UInt16)
    /// A ZFS dataset with this mountpoint, created if it is missing.
    case dataset(String, mountpoint: String)
    case run([String])
    case write(String, contents: String, mode: UInt16)
    /// Copied if the source exists; skipped if not (§4.5: /etc/localtime).
    case copyIfPresent(String, to: String)
    case remove(String)
    /// Remove an empty directory; a non-empty one is left and reported.
    case rmdir(String)
}

public struct JailCommands: Equatable, Sendable {
    public var mount = "/sbin/mount"
    public var umount = "/sbin/umount"
    public var devfs = "/sbin/devfs"
    public var pwdMkdb = "/usr/sbin/pwd_mkdb"
    public var zfs = "/sbin/zfs"
    public init() {}
}

public enum JailSteps {
    /// Everything up to the jail itself, for `user`. The jail is created after these, by the service.
    public static func build(_ p: JailPlan, user: JailUser, commands c: JailCommands = JailCommands()) -> [JailStep] {
        var s: [JailStep] = []
        let uid = user.uid, gid = user.gid
        let r = p.root

        // The root's directory, and the private home, on the host.
        s.append(.mkdir(r, uid: 0, gid: 0, mode: 0o755))
        if let ds = p.homeDataset { s.append(.dataset(ds, mountpoint: p.homeSource)) }
        s.append(.mkdir(p.homeSource, uid: uid, gid: gid, mode: 0o700))

        // The tmpfs first, then everything on it.
        s.append(.run([c.mount, "-t", "tmpfs", "-o", "mode=755", "tmpfs", r]))
        for d in p.dirs {
            s.append(.mkdir(r + d.path, uid: d.uid, gid: d.uid == 0 ? 0 : gid, mode: d.mode))
        }
        for m in p.mounts.dropFirst() {
            let target = r + m.target
            switch m.kind {
            case .tmpfs:
                s.append(.run([c.mount, "-t", "tmpfs", "tmpfs", target]))
            case .nullfs:
                // nosuid on everything: a setuid binary has nothing to do in an
                // application's jail, and root inside is still root of a jail.
                s.append(.run([c.mount, "-t", "nullfs", "-o", m.readOnly ? "ro,nosuid" : "nosuid", m.source, target]))
            case .devfs:
                s.append(.run([c.mount, "-t", "devfs", "devfs", target]))
                s.append(.run([c.devfs, "-m", target, "ruleset", "4"]))
                s.append(.run([c.devfs, "-m", target, "rule", "applyset"]))
                for path in p.unhide {
                    s.append(.run([c.devfs, "-m", target, "rule", "apply", "path", path, "unhide"]))
                }
            }
        }

        for f in p.files { s.append(.write(r + f.path, contents: f.contents, mode: 0o644)) }
        for cp in p.copies { s.append(.copyIfPresent(cp.source, to: r + cp.target)) }
        let master = r + "/etc/master.passwd"
        s.append(.write(master, contents: p.accounts, mode: 0o600))
        s.append(.run([c.pwdMkdb, "-p", "-d", r + "/etc", master]))
        s.append(.remove(master))
        s.append(.remove(r + "/etc/spwd.db"))
        return s
    }

    /// Undo a root: every mount at or under it, deepest first, then the
    /// directory. `mounted` is the host's mount points (from `MountTable`).
    public static func teardown(root: String, mounted: [String], commands c: JailCommands = JailCommands()) -> [JailStep] {
        let mine = mounted.filter { JailPlan.under($0, root) }
            .sorted { ($0.split(separator: "/").count, $0) > ($1.split(separator: "/").count, $1) }
        return mine.map { .run([c.umount, "-f", $0]) } + [.rmdir(root)]
    }
}

extension JailSteps {
    /// A granted file's name inside: its own, unless that could not be one.
    public static func grantName(_ source: String) -> String {
        let base = source.split(separator: "/").last.map(String.init) ?? ""
        return base.isEmpty || base == "." || base == ".." ? "file" : base
    }

    /// Where grant `n` of `source` is, inside the jail.
    public static func grantPath(_ n: Int, source: String) -> String {
        "\(JailLayout.granted)/\(n)/\(grantName(source))"
    }

    /// Mount one file into a running jail (P18.4, §4.4): a directory of its
    /// own, a placeholder to mount over, and nullfs — read-only unless the
    /// person's own descriptor of it was writable.
    public static func grant(root: String, n: Int, source: String, writable: Bool,
                             commands c: JailCommands = JailCommands()) -> [JailStep] {
        let dir = root + JailLayout.granted + "/\(n)"
        let target = root + grantPath(n, source: source)
        return [.mkdir(dir, uid: 0, gid: 0, mode: 0o755),
                .write(target, contents: "", mode: 0o644),
                .run([c.mount, "-t", "nullfs", "-o", writable ? "nosuid" : "ro,nosuid", source, target])]
    }

    /// Take grant `n` back: unmount it, and remove what held it.
    public static func revoke(root: String, n: Int, source: String, commands c: JailCommands = JailCommands()) -> [JailStep] {
        let target = root + grantPath(n, source: source)
        return [.run([c.umount, "-f", target]), .remove(target), .rmdir(root + JailLayout.granted + "/\(n)")]
    }
}

/// The mount table, as `JailPerformer.mounted()` reads it from the kernel
/// (`getmntinfo`), and what is under the jail roots in it.
public enum MountTable {
    /// The roots under `base` (`<base>/<uid>/<class>`) with anything mounted
    /// in them — what a daemon that died left behind.
    public static func roots(under base: String, in points: [String]) -> [String] {
        var out: [String] = []
        for p in points where JailPlan.under(p, base) && p != base {
            let rest = p.dropFirst(base.count + 1).split(separator: "/")
            guard rest.count >= 2 else { continue }
            let root = base + "/" + rest[0] + "/" + rest[1]
            if !out.contains(root) { out.append(root) }
        }
        return out
    }

    /// The jail a root belongs to: `<base>/1001/app` is `abyss-1001-app`.
    public static func jailName(root: String, base: String) -> String? {
        guard JailPlan.under(root, base) else { return nil }
        let rest = root.dropFirst(base.count + 1).split(separator: "/")
        guard rest.count == 2, UInt32(rest[0]) != nil else { return nil }
        return "abyss-\(rest[0])-\(rest[1])"
    }
}
