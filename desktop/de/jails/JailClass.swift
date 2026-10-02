// JailClass — what a jail contains, as data (PHASE18 P18.1).
//
// A class is a row in `jails.ini`, not code: the system it sees, the devices it
// may open, whether it has a network and a Wayland socket. The shipped classes
// are below; a `[name]` section in the file replaces one or adds one. Every
// class gets the same private home and the same read-only system — what varies
// is reach, and reach is what a person should be able to read in one file.

import PoolConfig

public struct JailClass: Equatable, Sendable {
    public enum Network: String, Equatable, Sendable {
        /// No address at all: `ip4=disable ip6=disable`.
        case none
        /// The host's stack (§6.5): a browser reaches the network and nothing
        /// of yours. Per-jail `vnet` behind an egress gate is 18b's.
        case host
    }

    public var name: String
    /// Host directories mounted read-only at the same path inside.
    public var system: [String]
    /// devfs paths unhidden on top of ruleset 4 (`devfsrules_jail`): "dri"
    /// gives `/dev/dri/*`, "dsp" gives `/dev/dsp*`.
    public var devices: [String]
    public var network: Network
    public var wayland: Bool

    public init(name: String, system: [String] = JailClass.baseSystem, devices: [String] = [],
                network: Network = .none, wayland: Bool = true) {
        self.name = name
        self.system = system
        self.devices = devices
        self.network = network
        self.wayland = wayland
    }

    /// The system every class sees unless its row says otherwise. `/usr`
    /// carries `/usr/local`, so ports' toolkits come with it.
    public static let baseSystem = ["/bin", "/lib", "/libexec", "/usr"]

    /// The devices a row may name. Anything else is refused, not passed to
    /// devfs: a typo must not become `unhide` on a path nobody reviewed.
    public static let knownDevices: [String: [String]] = [
        "dri": ["dri", "dri/*", "drm", "drm/*"],
        "dsp": ["dsp*", "mixer*", "sndstat"],
    ]

    public static let shipped: [JailClass] = [
        JailClass(name: "app"),
        JailClass(name: "app-gl", devices: ["dri"]),
        JailClass(name: "app-net", devices: ["dri", "dsp"], network: .host),
    ]

    /// The classes as they stand: the shipped ones, with `jails.ini`'s
    /// sections over them. A section names its class; unknown keys keep the
    /// shipped value, so a one-line override does not have to restate the rest.
    public static func table(_ c: Config?) -> [JailClass] {
        var out = shipped
        guard let c else { return out }
        for section in c.sectionNames where !section.isEmpty && section != JailClass.appsSection {
            var k = out.first { $0.name == section } ?? JailClass(name: section)
            if let s = c.string(section, "system") { k.system = words(s) }
            if let s = c.string(section, "devices") { k.devices = words(s) }
            if let s = c.string(section, "network") { k.network = Network(rawValue: s.lowercased()) ?? k.network }
            if let b = c.bool(section, "wayland") { k.wayland = b }
            out.removeAll { $0.name == section }
            out.append(k)
        }
        return out
    }

    /// `[apps]`: which applications run confined, and in what (P18.5) — read
    /// by abyss-appgen, not a class.
    public static let appsSection = "apps"

    public static func load(configDir: String? = nil) -> [JailClass] {
        table(try? Pool.load("jails", in: configDir))
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
    }
}
