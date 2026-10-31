//! What the Finder does *to* files (FinderOps.swift): new folder, rename,
//! duplicate, copy and paste, move to Trash. The naming rules are pure
//! functions over an `exists` predicate; the filesystem half returns a bool,
//! because every caller reacts alike: say so and leave the listing.
//!
//! Deleting is *move to Trash* (`~/.Trash`), as on a Mac: nothing here
//! unlinks what a person asked to delete. The one exception is emptying the
//! Trash, which is what emptying it means.

use crate::finder_model::{finder_display_name, finder_join, read_directory};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};

// MARK: naming rules

/// Usable as a filename: non-empty, no separator, not `.` or `..`, at most
/// 255 bytes.
pub fn finder_is_valid_name(name: &str) -> bool {
    !name.is_empty() && name != "." && name != ".." && name.len() <= 255 && !name.contains('/')
}

/// A leaf as (base, extension with its dot). A leading dot is part of the
/// base (".hidden" has none), and so is a trailing one.
pub fn finder_split_extension(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(d) if d > 0 && d + 1 < name.len() => (&name[..d], &name[d..]),
        _ => (name, ""),
    }
}

/// "untitled folder", then "untitled folder 2", 3, … until one is free.
pub fn finder_new_folder_name(exists: impl Fn(&str) -> bool) -> String {
    let base = "untitled folder";
    if !exists(base) {
        return base.into();
    }
    (2..).map(|n| format!("{base} {n}")).find(|n| !exists(n)).unwrap()
}

/// " copy" before the extension, then " copy 2", … ("Read Me copy.txt").
pub fn finder_copy_name(name: &str, exists: impl Fn(&str) -> bool) -> String {
    let (base, ext) = finder_split_extension(name);
    let first = format!("{base} copy{ext}");
    if !exists(&first) {
        return first;
    }
    (2..).map(|n| format!("{base} copy {n}{ext}")).find(|n| !exists(n)).unwrap()
}

/// A pasted item keeps its name unless that is taken (pasted where it
/// came from), when the copy naming applies.
pub fn finder_paste_name(name: &str, exists: impl Fn(&str) -> bool) -> String {
    if exists(name) { finder_copy_name(name, exists) } else { name.into() }
}

// MARK: the filesystem

pub fn finder_exists(path: &str) -> bool {
    fs::symlink_metadata(path).is_ok()
}

pub fn finder_is_directory(path: &str) -> bool {
    fs::metadata(path).is_ok_and(|m| m.is_dir())
}

pub fn finder_create_directory(path: &str) -> bool {
    fs::DirBuilder::new().mode(0o755).create(path).is_ok()
}

pub fn finder_rename_entry(from: &str, to: &str) -> bool {
    fs::rename(from, to).is_ok()
}

/// A file's bytes and mode bits; a failure leaves no partial copy behind.
pub fn finder_copy_file(from: &str, to: &str) -> bool {
    let Ok(md) = fs::metadata(from) else { return false };
    if fs::copy(from, to).is_err() {
        let _ = fs::remove_file(to);
        return false;
    }
    fs::set_permissions(to, fs::Permissions::from_mode(md.permissions().mode() & 0o777)).is_ok()
}

/// A file or a whole tree, dot-files included. What is neither a file nor
/// a directory (a socket, a device) is skipped, not fatal.
pub fn finder_copy_path(from: &str, to: &str) -> bool {
    if !finder_is_directory(from) {
        return finder_copy_file(from, to);
    }
    if !finder_create_directory(to) {
        return false;
    }
    let mut ok = true;
    for e in read_directory(from, true) {
        let (f, t) = (finder_join(from, &e.name), finder_join(to, &e.name));
        let is_file = fs::metadata(&f).is_ok_and(|m| m.is_file());
        if finder_is_directory(&f) || is_file {
            ok &= finder_copy_path(&f, &t);
        }
    }
    ok
}

/// Where the Trash would be; not created, since the Dock asks on every
/// repaint and looking must not conjure directories.
pub fn finder_trash_path() -> Option<String> {
    std::env::var("HOME").ok().map(|h| format!("{h}/.Trash"))
}

/// `~/.Trash`, made when needed.
pub fn finder_trash_directory() -> Option<String> {
    let dir = finder_trash_path()?;
    (finder_exists(&dir) || finder_create_directory(&dir)).then_some(dir)
}

/// Move `path` to the Trash, uniquing its name there. None if it cannot be
/// moved (across filesystems: a half-finished delete is worse than a
/// refusal, so no copy-and-delete).
pub fn finder_move_to_trash(path: &str) -> Option<String> {
    move_to_trash_in(&finder_trash_directory()?, path)
}

fn move_to_trash_in(trash: &str, path: &str) -> Option<String> {
    let name = finder_paste_name(&finder_display_name(path), |n| finder_exists(&finder_join(trash, n)));
    let dest = finder_join(trash, &name);
    finder_rename_entry(path, &dest).then_some(dest)
}

/// Everything in the Trash, dot-files too; empty when there is none.
pub fn finder_trash_contents() -> Vec<String> {
    finder_trash_path().map_or(vec![], |t| trash_contents_in(&t))
}

fn trash_contents_in(trash: &str) -> Vec<String> {
    if !finder_is_directory(trash) {
        return vec![];
    }
    read_directory(trash, true).into_iter().map(|e| finder_join(trash, &e.name)).collect()
}

/// Remove a file, or a tree. **This unlinks**; only emptying the Trash
/// calls it.
pub fn finder_remove_path(path: &str) -> bool {
    let is_dir = fs::symlink_metadata(path).is_ok_and(|m| m.is_dir());
    if is_dir { fs::remove_dir_all(path).is_ok() } else { fs::remove_file(path).is_ok() }
}

/// Empty the Trash: how many top-level items went, and how many refused.
pub fn finder_empty_trash() -> (usize, usize) {
    finder_trash_path().map_or((0, 0), |t| empty_trash_in(&t))
}

fn empty_trash_in(trash: &str) -> (usize, usize) {
    let all = trash_contents_in(trash);
    let removed = all.iter().filter(|p| finder_remove_path(p)).count();
    (removed, all.len() - removed)
}

// MARK: what a drop contains

/// The first local path in a `text/uri-list` (RFC 2483): CRLF lines, `#`
/// comments, percent-encoded URIs. **A drop is not a string**: a file called
/// `My Report` arrives as `file:///home/me/My%20Report`.
pub fn finder_dropped_path(bytes: &[u8]) -> Option<String> {
    for raw in bytes.split(|b| *b == b'\r' || *b == b'\n') {
        let line = String::from_utf8_lossy(raw);
        let line = line.trim_matches([' ', '\t']);
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut s = line;
        if let Some(rest) = s.strip_prefix("file://") {
            s = rest;
            // An empty host is this machine; a remote one is no path of ours.
            if !s.starts_with('/') {
                let Some(slash) = s.find('/') else { continue };
                if &s[..slash] != "localhost" {
                    continue;
                }
                s = &s[slash..];
            }
        }
        if s.starts_with('/')
            && let Some(p) = finder_percent_decode(s)
        {
            return Some(p);
        }
    }
    None
}

/// A path as a `file://` URI, every byte outside RFC 3986's unreserved set
/// (and `/`) as `%XX`: a list we hand to other applications must follow it.
pub fn finder_file_uri(path: &str) -> String {
    let mut out = String::from("file://");
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char)
        } else {
            out.push_str(&format!("%{b:02X}"))
        }
    }
    out
}

/// Percent-decoding, byte-wise; None for a malformed escape, since a path
/// not read exactly must not be acted on.
pub fn finder_percent_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] != b'%' {
            out.push(b[i]);
            i += 1;
            continue;
        }
        let hex = |c: u8| (c as char).to_digit(16).map(|d| d as u8);
        let (hi, lo) = (hex(*b.get(i + 1)?)?, hex(*b.get(i + 2)?)?);
        out.push(hi << 4 | lo);
        i += 3;
    }
    Some(String::from_utf8_lossy(&out).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn split_extension() {
        assert_eq!(finder_split_extension("Read Me.txt"), ("Read Me", ".txt"));
        assert_eq!(finder_split_extension("Documents").1, "");
        assert_eq!(finder_split_extension(".hidden"), (".hidden", ""));
        assert_eq!(finder_split_extension("weird.").1, "");
        assert_eq!(finder_split_extension("a.tar.gz").1, ".gz");
    }

    #[test]
    fn new_folder_name_sequence() {
        let mut taken = HashSet::new();
        assert_eq!(finder_new_folder_name(|n| taken.contains(n)), "untitled folder");
        taken.insert("untitled folder".to_string());
        assert_eq!(finder_new_folder_name(|n| taken.contains(n)), "untitled folder 2");
        taken.insert("untitled folder 2".to_string());
        assert_eq!(finder_new_folder_name(|n| taken.contains(n)), "untitled folder 3");
    }

    #[test]
    fn copy_name_keeps_the_extension() {
        let mut taken: HashSet<String> = ["Read Me.txt", "Documents"].map(String::from).into();
        assert_eq!(finder_copy_name("Read Me.txt", |n| taken.contains(n)), "Read Me copy.txt");
        taken.insert("Read Me copy.txt".into());
        assert_eq!(finder_copy_name("Read Me.txt", |n| taken.contains(n)), "Read Me copy 2.txt");
        assert_eq!(finder_copy_name("Documents", |n| taken.contains(n)), "Documents copy");
    }

    #[test]
    fn paste_name_only_renames_on_collision() {
        let taken: HashSet<String> = ["Read Me.txt".to_string()].into();
        assert_eq!(finder_paste_name("notes.txt", |n| taken.contains(n)), "notes.txt");
        assert_eq!(finder_paste_name("Read Me.txt", |n| taken.contains(n)), "Read Me copy.txt");
    }

    #[test]
    fn name_validation() {
        assert!(finder_is_valid_name("Reports"));
        assert!(finder_is_valid_name(".hidden"));
        for bad in ["", ".", "..", "a/b"] {
            assert!(!finder_is_valid_name(bad), "{bad}")
        }
        assert!(!finder_is_valid_name(&"x".repeat(256)));
    }

    #[test]
    fn uri_round_trip_and_drops() {
        let p = "/home/me/My Report ü.txt";
        let uri = finder_file_uri(p);
        assert_eq!(uri, "file:///home/me/My%20Report%20%C3%BC.txt");
        assert_eq!(finder_dropped_path(format!("# comment\r\n{uri}\r\nfile:///second\r\n").as_bytes()).as_deref(), Some(p));
        assert_eq!(finder_dropped_path(b"file://localhost/tmp/x").as_deref(), Some("/tmp/x"));
        assert_eq!(finder_dropped_path(b"file://elsewhere/tmp/x"), None);
        assert_eq!(finder_percent_decode("/bad%2"), None);
    }

    /// On a real directory, with the Trash inside it rather than the real
    /// home.
    #[test]
    fn file_operations() {
        let root = std::env::temp_dir().join(format!("finderops.{}", std::process::id()));
        let root = root.to_str().unwrap().to_string();
        let _ = fs::remove_dir_all(&root);
        assert!(finder_create_directory(&root));
        let trash = finder_join(&root, ".Trash");
        assert!(finder_create_directory(&trash));
        let j = |p: &str| finder_join(&root, p);
        let read = |p: &str| fs::read_to_string(p).unwrap_or_default();
        let dir = j("work");
        let d = |p: &str| finder_join(&dir, p);
        assert!(finder_create_directory(&dir));
        assert!(finder_create_directory(&d("untitled folder")));
        assert!(finder_rename_entry(&d("untitled folder"), &d("Reports")));
        assert!(!finder_exists(&d("untitled folder")));
        assert!(finder_is_directory(&d("Reports")));

        fs::write(d("Read Me.txt"), "hello abyss").unwrap();
        assert!(finder_copy_file(&d("Read Me.txt"), &d("Read Me copy.txt")));
        assert_eq!(read(&d("Read Me copy.txt")), "hello abyss");

        fs::write(d("Reports/q1.txt"), "quarter one").unwrap();
        fs::write(d("Reports/.notes"), "private").unwrap();
        assert!(finder_create_directory(&d("Reports/sub")));
        fs::write(d("Reports/sub/deep.txt"), "deep").unwrap();
        assert!(finder_copy_path(&d("Reports"), &d("Reports copy")));
        assert_eq!(read(&d("Reports copy/q1.txt")), "quarter one");
        assert_eq!(read(&d("Reports copy/sub/deep.txt")), "deep");
        assert_eq!(read(&d("Reports copy/.notes")), "private");
        assert_eq!(read(&d("Reports/q1.txt")), "quarter one");

        // Delete is a move to the Trash, never an unlink.
        let trashed = move_to_trash_in(&trash, &d("Read Me copy.txt")).unwrap();
        assert!(!finder_exists(&d("Read Me copy.txt")));
        assert_eq!(read(&trashed), "hello abyss");
        assert!(trashed.starts_with(&j(".Trash")));
        // A second of that name is uniqued, not clobbered.
        fs::write(d("Read Me copy.txt"), "second one").unwrap();
        let again = move_to_trash_in(&trash, &d("Read Me copy.txt")).unwrap();
        assert_ne!(again, trashed);
        assert_eq!(read(&trashed), "hello abyss");
        assert_eq!(read(&again), "second one");

        // Emptying it is the one unlink.
        assert_eq!(empty_trash_in(&trash), (2, 0));
        assert!(trash_contents_in(&trash).is_empty());
        assert_eq!(empty_trash_in(&trash), (0, 0));
        let _ = fs::remove_dir_all(&root);
    }

    /// Looking at an absent Trash does not create it, and reads as empty;
    /// emptying takes a folder whole, dot-files too, and leaves the Trash.
    #[test]
    fn empty_trash_removes_everything_permanently() {
        let root = std::env::temp_dir().join(format!("emptytrash.{}", std::process::id()));
        let root = root.to_str().unwrap().to_string();
        let _ = fs::remove_dir_all(&root);
        assert!(finder_create_directory(&root));
        let trash = finder_join(&root, ".Trash");
        assert!(trash_contents_in(&trash).is_empty());
        assert_eq!(empty_trash_in(&trash), (0, 0));
        assert!(!finder_exists(&trash), "looking must not create it");

        assert!(finder_create_directory(&trash));
        let work = finder_join(&root, "work");
        assert!(finder_create_directory(&work));
        fs::write(finder_join(&work, "Read Me.txt"), "hello").unwrap();
        assert!(finder_create_directory(&finder_join(&work, "Reports")));
        fs::write(finder_join(&work, "Reports/q1.txt"), "quarter one").unwrap();
        fs::write(finder_join(&work, "Reports/.notes"), "private").unwrap();
        assert!(move_to_trash_in(&trash, &finder_join(&work, "Read Me.txt")).is_some());
        assert!(move_to_trash_in(&trash, &finder_join(&work, "Reports")).is_some());
        assert_eq!(trash_contents_in(&trash).len(), 2);

        assert_eq!(empty_trash_in(&trash), (2, 0));
        assert!(trash_contents_in(&trash).is_empty());
        assert!(finder_is_directory(&trash), "the folder stays, its contents do not");
        assert!(!finder_exists(&finder_join(&trash, "Reports/q1.txt")));
        assert!(finder_is_directory(&work), "nothing outside the Trash was touched");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn remove_path_deletes_trees_and_reports_failure() {
        let root = std::env::temp_dir().join(format!("removepath.{}", std::process::id()));
        let root = root.to_str().unwrap().to_string();
        let _ = fs::remove_dir_all(&root);
        let tree = finder_join(&root, "a");
        assert!(finder_create_directory(&root) && finder_create_directory(&tree) && finder_create_directory(&finder_join(&tree, "b")));
        fs::write(finder_join(&tree, "b/c.txt"), "").unwrap();
        assert!(finder_remove_path(&tree));
        assert!(!finder_exists(&tree));
        assert!(!finder_remove_path(&finder_join(&root, "gone")), "removing what is not there fails rather than pretending");
        let _ = fs::remove_dir_all(&root);
    }
}
