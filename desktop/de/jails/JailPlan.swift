// JailPlan — a class plus a person, made into the steps that build the jail
// (PHASE18 P18.1).
//
// Pure, so it can be read and tested on Linux, where there are no jails:
// `abyss-jaild` (P18.2) performs a plan and makes no decisions of its own. What
// the jail can reach is therefore settled here, and `violations` says what a
// plan must never do — the checks a root daemon runs before it mounts anything.
//
// The shape is PHASE18 §4.1's spike: a tmpfs root, the system read-only by
// nullfs, a generated `/etc` that knows two accounts and no passwords, devfs
// ruleset 4 with named devices unhidden, a private home, and a runtime
// directory that holds the jail's own Wayland socket and nothing of undertow's.

public struct JailUser: Equatable, Sendable {
    public var name: String
    public var uid: UInt32
    public var gid: UInt32

    public init(name: String, uid: UInt32, gid: UInt32) {
        self.name = name
        self.uid = uid
        self.gid = gid
    }
}

public struct JailMount: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case tmpfs, nullfs, devfs }
    public var kind: Kind
    /// Host path for nullfs; empty otherwise.
    public var source: String
    /// Path inside the jail, absolute (`/usr`), or "/" for the root itself.
    public var target: String
    public var readOnly: Bool
}

public struct JailPlan: Equatable, Sendable {
    /// `abyss-<uid>-<class>`: one per person and class (pooled, §3 P18.2).
    public var name: String
    /// The jail's root on the host.
    public var root: String
    /// In order: the root's tmpfs first, everything else on it.
    public var mounts: [JailMount]
    /// devfs paths unhidden on top of ruleset 4.
    public var unhide: [String]
    /// Directories created inside the root, with their owner's uid (0 = root)
    /// and mode — mount points, and the places the person writes.
    public var dirs: [(path: String, uid: UInt32, mode: UInt16)]
    /// The jail's accounts in `master.passwd(5)` form, every password `*`.
    /// jaild compiles them with `pwd_mkdb -p -d <root>/etc` and then deletes
    /// the `master.passwd` and `spwd.db` that writes (§4.5): what is left is
    /// `passwd` and `pwd.db`, and nothing inside can read a hash, not even `*`.
    public var accounts: String
    /// Files written into the root: path inside, contents.
    public var files: [(path: String, contents: String)]
    /// Host files copied in as they are. A missing source is skipped, not an
    /// error: the guest has no `/etc/localtime`, and a jail without one is UTC.
    public var copies: [(source: String, target: String)]
    /// `jail_set(2)` parameters; a nil value is a boolean parameter.
    public var params: [(String, String?)]
    /// The environment a process started in it gets, and nothing else.
    public var env: [(String, String)]
    public var layout: JailLayout
    /// The private home: a host directory (a ZFS dataset's mountpoint where
    /// there is one, §6.3) mounted at the person's home path inside.
    public var homeSource: String
    /// Created by jaild when the host has ZFS; nil on UFS.
    public var homeDataset: String?

    public static func == (a: JailPlan, b: JailPlan) -> Bool {
        a.name == b.name && a.root == b.root && a.mounts == b.mounts && a.unhide == b.unhide
            && a.accounts == b.accounts
            && a.dirs.map { "\($0.path)|\($0.uid)|\($0.mode)" } == b.dirs.map { "\($0.path)|\($0.uid)|\($0.mode)" }
            && a.files.map { $0.path + "\n" + $0.contents } == b.files.map { $0.path + "\n" + $0.contents }
            && a.copies.map { $0.source + ">" + $0.target } == b.copies.map { $0.source + ">" + $0.target }
            && a.params.map { $0.0 + "=" + ($0.1 ?? "∅") } == b.params.map { $0.0 + "=" + ($0.1 ?? "∅") }
            && a.env.map { $0.0 + "=" + $0.1 } == b.env.map { $0.0 + "=" + $0.1 }
            && a.homeSource == b.homeSource && a.homeDataset == b.homeDataset && a.layout == b.layout
    }
}
extension JailPlan: @unchecked Sendable {}

/// Where jails are kept on the host. `standard` is the machine's; a test
/// passes temporary directories, and the plan's checks follow the layout it
/// was made with.
public struct JailLayout: Equatable, Sendable {
    /// Where roots live: under /var/run, so a reboot leaves none.
    public var rootBase: String
    /// Where private homes live (a ZFS dataset's mountpoint, or a directory, §6.3).
    public var homeBase: String

    public init(rootBase: String = "/var/run/abyss-jails", homeBase: String = "/var/db/abyss-jails") {
        self.rootBase = rootBase
        self.homeBase = homeBase
    }
    public static let standard = JailLayout()

    /// The runtime directory inside: the jail's own Wayland socket goes here.
    public static let runtime = "/run/user"
    /// Where granted files are mounted (P18.4).
    public static let granted = "/run/granted"
    /// The jail's own D-Bus (P18.4): the portal is the only service on it.
    public static let bus = "/run/user/bus"
    public static let waylandDisplay = "wayland-0"
}

extension JailPlan {
    /// The plan for `user` in `cls`. `pool` is the ZFS pool to keep homes in,
    /// or nil on UFS.
    public static func make(_ cls: JailClass, for user: JailUser, pool: String? = nil,
                            layout: JailLayout = .standard) -> JailPlan {
        let name = "abyss-\(user.uid)-\(cls.name)"
        let root = "\(layout.rootBase)/\(user.uid)/\(cls.name)"
        let home = "/home/\(user.name)"
        let homeSource = "\(layout.homeBase)/\(user.name)/\(cls.name)"

        var mounts = [JailMount(kind: .tmpfs, source: "", target: "/", readOnly: false)]
        for dir in cls.system {
            mounts.append(JailMount(kind: .nullfs, source: dir, target: dir, readOnly: true))
        }
        mounts.append(JailMount(kind: .devfs, source: "", target: "/dev", readOnly: false))
        mounts.append(JailMount(kind: .nullfs, source: homeSource, target: home, readOnly: false))

        var dirs: [(path: String, uid: UInt32, mode: UInt16)] = [
            ("/etc", 0, 0o755), ("/var", 0, 0o755), ("/var/run", 0, 0o755), ("/dev", 0, 0o555),
            ("/tmp", 0, 0o1777), ("/home", 0, 0o755), (home, user.uid, 0o700),
            ("/run", 0, 0o755), (JailLayout.runtime, user.uid, 0o700), (JailLayout.granted, 0, 0o755),
        ]
        for dir in cls.system { dirs.insert((dir, 0, 0o755), at: 1) }

        // Two accounts and no passwords: getpwuid answers for the person, and
        // there is nothing for anything inside to crack. `pwd.db` is built
        // from these by jaild, never copied from the host's (which knows
        // everyone). The person is in their own group only: not wheel, even
        // when they are outside.
        let accounts = "root:*:0:0::0:0:Charlie &:/root:/usr/sbin/nologin\n"
            + "\(user.name):*:\(user.uid):\(user.gid)::0:0:\(user.name):\(home):/bin/sh\n"
        let files: [(path: String, contents: String)] = [
            ("/etc/group", "wheel:*:0:root\n\(user.name):*:\(user.gid):\n"),
        ]
        var copies: [(source: String, target: String)] = [
            ("/etc/nsswitch.conf", "/etc/nsswitch.conf"),
            ("/etc/libmap.conf", "/etc/libmap.conf"),
            ("/etc/localtime", "/etc/localtime"),
            ("/var/run/ld-elf.so.hints", "/var/run/ld-elf.so.hints"),
        ]
        if cls.network == .host { copies.append(("/etc/resolv.conf", "/etc/resolv.conf")) }

        var params: [(String, String?)] = [
            ("name", name), ("path", root), ("host.hostname", name), ("persist", nil),
            ("enforce_statfs", "2"), ("devfs_ruleset", "4"),
        ]
        switch cls.network {
        case .none: params += [("ip4", "disable"), ("ip6", "disable")]
        case .host: params += [("ip4", "inherit"), ("ip6", "inherit")]
        }

        var env: [(String, String)] = [
            ("HOME", home), ("USER", user.name), ("LOGNAME", user.name), ("SHELL", "/bin/sh"),
            ("PATH", "/bin:/usr/bin:/usr/local/bin"), ("TMPDIR", "/tmp"),
            ("XDG_RUNTIME_DIR", JailLayout.runtime),
        ]
        if cls.wayland {
            env += [("WAYLAND_DISPLAY", JailLayout.waylandDisplay), ("GDK_BACKEND", "wayland")]
            // Files come in through the Open panel (P18.4): GTK asks the
            // portal on the jail's own bus, which grants the file it was
            // given — rather than browsing a filesystem that holds nothing.
            env += [("DBUS_SESSION_BUS_ADDRESS", "unix:path=\(JailLayout.bus)"),
                    ("GTK_USE_PORTAL", "1"), ("GDK_DEBUG", "portals")]
        }

        return JailPlan(
            name: name, root: root, mounts: mounts,
            unhide: cls.devices.flatMap { JailClass.knownDevices[$0] ?? [] },
            dirs: dirs, accounts: accounts, files: files, copies: copies, params: params, env: env,
            layout: layout, homeSource: homeSource,
            homeDataset: pool.map { "\($0)/abyss/jails/\(user.name)/\(cls.name)" })
    }

    /// What this plan would do that no plan may: each a sentence a refusal can
    /// show. Empty is the only answer jaild acts on.
    public func violations(for cls: JailClass, hostHome: String) -> [String] {
        var out: [String] = []
        let home = env.first { $0.0 == "HOME" }?.1 ?? ""
        for unknown in cls.devices where JailClass.knownDevices[unknown] == nil {
            out.append("class \(cls.name) names an unknown device '\(unknown)'")
        }
        for m in mounts where m.kind == .nullfs {
            if m.target == home {
                if m.source != homeSource || m.readOnly { out.append("the home is not the private one: \(m.source)") }
                continue
            }
            if !m.readOnly { out.append("\(m.target) is writable from inside") }
            if Self.under(m.source, hostHome) || Self.under(hostHome, m.source) {
                out.append("\(m.source) reaches the person's own home")
            }
            if Self.under(m.source, layout.rootBase) || Self.under(m.source, layout.homeBase) || m.source == "/" || m.source == "/etc"
                || Self.under(m.source, "/root") || Self.under(m.source, "/var") {
                out.append("\(m.source) is not a system directory")
            }
        }
        if Self.under(homeSource, hostHome) || !Self.under(homeSource, layout.homeBase) {
            out.append("the private home \(homeSource) is not under \(layout.homeBase)")
        }
        for f in files where Self.secret(f.path) { out.append("\(f.path) is written into the jail") }
        for c in copies where Self.secret(c.source) || Self.secret(c.target) {
            out.append("\(c.source) is copied into the jail")
        }
        if accounts.split(separator: "\n").contains(where: { $0.split(separator: ":").dropFirst().first != "*" }) {
            out.append("an account carries a password")
        }
        for row in accounts.split(separator: "\n") {
            let f = row.split(separator: ":", omittingEmptySubsequences: false)
            if f.count != 10 { out.append("an account is not in master.passwd form: \(f.first ?? "")") }
            if f.count > 2, f[2] == "0", f[0] != "root" { out.append("\(f[0]) has uid 0") }
        }
        let ip4 = params.first { $0.0 == "ip4" }?.1, ip6 = params.first { $0.0 == "ip6" }?.1
        if cls.network == .none, ip4 != "disable" || ip6 != "disable" {
            out.append("class \(cls.name) has no network, but the jail has an address")
        }
        if params.first(where: { $0.0 == "devfs_ruleset" })?.1 != "4" {
            out.append("the devfs ruleset is not 4")
        }
        if let wd = env.first(where: { $0.0 == "XDG_RUNTIME_DIR" })?.1, wd != JailLayout.runtime {
            out.append("the runtime directory is \(wd), not the jail's own")
        }
        return out
    }

    static func secret(_ path: String) -> Bool {
        ["/etc/master.passwd", "/etc/spwd.db"].contains(path) || path.hasPrefix("/root/")
            || path.contains("/.ssh")
    }

    /// Whether `path` is `dir` or below it (component-wise, so /usr/localx is
    /// not under /usr/local).
    public static func under(_ path: String, _ dir: String) -> Bool {
        guard !dir.isEmpty else { return false }
        let d = dir.hasSuffix("/") && dir.count > 1 ? String(dir.dropLast()) : dir
        return path == d || path.hasPrefix(d == "/" ? "/" : d + "/")
    }
}
