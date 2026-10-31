//! What a double-click on something that is not a folder does
//! (Launcher.swift), in the order the Finder tries:
//!
//! 1. an **application bundle** runs `Foo.app/Contents/MacOS/Foo` (else the
//!    first executable there);
//! 2. plain text opens in TextEdit, by its name, or by its bytes when it has
//!    no extension, unless an opener is configured;
//! 3. a plain **executable** runs;
//! 4. anything else goes to the **opener** (`$ABYSS_OPEN`, else
//!    `open_command` in `finder.ini`), if there is one.
//!
//! With no handler nothing runs and the caller says so: a double-click
//! that silently does nothing is worse than one that says why. Processes
//! start detached (`spawn::detached`), never ours to reap.
//!
//! RecentItems (RecentItems.swift, P15.2c) is here too: the applications
//! last opened, for the Apple menu, in the `recent` domain of the pool.

use crate::finder_model::{finder_display_name, finder_join, read_directory};
use crate::finder_ops::finder_is_directory;
use menu_model::{Command, Menu, MenuItem};
use std::collections::BTreeMap;
use std::fmt;
use std::os::unix::fs::PermissionsExt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LaunchOutcome {
    LaunchedApp(String),
    RanExecutable(String),
    OpenedWith(String),
    NoHandler,
    Failed(String),
}

/// A short line for the log (the live tests read these).
impl fmt::Display for LaunchOutcome {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            LaunchOutcome::LaunchedApp(p) => write!(f, "launched {p}"),
            LaunchOutcome::RanExecutable(p) => write!(f, "ran {p}"),
            LaunchOutcome::OpenedWith(c) => write!(f, "opened with {c}"),
            LaunchOutcome::NoHandler => write!(f, "no handler"),
            LaunchOutcome::Failed(why) => write!(f, "launch failed: {why}"),
        }
    }
}

/// A regular file with any execute bit.
pub fn is_executable_file(path: &str) -> bool {
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// `Foo.app/Contents/MacOS/Foo` by the convention, else the first
/// executable in `Contents/MacOS`.
pub fn bundle_executable(bundle: &str) -> Option<String> {
    let mac_os = finder_join(bundle, "Contents/MacOS");
    let name = finder_display_name(bundle);
    let conventional = finder_join(&mac_os, name.strip_suffix(".app").unwrap_or(&name));
    if is_executable_file(&conventional) {
        return Some(conventional);
    }
    read_directory(&mac_os, false).into_iter().map(|e| finder_join(&mac_os, &e.name)).find(|p| is_executable_file(p))
}

/// Split on runs of spaces and tabs. No quoting: pretending to parse it
/// would mangle an argument with a space in it silently.
pub fn split_command(s: &str) -> Vec<String> {
    s.split([' ', '\t']).filter(|p| !p.is_empty()).map(String::from).collect()
}

/// The opener: `$ABYSS_OPEN`, else `finder.ini`'s `open_command`.
pub fn opener_command() -> Vec<String> {
    if let Ok(e) = std::env::var("ABYSS_OPEN")
        && !e.is_empty()
    {
        return split_command(&e);
    }
    let config = pool_config::load("finder", None).unwrap_or_default();
    config.string("finder", "open_command").map_or(vec![], split_command)
}

/// This program: how the Dock starts another copy of the shell.
/// `$ABYSS_APP_BINARY` overrides, when it names something executable.
pub fn self_executable() -> Option<String> {
    if let Ok(e) = std::env::var("ABYSS_APP_BINARY")
        && is_executable_file(&e)
    {
        return Some(e);
    }
    abyss_sys::proc::self_executable()
}

/// Start `argv` detached, with `env` added to ours.
pub fn launch_detached(argv: &[String], env: &[(&str, &str)]) -> bool {
    let a: Vec<&str> = argv.iter().map(String::as_str).collect();
    let e: BTreeMap<String, String> = env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    spawn::detached(&a, &e)
}

/// Decide what to do with `path`, and do it.
pub fn open(path: &str) -> LaunchOutcome {
    if path.ends_with(".app") && finder_is_directory(path) {
        let Some(exe) = bundle_executable(path) else { return LaunchOutcome::Failed(format!("{path} has no executable in Contents/MacOS")) };
        if !launch_detached(std::slice::from_ref(&exe), &[]) {
            return LaunchOutcome::Failed(format!("could not start {exe}"));
        }
        recent::record(path);
        return LaunchOutcome::LaunchedApp(exe);
    }
    // Text by its name before the execute bit: a file off a FAT stick has
    // every bit set, and a `.txt` must not run.
    let base = path.rsplit('/').next().unwrap_or(path);
    if has_text_extension(base) {
        return open_document(path, true);
    }
    if is_executable_file(path) {
        return if launch_detached(&[path.to_string()], &[]) { LaunchOutcome::RanExecutable(path.into()) } else { LaunchOutcome::Failed(format!("could not start {path}")) };
    }
    if !base.contains('.') && looks_like_text(&head(path)) {
        return open_document(path, true);
    }
    open_document(path, false)
}

/// A document: to the opener when there is one; else text to TextEdit.
fn open_document(path: &str, text: bool) -> LaunchOutcome {
    let opener = opener_command();
    if opener.is_empty() {
        return if text { open_in_text_edit(path) } else { LaunchOutcome::NoHandler };
    }
    let mut argv = opener.clone();
    argv.push(path.into());
    if launch_detached(&argv, &[]) { LaunchOutcome::OpenedWith(opener.join(" ")) } else { LaunchOutcome::Failed(format!("could not run {}", opener[0])) }
}

/// TextEdit is this program in another scene.
fn open_in_text_edit(path: &str) -> LaunchOutcome {
    let Some(exe) = self_executable() else { return LaunchOutcome::Failed("cannot find this program to run TextEdit".into()) };
    if launch_detached(&[exe, path.into()], &[("AQUA_SCENE", "textedit")]) { LaunchOutcome::OpenedWith("TextEdit".into()) } else { LaunchOutcome::Failed("could not start TextEdit".into()) }
}

/// The first 4 KB, for sniffing.
fn head(path: &str) -> Vec<u8> {
    use std::io::Read;
    let mut buf = Vec::new();
    if let Ok(f) = std::fs::File::open(path) {
        let _ = f.take(4096).read_to_end(&mut buf);
    }
    buf
}

const TEXT_EXTENSIONS: &[&str] = &[
    "txt", "text", "md", "markdown", "rst", "log", "conf", "cfg", "ini", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "sh", "c", "h", "cc", "cpp", "hpp", "swift", "py", "rb", "pl", "lua", "rs", "go", "js", "ts", "css", "html", "htm", "tex", "diff", "patch",
];

/// A text name: an extension TextEdit opens. A dotfile's name is not one.
pub fn has_text_extension(name: &str) -> bool {
    match name.rfind('.') {
        Some(d) if d > 0 => TEXT_EXTENSIONS.contains(&name[d + 1..].to_lowercase().as_str()),
        _ => false,
    }
}

/// UTF-8 with no NUL. A rune cut off at the 4 KB edge is no reason to say
/// no: up to three trailing non-ASCII bytes may go.
pub fn looks_like_text(head: &[u8]) -> bool {
    if head.is_empty() || head.contains(&0) {
        return false;
    }
    for drop in 0..=3.min(head.len() - 1) {
        if drop > 0 && head[head.len() - drop] < 0x80 {
            break;
        }
        if std::str::from_utf8(&head[..head.len() - drop]).is_ok() {
            return true;
        }
    }
    false
}

/// The applications last opened. Three processes open them (the Finder,
/// the Dock and the menu bar) and a fourth shows them, so the list lives in
/// the pool, one key per entry, most recent first.
pub mod recent {
    use super::*;

    /// Jaguar's default length.
    pub const LIMIT: usize = 10;
    const DOMAIN: &str = "recent";
    const SECTION: &str = "applications";

    /// `list` with `bundle` first, once, and no longer than the limit.
    pub fn adding(bundle: &str, list: &[String]) -> Vec<String> {
        std::iter::once(bundle.to_string()).chain(list.iter().filter(|b| *b != bundle).cloned()).take(LIMIT).collect()
    }

    /// Keys are `0`…`9`, so sorted order is the order.
    pub fn load(dir: Option<&str>) -> Vec<String> {
        let c = pool_config::load(DOMAIN, dir).unwrap_or_default();
        let mut pairs: Vec<(usize, String)> = c.pairs(SECTION).into_iter().filter(|(_, v)| !v.is_empty()).filter_map(|(k, v)| Some((k.parse().ok()?, v.to_string()))).collect();
        pairs.sort();
        pairs.into_iter().map(|(_, v)| v).collect()
    }

    pub fn save(list: &[String], dir: Option<&str>) {
        let mut c = pool_config::Config::new();
        for (i, p) in list.iter().take(LIMIT).enumerate() {
            c.set(SECTION, &i.to_string(), p);
        }
        let _ = c.store(DOMAIN, dir);
    }

    /// `bundle` was just opened.
    pub fn record(bundle: &str) {
        save(&adding(bundle, &load(None)), None)
    }

    /// Each application by its bundle's name, then Clear Menu. A verb
    /// carries its place in `list`, which the bar keeps.
    pub fn submenu(list: &[String]) -> Menu {
        let mut items: Vec<MenuItem> = list
            .iter()
            .enumerate()
            .map(|(i, path)| {
                let base = path.rsplit('/').next().unwrap_or(path);
                let name = base.strip_suffix(".app").unwrap_or(base);
                MenuItem::Command(Command::new(&format!("system.recent.{i}"), name, &format!("Open {name} again.")))
            })
            .collect();
        if !items.is_empty() {
            items.push(MenuItem::Separator)
        }
        items.push(MenuItem::Command(Command::new("system.recent.clear", "Clear Menu", "Forget the recent applications.")));
        Menu::new("Recent Items", items)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> String {
        let d = std::env::temp_dir().join(format!("{tag}.{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d.to_str().unwrap().into()
    }

    #[test]
    fn recent_items_are_the_last_ten_applications_opened() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(recent::adding("/A/K.app", &s(&["/A/F.app", "/A/K.app", "/A/T.app"])), s(&["/A/K.app", "/A/F.app", "/A/T.app"]), "moved to the top, not doubled");
        let many: Vec<String> = (0..10).map(|i| format!("/A/{i}.app")).collect();
        let added = recent::adding("/A/new.app", &many);
        assert_eq!((added.len(), added.last().map(String::as_str)), (10, Some("/A/8.app")));
        let titles: Vec<String> = recent::submenu(&s(&["/Applications/Galculator.app", "/u/Applications/Firefox Web Browser.app"])).commands().iter().map(|c| c.title.clone()).collect();
        assert_eq!(titles, ["Galculator", "Firefox Web Browser", "Clear Menu"]);
        assert_eq!(recent::submenu(&[]).commands().iter().map(|c| c.verb.clone()).collect::<Vec<_>>(), ["system.recent.clear"]);
        let dir = scratch("recent");
        let list: Vec<String> = (0..12).map(|i| format!("/A/{i}.app")).collect();
        recent::save(&list, Some(&dir));
        assert_eq!(recent::load(Some(&dir)), list[..10].to_vec(), "read back in order, ten kept");
        assert_eq!(recent::load(Some(&format!("{dir}/nowhere"))), Vec::<String>::new());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn plain_text_is_known_by_name_or_bytes() {
        assert!(has_text_extension("notes.TXT"));
        assert!(has_text_extension("main.swift"));
        assert!(!has_text_extension("run.sh.bak"));
        assert!(!has_text_extension(".profile"), "a dotfile's name is not an extension");
        assert!(looks_like_text("# README\nCafé ☕\n".as_bytes()));
        assert!(!looks_like_text(&[0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x00]), "an ELF binary");
        assert!(!looks_like_text(&[0xFF, 0xFE, 0x41]), "not UTF-8");
        let mut cut = b"aaaaaaaaaa".to_vec();
        cut.extend([0xE2, 0x98]);
        assert!(looks_like_text(&cut), "a rune cut off at the edge is still text");
        assert!(!looks_like_text(&[]));
    }

    #[test]
    fn launcher_finds_its_own_executable() {
        let me = self_executable().expect("self_executable");
        assert!(me.starts_with('/') && is_executable_file(&me), "{me}");
    }

    #[test]
    fn launcher_splits_command_lines() {
        assert_eq!(split_command("xdg-open"), ["xdg-open"]);
        assert_eq!(split_command("  open   -a  Preview "), ["open", "-a", "Preview"]);
        assert!(split_command("").is_empty());
    }

    #[test]
    fn launcher_finds_a_bundle_executable() {
        let root = scratch("bundle");
        let app = finder_join(&root, "Foo.app");
        std::fs::create_dir_all(finder_join(&app, "Contents/MacOS")).unwrap();
        let exe = finder_join(&app, "Contents/MacOS/Foo");
        std::fs::write(&exe, "").unwrap();
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(bundle_executable(&app).as_deref(), Some(exe.as_str()));
        assert!(is_executable_file(&exe));
        let bare = finder_join(&root, "Bare.app");
        std::fs::create_dir_all(&bare).unwrap();
        assert_eq!(bundle_executable(&bare), None);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn launcher_runs_a_detached_process() {
        let root = scratch("launch");
        let marker = finder_join(&root, "ran.txt");
        let script = finder_join(&root, "run.sh");
        std::fs::write(&script, format!("#!/bin/sh\nprintf '%s' \"$ABYSS_TEST_TAG\" > {marker}\n")).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(launch_detached(std::slice::from_ref(&script), &[("ABYSS_TEST_TAG", "hello")]));
        let mut got = String::new();
        for _ in 0..50 {
            got = std::fs::read_to_string(&marker).unwrap_or_default();
            if !got.is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert_eq!(got, "hello", "the detached child ran with our environment");
        assert!(!launch_detached(&["definitely-not-a-real-command-xyz".into()], &[]));
        let _ = std::fs::remove_dir_all(&root);
    }
}
