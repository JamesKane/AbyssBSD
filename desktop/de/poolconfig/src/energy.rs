//! EnergyPrefs.swift: when the display and the computer sleep, per user
//! (PHASE14 P14.8). Written by System Preferences' Energy Saver pane, read
//! by undertow (the display's delay) and the session's idle policy
//! (`abyss-idle`, P16.3), which reads all three.
//!
//! ```ini
//! [energy]
//! display_sleep_minutes = 10
//! system_sleep_minutes = 30
//! require_password = true
//! ```

use crate::{pool, Config, Error};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EnergyPrefs {
    /// Minutes of inactivity before the display sleeps; 0 is never.
    pub display_sleep_minutes: i64,
    /// Minutes of inactivity before the computer sleeps; 0 is never.
    pub system_sleep_minutes: i64,
    /// Lock when the display sleeps, and before the computer does. On
    /// unless a person turns it off.
    pub require_password: bool,
}

impl Default for EnergyPrefs {
    fn default() -> EnergyPrefs {
        EnergyPrefs { display_sleep_minutes: 10, system_sleep_minutes: 30, require_password: true }
    }
}

const DOMAIN: &str = "energy";
const SECTION: &str = "energy";

impl EnergyPrefs {
    /// Jaguar's slider stops, in minutes; never (0) sits past the last.
    pub const STOPS: [i64; 13] = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180];

    /// What idleness does, in milliseconds of it (P16.3): when to lock, and
    /// when to ask the computer to sleep; None is never. `minute_ms` is how
    /// long a minute is: 60 000, but a test may make it a second.
    pub fn idle_timeouts(&self, minute_ms: u64) -> (Option<u64>, Option<u64>) {
        let lock = (self.require_password && self.display_sleep_minutes > 0)
            .then(|| self.display_sleep_minutes as u64 * minute_ms);
        let sleep = (self.system_sleep_minutes > 0).then(|| self.system_sleep_minutes as u64 * minute_ms);
        (lock, sleep)
    }

    /// **The display never sleeps later than the computer.** Setting one
    /// moves the other; `changed_display` says which was moved.
    pub fn consistent(&self, changed_display: bool) -> EnergyPrefs {
        let mut p = *self;
        let (d, s) = (p.display_sleep_minutes, p.system_sleep_minutes);
        if s == 0 {
            return p; // the computer never sleeps
        }
        if d == 0 || d > s {
            if changed_display {
                p.system_sleep_minutes = if d == 0 { 0 } else { d };
            } else {
                p.display_sleep_minutes = s;
            }
        }
        p
    }

    /// "10 min", "1 hr 30 min", "Never".
    pub fn words(minutes: i64) -> String {
        if minutes <= 0 {
            return "Never".into();
        }
        let (h, m) = (minutes / 60, minutes % 60);
        if h == 0 {
            return format!("{m} min");
        }
        if m > 0 { format!("{h} hr {m} min") } else { format!("{h} hr") }
    }

    pub fn load(dir: Option<&str>) -> EnergyPrefs {
        let mut p = EnergyPrefs::default();
        let Ok(c) = pool::load(DOMAIN, dir) else { return p };
        if let Some(v) = c.int64(SECTION, "display_sleep_minutes").filter(|&v| v >= 0) {
            p.display_sleep_minutes = v;
        }
        if let Some(v) = c.int64(SECTION, "system_sleep_minutes").filter(|&v| v >= 0) {
            p.system_sleep_minutes = v;
        }
        if let Some(v) = c.bool(SECTION, "require_password") {
            p.require_password = v;
        }
        p
    }

    pub fn store(&self, dir: Option<&str>) -> Result<(), Error> {
        let mut c = pool::load(DOMAIN, dir).unwrap_or_else(|_| Config::new());
        c.set(SECTION, "display_sleep_minutes", &self.display_sleep_minutes.to_string())
            .set(SECTION, "system_sleep_minutes", &self.system_sleep_minutes.to_string())
            .set_bool(SECTION, "require_password", self.require_password);
        c.store(DOMAIN, dir)
    }
}
