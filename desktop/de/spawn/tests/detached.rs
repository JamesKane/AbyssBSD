//! SpawnTests.swift's detached half: a detached program runs, in its own
//! session, and leaves nothing to reap. One test, in a binary of its own,
//! because it asks whether this process has any child at all.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

fn read_within(path: &Path, seconds: u64) -> Option<String> {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    while Instant::now() < deadline {
        if let Ok(s) = fs::read_to_string(path)
            && s.ends_with('\n')
        {
            return Some(s.trim_end().to_owned());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    None
}

#[test]
fn a_detached_program_runs_in_its_own_session_and_leaves_nothing_to_reap() {
    let dir = std::env::temp_dir().join(format!("abyss-detached-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let none = BTreeMap::new();

    // It runs, as a session leader of its own (setsid), not in ours.
    let out = dir.join("out");
    assert!(spawn::detached(&["sh", "-c", &format!("echo $$ $(ps -o sid= -p $$) > '{}.t' && mv '{0}.t' '{0}'", out.display())], &none));
    let line = read_within(&out, 5).expect("the program never ran");
    let f: Vec<i32> = line.split_whitespace().filter_map(|w| w.parse().ok()).collect();
    assert_eq!(f.len(), 2, "unexpected output: {line}");
    assert_eq!(f[0], f[1], "not a session leader: setsid did not happen");
    assert_ne!(f[1], abyss_sys::spawn::session_id(), "it is still in our session");
    assert!(!abyss_sys::spawn::has_children(), "a child was left for us to reap");

    // The environment reaches it.
    let env_out = dir.join("env");
    let env = BTreeMap::from([("ABYSS_SPAWN_T".to_owned(), "given".to_owned())]);
    assert!(spawn::detached(&["sh", "-c", &format!("echo \"$ABYSS_SPAWN_T\" > '{}.t' && mv '{0}.t' '{0}'", env_out.display())], &env));
    assert_eq!(read_within(&env_out, 5).as_deref(), Some("given"));

    // A program that cannot be found is not forked.
    assert!(!spawn::detached(&["no-such-program-anywhere-at-all"], &none));
    assert!(!spawn::detached(&[], &none));
    assert!(!abyss_sys::spawn::has_children(), "a fork happened for a command that was never going to run");
    fs::remove_dir_all(dir).unwrap();
}
