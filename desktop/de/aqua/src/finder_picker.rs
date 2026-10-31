//! The Finder as a file picker (FinderPicker.swift, P7.1): the seam the
//! portal needs, deliberately tiny and file-shaped.
//!
//! ```text
//! $ABYSS_FINDER_PICK=/path/to/result   AquaDemo (AQUA_SCENE=finder)
//!   chosen     → its path written to the result file, exit 0
//!   cancelled  → nothing written,                     exit 1
//!   otherwise  → a crash, which the portal must tell apart
//! ```

use crate::finder_model::{finder_join, FinderEntry};
use std::io::Write;

/// What activating an item means. In picker mode a *file* is chosen, never
/// launched: a file dialog that ran what you clicked would be surprising,
/// and a way to make the picker execute things on an app's behalf.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FinderActivation {
    Navigate(String),
    Choose(String),
    Launch(String),
}

pub fn finder_activation(entry: &FinderEntry, directory: &str, picking: bool) -> FinderActivation {
    let full = finder_join(directory, &entry.name);
    match (entry.is_container(), picking) {
        (true, _) => FinderActivation::Navigate(full),
        (false, true) => FinderActivation::Choose(full),
        (false, false) => FinderActivation::Launch(full),
    }
}

pub const CHOSEN_EXIT: i32 = 0;
pub const CANCELLED_EXIT: i32 = 1;

/// The result file `$ABYSS_FINDER_PICK` names; None (empty too) when not
/// picking.
pub fn result_path() -> Option<String> {
    std::env::var("ABYSS_FINDER_PICK").ok().filter(|v| !v.is_empty())
}

pub fn is_picking() -> bool {
    result_path().is_some()
}

/// In save mode, the suggested name (`$ABYSS_FINDER_SAVE_NAME`): ⌘S saves
/// into the folder on screen under it, since picking from a listing cannot
/// name a file that does not exist yet. A stopgap with a real save panel
/// behind it.
pub fn save_name() -> Option<String> {
    std::env::var("ABYSS_FINDER_SAVE_NAME").ok().filter(|n| !n.is_empty() && !n.contains('/') && n != "." && n != "..")
}

pub fn is_saving() -> bool {
    is_picking() && save_name().is_some()
}

/// Write the chosen path, synced, and exit 0: the portal reads it the
/// moment the picker exits, and opens what it reads.
pub fn chose(path: &str) -> ! {
    if let Some(result) = result_path()
        && let Ok(mut f) = std::fs::OpenOptions::new().write(true).create(true).truncate(true).open(&result)
    {
        let _ = f.write_all(format!("{path}\n").as_bytes());
        let _ = f.sync_all();
    }
    std::process::exit(CHOSEN_EXIT)
}

/// Exit without writing: the person declined.
pub fn cancelled() -> ! {
    std::process::exit(CANCELLED_EXIT)
}

/// A result file as the portal reads it: None for no choice (absent, empty,
/// or not an absolute path, which would resolve against the portal's
/// directory rather than the person's choice).
pub fn read_result(path: &str) -> Option<String> {
    let s = std::fs::read_to_string(path).ok()?;
    let s = s.trim_end_matches(['\n', '\r']);
    (s.starts_with('/')).then(|| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::finder_model::FinderItemKind;

    #[test]
    fn picker_mode_chooses_a_file_instead_of_launching_it() {
        let doc = FinderEntry::sized("Read Me.txt", FinderItemKind::Document, 10);
        let folder = FinderEntry::new("Reports", FinderItemKind::Folder);
        let app = FinderEntry::new("Marker.app", FinderItemKind::Application);
        assert_eq!(finder_activation(&doc, "/home/x", false), FinderActivation::Launch("/home/x/Read Me.txt".into()));
        assert_eq!(finder_activation(&doc, "/home/x", true), FinderActivation::Choose("/home/x/Read Me.txt".into()));
        assert_eq!(finder_activation(&app, "/home/x", true), FinderActivation::Choose("/home/x/Marker.app".into()), "a bundle is chosen, never run");
        assert_eq!(finder_activation(&folder, "/home/x", true), FinderActivation::Navigate("/home/x/Reports".into()));
        assert_eq!(finder_activation(&folder, "/home/x", false), FinderActivation::Navigate("/home/x/Reports".into()));
    }

    #[test]
    fn the_result_file_round_trips_and_only_an_absolute_path_counts() {
        let d = std::env::temp_dir().join(format!("picker.{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let f = |n: &str| d.join(n).to_str().unwrap().to_string();
        std::fs::write(f("result"), "/home/x/Read Me.txt\n").unwrap();
        assert_eq!(read_result(&f("result")).as_deref(), Some("/home/x/Read Me.txt"));
        assert_eq!(read_result(&f("never-written")), None, "a cancel leaves no file");
        std::fs::write(f("empty"), "").unwrap();
        assert_eq!(read_result(&f("empty")), None, "a picker that died mid-write chose nothing");
        std::fs::write(f("relative"), "Read Me.txt\n").unwrap();
        assert_eq!(read_result(&f("relative")), None);
        let _ = std::fs::remove_dir_all(&d);
    }
}
