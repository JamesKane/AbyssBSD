//! The applications installed as bundles (AppLibrary.swift, P15.2), for the
//! Dock and the Apple menu. `abyss-appgen` writes one per installed port
//! into ~/Applications and /Applications; anything else dropped there is a
//! bundle too. Each: its name, what to run, its icon, and the app_ids its
//! windows may carry, which is how a running window finds its tile.

use crate::app_icon;
use crate::finder_model::finder_join;
use crate::launcher::bundle_executable;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstalledApp {
    /// The bundle's name without `.app`: what the Dock shows.
    pub name: String,
    pub bundle: String,
    pub executable: Option<String>,
    pub icon: Option<String>,
    /// From `Contents/app-id`; empty for a bundle appgen did not write,
    /// which then matches by its own name only.
    pub app_ids: Vec<String>,
}

impl InstalledApp {
    pub fn matches(&self, app_id: &str) -> bool {
        let names = if self.app_ids.is_empty() { std::slice::from_ref(&self.name) } else { &self.app_ids[..] };
        app_bundles::matches(app_id, names)
    }
}

/// Where bundles live, the person's first: one of theirs shadows root's of
/// the same name.
pub fn directories() -> Vec<String> {
    let mut d = Vec::new();
    if let Ok(h) = std::env::var("HOME")
        && !h.is_empty()
    {
        d.push(finder_join(&h, "Applications"))
    }
    d.push("/Applications".into());
    d
}

fn small(path: &str) -> Option<String> {
    use std::io::Read;
    let mut s = String::new();
    std::fs::File::open(path).ok()?.take(4096).read_to_string(&mut s).ok()?;
    (!s.is_empty()).then_some(s)
}

/// A bundle's marker (`builtin:TOKEN` for a built-in's), if it has one.
pub fn marker(bundle: &str) -> Option<String> {
    small(&finder_join(bundle, app_bundles::MARKER))
}

/// Every bundle in `dirs` and their Utilities (Jaguar's: Terminal, Disk
/// Utility…), by name, the first of a name winning.
pub fn all_in(dirs: &[String]) -> Vec<InstalledApp> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for dir in dirs.iter().flat_map(|d| [d.clone(), finder_join(d, "Utilities")]) {
        let mut names: Vec<String> = std::fs::read_dir(&dir).map(|r| r.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default();
        names.sort();
        for e in names.into_iter().filter(|e| e.ends_with(".app")) {
            let name = e[..e.len() - 4].to_string();
            if !seen.insert(name.clone()) {
                continue;
            }
            let bundle = finder_join(&dir, &e);
            let app_ids = small(&finder_join(&bundle, app_bundles::APP_ID_FILE)).map_or(vec![], |s| s.lines().filter(|l| !l.is_empty()).map(String::from).collect());
            out.push(InstalledApp { name, executable: bundle_executable(&bundle), icon: app_icon::icon_file(&bundle), bundle, app_ids });
        }
    }
    out
}

pub fn all() -> Vec<InstalledApp> {
    all_in(&directories())
}

/// The bundle a name means: `Galculator`, `Galculator.app`, or a path.
pub fn find<'a>(name: &str, apps: &'a [InstalledApp]) -> Option<&'a InstalledApp> {
    if name.starts_with('/') {
        return apps.iter().find(|a| a.bundle == name);
    }
    let n = name.strip_suffix(".app").unwrap_or(name);
    apps.iter().find(|a| a.name == n)
}

/// The bundle a running window belongs to.
pub fn owner<'a>(app_id: &str, apps: &'a [InstalledApp]) -> Option<&'a InstalledApp> {
    apps.iter().find(|a| a.matches(app_id))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A bundle may name a theme icon; Utilities is read.
    #[test]
    fn a_builtins_bundle_wears_the_themes_icon() {
        let dir = std::env::temp_dir().join(format!("abyss-apps-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let b = dir.join("Utilities/Grab.app");
        std::fs::create_dir_all(b.join("Contents/MacOS")).unwrap();
        std::fs::write(b.join("Contents/theme-icon"), "dock.icon.grab\n").unwrap();
        std::fs::write(b.join("Contents/app-id"), "org.abyssbsd.grab\n").unwrap();
        assert_eq!(app_icon::icon_file(b.to_str().unwrap()).as_deref(), Some("theme:dock.icon.grab"));
        let lib = all_in(&[dir.to_str().unwrap().into()]);
        assert_eq!(lib.iter().map(|a| a.name.as_str()).collect::<Vec<_>>(), ["Grab"], "Utilities is read");
        assert_eq!(lib[0].icon.as_deref(), Some("theme:dock.icon.grab"));
        assert!(lib[0].matches("org.abyssbsd.grab"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
