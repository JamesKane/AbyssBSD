//! When the displays sleep (DisplaySleep.swift, BACKLOG U.9): pure, so
//! tested without a clock.

use pool_config::EnergyPrefs;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IdleChange {
    Sleep,
    Wake,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IdleClock {
    /// Inactivity before sleep, in ns; 0 is never.
    pub timeout_ns: u64,
    pub last_activity_ns: u64,
    pub asleep: bool,
}

impl IdleClock {
    pub fn new(timeout_ns: u64, now: u64) -> IdleClock {
        IdleClock { timeout_ns, last_activity_ns: now, asleep: false }
    }

    /// A person did something: wakes the displays if they were asleep.
    pub fn activity(&mut self, now: u64) -> Option<IdleChange> {
        self.last_activity_ns = now;
        std::mem::take(&mut self.asleep).then_some(IdleChange::Wake)
    }

    /// Time passed. While inhibited the clock is held at `now`, so it runs
    /// its full length once the inhibitor goes.
    pub fn tick(&mut self, now: u64, inhibited: bool) -> Option<IdleChange> {
        if inhibited {
            self.last_activity_ns = self.last_activity_ns.max(now);
            return None;
        }
        if self.asleep || self.timeout_ns == 0 || now.wrapping_sub(self.last_activity_ns) < self.timeout_ns {
            return None;
        }
        self.asleep = true;
        Some(IdleChange::Sleep)
    }

    /// The timeout a person asked for: energy.ini's minutes, unless a run
    /// was given seconds (`--display-sleep`, for tests).
    pub fn timeout_ns_for(prefs: &EnergyPrefs, override_seconds: Option<f64>) -> u64 {
        match override_seconds {
            Some(s) if s > 0.0 => (s * 1e9) as u64,
            Some(_) => 0,
            None => prefs.display_sleep_minutes.max(0) as u64 * 60 * 1_000_000_000,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: u64 = 1_000_000_000;

    #[test]
    fn the_displays_sleep_after_the_timeout_and_the_first_input_wakes_them() {
        let mut c = IdleClock::new(60 * S, 0);
        assert_eq!(c.tick(59 * S, false), None);
        assert_eq!(c.tick(60 * S, false), Some(IdleChange::Sleep));
        assert_eq!(c.tick(61 * S, false), None, "asleep is said once");
        assert_eq!(c.activity(70 * S), Some(IdleChange::Wake));
        assert_eq!(c.activity(71 * S), None, "awake is said once");
        assert_eq!(c.tick(130 * S, false), None, "the clock runs from the last input");
        assert_eq!(c.tick(131 * S, false), Some(IdleChange::Sleep));
    }

    #[test]
    fn an_inhibitor_holds_the_clock_and_it_runs_in_full_after() {
        let mut c = IdleClock::new(60 * S, 0);
        assert_eq!(c.tick(100 * S, true), None);
        assert_eq!(c.tick(159 * S, false), None, "the full timeout from the inhibitor's end");
        assert_eq!(c.tick(160 * S, false), Some(IdleChange::Sleep));
    }

    #[test]
    fn never_means_never() {
        assert_eq!(IdleClock::new(0, 0).tick(1_000_000 * S, false), None);
    }

    #[test]
    fn the_timeout_is_energy_inis_minutes_unless_a_run_gave_seconds() {
        let ten = EnergyPrefs { display_sleep_minutes: 10, ..EnergyPrefs::default() };
        let zero = EnergyPrefs { display_sleep_minutes: 0, ..EnergyPrefs::default() };
        assert_eq!(IdleClock::timeout_ns_for(&ten, None), 600 * S);
        assert_eq!(IdleClock::timeout_ns_for(&zero, None), 0);
        assert_eq!(IdleClock::timeout_ns_for(&ten, Some(1.5)), 1_500_000_000);
        assert_eq!(IdleClock::timeout_ns_for(&ten, Some(0.0)), 0);
    }
}
