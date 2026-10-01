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
//     require_password = true      (PHASE16 P16.3: lock when the display sleeps)
//
// The session's idle policy (`abyss-idle`, P16.3) reads all three: it locks
// when the display sleeps if a password is required, and asks for the
// computer to sleep — locking first — after the computer's delay.

public struct EnergyPrefs: Equatable, Sendable {
    /// Minutes of inactivity before the display sleeps; 0 is never.
    public var displaySleepMinutes: Int
    /// Minutes of inactivity before the computer sleeps; 0 is never.
    public var systemSleepMinutes: Int
    /// Jaguar's "require a password to wake this computer from sleep or
    /// screen saver": lock when the display sleeps, and before the computer
    /// does. On unless a person turns it off.
    public var requirePassword: Bool

    public init(displaySleepMinutes: Int = 10, systemSleepMinutes: Int = 30, requirePassword: Bool = true) {
        self.displaySleepMinutes = displaySleepMinutes
        self.systemSleepMinutes = systemSleepMinutes
        self.requirePassword = requirePassword
    }

    /// What idleness does, in milliseconds of it (P16.3): when to lock, and
    /// when to ask for the computer to sleep; nil is never. `minuteMs` is how
    /// long a minute is — 60 000, but a test may make it a second.
    ///
    /// The lock comes with the display's sleep, as the Mac's screen saver
    /// password did; with no display sleep there is no lock *before* the
    /// computer's — but the computer is locked as it goes to sleep, whatever
    /// the delays (the idle component does that, not this arithmetic).
    public func idleTimeouts(minuteMs: UInt64 = 60_000) -> (lock: UInt64?, sleep: UInt64?) {
        let lock = requirePassword && displaySleepMinutes > 0 ? UInt64(displaySleepMinutes) * minuteMs : nil
        let sleep = systemSleepMinutes > 0 ? UInt64(systemSleepMinutes) * minuteMs : nil
        return (lock, sleep)
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
        if let v = c.bool(section, "require_password") { p.requirePassword = v }
        return p
    }

    public func store(configDir: String? = nil) throws {
        var c = (try? Pool.load(EnergyPrefs.domain, in: configDir)) ?? Config()
        c = c.set(EnergyPrefs.section, "display_sleep_minutes", "\(displaySleepMinutes)")
        c = c.set(EnergyPrefs.section, "system_sleep_minutes", "\(systemSleepMinutes)")
        c = c.set(EnergyPrefs.section, "require_password", requirePassword ? "true" : "false")
        try c.store(EnergyPrefs.domain, in: configDir)
    }
}
