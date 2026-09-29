// EnergyPrefs — when the display and the computer sleep, per user
// (PHASE14 P14.8).
//
// Written by System Preferences' Energy Saver pane. The display's delay is
// read by undertow, which sleeps the displays (U.9, DisplaySleep); the
// computer's waits for Phase 16's suspend — and the pane says so. Kept here, in the
// config pool, because both the toolkit and the compositor-side session will
// read it and neither should depend on the other.
//
//     [energy]
//     display_sleep_minutes = 10
//     system_sleep_minutes = 30

public struct EnergyPrefs: Equatable, Sendable {
    /// Minutes of inactivity before the display sleeps; 0 is never.
    public var displaySleepMinutes: Int
    /// Minutes of inactivity before the computer sleeps; 0 is never.
    public var systemSleepMinutes: Int

    public init(displaySleepMinutes: Int = 10, systemSleepMinutes: Int = 30) {
        self.displaySleepMinutes = displaySleepMinutes
        self.systemSleepMinutes = systemSleepMinutes
    }

    /// Jaguar's slider stops, in minutes; `never` (0) sits past the last.
    public static let stops = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180]

    /// **The display never sleeps later than the computer**: a sleeping
    /// computer has no display to keep lit. Setting one moves the other, as the
    /// Mac's sliders push each other; `changedDisplay` says which was moved.
    public func consistent(changedDisplay: Bool) -> EnergyPrefs {
        var p = self
        let d = p.displaySleepMinutes, s = p.systemSleepMinutes
        guard s != 0 else { return p }                                   // the computer never sleeps
        if d == 0 || d > s {
            if changedDisplay { p.systemSleepMinutes = d == 0 ? 0 : d } else { p.displaySleepMinutes = s }
        }
        return p
    }

    /// "10 min", "1 hr 30 min", "Never".
    public static func words(_ minutes: Int) -> String {
        guard minutes > 0 else { return "Never" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return "\(h) hr" + (m > 0 ? " \(m) min" : "")
    }

    static let domain = "energy", section = "energy"

    public static func load(configDir: String? = nil) -> EnergyPrefs {
        guard let c = try? Pool.load(domain, in: configDir) else { return EnergyPrefs() }
        var p = EnergyPrefs()
        if let v = c.int64(section, "display_sleep_minutes"), v >= 0 { p.displaySleepMinutes = Int(v) }
        if let v = c.int64(section, "system_sleep_minutes"), v >= 0 { p.systemSleepMinutes = Int(v) }
        return p
    }

    public func store(configDir: String? = nil) throws {
        var c = (try? Pool.load(EnergyPrefs.domain, in: configDir)) ?? Config()
        c = c.set(EnergyPrefs.section, "display_sleep_minutes", "\(displaySleepMinutes)")
        c = c.set(EnergyPrefs.section, "system_sleep_minutes", "\(systemSleepMinutes)")
        try c.store(EnergyPrefs.domain, in: configDir)
    }
}
