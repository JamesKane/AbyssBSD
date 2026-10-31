//! abyss-theme: the loaded theme, for things that do not draw (P11.10),
//! ported from main.swift beside it.
//!
//!     abyss-theme palette       the palette the portal publishes (INI, stdout)
//!     abyss-theme check [NAME]  every scheme of a theme against the
//!                               legibility floor, in words
//!     abyss-theme cursors DIR [NAME]
//!                               the theme's cursors as an XCursor theme,
//!                               NAME ("Abyss") in DIR, for toolkits that
//!                               draw their own (U.7b)
//!     abyss-theme set NAME [SCHEME]
//!                               choose the desktop's theme: writes
//!                               appearance.ini, which every running
//!                               process follows (P14.2)
//!
//! The theme is chosen as every process chooses it: appearance.ini, or
//! $ABYSS_THEME / $ABYSS_THEME_SCHEME.

use aquadraw::legibility;
use aquadraw::theme::{self, Outcome, Theme};
use aquadraw::tokens::ThemeTokens;
use aquadraw::{scene, xcursor};
use std::collections::BTreeMap;
use std::process::exit;

fn fail(s: &str, code: i32) -> ! {
    eprintln!("{s}");
    exit(code)
}

/// The text of theme `name`'s theme.ini, from the first directory that has one.
fn theme_text(name: &str) -> String {
    let dirs = theme::search_path(None);
    dirs.iter()
        .find_map(|d| std::fs::read_to_string(format!("{d}/{name}/theme.ini")).ok())
        .unwrap_or_else(|| fail(&format!("abyss-theme: no theme {name} (looked in {})", dirs.join(", ")), 1))
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let none = BTreeMap::new();
    match args.first().map(String::as_str) {
        Some("palette") => {
            let mut t = Theme::default();
            match t.load_current(None, None) {
                Outcome::Loaded(l, _) => print!("{}", legibility::palette_ini(&l.tokens, &l.name, l.scheme.as_deref())),
                o => {
                    // The compiled Jaguar is what draws, so it is what is reported.
                    eprintln!("{}", theme::announcement(&o));
                    print!("{}", legibility::palette_ini(&ThemeTokens::jaguar(), "Aqua (compiled)", None));
                }
            }
        }
        Some("check") => {
            let name = args.get(1).cloned().unwrap_or_else(|| theme::choice(None).name);
            let text = theme_text(&name);
            let schemes = theme::parse(&text, None, &none).map(|t| t.schemes).unwrap_or_default();
            let mut bad = false;
            for scheme in std::iter::once(None).chain(schemes.iter().map(|s| Some(s.as_str()))) {
                let label = scheme.unwrap_or("(base)");
                match theme::parse(&text, scheme, &none) {
                    Ok(t) => {
                        let lo = legibility::fmt(legibility::minimum_body_ratio(&t.tokens));
                        let warnings = t.warnings.iter().map(|w| format!("\n  {w}")).collect::<String>();
                        println!("{name} {label}: readable — lowest body contrast {lo}:1{warnings}");
                    }
                    Err(e) => {
                        bad = true;
                        println!("{name} {label}: REFUSED\n  {}", e.problems.join("\n  "));
                    }
                }
            }
            exit(if bad { 1 } else { 0 })
        }
        Some("cursors") => {
            if !(2..=3).contains(&args.len()) {
                fail("usage: abyss-theme cursors DIR [NAME]", 2)
            }
            let mut t = Theme::default();
            eprintln!("{}", theme::announcement(&t.load_current(None, None)));
            let name = args.get(2).map_or("Abyss", String::as_str);
            let Some(mut runner) = scene::runner(1) else { fail("abyss-theme: no font loads, so no cursor can be drawn", 1) };
            let Some((files, links)) = xcursor::install(&mut runner, &t, &args[1], name) else {
                fail(&format!("abyss-theme: could not write the cursor theme {name} in {}", args[1]), 1)
            };
            let sizes = xcursor::SIZES.map(|s| s.to_string()).join(",");
            println!("abyss-theme: wrote {}/{name}: {files} cursors at sizes {sizes}, {links} X11 names linked", args[1]);
        }
        Some("set") => {
            if !(2..=3).contains(&args.len()) {
                fail("usage: abyss-theme set NAME [SCHEME]", 2)
            }
            let (name, scheme) = (&args[1], args.get(2).map(String::as_str));
            // Refuse what would not load, here, in words, rather than write
            // it and have every process fall back to Jaguar at once.
            if let Err(e) = theme::parse(&theme_text(name), scheme, &none) {
                let s = scheme.map_or(String::new(), |s| format!(" {s}"));
                fail(&format!("abyss-theme: {name}{s} would be refused:\n  {}", e.problems.join("\n  ")), 1)
            }
            if let Err(e) = theme::store(name, scheme, &none, None) {
                fail(&format!("abyss-theme: could not write appearance.ini: {e}"), 1)
            }
        }
        _ => fail("usage: abyss-theme palette | abyss-theme check [NAME] | abyss-theme set NAME [SCHEME]", 2),
    }
}
