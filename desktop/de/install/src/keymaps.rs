//! The keyboard layouts, in both of FreeBSD's vocabularies (Keymaps.swift).
//!
//! The console reads rc.conf's `keymap=`, a `kbdmap` file name
//! (`uk.kbd`); the desktop compiles an XKB keymap from a layout and variant
//! (`gb`). The installer writes one, and this is how it is read twice
//! (HANDOFF §2.70).

use std::fs;

/// One layout, named the way each half of the system names it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Keymap {
    /// The file in `/usr/share/vt/keymaps`, as `keymap=` takes it.
    pub kbdmap: String,
    /// XKB's layout and variant (`us`, `dvorak`); empty for the default.
    pub layout: String,
    pub variant: String,
    /// What a person reads (BACKLOG T.1): "U.S.", "British", not the file.
    /// Empty for a keymap the installer does not offer.
    pub name: String,
}

fn k(kbdmap: &str, layout: &str, variant: &str, name: &str) -> Keymap {
    Keymap { kbdmap: kbdmap.into(), layout: layout.into(), variant: variant.into(), name: name.into() }
}

/// What the installer offers: a short, honest list. **Each `kbdmap` must be
/// a file FreeBSD ships** (it once offered `dvorak.kbd`, which is not).
pub fn offered() -> Vec<Keymap> {
    vec![
        k("us.kbd", "us", "", "U.S."),
        k("uk.kbd", "gb", "", "British"),
        k("de.kbd", "de", "", "German"),
        k("fr.kbd", "fr", "", "French"),
        k("es.kbd", "es", "", "Spanish"),
        k("it.kbd", "it", "", "Italian"),
        k("us.dvorak.kbd", "us", "dvorak", "Dvorak"),
        k("colemak.acc.kbd", "us", "colemak", "Colemak"),
    ]
}

/// What to call a `kbdmap` on screen: its name when offered, otherwise the
/// file, since a guessed name could be wrong.
pub fn display_name(kbdmap: &str) -> String {
    offered().into_iter().find(|k| k.kbdmap == kbdmap).map_or_else(|| kbdmap.to_owned(), |k| k.name)
}

/// The XKB layout for a `kbdmap` name, and whether it is exact. An offered
/// name translates exactly; another is guessed from its prefix
/// (`de.acc.kbd` is `de`, and `uk` is `gb`), so XKB may refuse it.
pub fn xkb(kbdmap: &str) -> Option<(Keymap, bool)> {
    if let Some(k) = offered().into_iter().find(|k| k.kbdmap == kbdmap) {
        return Some((k, true));
    }
    if !kbdmap.ends_with(".kbd") {
        return None;
    }
    let prefix = kbdmap.split('.').find(|p| !p.is_empty())?;
    let layout = if prefix == "uk" { "gb" } else { prefix };
    Some((k(kbdmap, layout, "", ""), false))
}

/// The `keymap=` a system is configured with, or None: rc.conf, then
/// rc.conf.local, as rc(8) reads them, the last assignment winning. `NO`,
/// /etc/defaults/rc.conf's default, means none.
pub fn configured(rc_conf: &[&str]) -> Option<String> {
    let mut value = None;
    for path in rc_conf {
        let Ok(bytes) = fs::read(path) else { continue };
        if let Some(v) = last_assignment("keymap", &String::from_utf8_lossy(&bytes)) {
            value = Some(v);
        }
    }
    value.filter(|v| !v.is_empty() && v != "NO")
}

/// The system's own rc.conf files.
pub const RC_CONF: [&str; 2] = ["/etc/rc.conf", "/etc/rc.conf.local"];

/// The last `name=value` in shell-assignment text, quotes removed. Not a
/// shell: plain assignments, which is what the installer writes and `sysrc`
/// edits. A line ends at LF, and a CR before it is dropped, so a CRLF file
/// reads (to Swift it is one line).
pub fn last_assignment(name: &str, text: &str) -> Option<String> {
    let mut found = None;
    for raw in text.split('\n') {
        let line = raw.strip_suffix('\r').unwrap_or(raw).trim_start_matches([' ', '\t']);
        let Some(v) = line.strip_prefix(name).and_then(|l| l.strip_prefix('=')) else { continue };
        let v = match v.chars().next() {
            Some(q @ ('"' | '\'')) => v[1..].split(q).next().unwrap_or(""),
            _ => v.split([' ', '\t', '#']).next().unwrap_or(""),
        };
        found = Some(v.to_owned());
    }
    found
}
