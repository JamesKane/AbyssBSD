//! AppBundles in Rust: a port's `.desktop` entry, as a Mac-shaped
//! application bundle (PHASE15 P15.1), ported from AppBundles.swift beside
//! it.
//!
//! Ports install freedesktop Desktop Entries and icon themes; the Finder and
//! the Dock understand `Foo.app` bundles (`Contents/MacOS/Foo` is run, the
//! first icon in `Contents/Resources` is drawn). This is the translation, as
//! values: parse an entry, decide whether it is an application a person
//! should see, turn its `Exec` into a launcher script, and choose its icon
//! from the files a theme offers. It does no I/O (`abyss-appgen` walks the
//! directories, rasterises, and writes), so every rule is tested with no
//! filesystem.

// MARK: the entry

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DesktopEntry {
    pub kind: String,
    pub name: String,
    pub exec: String,
    pub icon: String,
    pub comment: String,
    pub no_display: bool,
    pub hidden: bool,
    pub terminal: bool,
    pub try_exec: String,
    pub startup_wm_class: String,
    pub only_show_in: Vec<String>,
    pub not_show_in: Vec<String>,
    /// `X-Abyss-Jail`: the jail class the entry asks to run in (P18.5).
    pub jail: String,
}

/// Where the files go in `command().0`.
pub const FILES_MARKER: &str = "\0files\0";

fn trim(s: &str) -> &str {
    s.trim_matches([' ', '\t', '\r'])
}

fn list(v: &str) -> Vec<String> {
    v.split(';').filter(|x| !x.is_empty()).map(str::to_owned).collect()
}

/// The string escapes every value may carry: `\s \n \t \r \\`.
fn unescape(s: &str) -> String {
    if !s.contains('\\') {
        return s.to_owned();
    }
    let mut out = String::new();
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.next() {
            None => out.push('\\'),
            Some('s') => out.push(' '),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some(n) => {
                out.push('\\');
                out.push(n);
            }
        }
    }
    out
}

/// The spec's argument splitting: double quotes, with backslash escapes
/// inside them. None for an unclosed quote.
fn split(s: &str) -> Option<Vec<String>> {
    let (mut out, mut cur, mut quoted, mut in_word) = (vec![], String::new(), false, false);
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if quoted {
            match c {
                '"' => quoted = false,
                '\\' => {
                    if let Some(n) = it.next() {
                        cur.push(n);
                    }
                }
                _ => cur.push(c),
            }
        } else if c == '"' {
            quoted = true;
            in_word = true;
        } else if c == ' ' || c == '\t' {
            if in_word {
                out.push(std::mem::take(&mut cur));
                in_word = false;
            }
        } else {
            cur.push(c);
            in_word = true;
        }
    }
    if quoted {
        return None;
    }
    if in_word {
        out.push(cur);
    }
    Some(out)
}

impl DesktopEntry {
    /// Parse the `[Desktop Entry]` group. Localised keys (`Name[fr]`) are
    /// skipped: the bundle takes the default. Unknown keys are ignored, as
    /// the spec asks; a line that is not `key=value` is ignored rather than
    /// fatal. None when there is no such group.
    pub fn parse(text: &str) -> Option<DesktopEntry> {
        let mut e = DesktopEntry::default();
        let (mut in_group, mut saw) = (false, false);
        for raw in text.split('\n') {
            let line = trim(raw);
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if line.starts_with('[') {
                in_group = line == "[Desktop Entry]";
                saw |= in_group;
                continue;
            }
            let Some((key, value)) = line.split_once('=').filter(|_| in_group) else { continue };
            let key = trim(key);
            if key.contains('[') {
                continue;
            }
            let value = unescape(trim(value));
            let flag = || value == "true";
            match key {
                "Type" => e.kind = value,
                "Name" => e.name = value,
                "Exec" => e.exec = value,
                "Icon" => e.icon = value,
                "Comment" => e.comment = value,
                "NoDisplay" => e.no_display = flag(),
                "Hidden" => e.hidden = flag(),
                "Terminal" => e.terminal = flag(),
                "TryExec" => e.try_exec = value,
                "StartupWMClass" => e.startup_wm_class = value,
                "OnlyShowIn" => e.only_show_in = list(&value),
                "NotShowIn" => e.not_show_in = list(&value),
                "X-Abyss-Jail" => e.jail = value,
                _ => {}
            }
        }
        saw.then_some(e)
    }

    /// Why this entry does not become an application a person sees, or None
    /// when it does. `desktop` is `XDG_CURRENT_DESKTOP`'s name for us.
    pub fn skip_reason(&self, desktop: &str, have_terminal: bool) -> Option<String> {
        if self.kind != "Application" {
            return Some(if self.kind.is_empty() { "no Type".into() } else { format!("a {}, not an application", self.kind) });
        }
        if self.hidden {
            return Some("Hidden".into());
        }
        if self.no_display {
            return Some("NoDisplay (a handler or a service, not an application)".into());
        }
        if self.name.is_empty() {
            return Some("no Name".into());
        }
        if self.exec.is_empty() {
            return Some("no Exec".into());
        }
        if !self.only_show_in.is_empty() && !self.only_show_in.iter().any(|d| d == desktop) {
            return Some(format!("only for {}", self.only_show_in.join(", ")));
        }
        if self.not_show_in.iter().any(|d| d == desktop) {
            return Some(format!("not for {desktop}"));
        }
        if self.terminal && !have_terminal {
            return Some("needs a terminal, and Terminal was not found beside abyss-appgen".into());
        }
        None
    }

    /// `Exec` as the words to run and whether it takes files: the spec's
    /// quoting, and its field codes: `%f %F %u %U` are the files a person
    /// opens with it (at most one of them), `%%` is a percent sign, and the
    /// rest are dropped. None when it cannot be run (nothing, or a field
    /// code where the program should be).
    pub fn command(&self) -> Option<(Vec<String>, bool)> {
        let words = split(&self.exec)?;
        let mut takes_files = false;
        let mut out = vec![];
        for w in words {
            match w.as_str() {
                "%f" | "%F" | "%u" | "%U" => {
                    if !takes_files {
                        takes_files = true;
                        out.push(FILES_MARKER.to_owned());
                    }
                }
                "%i" | "%c" | "%k" | "%d" | "%D" | "%n" | "%N" | "%v" | "%m" => {}
                _ => out.push(w.replace("%%", "%")),
            }
        }
        if out.is_empty() || out[0] == FILES_MARKER {
            return None;
        }
        Some((out, takes_files))
    }

    /// The app_ids a running window of this application may carry (P15.2):
    /// its `StartupWMClass`, its desktop-file ID (the Wayland convention),
    /// then the name of the program it runs. None is guaranteed (Firefox
    /// ESR's window says `firefox-esr`), so [`matches`] also takes the
    /// program's name with a suffix.
    pub fn app_ids(&self, desktop_file: &str) -> Vec<String> {
        let mut ids: Vec<String> = vec![];
        let mut add = |s: &str| {
            if !s.is_empty() && !ids.iter().any(|i| i == s) {
                ids.push(s.to_owned());
            }
        };
        add(&self.startup_wm_class);
        let base = desktop_file.rsplit('/').next().unwrap_or(desktop_file);
        add(base.strip_suffix(".desktop").unwrap_or(base));
        if let Some((argv, _)) = self.command() {
            // `env VAR=x prog` runs prog.
            let prog = if argv[0] == "env" { argv.iter().skip(1).find(|a| !a.contains('=')) } else { argv.first() };
            if let Some(p) = prog {
                add(p.rsplit('/').next().unwrap_or(p));
            }
        }
        ids
    }
}

// MARK: the bundle

/// The desktop's own applications (PHASE15, PHASE18): each the shell binary
/// in a scene. One list, for the Dock's tiles and the bundles abyss-appgen
/// writes: Jaguar's layout, the utilities in `Utilities`, and the Finder in
/// neither (it lived in CoreServices).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BuiltinApp {
    /// What pins it in dock.ini.
    pub token: &'static str,
    pub name: &'static str,
    /// The app_id its windows carry.
    pub app_id: &'static str,
    /// `AQUA_SCENE`.
    pub scene: &'static str,
    /// Where its bundle goes under an Applications folder: "" (the folder
    /// itself), "Utilities", or None for no bundle at all.
    pub folder: Option<&'static str>,
    /// Its icon in the theme's Dock set, `dock.icon.<icon>`.
    pub icon: &'static str,
}

const fn builtin(token: &'static str, name: &'static str, app_id: &'static str, scene: &'static str, folder: Option<&'static str>, icon: &'static str) -> BuiltinApp {
    BuiltinApp { token, name, app_id, scene, folder, icon }
}

pub const BUILTIN_APPS: [BuiltinApp; 9] = [
    builtin("finder", "Finder", "org.abyssbsd.finder", "finder", None, "finder"),
    builtin("terminal", "Terminal", "org.abyssbsd.terminal", "terminal", Some("Utilities"), "terminal"),
    builtin("sysprefs", "System Preferences", "org.abyssbsd.preferences", "sysprefs", Some(""), "prefs"),
    builtin("agent", "Agent", "org.abyssbsd.agent", "agent", Some(""), "agent"),
    builtin("textedit", "TextEdit", "org.abyssbsd.textedit", "textedit", Some(""), "textedit"),
    builtin("grab", "Grab", "org.abyssbsd.grab", "grab", Some("Utilities"), "grab"),
    builtin("activity", "Activity Monitor", "org.abyssbsd.activitymonitor", "activity", Some("Utilities"), "activity"),
    builtin("diskutility", "Disk Utility", "org.abyssbsd.diskutility", "diskutility", Some("Utilities"), "diskutility"),
    builtin("systemprofiler", "System Profiler", "org.abyssbsd.systemprofiler", "systemprofiler", Some("Utilities"), "systemprofiler"),
];

impl BuiltinApp {
    /// The theme icon that draws it: the Dock's, in whatever theme is on.
    pub fn theme_icon(&self) -> String {
        format!("dock.icon.{}", self.icon)
    }

    /// Its bundle's marker text: how abyss-appgen knows it as a built-in's.
    pub fn marker(&self) -> String {
        format!("builtin:{}", self.token)
    }

    /// The launcher: the shell binary, in its scene, with what it is handed.
    pub fn launcher(&self, binary: &str) -> String {
        format!(
            "#!/bin/sh\n# Generated by abyss-appgen: the desktop's {} — regenerated, do not edit.\nAQUA_SCENE={} exec {} \"$@\"\n",
            self.name,
            self.scene,
            shell_quote(binary)
        )
    }
}

/// A theme icon to draw for a bundle, by name, in place of artwork in
/// `Contents/Resources`: a built-in's, which follows the theme.
pub const THEME_ICON_FILE: &str = "Contents/theme-icon";
/// The marker that says a bundle is ours to replace or remove: the entry it
/// came from. A bundle without one was put there by somebody else.
pub const MARKER: &str = "Contents/abyss-appgen";
/// The app_ids its windows may carry, one per line, so the Dock can show a
/// running application on its tile.
pub const APP_ID_FILE: &str = "Contents/app-id";

/// A bundle's directory name for an application called `name`: what the
/// Finder shows, minus what a path cannot hold.
pub fn directory_name(name: &str) -> String {
    let n = name.replace('/', "-");
    let n = n.trim_start_matches('.');
    format!("{}.app", if n.is_empty() { "Application" } else { n })
}

/// The launcher `Contents/MacOS/<Name>`: `exec` the entry's command, with
/// the files the Finder hands it where the entry asked for them. With
/// `terminal` (the shell binary, for `Terminal=true`) it runs in a Terminal
/// window, `-e` as xterm has it (P15.4); with `jail`, confined, through the
/// session's `abyss-jail launch` (P18.5). Never both: Terminal is the
/// person's own, unconfined.
pub fn launcher(argv: &[String], source: &str, terminal: Option<&str>, jail: Option<&str>) -> String {
    let mut words: Vec<String> = argv.iter().map(|a| if a == FILES_MARKER { "\"$@\"".to_owned() } else { shell_quote(a) }).collect();
    if let Some(t) = terminal {
        words.splice(0..0, ["env".to_owned(), "AQUA_SCENE=terminal".into(), shell_quote(t), "-e".into()]);
    } else if let Some(j) = jail.filter(|j| !j.is_empty()) {
        words.splice(0..0, ["abyss-jail".to_owned(), "launch".into(), shell_quote(j), "--".into()]);
    }
    format!("#!/bin/sh\n# Generated by abyss-appgen from {source} — regenerated, do not edit.\nexec {}\n", words.join(" "))
}

/// The class an application runs confined in, if any (P18.5): the
/// `jails.ini` `[apps]` row for its desktop file's name, over the entry's
/// own `X-Abyss-Jail`. A row of `none` keeps an application out of a jail
/// its entry asked for. Opt-in (§6.1): with neither, None.
pub fn jail_class(entry: &DesktopEntry, desktop_file: &str, apps: &[(String, String)]) -> Option<String> {
    let base = desktop_file.rsplit('/').next().unwrap_or("");
    let id = base.strip_suffix(".desktop").unwrap_or(base);
    if let Some((_, class)) = apps.iter().find(|(k, _)| k == id) {
        return (!class.is_empty() && !class.eq_ignore_ascii_case("none")).then(|| class.clone());
    }
    (!entry.jail.is_empty()).then(|| entry.jail.clone())
}

/// Whether a window's app_id is this application's: one of its candidates,
/// or the program's name (the last candidate) with a variant after a dash
/// (`firefox-esr`).
pub fn matches(app_id: &str, candidates: &[String]) -> bool {
    if app_id.is_empty() {
        return false;
    }
    if candidates.iter().any(|c| c == app_id) {
        return true;
    }
    candidates.last().is_some_and(|p| !p.is_empty() && app_id.starts_with(&format!("{p}-")))
}

pub fn shell_quote(s: &str) -> String {
    if !s.is_empty() && s.chars().all(|c| c.is_alphanumeric() || "-_./=:,+@%".contains(c)) {
        return s.to_owned();
    }
    format!("'{}'", s.replace('\'', "'\\''"))
}

// MARK: the icon

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IconChoice {
    /// Copy this PNG as it is.
    Png(String),
    /// Rasterise this SVG to `size` pixels square.
    Svg(String, u32),
}

/// The size a bundle icon wants: the Dock magnifies to 128, and 2× that is
/// what a HiDPI display draws.
pub const WANTED: u32 = 256;

/// A theme directory's pixel size: the first `NxN` path component (`@2x`
/// doubling it); 0 when there is none (pixmaps, `scalable`).
fn size_of(path: &str) -> u32 {
    for comp in path.split('/').filter(|c| !c.is_empty()) {
        let mut parts = comp.split('@');
        let dims: Vec<&str> = parts.next().unwrap_or("").split('x').collect();
        if dims.len() == 2
            && let (Ok(w), Ok(_)) = (dims[0].parse::<u32>(), dims[1].parse::<u32>())
        {
            let scale = parts.next().and_then(|s| s.strip_suffix('x').unwrap_or(s).parse::<u32>().ok()).unwrap_or(1);
            return w.saturating_mul(scale);
        }
    }
    0
}

fn hicolor(p: &str) -> bool {
    p.contains("/hicolor/")
}

/// Choose from every file a theme offers under an icon's name. A PNG at
/// least WANTED/2 pixels is taken as it is (the largest); failing that an
/// SVG, rasterised; failing that the largest PNG there is. A `-symbolic`
/// icon is a monochrome glyph, never an application's face. `hicolor`, the
/// fallback theme every application installs into, wins a tie.
pub fn choose_icon(paths: &[String]) -> Option<IconChoice> {
    let usable: Vec<&String> = paths.iter().filter(|p| !p.contains("-symbolic")).collect();
    let mut pngs: Vec<(&String, u32)> = usable.iter().filter(|p| p.ends_with(".png")).map(|p| (*p, size_of(p))).collect();
    pngs.sort_by_key(|p| std::cmp::Reverse((p.1, hicolor(p.0))));
    let mut svgs: Vec<&String> = usable.iter().copied().filter(|p| p.ends_with(".svg") || p.ends_with(".svgz")).collect();
    svgs.sort_by_key(|p| !hicolor(p));
    if let Some((best, size)) = pngs.first()
        && *size >= WANTED / 2
    {
        return Some(IconChoice::Png((*best).clone()));
    }
    if let Some(svg) = svgs.first() {
        return Some(IconChoice::Svg((*svg).clone(), WANTED));
    }
    pngs.first().map(|(p, _)| IconChoice::Png((*p).clone()))
}

#[cfg(test)]
mod tests;
