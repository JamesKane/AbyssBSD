//! The themes a person can choose, and what appearance.ini chose
//! (AppearancePane.swift's catalogue): **read, not remembered**, so a change
//! made elsewhere shows as soon as the window draws again.

use aquadraw::theme::{choice, parse, search_path, Choice, ThemeParameter};
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Debug, PartialEq)]
pub struct InstalledTheme {
    /// The directory name: what appearance.ini says.
    pub id: String,
    /// What the theme calls itself.
    pub name: String,
    pub schemes: Vec<String>,
    pub default_scheme: Option<String>,
    pub parameters: Vec<ThemeParameter>,
}

/// Every theme on `dirs` whose `theme.ini` parses (the first of a name
/// winning, as in loading), Aqua first, then by name. One that does not
/// parse is not offered: choosing it would put every process back on
/// Jaguar's compiled look at once.
pub fn installed_in(dirs: &[String]) -> Vec<InstalledTheme> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for d in dirs {
        let mut names: Vec<String> = std::fs::read_dir(d).map(|r| r.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| !n.starts_with('.')).collect()).unwrap_or_default();
        names.sort();
        for id in names {
            if seen.contains(&id) {
                continue;
            }
            let Some(t) = std::fs::read_to_string(format!("{d}/{id}/theme.ini")).ok().and_then(|text| parse(&text, None, &BTreeMap::new()).ok()) else { continue };
            seen.insert(id.clone());
            let mut schemes = t.schemes.clone();
            schemes.sort();
            out.push(InstalledTheme { id, name: t.name, schemes, default_scheme: t.scheme, parameters: t.parameters });
        }
    }
    out.sort_by(|a, b| (a.id != "aqua").cmp(&(b.id != "aqua")).then_with(|| a.name.cmp(&b.name)));
    out
}

pub fn installed() -> Vec<InstalledTheme> {
    installed_in(&search_path(None))
}

/// The choice, as every process reads it.
pub fn current() -> Choice {
    choice(None)
}
