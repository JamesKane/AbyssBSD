// displays.ini — the arrangement a person chose, kept per user and applied at
// start (PHASE14 P14.7b). One line per output, by name:
//
//     [displays]
//     HEADLESS-2 = 640,0 800x600@60000 1
//
// Written by undertow when a configuration is applied (whoever sent it — the
// Displays pane, wlr-randr, kanshi), so the file is always what is on screen.

import PoolConfig

public enum DisplaysFile {
    static let domain = "displays", section = "displays"

    public static func load(configDir: String?) -> [String: DisplaySetting] {
        guard let c = try? Pool.load(domain, in: configDir) else { return [:] }
        var out: [String: DisplaySetting] = [:]
        for (key, v) in c.pairs(section) {
            if let s = DisplaysConfig.parse(name: key, v) { out[key] = s }
        }
        return out
    }

    public static func store(_ settings: [DisplaySetting], configDir: String?) throws {
        var c = (try? Pool.load(domain, in: configDir)) ?? Config()
        for s in settings { c = c.set(section, s.name, DisplaysConfig.format(s)) }
        try c.store(domain, in: configDir)
    }
}
