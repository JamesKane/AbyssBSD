//! The floor a theme may not go below (Legibility.swift, PHASE11 P11.10,
//! PRODUCT §8.4), and what a foreign toolkit is told about the look
//! (ThemePalette.swift).
//!
//! A theme is data a person can write, and a person can write one nobody can
//! read. The floor is checked **when the theme is loaded**, on the pairs the
//! toolkit actually draws (which text sits on which surface is the toolkit's
//! knowledge, so it is a table here), and a failure is said in words: the
//! pair, both colours, the ratio and the bar. Body text under WCAG AA's
//! 4.5:1 refuses the theme; secondary text under 3:1 is a warning; a gadget
//! under 12 pt or a row under 16 refuses it. Translucent colours are
//! composited before they are measured, as the eye is shown them.

use crate::color::Color;
use crate::tokens::ThemeTokens;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Weight {
    Body,
    Secondary,
}

/// Text token, the surfaces the toolkit draws it on, and its weight.
pub const PAIRS: [(&str, &[&str], Weight); 19] = [
    ("bodyText", &["contentBackground", "listBackground", "sheetBackground", "tabPaneBackground"], Weight::Body),
    ("controlLabel", &["contentBackground"], Weight::Body),
    ("titleText", &["titleBarTop", "titleBarBottom"], Weight::Body),
    ("menuText", &["menuBackground"], Weight::Body),
    ("menuTextOnHighlight", &["menuHighlight"], Weight::Body),
    ("menuBarText", &["menuBarTop", "menuBarBottom"], Weight::Body),
    ("fieldText", &["fieldBackground"], Weight::Body),
    ("buttonTextOnWhite", &["buttonWhiteTop", "buttonWhiteBottom"], Weight::Body),
    // A default button's label sits on its gel's middle band (the top is
    // under the gloss, the bottom below the text), so that is its surface.
    ("buttonTextOnBlue", &["buttonBlueMid"], Weight::Body),
    ("tabText", &["tabSelectedTop", "tabSelectedBottom"], Weight::Body),
    ("iconLabelText", &["contentBackground", "listBackground"], Weight::Body),
    ("dockLabelText", &["dockLabelBackground"], Weight::Body),
    ("readoutText", &["readoutBackground"], Weight::Body),
    ("secondaryText", &["contentBackground"], Weight::Secondary),
    ("sectionTitleText", &["contentBackground"], Weight::Secondary),
    ("fieldPlaceholder", &["fieldBackground"], Weight::Secondary),
    ("menuTextDisabled", &["menuBackground"], Weight::Secondary),
    ("toolbarLabelText", &["toolbarTop", "toolbarBottom", "prefsToolbarTop", "prefsToolbarBottom"], Weight::Secondary),
    ("attentionText", &["attentionBackground"], Weight::Secondary),
];

pub const BODY_FLOOR: f64 = 4.5;
pub const SECONDARY_FLOOR: f64 = 3.0;
pub const GADGET_FLOOR: f64 = 12.0;
pub const ROW_FLOOR: f64 = 16.0;

/// WCAG 2's relative luminance of an opaque sRGB colour.
pub fn luminance(c: Color) -> f64 {
    let lin = |v: f64| if v <= 0.04045 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) };
    0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

/// `top` over `bottom`, in sRGB (as the compositor blends).
pub fn over(top: Color, bottom: Color) -> Color {
    let a = top.a;
    Color::new(top.r * a + bottom.r * (1.0 - a), top.g * a + bottom.g * (1.0 - a), top.b * a + bottom.b * (1.0 - a), 1.0)
}

pub fn ratio(a: Color, b: Color) -> f64 {
    let (la, lb) = (luminance(a), luminance(b));
    (la.max(lb) + 0.05) / (la.min(lb) + 0.05)
}

/// The window's own background, composited on black.
fn window(t: &ThemeTokens) -> Color {
    over(t.content_background, Color::new(0.0, 0.0, 0.0, 1.0))
}

/// Each pair as the eye sees it: (text, its colour, surface, its colour, weight).
fn measured(t: &ThemeTokens) -> Vec<(&'static str, Color, &'static str, Color, Weight)> {
    let w = window(t);
    let mut out = vec![];
    for (fg, surfaces, weight) in PAIRS {
        let Some(f) = t.color_named(fg) else { continue };
        for s in surfaces {
            let Some(sc) = t.color_named(s) else { continue };
            let surface = over(sc, w);
            out.push((fg, over(f, surface), *s, surface, weight));
        }
    }
    out
}

fn hex(c: Color) -> String {
    let b = |v: f64| format!("{:02x}", (v.clamp(0.0, 1.0) * 255.0).round() as i64);
    format!("#{}{}{}", b(c.r), b(c.g), b(c.b))
}

/// A number as Swift's String(Double) wrote it after rounding to hundredths.
pub fn fmt(v: f64) -> String {
    let r = (v * 100.0).round() / 100.0;
    if r == r.round() { format!("{}", r as i64) } else { format!("{r}") }
}

/// What is wrong with `t`: problems refuse it, warnings are shown.
pub fn check(t: &ThemeTokens) -> (Vec<String>, Vec<String>) {
    let (mut problems, mut warnings) = (vec![], vec![]);
    for (fg_name, fg, s_name, surface, weight) in measured(t) {
        let r = ratio(fg, surface);
        let floor = if weight == Weight::Body { BODY_FLOOR } else { SECONDARY_FLOOR };
        if r >= floor {
            continue;
        }
        let need = if weight == Weight::Body { format!("body text needs {}:1", fmt(BODY_FLOOR)) } else { format!("secondary text needs {}:1", fmt(SECONDARY_FLOOR)) };
        let line = format!("{fg_name} {} on {s_name} {} is {}:1 — {need}", hex(fg), hex(surface), fmt(r));
        if weight == Weight::Body {
            problems.push(format!("[legibility] {line}"));
        } else {
            warnings.push(format!("legibility: {line}"));
        }
    }
    if t.traffic_radius * 2.0 < GADGET_FLOOR {
        problems.push(format!("[legibility] a title-bar gadget is {} pt — a pointer needs {}", fmt(t.traffic_radius * 2.0), fmt(GADGET_FLOOR)));
    }
    for (name, v) in [("menu.itemHeight", t.menu_item_height), ("finder.rowHeight", t.finder_row_height)] {
        if v < ROW_FLOOR {
            problems.push(format!("[legibility] {name} = {} — a row a pointer can hit is {} pt", fmt(v), fmt(ROW_FLOOR)));
        }
    }
    (problems, warnings)
}

/// The lowest body-text contrast among the pairs the toolkit draws.
pub fn minimum_body_ratio(t: &ThemeTokens) -> f64 {
    measured(t).into_iter().filter(|m| m.4 == Weight::Body).map(|(_, fg, _, s, _)| ratio(fg, s)).fold(21.0, f64::min)
}

/// Four decimal places, as the portal reads them: `0.0125`, `1`, `0`.
fn r4(v: f64) -> String {
    let n = (v.clamp(0.0, 1.0) * 10000.0).round() as i64;
    match n {
        10000 => "1".into(),
        0 => "0".into(),
        _ => format!("0.{n:04}"),
    }
}

/// The palette of `t`, as INI text, for the portal (P11.10): GTK draws its
/// own widgets, and what it can be told is a colour scheme, an accent, a
/// contrast preference and a palette. `abyss-theme palette` prints it.
pub fn palette_ini(t: &ThemeTokens, name: &str, scheme: Option<&str>) -> String {
    let w = window(t);
    let rgb = |c: Color| {
        let o = over(c, w);
        format!("{} {} {}", r4(o.r), r4(o.g), r4(o.b))
    };
    // Dark when the window's own background is darker than mid-grey; high
    // contrast only when every body pair clears WCAG AAA's 7:1, a
    // measurement, not a scheme's name.
    let dark = luminance(w) < 0.18;
    let high = minimum_body_ratio(t) >= 7.0;
    let mut s = String::from("# The palette of the loaded theme (P11.10), for the portal.\n");
    s += &format!("[theme]\nname = {name}\n");
    if let Some(sc) = scheme {
        s += &format!("scheme = {sc}\n");
    }
    s += "\n[appearance]\n";
    s += &format!("color-scheme = {}\n", if dark { 1 } else { 2 }); // 1 prefer dark, 2 prefer light
    s += &format!("accent-color = {}\n", rgb(t.menu_highlight));
    s += &format!("contrast = {}\n", if high { 1 } else { 0 });
    s += "\n[palette]\n";
    for (k, c) in [
        ("window-background", t.content_background),
        ("window-foreground", t.body_text),
        ("view-background", t.list_background),
        ("view-foreground", t.body_text),
        ("selected-background", t.menu_highlight),
        ("selected-foreground", t.menu_text_on_highlight),
        ("headerbar-background", t.title_bar_bottom),
        ("headerbar-foreground", t.title_text),
        ("button-background", t.button_white_bottom),
        ("button-foreground", t.button_text_on_white),
        ("border", t.window_border),
        ("focus", t.glow_focus),
        ("secondary-foreground", t.secondary_text),
        ("alert", t.alert),
    ] {
        s += &format!("{k} = {}\n", rgb(c));
    }
    s
}
