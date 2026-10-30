//! The PoolConfig halves of tests that live with their callers in Swift
//! (AquaTests' EnergyPaneTests, IslandsPaneTests and SetupAssistantTests,
//! UndertowTests' islands cases), ported: the types are here, so their
//! tests are too.

use pool_config::{Config, DesktopKeys, EnergyPrefs, IslandsConfig, SetupState};
use std::fs;
use std::sync::atomic::{AtomicUsize, Ordering};

fn temp_dir() -> String {
    static N: AtomicUsize = AtomicUsize::new(0);
    let base = std::env::temp_dir();
    loop {
        let p = base.join(format!("poolprefs-rs.{}.{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
        if fs::create_dir(&p).is_ok() {
            return p.to_str().unwrap().to_owned();
        }
    }
}

fn energy(d: i64, s: i64) -> EnergyPrefs {
    EnergyPrefs { display_sleep_minutes: d, system_sleep_minutes: s, ..EnergyPrefs::default() }
}

#[test]
fn the_display_never_sleeps_later_than_the_computer() {
    // The display slider pushed past the computer's: the computer follows.
    assert_eq!(energy(60, 30).consistent(true), energy(60, 60));
    // The computer's slider pulled under the display's: the display follows.
    assert_eq!(energy(60, 30).consistent(false), energy(30, 30));
    // A display that never sleeps means a computer that never does either.
    assert_eq!(energy(0, 30).consistent(true), energy(0, 0));
    // A computer that never sleeps constrains nothing.
    assert_eq!(energy(180, 0).consistent(true), energy(180, 0));
}

#[test]
fn delays_in_words() {
    assert_eq!(EnergyPrefs::words(10), "10 min");
    assert_eq!(EnergyPrefs::words(90), "1 hr 30 min");
    assert_eq!(EnergyPrefs::words(120), "2 hr");
    assert_eq!(EnergyPrefs::words(0), "Never");
    assert_eq!(EnergyPrefs::STOPS.first(), Some(&1));
    assert_eq!(EnergyPrefs::STOPS.last(), Some(&180));
}

#[test]
fn energy_ini_is_stored_and_loaded() {
    let dir = temp_dir();
    assert_eq!(EnergyPrefs::load(Some(&dir)), EnergyPrefs::default(), "nothing written: the defaults");
    energy(5, 0).store(Some(&dir)).unwrap();
    assert_eq!(EnergyPrefs::load(Some(&dir)), energy(5, 0));
}

/// The idle policy's arithmetic (PHASE16 P16.3).
#[test]
fn idle_timeouts() {
    let p = energy(10, 30);
    assert!(p.require_password, "a password is required unless a person says otherwise");
    assert_eq!(p.idle_timeouts(60_000).0, Some(600_000));
    assert_eq!(p.idle_timeouts(60_000).1, Some(1_800_000));
    assert_eq!(p.idle_timeouts(1000).0, Some(10_000), "a test's minute is a second");
    let q = EnergyPrefs { require_password: false, ..p };
    assert_eq!(q.idle_timeouts(60_000).0, None, "no password, no lock");
    assert_eq!(q.idle_timeouts(60_000).1, Some(1_800_000), "but the computer still sleeps");
    assert_eq!(energy(0, 0).idle_timeouts(60_000), (None, None));
}

#[test]
fn require_password_is_stored_and_loaded() {
    let dir = temp_dir();
    assert!(EnergyPrefs::load(Some(&dir)).require_password, "no file: on");
    EnergyPrefs { require_password: false, ..energy(5, 0) }.store(Some(&dir)).unwrap();
    assert!(!EnergyPrefs::load(Some(&dir)).require_password);
}

#[test]
fn energy_ignores_a_negative_delay_and_keeps_other_keys() {
    let dir = temp_dir();
    fs::write(format!("{dir}/energy.ini"), "[energy]\ndisplay_sleep_minutes = -4\nmine = kept\n").unwrap();
    assert_eq!(EnergyPrefs::load(Some(&dir)).display_sleep_minutes, 10);
    energy(3, 9).store(Some(&dir)).unwrap();
    let c = pool_config::load("energy", Some(&dir)).unwrap();
    assert_eq!(c.string("energy", "mine"), Some("kept"));
    assert_eq!(c.string("energy", "require_password"), Some("true"));
}

/// islands.ini: the slide on by default at 150 ms; off; and a length
/// clamped to what a test may slow it to.
#[test]
fn the_slide_is_configurable() {
    assert!(IslandsConfig::default().animate);
    assert_eq!(IslandsConfig::default().slide_ms, 150);
    let mut cfg = Config::new();
    cfg.set("islands", "animate", "no").set("islands", "slide_ms", "99999");
    let c = IslandsConfig::from(&cfg);
    assert!(!c.animate);
    assert_eq!(c.slide_ms, 2000);
}

/// islands.ini: a count from 1 to 9 (a digit each), names, and wrapping.
#[test]
fn islands_config_clamps_names_and_wraps() {
    assert_eq!(IslandsConfig::default().count, 4, "§6.1: four by default");
    assert_eq!(IslandsConfig::new(0, vec![], true, 150).count, 1);
    assert_eq!(IslandsConfig::new(40, vec![], true, 150).count, 9);
    let mut cfg = Config::new();
    cfg.set("islands", "count", "3").set("islands", "name.2", "Mail");
    let c = IslandsConfig::from(&cfg);
    assert_eq!(c.count, 3);
    assert_eq!(c.names, ["", "Mail"], "trailing unnamed islands are dropped, earlier ones kept");
    assert_eq!(c.name(2), "Mail");
    assert_eq!(c.name(1), "1", "an unnamed island is its number");
    assert_eq!(c.step(3, 1), 1, "Ctrl-→ from the last is the first");
    assert_eq!(c.step(1, -1), 3, "Ctrl-← from the first is the last");
    assert_eq!(c.step(2, 1), 3);
}

#[test]
fn setup_is_done_once_said() {
    let dir = temp_dir();
    assert!(!SetupState::done(Some(&dir)), "a new account has not been through it");
    SetupState::mark_done(true, Some(&dir)).unwrap();
    assert!(SetupState::done(Some(&dir)), "skipped counts as said");
    assert_eq!(pool_config::load("setup", Some(&dir)).unwrap().string("setup", "how"), Some("skipped"));
}

#[test]
fn keys_ini_rows_lie_over_the_defaults() {
    let d = DesktopKeys::defaults();
    assert_eq!(d.len(), 20 + 9 * 4);
    assert_eq!(d[20], ("Ctrl+Shift+1".to_owned(), "shoal recall 1".to_owned()));
    assert_eq!(d.last().unwrap(), &("Ctrl+Alt+Shift+9".to_owned(), "move-to-island 9 follow".to_owned()));
    let dir = temp_dir();
    fs::write(format!("{dir}/keys.ini"), "[keys]\nf3 = ebb app\nCmd+K = run: x\n").unwrap();
    let rows = DesktopKeys::effective(Some(&dir));
    assert!(!rows.iter().any(|r| r.0 == "F3"), "a row replaces its default, in any case");
    assert_eq!(&rows[rows.len() - 2..], [("Cmd+K".to_owned(), "run: x".to_owned()), ("f3".to_owned(), "ebb app".to_owned())]);
    assert_eq!(DesktopKeys::effective(Some(&temp_dir())), d, "no keys.ini: the defaults");
}
