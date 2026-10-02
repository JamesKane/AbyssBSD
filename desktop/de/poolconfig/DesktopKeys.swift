// DesktopKeys — what the desktop does with no keys.ini at all (P9.5), shared by
// undertow, which answers the keys, and System Preferences, which shows them
// (PHASE13 P13.7). Data only: `KeyBindings` in undertow parses it.

public enum DesktopKeys {
    /// A desktop whose shortcuts only exist if you write a file is a desktop
    /// with no shortcuts, so these are compiled in and `~/.config/abyss/keys.ini`
    /// overrides them row by row.
    public static let defaults: [(String, String)] = [
        ("Cmd+Tab",           "next-window"),
        ("Cmd+Shift+Tab",     "previous-window"),
        ("Cmd+W",             "close-window"),
        ("Cmd+Q",             "quit-app"),
        ("Ctrl+Cmd+Q",        "run: abyssctl lock"),
        ("Cmd+Shift+3",       "run: abyssgrab screen"),
        ("Cmd+Shift+4",       "run: abyssgrab region"),
        ("XF86AudioRaiseVolume", "run: ventsctl volume +5"),
        ("XF86AudioLowerVolume", "run: ventsctl volume -5"),
        ("XF86AudioMute",        "run: ventsctl volume 0"),
        // The Agent window (PHASE18 P18.13) — a chord only while agents are
        // on: with no agents.ini the key goes to the application as if unbound.
        ("Cmd+Alt+A",            "agent"),
        // Islands (PHASE13 §6.4): Mac's Spaces keys; Ctrl-Alt sends the
        // focused window, and Shift goes with it (§6.2). A digit past
        // `islands.ini`'s count does nothing.
        ("Ctrl+Left",  "island previous"),
        ("Ctrl+Right", "island next"),
        // Ebb (§6.4): Mission Control's and App Exposé's keys.
        ("F3",         "ebb island"),
        ("Ctrl+Up",    "ebb archipelago"),
        ("Ctrl+Down",  "ebb app"),
        // Shoals (P13.6): Ctrl-Alt with N for new, = to add, - to take out;
        // Ctrl-Shift-N recalls this island's Nth; Ctrl-F3 the strip, beside
        // Ebb's F3.
        ("Ctrl+Alt+N",     "shoal new"),
        ("Ctrl+Alt+equal", "shoal add"),
        ("Ctrl+Alt+minus", "shoal remove"),
        ("Ctrl+F3",        "shoal strip"),
    ] + (1...9).flatMap { n in [
        ("Ctrl+Shift+\(n)",     "shoal recall \(n)"),
        ("Ctrl+\(n)",           "island \(n)"),
        ("Ctrl+Alt+\(n)",       "move-to-island \(n)"),
        ("Ctrl+Alt+Shift+\(n)", "move-to-island \(n) follow"),
    ] }

    /// The table as it stands: these, with `keys.ini`'s `[keys]` rows over them.
    public static func effective(configDir: String? = nil) -> [(String, String)] {
        var rows = defaults
        if let c = try? Pool.load("keys", in: configDir) {
            for (spec, action) in c.pairs("keys") {
                rows.removeAll { $0.0.lowercased() == spec.lowercased() }
                rows.append((spec, action))
            }
        }
        return rows
    }
}
