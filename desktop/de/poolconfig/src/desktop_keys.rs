//! DesktopKeys.swift: what the desktop does with no keys.ini at all (P9.5),
//! shared by undertow, which answers the keys, and System Preferences, which
//! shows them (PHASE13 P13.7). Data only.

use crate::pool;

pub struct DesktopKeys;

impl DesktopKeys {
    /// A desktop whose shortcuts only exist if you write a file is a desktop
    /// with no shortcuts, so these are compiled in, and
    /// `~/.config/abyss/keys.ini` overrides them row by row.
    pub fn defaults() -> Vec<(String, String)> {
        const FIXED: &[(&str, &str)] = &[
            ("Cmd+Tab", "next-window"),
            ("Cmd+Shift+Tab", "previous-window"),
            ("Cmd+W", "close-window"),
            ("Cmd+Q", "quit-app"),
            ("Ctrl+Cmd+Q", "run: abyssctl lock"),
            ("Cmd+Shift+3", "run: abyssgrab screen"),
            ("Cmd+Shift+4", "run: abyssgrab region"),
            ("XF86AudioRaiseVolume", "run: ventsctl volume +5"),
            ("XF86AudioLowerVolume", "run: ventsctl volume -5"),
            ("XF86AudioMute", "run: ventsctl volume 0"),
            // The Agent window (PHASE18 P18.13): a chord only while agents
            // are on; with no agents.ini the key goes to the application.
            ("Cmd+Alt+A", "agent"),
            // Islands (PHASE13 §6.4): Mac's Spaces keys.
            ("Ctrl+Left", "island previous"),
            ("Ctrl+Right", "island next"),
            // Ebb (§6.4): Mission Control's and App Exposé's keys.
            ("F3", "ebb island"),
            ("Ctrl+Up", "ebb archipelago"),
            ("Ctrl+Down", "ebb app"),
            // Shoals (P13.6).
            ("Ctrl+Alt+N", "shoal new"),
            ("Ctrl+Alt+equal", "shoal add"),
            ("Ctrl+Alt+minus", "shoal remove"),
            ("Ctrl+F3", "shoal strip"),
        ];
        let mut rows: Vec<(String, String)> =
            FIXED.iter().map(|&(k, a)| (k.to_owned(), a.to_owned())).collect();
        for n in 1..=9 {
            rows.push((format!("Ctrl+Shift+{n}"), format!("shoal recall {n}")));
            rows.push((format!("Ctrl+{n}"), format!("island {n}")));
            rows.push((format!("Ctrl+Alt+{n}"), format!("move-to-island {n}")));
            rows.push((format!("Ctrl+Alt+Shift+{n}"), format!("move-to-island {n} follow")));
        }
        rows
    }

    /// The table as it stands: the defaults, with `keys.ini`'s `[keys]` rows
    /// over them (a row replaces any default with its shortcut, in any
    /// case, and goes to the end).
    pub fn effective(dir: Option<&str>) -> Vec<(String, String)> {
        let mut rows = Self::defaults();
        if let Ok(c) = pool::load("keys", dir) {
            for (spec, action) in c.pairs("keys") {
                let lower = spec.to_lowercase();
                rows.retain(|r| r.0.to_lowercase() != lower);
                rows.push((spec.to_owned(), action.to_owned()));
            }
        }
        rows
    }
}
