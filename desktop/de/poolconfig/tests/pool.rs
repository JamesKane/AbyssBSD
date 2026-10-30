//! Tests/PoolConfigTests (PoolConfigTests.swift, AgentsOnOffTests.swift),
//! ported: the same cases, against the Rust half.

use pool_config::{load, Agents, Config, DesktopKeys, KeyboardPrefs, Watcher};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};

/// A fresh, unique temp directory (created), so tests never touch the real
/// ~/.config/abyss and don't collide.
fn temp_dir() -> String {
    static N: AtomicUsize = AtomicUsize::new(0);
    let base = std::env::temp_dir();
    loop {
        let p = base.join(format!("poolcfg-rs.{}.{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
        if fs::create_dir(&p).is_ok() {
            return p.to_str().unwrap().to_owned();
        }
    }
}

fn exists(p: &str) -> bool {
    Path::new(p).exists()
}

// MARK: parse + typed coercion

#[test]
fn parse_sections_and_types() {
    let c = Config::parse(
        "schema_version = 1

[panel]
bg = #ff202028
apps = firefox,nautilus
height = 28
show_clock = true
offset = -3

# a comment, and a blank line follow

[desktop]
image = /path/to/wallpaper.png",
    );
    assert_eq!(c.schema_version(), 1);
    assert_eq!(c.string("panel", "bg"), Some("#ff202028"));
    assert_eq!(c.string("panel", "apps"), Some("firefox,nautilus"));
    assert_eq!(c.uint64("panel", "height"), Some(28));
    assert_eq!(c.bool("panel", "show_clock"), Some(true));
    assert_eq!(c.int64("panel", "offset"), Some(-3));
    assert_eq!(c.string("desktop", "image"), Some("/path/to/wallpaper.png"));

    // Absent keys/sections and type mismatches are None, not crashes.
    assert_eq!(c.string("panel", "nope"), None);
    assert_eq!(c.string("nosuch", "key"), None);
    assert_eq!(c.uint64("panel", "bg"), None);
    assert_eq!(c.bool("panel", "apps"), None);
}

#[test]
fn boolean_variants() {
    let c = Config::parse("[b]\na = TRUE\nb = on\nc = Yes\nd = 1\ne = off\nf = NO\ng = 0\nh = maybe\n");
    for (k, v) in [("a", true), ("b", true), ("c", true), ("d", true), ("e", false), ("f", false), ("g", false)] {
        assert_eq!(c.bool("b", k), Some(v), "{k}");
    }
    assert_eq!(c.bool("b", "h"), None);
}

// MARK: serialize

#[test]
fn to_ini_deterministic_and_reparses() {
    let mut c = Config::new();
    c.set_u64("", "schema_version", 1)
        .set_u64("panel", "height", 28)
        .set("panel", "bg", "#ff202028")
        .set("desktop", "image", "/wall.png")
        .set_bool("desktop", "show", false);
    let text = c.to_ini();
    // Default section first (no header); sections and keys sorted.
    assert_eq!(
        text,
        "schema_version = 1\n\n[desktop]\nimage = /wall.png\nshow = false\n\n[panel]\nbg = #ff202028\nheight = 28\n"
    );
    // Byte-identical after a round-trip through the parser.
    assert_eq!(Config::parse(&text).to_ini(), text);
}

// MARK: store / load round-trip

#[test]
fn store_load_round_trip() {
    let dir = temp_dir();
    let mut c = Config::new();
    c.set_u64("", "schema_version", 2)
        .set("desktop", "grad_top", "#ff0a0e16")
        .set_u64("desktop", "height", 600)
        .set_bool("desktop", "enabled", true);
    c.store("desktop", Some(&dir)).unwrap();
    assert!(exists(&format!("{dir}/desktop.ini")));

    let loaded = load("desktop", Some(&dir)).unwrap();
    assert_eq!(loaded.schema_version(), 2);
    assert_eq!(loaded.string("desktop", "grad_top"), Some("#ff0a0e16"));
    assert_eq!(loaded.uint64("desktop", "height"), Some(600));
    assert_eq!(loaded.bool("desktop", "enabled"), Some(true));
    assert_eq!(loaded, c); // full-config equality
}

/// T.2: the session's keyboard layout, as the installer writes it and
/// undertow reads it; none written is "none", so rc.conf's stands.
#[test]
fn keyboard_prefs_round_trip_and_default_to_none() {
    let dir = temp_dir();
    assert_eq!(KeyboardPrefs::load(Some(&dir)).kbdmap, "");
    KeyboardPrefs::new("de.kbd").store(Some(&dir)).unwrap();
    assert!(exists(&format!("{dir}/keyboard.ini")));
    assert_eq!(KeyboardPrefs::load(Some(&dir)), KeyboardPrefs::new("de.kbd"));
}

#[test]
fn missing_domain_is_empty() {
    let dir = temp_dir();
    let c = load("does-not-exist", Some(&dir)).unwrap();
    assert_eq!(c, Config::new());
    assert_eq!(c.schema_version(), 0);
}

#[test]
fn atomic_write_leaves_no_temp_or_lock_clutter() {
    let dir = temp_dir();
    let mut c = Config::new();
    c.set("x", "y", "z");
    c.store("panel", Some(&dir)).unwrap();
    assert!(exists(&format!("{dir}/panel.ini")));
    // The temp file is gone (renamed into place); the lock may remain as a
    // zero-byte coordination file, but never the .tmp.
    assert!(!exists(&format!("{dir}/panel.ini.tmp")));
}

#[test]
fn overwrite_replaces_atomically() {
    let dir = temp_dir();
    let mut a = Config::new();
    a.set("s", "k", "first");
    a.store("d", Some(&dir)).unwrap();
    let mut b = Config::new();
    b.set("s", "k", "second");
    b.store("d", Some(&dir)).unwrap();
    assert_eq!(load("d", Some(&dir)).unwrap().string("s", "k"), Some("second"));
}

// MARK: watcher

#[test]
fn watcher_wakes_on_store() {
    let dir = temp_dir();
    let watcher = Watcher::new(Some(&dir)).unwrap();
    // Nothing has changed yet.
    assert!(!watcher.drain());
    let mut c = Config::new();
    c.set("desktop", "bg", "#ff112233");
    c.store("desktop", Some(&dir)).unwrap();
    // The atomic store renames a file into the directory: the watcher wakes.
    assert!(watcher.wait(2000).unwrap(), "watcher should wake on an atomic store into its directory");
}

/// Truncate and rewrite, as a shell's `>` does: no rename, no new entry.
fn overwrite(path: &str, text: &str) {
    let mut f = OpenOptions::new().write(true).create(true).truncate(true).mode(0o644).open(path).unwrap();
    f.write_all(text.as_bytes()).unwrap();
}

/// An edit IN PLACE wakes it on both platforms (HANDOFF §2.124), and a file
/// that arrives after the watch began is watched too.
#[test]
fn watcher_wakes_on_an_edit_in_place_of_an_existing_file() {
    let dir = temp_dir();
    overwrite(&format!("{dir}/jails.ini"), "[apps]\nfirefox = app-net\n");
    let watcher = Watcher::new(Some(&dir)).unwrap();
    assert!(!watcher.wait(100).unwrap());
    overwrite(&format!("{dir}/jails.ini"), "[apps]\n");
    assert!(watcher.wait(2000).unwrap(), "an in-place edit of a file that was there did not wake it");
    while watcher.drain() {}

    overwrite(&format!("{dir}/later.ini"), "a = 1\n"); // arrives: the directory changes
    assert!(watcher.wait(2000).unwrap());
    while watcher.drain() {}
    overwrite(&format!("{dir}/later.ini"), "a = 2\n"); // and is then edited in place
    assert!(watcher.wait(2000).unwrap(), "an in-place edit of a file that arrived later did not wake it");
}

#[test]
fn watcher_times_out_when_idle() {
    let dir = temp_dir();
    let watcher = Watcher::new(Some(&dir)).unwrap();
    assert!(!watcher.wait(150).unwrap(), "watcher should time out when nothing changes");
}

// MARK: agents (AgentsOnOffTests.swift)

#[test]
fn off_is_the_file_absent() {
    let dir = temp_dir();
    assert!(!Agents::on(Some(&dir)), "a new account has no agents");
    assert_eq!(Agents::set(true, Some(&dir)), None);
    assert!(Agents::on(Some(&dir)));
    assert_eq!(Agents::set(true, Some(&dir)), None, "on twice is on");
    let mode = fs::metadata(format!("{dir}/agents.ini")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    assert_eq!(Agents::set(false, Some(&dir)), None);
    assert!(!Agents::on(Some(&dir)));
    assert_eq!(Agents::set(false, Some(&dir)), None, "off twice is off");
}

#[test]
fn the_chord_is_a_default() {
    assert!(DesktopKeys::defaults().iter().any(|(k, a)| k == "Cmd+Alt+A" && a == "agent"));
}
