// SetupState — whether an account has been through the Setup Assistant
// (PHASE16 P16.7).
//
//     [setup]
//     done = true
//
// In the account's own config directory (setup.ini), so it is theirs: a new
// account sees the assistant at its first login, and once it is finished —
// or skipped — never again. anchor reads it to decide whether to start the
// assistant; the assistant writes it.

public enum SetupState {
    static let domain = "setup", section = "setup"

    public static func done(configDir: String? = nil) -> Bool {
        (try? Pool.load(domain, in: configDir))?.bool(section, "done") ?? false
    }

    /// Finished or skipped: say so, and how, for whoever looks.
    public static func markDone(skipped: Bool, configDir: String? = nil) throws {
        var c = (try? Pool.load(domain, in: configDir)) ?? Config()
        c = c.set(section, "done", "true")
        c = c.set(section, "how", skipped ? "skipped" : "finished")
        try c.store(domain, in: configDir)
    }
}
