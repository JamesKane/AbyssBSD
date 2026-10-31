//! A theme is a file, not a build (ThemeLoader.swift and Theme.swift's
//! `Theme`, PHASE11 P11.2).
//!
//! A theme is a directory, `themes/<name>/`, and its tokens are
//! `themes/<name>/theme.ini`:
//!
//! ```text
//! [theme]         name = Aqua            human name
//!                 default_scheme = …     optional
//! [colors]        titleBarTop = #f4f4f4  #rrggbb, #rrggbb/alpha,
//!                 separator = 0 0 0 0.12 "r g b [a]" as fractions,
//!                 raisedTop = mix(raised, #ffffff, 0.14)   or an OKLCH mix
//! [metrics]       titleBarHeight = 22    a number, or "number * parameter"
//! [fonts]         fontFamily = Lucida Grande
//! [chrome]        left = close minimize zoom    right = pill
//!                 title = center  titleWeight = regular
//! [parameters]    glow = 0.6 0 1         default, min, max
//! [colors.<scheme>], [metrics.<scheme>]  a scheme overrides the base
//! ```
//!
//! **Strict where PoolConfig is lenient**: a misspelt token would silently
//! draw Jaguar's value and the theme would look *almost* right. An unknown
//! key, a malformed value, an unknown reference or a cycle is an error
//! naming the section, the key and why, and the theme is refused whole,
//! with the compiled Jaguar used instead **and said so** (§2.45). **Not a
//! language** (PHASE11 §6.5): the only operations are a colour mix and a
//! metric times a bounded parameter.
//!
//! Swift keeps the loaded theme in a global every paint reads. Here it is a
//! value, `Theme`, held by whoever draws, which hands it to its runner.

use crate::chrome::{Gadget, TitleAlign};
use crate::color::{mix_oklch, Color};
use crate::drawlist::DrawListFile;
use crate::legibility;
use crate::runner::Runner;
use crate::tokens::ThemeTokens;
use pool_config::Config;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt;
use std::sync::OnceLock;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ThemeError {
    pub problems: Vec<String>,
}

impl fmt::Display for ThemeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.problems.join("; "))
    }
}

/// A bounded setting a person may change (glow strength, bevel width, …).
#[derive(Clone, Debug, PartialEq)]
pub struct ThemeParameter {
    pub name: String,
    pub value: f64,
    pub min: f64,
    pub max: f64,
}

/// A theme file, read.
#[derive(Clone, Debug, PartialEq)]
pub struct LoadedTheme {
    pub name: String,
    pub scheme: Option<String>,
    pub schemes: Vec<String>,
    pub parameters: Vec<ThemeParameter>,
    pub tokens: ThemeTokens,
    /// Things not wrong enough to refuse the theme (a parameter clamped to
    /// its bounds, say): shown, never swallowed.
    pub warnings: Vec<String>,
    /// The draw lists the theme's own files define (P11.4), sorted. Empty
    /// when it ships none: every widget draws Jaguar's.
    pub draw_lists: Vec<String>,
}

fn trim(s: &str) -> &str {
    s.trim_matches([' ', '\t'])
}

fn numbers(v: &str) -> Vec<f64> {
    v.split(' ').filter(|w| !w.is_empty()).filter_map(|w| w.parse().ok()).collect()
}

/// `#rrggbb`, `#rrggbb/alpha`, `r g b [a]`, or `mix(a, b, t)` (a and b a
/// colour or another token's name, through `lookup`).
pub fn color_value(s: &str, lookup: &mut dyn FnMut(&str) -> Option<Color>) -> Option<Color> {
    let v = trim(s);
    if let Some(inner) = v.strip_prefix("mix(").and_then(|r| r.strip_suffix(')')) {
        let args: Vec<&str> = inner.split(',').map(trim).collect();
        let [a, b, t] = args.as_slice() else { return None };
        let t: f64 = t.parse().ok().filter(|t| (0.0..=1.0).contains(t))?;
        let mut side = |x: &str| color_value(x, lookup).or_else(|| lookup(x));
        let (a, b) = (side(a)?, side(b)?);
        return Some(mix_oklch(a, b, t));
    }
    if let Some(rest) = v.strip_prefix('#') {
        let parts: Vec<&str> = rest.split('/').map(trim).collect();
        let hex = parts.first().filter(|h| h.len() == 6).and_then(|h| u32::from_str_radix(h, 16).ok())?;
        return match parts.as_slice() {
            [_] => Some(Color::hex(hex, 1.0)),
            [_, a] => a.parse::<f64>().ok().filter(|a| (0.0..=1.0).contains(a)).map(|a| Color::hex(hex, a)),
            _ => None,
        };
    }
    let words: Vec<&str> = v.split(' ').filter(|w| !w.is_empty()).collect();
    let f = numbers(v);
    if !(f.len() == 3 || f.len() == 4) || words.len() != f.len() || !f.iter().all(|x| (0.0..=1.0).contains(x)) {
        return None;
    }
    Some(Color::new(f[0], f[1], f[2], f.get(3).copied().unwrap_or(1.0)))
}

/// A number, or `number * parameter`.
pub fn metric_value(s: &str, params: &HashMap<String, f64>) -> Option<f64> {
    let parts: Vec<&str> = s.split('*').map(trim).collect();
    let n: f64 = parts[0].parse().ok()?;
    match parts.as_slice() {
        [_] => Some(n),
        [_, p] => params.get(*p).map(|v| n * v),
        _ => None,
    }
}

const ROLES: [&str; 4] = ["interface", "chrome", "readout", "mono"];

/// Read a theme from its `theme.ini` text. `scheme` picks a variant (None
/// for the theme's default); `overrides` are a person's parameter settings.
pub fn parse(text: &str, wanted: Option<&str>, overrides: &BTreeMap<String, f64>) -> Result<LoadedTheme, ThemeError> {
    let c = Config::parse(text);
    let (mut problems, mut warnings) = (vec![], vec![]);
    let names = c.section_names();
    let scheme_of = |s: &str| s.strip_prefix("colors.").or_else(|| s.strip_prefix("metrics.")).map(str::to_owned);
    let schemes: Vec<String> = names.iter().filter_map(|s| scheme_of(s)).collect::<BTreeSet<_>>().into_iter().collect();
    for s in &names {
        if !["", "theme", "colors", "metrics", "fonts", "parameters", "chrome"].contains(s) && scheme_of(s).is_none() {
            problems.push(format!("[{s}] is not a section a theme has"));
        }
    }
    let scheme = wanted.map(str::to_owned).or_else(|| c.string("theme", "default_scheme").map(str::to_owned));
    if let Some(s) = &scheme
        && !schemes.contains(s)
        && s != "default"
    {
        let has = if schemes.is_empty() { "none".to_owned() } else { schemes.join(", ") };
        problems.push(format!("there is no scheme {s} (the theme has: {has})"));
    }

    // Parameters first: metrics may use them.
    let mut params = vec![];
    for (k, v) in c.pairs("parameters") {
        let f = numbers(v);
        if f.len() != 3 || f[1] > f[2] {
            problems.push(format!("[parameters] {k} = {v}: want \"default min max\""));
            continue;
        }
        let mut value = overrides.get(k).copied().unwrap_or(f[0]);
        if value < f[1] || value > f[2] {
            warnings.push(format!("{k} = {value:?} is outside {:?}…{:?}; clamped", f[1], f[2]));
            value = value.clamp(f[1], f[2]);
        }
        params.push(ThemeParameter { name: k.into(), value, min: f[1], max: f[2] });
    }
    for k in overrides.keys() {
        if !params.iter().any(|p| &p.name == k) {
            warnings.push(format!("this theme has no parameter {k}; ignored"));
        }
    }
    let param_value: HashMap<String, f64> = params.iter().map(|p| (p.name.clone(), p.value)).collect();
    let merged = |base: &str| {
        let mut d: BTreeMap<String, String> = c.pairs(base).into_iter().map(|(k, v)| (k.to_owned(), v.to_owned())).collect();
        if let Some(s) = &scheme {
            d.extend(c.pairs(&format!("{base}.{s}")).into_iter().map(|(k, v)| (k.to_owned(), v.to_owned())));
        }
        d
    };

    let mut t = ThemeTokens::jaguar();
    // Colours: literals, then mixes, which may name other tokens.
    let mut raw = merged("colors");
    raw.retain(|k, _| {
        let known = ThemeTokens::color_index(k).is_some();
        if !known {
            problems.push(format!("[colors] {k} is not a token (misspelt?)"));
        }
        known
    });
    let mut resolved: BTreeMap<String, Color> = BTreeMap::new();
    fn resolve(name: &str, stack: &mut Vec<String>, raw: &BTreeMap<String, String>, resolved: &mut BTreeMap<String, Color>, problems: &mut Vec<String>, jaguar: &ThemeTokens) -> Option<Color> {
        if let Some(c) = resolved.get(name) {
            return Some(*c);
        }
        // A token the file does not set keeps its Jaguar value, and may
        // still be mixed from.
        let Some(v) = raw.get(name) else { return jaguar.color_named(name) };
        if stack.iter().any(|s| s == name) {
            let chain: Vec<&str> = stack.iter().map(String::as_str).chain([name]).collect();
            problems.push(format!("[colors] {name}: a mix that refers to itself ({})", chain.join(" → ")));
            return None;
        }
        stack.push(name.to_owned());
        let col = color_value(v, &mut |n| resolve(n, stack, raw, resolved, problems, jaguar));
        stack.pop();
        let Some(col) = col else {
            problems.push(format!("[colors] {name} = {v}: not a colour"));
            return None;
        };
        resolved.insert(name.to_owned(), col);
        Some(col)
    }
    let jaguar = ThemeTokens::jaguar();
    for k in raw.keys() {
        if let Some(col) = resolve(k, &mut vec![], &raw, &mut resolved, &mut problems, &jaguar)
            && let Some(i) = ThemeTokens::color_index(k)
        {
            t.set_color(i, col);
        }
    }

    for (k, v) in merged("metrics") {
        let Some(i) = ThemeTokens::metric_index(&k) else {
            problems.push(format!("[metrics] {k} is not a token"));
            continue;
        };
        match metric_value(&v, &param_value) {
            Some(n) => t.set_metric(i, n),
            None => problems.push(format!("[metrics] {k} = {v}: want a number, or \"number * parameter\"")),
        }
    }

    for (k, v) in c.pairs("fonts") {
        // role.upper / role.tracking (P11.9)
        if let Some((role, what)) = k.split_once('.')
            && ROLES.contains(&role)
        {
            match what {
                "upper" => match v {
                    "true" => {
                        t.role_upper.insert(role.into());
                    }
                    "false" => {
                        t.role_upper.remove(role);
                    }
                    _ => problems.push(format!("[fonts] {k} = {v}: want true or false")),
                },
                "tracking" => match v.parse::<f64>() {
                    Ok(n) if (-0.2..=1.0).contains(&n) => {
                        t.role_tracking.insert(role.into(), n);
                    }
                    _ => problems.push(format!("[fonts] {k} = {v}: want a tracking in em, -0.2…1")),
                },
                _ => problems.push(format!("[fonts] {k} is not a token")),
            }
            continue;
        }
        if let Some(i) = ThemeTokens::font_index(k) {
            t.set_font(i, v.into());
        } else if let Some(i) = ThemeTokens::metric_index(k) {
            // fontSize is a metric that lives with the fonts.
            match metric_value(v, &param_value) {
                Some(n) => t.set_metric(i, n),
                None => problems.push(format!("[fonts] {k} = {v}: not a number")),
            }
        } else {
            problems.push(format!("[fonts] {k} is not a token"));
        }
    }

    // The frame's shape: named gadgets, each on one side at most once.
    let mut placed: BTreeMap<&str, &str> = BTreeMap::new();
    for (k, v) in c.pairs("chrome") {
        match k {
            "left" | "right" => {
                let mut gs = vec![];
                for w in v.split(' ').filter(|w| !w.is_empty()) {
                    let Some(g) = Gadget::named(w) else {
                        problems.push(format!("[chrome] {k} = {v}: {w} is not a gadget (close minimize zoom depth pill)"));
                        continue;
                    };
                    if let Some(other) = placed.get(g.name()) {
                        problems.push(format!("[chrome] {w} is on the {other} already"));
                        continue;
                    }
                    placed.insert(g.name(), k);
                    gs.push(g);
                }
                if k == "left" { t.chrome_left = gs } else { t.chrome_right = gs }
            }
            "title" => match TitleAlign::named(v) {
                Some(a) => t.title_align = a,
                None => problems.push(format!("[chrome] title = {v}: want left or center")),
            },
            "titleWeight" => match v {
                "regular" | "bold" => t.title_bold = v == "bold",
                _ => problems.push(format!("[chrome] titleWeight = {v}: want regular or bold")),
            },
            _ => problems.push(format!("[chrome] {k} is not a token")),
        }
    }

    // The floor (P11.10): on what this theme, in this scheme, will show.
    if problems.is_empty() {
        let (p, w) = legibility::check(&t);
        problems.extend(p);
        warnings.extend(w);
    }
    if !problems.is_empty() {
        return Err(ThemeError { problems });
    }
    Ok(LoadedTheme {
        name: c.string("theme", "name").unwrap_or("unnamed").into(),
        scheme,
        schemes,
        parameters: params,
        tokens: t,
        warnings,
        draw_lists: vec![],
    })
}

// MARK: the compiled Jaguar lists

/// The shipped Aqua theme's lists, `draw/*.dl` then `icons/*.dl` in name
/// order, compiled in: what draws when no theme can be read, or one is
/// refused. The files themselves, so the fallback cannot drift from them.
pub const JAGUAR_SOURCES: [(&str, &str); 9] = [
    ("draw/aqua.dl", include_str!("../../../themes/aqua/draw/aqua.dl")),
    ("draw/chrome.dl", include_str!("../../../themes/aqua/draw/chrome.dl")),
    ("draw/finder.dl", include_str!("../../../themes/aqua/draw/finder.dl")),
    ("draw/installer.dl", include_str!("../../../themes/aqua/draw/installer.dl")),
    ("draw/shell.dl", include_str!("../../../themes/aqua/draw/shell.dl")),
    ("icons/cursors.dl", include_str!("../../../themes/aqua/icons/cursors.dl")),
    ("icons/dock.dl", include_str!("../../../themes/aqua/icons/dock.dl")),
    ("icons/finder.dl", include_str!("../../../themes/aqua/icons/finder.dl")),
    ("icons/prefs.dl", include_str!("../../../themes/aqua/icons/prefs.dl")),
];

pub fn jaguar_lists() -> &'static DrawListFile {
    static LISTS: OnceLock<DrawListFile> = OnceLock::new();
    LISTS.get_or_init(|| {
        let source: String = JAGUAR_SOURCES.iter().map(|(_, s)| *s).collect();
        DrawListFile::parse(&source).unwrap_or_else(|e| panic!("the compiled Jaguar draw lists do not parse: {e}"))
    })
}

// MARK: finding and choosing

/// Where themes live, in order: `$ABYSS_THEME_DIR`, the person's config
/// dir (`<config>/themes`), the install (`<prefix>/share/abyss/themes`
/// beside `<prefix>/bin`), and, for a build tree, the repository's
/// `themes/`, found by walking up to the directory holding Package.swift.
pub fn search_path(config_dir: Option<&str>) -> Vec<String> {
    let mut dirs = vec![];
    if let Ok(d) = std::env::var("ABYSS_THEME_DIR")
        && !d.is_empty()
    {
        dirs.push(d);
    }
    if let Some(c) = config_dir.map(str::to_owned).or_else(|| pool_config::config_dir().ok()) {
        dirs.push(format!("{c}/themes"));
    }
    if let Some(exe) = abyss_sys::proc::self_executable().and_then(|e| e.rsplit_once('/').map(|(d, _)| d.to_owned())) {
        // <prefix>/bin to <prefix>/share/abyss/themes, said without a `..`.
        match exe.rsplit_once('/') {
            Some((prefix, _)) if !prefix.is_empty() => dirs.push(format!("{prefix}/share/abyss/themes")),
            _ => dirs.push(format!("{exe}/../share/abyss/themes")),
        }
        let mut d = exe.as_str();
        for _ in 0..5 {
            let Some((up, _)) = d.rsplit_once('/').filter(|(u, _)| !u.is_empty()) else { break };
            d = up;
            if std::path::Path::new(&format!("{d}/Package.swift")).exists() {
                dirs.push(format!("{d}/themes"));
                break;
            }
        }
    }
    dirs
}

/// The theme a person chose: `appearance.ini` `[appearance] theme` and
/// `scheme`, and `[parameters]`. Aqua when nothing says otherwise.
/// `$ABYSS_THEME` (and `$ABYSS_THEME_SCHEME`) override the file, for one
/// process: a test, or a person trying a theme, as `GTK_THEME` does.
#[derive(Clone, Debug, PartialEq)]
pub struct Choice {
    pub name: String,
    pub scheme: Option<String>,
    pub overrides: BTreeMap<String, f64>,
}

pub fn choice(config_dir: Option<&str>) -> Choice {
    let a = pool_config::load("appearance", config_dir).unwrap_or_default();
    let overrides = a.pairs("parameters").into_iter().filter_map(|(k, v)| v.parse().ok().map(|d| (k.to_owned(), d))).collect();
    let env = |n: &str| std::env::var(n).ok().filter(|v| !v.is_empty());
    Choice {
        name: env("ABYSS_THEME").or_else(|| a.string("appearance", "theme").map(str::to_owned)).unwrap_or_else(|| "aqua".into()),
        scheme: env("ABYSS_THEME_SCHEME").or_else(|| a.string("appearance", "scheme").map(str::to_owned)),
        overrides,
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Loaded(Box<LoadedTheme>, String),
    NotFound { name: String, looked: Vec<String> },
    Refused { name: String, path: String, error: ThemeError },
}

/// A theme's draw lists: every `draw/*.dl` and `icons/*.dl` in `dir`, in
/// name order, one namespace. Strict as `parse` is: a list that does not
/// parse, or a name two files define, refuses the theme. A list the toolkit
/// never asks for is only a warning: a theme may carry a later toolkit's.
pub fn load_lists(dir: &str) -> Result<(Option<DrawListFile>, Vec<String>), ThemeError> {
    let mut names = vec![];
    for sub in ["draw", "icons"] {
        let Ok(d) = std::fs::read_dir(format!("{dir}/{sub}")) else { continue };
        for e in d.filter_map(|e| e.ok()) {
            let n = e.file_name().to_string_lossy().into_owned();
            if n.ends_with(".dl") && !n.starts_with('.') {
                names.push(format!("{sub}/{n}"));
            }
        }
    }
    if names.is_empty() {
        return Ok((None, vec![]));
    }
    names.sort();
    let (mut merged, mut problems, mut seen) = (DrawListFile::default(), vec![], BTreeMap::<String, String>::new());
    for n in &names {
        let Ok(text) = std::fs::read_to_string(format!("{dir}/{n}")) else {
            problems.push(format!("{n}: cannot be read"));
            continue;
        };
        match DrawListFile::parse(&text) {
            Ok(f) => {
                let mut keys: Vec<&String> = f.lists.keys().collect();
                keys.sort();
                for k in keys {
                    if let Some(other) = seen.get(k) {
                        problems.push(format!("{n}: list {k} is also in {other}"));
                    }
                    seen.insert(k.clone(), n.clone());
                }
                merged = merged.merging(&f);
            }
            Err(e) => problems.push(format!("{n} line {}: {}", e.line, e.message)),
        }
    }
    if !problems.is_empty() {
        return Err(ThemeError { problems });
    }
    let mut keys: Vec<&String> = merged.lists.keys().collect();
    keys.sort();
    let warnings = keys.into_iter().filter(|k| jaguar_lists().get(k).is_none()).map(|k| format!("list {k} ({}) is not one the toolkit draws", seen[k])).collect();
    Ok((Some(merged), warnings))
}

/// Where font files may be for a theme chosen from `theme_dirs`: each
/// `…/themes` directory's sibling `…/fonts`, and `<themes>/<theme>/fonts`.
pub fn font_dirs(theme_dirs: &[String], theme: &str) -> Vec<String> {
    let mut out = vec![];
    for d in theme_dirs {
        if let Some(base) = d.strip_suffix("themes")
            && d.ends_with("/themes")
        {
            out.push(format!("{base}fonts"));
        }
        out.push(format!("{d}/{theme}/fonts"));
    }
    out.retain(|p| std::path::Path::new(p).exists());
    out
}

/// Write a person's choice where every process reads it: the `appearance`
/// domain, by atomic rename. No scheme or parameters removes those keys.
pub fn store(theme: &str, scheme: Option<&str>, parameters: &BTreeMap<String, f64>, config_dir: Option<&str>) -> Result<(), pool_config::Error> {
    let mut c = Config::new();
    c.set("appearance", "theme", theme);
    if let Some(s) = scheme {
        c.set("appearance", "scheme", s);
    }
    for (k, v) in parameters {
        c.set("parameters", k, &format!("{v:?}"));
    }
    c.store("appearance", config_dir)
}

/// One line saying what is being drawn with: a silent fallback is
/// invisible to every test downstream (§2.45).
pub fn announcement(o: &Outcome) -> String {
    match o {
        Outcome::Loaded(t, path) => {
            let scheme = t.scheme.as_ref().map_or(String::new(), |s| format!(" ({s})"));
            let warnings = if t.warnings.is_empty() { String::new() } else { format!(" — {}", t.warnings.join("; ")) };
            format!("Theme: {}{scheme} from {path}, {} draw lists from draw/ and icons/{warnings}", t.name, t.draw_lists.len())
        }
        Outcome::NotFound { name, looked } => format!("Theme: NO THEME {name} — drawing with the compiled Jaguar (looked in {})", looked.join(", ")),
        Outcome::Refused { name, path, error } => format!("Theme: {name} REFUSED ({path}): {error} — drawing with the compiled Jaguar"),
    }
}

// MARK: the loaded theme

/// What draws: tokens, lists (Jaguar's, with any the theme ships replacing
/// theirs by name), parameters, and a generation that only goes up.
pub struct Theme {
    pub tokens: ThemeTokens,
    pub lists: DrawListFile,
    /// The theme's parameters: what a list reads as `$name` when the widget
    /// does not pass one.
    pub parameters: HashMap<String, f64>,
    /// Bumped by every `use_theme`: **what a cache of theme-derived pixels
    /// keys on** (PHASE14 §6.7). A frame rasterised under generation 3 is
    /// never the right picture under generation 4.
    pub generation: u64,
    loaded_choice: Option<Choice>,
    fonts_added: BTreeSet<String>,
}

impl Default for Theme {
    fn default() -> Theme {
        Theme { tokens: ThemeTokens::jaguar(), lists: jaguar_lists().clone(), parameters: HashMap::new(), generation: 0, loaded_choice: None, fonts_added: BTreeSet::new() }
    }
}

impl Theme {
    /// Replace the theme, and tell `runner`. Lists a theme does not ship
    /// stay Jaguar's, as tokens it does not set do.
    pub fn use_theme(&mut self, tokens: ThemeTokens, lists: Option<&DrawListFile>, parameters: HashMap<String, f64>, runner: Option<&mut Runner>) {
        self.generation += 1;
        self.lists = lists.map_or_else(|| jaguar_lists().clone(), |l| jaguar_lists().merging(l));
        if let Some(r) = runner {
            r.use_theme(&tokens, &parameters);
        }
        self.tokens = tokens;
        self.parameters = parameters;
    }

    /// Find, read and **use** the chosen theme; fall back to the compiled
    /// Jaguar when it cannot be, and return which, so it can be said.
    pub fn load_current(&mut self, config_dir: Option<&str>, runner: Option<&mut Runner>) -> Outcome {
        self.load_from(choice(config_dir), &search_path(config_dir), runner)
    }

    /// `load_current`'s work, for a choice and search path already made.
    pub fn load_from(&mut self, ch: Choice, dirs: &[String], mut runner: Option<&mut Runner>) -> Outcome {
        self.loaded_choice = Some(ch.clone());
        // Fonts live beside the themes (P11.7), known to fontconfig before
        // any role is matched.
        for d in font_dirs(dirs, &ch.name) {
            if self.fonts_added.insert(d.clone()) {
                abyss_sys::font_add_dir(&d);
            }
        }
        for d in dirs {
            let path = format!("{d}/{}/theme.ini", ch.name);
            let Ok(text) = std::fs::read_to_string(&path) else { continue };
            let read = parse(&text, ch.scheme.as_deref(), &ch.overrides).and_then(|t| load_lists(&format!("{d}/{}", ch.name)).map(|l| (t, l)));
            return match read {
                Ok((mut t, (lists, w))) => {
                    t.draw_lists = lists.as_ref().map(|l| {
                        let mut k: Vec<String> = l.lists.keys().cloned().collect();
                        k.sort();
                        k
                    }).unwrap_or_default();
                    t.warnings.extend(w);
                    let params = t.parameters.iter().map(|p| (p.name.clone(), p.value)).collect();
                    self.use_theme(t.tokens.clone(), lists.as_ref(), params, runner.as_deref_mut());
                    Outcome::Loaded(Box::new(t), path)
                }
                Err(error) => {
                    self.use_theme(ThemeTokens::jaguar(), None, HashMap::new(), runner.as_deref_mut());
                    Outcome::Refused { name: ch.name, path, error }
                }
            };
        }
        self.use_theme(ThemeTokens::jaguar(), None, HashMap::new(), runner);
        Outcome::NotFound { name: ch.name, looked: dirs.to_vec() }
    }

    /// Load the theme again **if the choice changed** (appearance.ini's
    /// theme, scheme or parameters); None when nothing did. Cheap when
    /// nothing changed, so a caller may ask on every change in the config
    /// directory.
    pub fn reload_if_changed(&mut self, config_dir: Option<&str>, runner: Option<&mut Runner>) -> Option<Outcome> {
        if self.loaded_choice.as_ref() == Some(&choice(config_dir)) {
            return None;
        }
        Some(self.load_current(config_dir, runner))
    }
}

/// One line per font role: what it asked for and what it got (§2.45: a role
/// that fell back draws text that looks fine and is the wrong typeface).
pub fn role_announcements(t: &ThemeTokens) -> Vec<String> {
    use crate::drawlist::Role;
    [(Role::Interface, &t.font_interface), (Role::Chrome, &t.font_chrome), (Role::Readout, &t.font_readout), (Role::Mono, &t.font_mono)]
        .into_iter()
        .map(|(r, want)| {
            let (fam, file) = abyss_sys::font_role_resolved(r as i32);
            if !want.is_empty() && fam.eq_ignore_ascii_case(want) {
                format!("Text: role {} = {fam} ({file})", r.name())
            } else {
                format!("Text: role {} wants {} — not found, drawing with {fam} ({file})", r.name(), if want.is_empty() { "nothing" } else { want.as_str() })
            }
        })
        .collect()
}

#[cfg(test)]
#[path = "theme_tests.rs"]
mod tests;
