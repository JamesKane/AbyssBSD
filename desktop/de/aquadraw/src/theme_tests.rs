//! ThemeTests, ChromeTests and LegibilityTests (Tests/AquaTests), ported.

use super::*;
use crate::chrome::{chrome_hit, window_chrome, ChromeEdge, ChromeHit};
use crate::legibility::{self, over, ratio};
use crate::runner::Rect;
use crate::tokens::{COLOR_KEYS, FONT_KEYS, METRIC_KEYS};

const AQUA_INI: &str = include_str!("../../../themes/aqua/theme.ini");

fn none() -> BTreeMap<String, f64> {
    BTreeMap::new()
}

fn problems(s: &str, scheme: Option<&str>) -> Vec<String> {
    match parse(s, scheme, &none()) {
        Ok(_) => vec![],
        Err(e) => e.problems,
    }
}

fn scratch(tag: &str) -> String {
    let d = std::env::temp_dir().join(format!("abyss-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d.to_string_lossy().into_owned()
}

// MARK: ThemeTests

/// The shipped Aqua theme and the compiled fallback are the same values, so
/// whichever one draws, Jaguar is what appears, and neither can drift.
#[test]
fn the_shipped_aqua_file_is_the_compiled_jaguar() {
    let t = parse(AQUA_INI, None, &none()).unwrap();
    assert_eq!(t.name, "Aqua");
    assert_eq!(t.tokens, ThemeTokens::jaguar());
    assert!(t.warnings.is_empty(), "{:?}", t.warnings);
}

/// Every token is set by the file, not left to the fallback.
#[test]
fn the_aqua_file_sets_every_token() {
    let keys: BTreeSet<&str> = AQUA_INI.lines().filter(|l| !l.starts_with('#')).filter_map(|l| l.split_once('=')).map(|(k, _)| k.trim()).collect();
    for k in COLOR_KEYS.iter().chain(METRIC_KEYS.iter()).chain(FONT_KEYS.iter()) {
        assert!(keys.contains(k), "{k} not in the file");
    }
}

#[test]
fn colour_forms() {
    let mut none = |_: &str| None;
    assert_eq!(color_value("#3f6fdf", &mut none), Some(Color::hex(0x3f6fdf, 1.0)));
    assert_eq!(color_value("#74a6ee/0.85", &mut none), Some(Color::hex(0x74a6ee, 0.85)));
    assert_eq!(color_value("0 0 0 0.035", &mut none), Some(Color::new(0.0, 0.0, 0.0, 0.035)));
    assert_eq!(color_value("0.62 0.66 0.72", &mut none), Some(Color::new(0.62, 0.66, 0.72, 1.0)));
    for bad in ["#3f6fd", "#zzzzzz", "#3f6fdf/2", "1 2 3", "0 0", "red", "0.5 0.5 x"] {
        assert_eq!(color_value(bad, &mut none), None, "{bad}");
    }
}

#[test]
fn oklch_mixing() {
    let (black, white) = (Color::new(0.0, 0.0, 0.0, 1.0), Color::new(1.0, 1.0, 1.0, 1.0));
    let mid = mix_oklch(black, white, 0.5);
    assert!((mid.r - 0.3885).abs() < 0.002, "{mid:?}");
    assert!((mid.r - mid.g).abs() < 1e-6);
    let mag = Color::hex(0xff2bd6, 1.0);
    let (a, b) = (mix_oklch(mag, white, 0.0), mix_oklch(mag, white, 1.0));
    assert!((a.r - mag.r).abs() < 1e-3 && (a.g - mag.g).abs() < 1e-3);
    assert!((b.r - 1.0).abs() < 1e-3 && (b.b - 1.0).abs() < 1e-3);
    let tint = mix_oklch(mag, white, 0.14);
    assert!(tint.r > tint.g && tint.b > tint.g);
}

#[test]
fn mixes_may_name_other_tokens_and_schemes_override() {
    let ini = "[theme]\nname = Test\n[colors]\nmenuHighlight = #ff2bd6\nmenuSeparator = mix(menuHighlight, #000000, 0.9)\n[colors.daylight]\nmenuHighlight = #b0008f\n[parameters]\nbevel = 1 0 3\n[metrics]\ntitleBarHeight = 24 * bevel\n";
    let t = parse(ini, Some("daylight"), &BTreeMap::from([("bevel".to_owned(), 2.0)])).unwrap();
    assert_eq!(t.schemes, ["daylight"]);
    assert_eq!(t.tokens.menu_highlight, Color::hex(0xb0008f, 1.0), "the scheme overrides the base");
    assert_eq!(t.tokens.title_bar_height, 48.0, "a metric times a parameter");
    assert!(t.tokens.menu_separator.r < 0.2, "mixed from the scheme's own token");
    assert_eq!(t.tokens.menu_text, ThemeTokens::jaguar().menu_text, "what a file does not set stays Jaguar's");
}

/// Strict, and it says why.
#[test]
fn every_mistake_is_refused_by_name() {
    assert_eq!(problems("[colors]\nmenuHighlite = #ffffff", None), ["[colors] menuHighlite is not a token (misspelt?)"]);
    assert_eq!(problems("[colors]\nmenuHighlight = blue", None), ["[colors] menuHighlight = blue: not a colour"]);
    assert_eq!(problems("[metrics]\ntitleBarHeight = tall", None), ["[metrics] titleBarHeight = tall: want a number, or \"number * parameter\""]);
    assert_eq!(problems("[metrics]\ntitleBarHeight = 2 * glow", None), ["[metrics] titleBarHeight = 2 * glow: want a number, or \"number * parameter\""]);
    assert_eq!(problems("[widgets]\nx = 1", None), ["[widgets] is not a section a theme has"]);
    assert_eq!(problems("[colors]\nmenuHighlight = #ffffff", Some("neon")), ["there is no scheme neon (the theme has: none)"]);
    let cycle = problems("[colors]\nmenuText = mix(menuBorder, #000000, 0.5)\nmenuBorder = mix(menuText, #ffffff, 0.5)", None);
    assert!(cycle.iter().any(|p| p.contains("refers to itself")), "{cycle:?}");
}

#[test]
fn parameters_are_bounded_and_overridable() {
    let o = BTreeMap::from([("glow".to_owned(), 4.0), ("blur".to_owned(), 1.0)]);
    let t = parse("[parameters]\nglow = 0.6 0 1", None, &o).unwrap();
    assert_eq!(t.parameters, [ThemeParameter { name: "glow".into(), value: 1.0, min: 0.0, max: 1.0 }]);
    assert!(t.warnings.iter().any(|w| w.contains("clamped")));
    assert!(t.warnings.iter().any(|w| w.contains("no parameter blur")));
    assert!(parse("[parameters]\nglow = 0.6 1 0", None, &none()).is_err(), "min above max");
}

#[test]
fn a_missing_or_refused_theme_falls_back_to_jaguar_and_says_so() {
    let dir = scratch("theme");
    std::fs::create_dir_all(format!("{dir}/aqua")).unwrap();
    let aqua = || Choice { name: "aqua".into(), scheme: None, overrides: none() };
    let dirs = [dir.clone()];
    std::fs::write(format!("{dir}/aqua/theme.ini"), "[colors]\nmenuHighlight = #000001\n").unwrap();
    let mut theme = Theme::default();
    let Outcome::Loaded(t, path) = theme.load_from(aqua(), &dirs, None) else { panic!("did not load") };
    assert_eq!(path, format!("{dir}/aqua/theme.ini"));
    assert_eq!(theme.tokens.menu_highlight, Color::hex(0x000001, 1.0), "the Theme holds the loaded tokens");
    assert_eq!(t.tokens.menu_highlight, Color::hex(0x000001, 1.0));
    assert_eq!(theme.generation, 1);

    std::fs::write(format!("{dir}/aqua/theme.ini"), "[colors]\nmenuHighlite = #000001\n").unwrap();
    let Outcome::Refused { .. } = theme.load_from(aqua(), &dirs, None) else { panic!("a bad theme was not refused") };
    assert_eq!(theme.tokens, ThemeTokens::jaguar(), "refused means Jaguar, not half a theme");
    assert_eq!(theme.generation, 2);

    let Outcome::NotFound { looked, .. } = theme.load_from(Choice { name: "nowhere".into(), ..aqua() }, &dirs, None) else { panic!("found nowhere") };
    assert_eq!(looked, dirs);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The compiled Jaguar lists are the shipped files, in name order, and
/// every one of them.
#[test]
fn the_compiled_jaguar_lists_are_the_shipped_files() {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../themes/aqua");
    let mut names = vec![];
    for sub in ["draw", "icons"] {
        for e in std::fs::read_dir(format!("{dir}/{sub}")).unwrap() {
            let n = e.unwrap().file_name().to_string_lossy().into_owned();
            if n.ends_with(".dl") {
                names.push(format!("{sub}/{n}"));
            }
        }
    }
    names.sort();
    let compiled: Vec<&str> = JAGUAR_SOURCES.iter().map(|(n, _)| *n).collect();
    assert_eq!(compiled, names, "themes/aqua/draw or icons gained or lost a file: list it in JAGUAR_SOURCES");
    assert!(jaguar_lists().lists.len() > 20);
}

/// A theme's draw/ is strict as its theme.ini is, and what it does not
/// ship stays Jaguar's.
#[test]
fn draw_lists_load_strictly_and_fall_back_per_list() {
    let dir = scratch("lists");
    std::fs::create_dir_all(format!("{dir}/draw")).unwrap();
    let write = |n: &str, t: &str| std::fs::write(format!("{dir}/draw/{n}"), t).unwrap();
    assert!(load_lists(&format!("{dir}/nowhere")).unwrap().0.is_none(), "no draw/ is not an error: all Jaguar");

    write("a.dl", "list gadget.pill\n  rect 0 0 w h\n  fill #ff0000\nend\nlist sparkle\n  rect 0 0 w h\nend\n");
    let (lists, warnings) = load_lists(&dir).unwrap();
    assert_eq!(warnings, ["list sparkle (draw/a.dl) is not one the toolkit draws"]);
    let mut theme = Theme::default();
    theme.use_theme(ThemeTokens::jaguar(), lists.as_ref(), HashMap::new(), None);
    assert_eq!(theme.lists.get("gadget.pill").unwrap().steps.len(), 2, "the theme's pill replaces Jaguar's");
    assert!(theme.lists.get("button").is_some(), "and the button it does not ship stays Jaguar's");

    write("b.dl", "list tab\n  frobnicate\nend\n");
    write("c.dl", "list gadget.pill\nend\n");
    let e = load_lists(&dir).err().unwrap();
    assert_eq!(
        e.problems,
        [
            "draw/b.dl line 2: frobnicate is not an op (rect ellipse circle arc path fill stroke bevel innershadow glow shadow rules text push pop clip move rotate scale)",
            "draw/c.dl: list gadget.pill is also in draw/a.dl",
        ]
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// Colour tokens and metrics resolve in a list, and say so when misspelt.
#[test]
fn lists_name_tokens_and_metrics() {
    let f = DrawListFile::parse("list x\n  rect 0 0 @titleBarHeight w\n  fill bodyText\nend\n").unwrap();
    assert_eq!(f.get("x").unwrap().steps.len(), 2);
    let e = DrawListFile::parse("list x\n  fill bodyTxt\nend\n").err().unwrap();
    assert_eq!(e.message, "bodyTxt is not a colour token");
    let e = DrawListFile::parse("list x\n  rect 0 0 @tall w\nend\n").err().unwrap();
    assert!(e.message.starts_with("@tall: @tall is not a metric (titleBarHeight "), "{}", e.message);
}

// MARK: ChromeTests

fn tokens(ini: &str) -> ThemeTokens {
    parse(ini, None, &none()).unwrap().tokens
}

#[test]
fn jaguars_frame_is_where_it_always_was() {
    let l = window_chrome(&ThemeTokens::jaguar(), 400.0, 300.0, false);
    assert_eq!(l.gadgets.iter().map(|g| g.gadget).collect::<Vec<_>>(), [Gadget::Close, Gadget::Minimize, Gadget::Zoom, Gadget::Pill]);
    assert_eq!(l.rect(Gadget::Close), Some(Rect::new(10.0, 4.5, 13.0, 13.0)));
    assert_eq!(l.rect(Gadget::Minimize), Some(Rect::new(30.0, 4.5, 13.0, 13.0)));
    assert_eq!(l.rect(Gadget::Zoom), Some(Rect::new(50.0, 4.5, 13.0, 13.0)));
    assert_eq!(l.rect(Gadget::Pill), Some(Rect::new(370.0, 4.5, 22.0, 13.0)));
    assert_eq!((l.title_align, l.title_x), (TitleAlign::Center, 200.0));
    assert_eq!(l.body, Rect::new(0.0, 22.0, 400.0, 278.0));
}

/// A foreign window has no toolbar, so no pill: in the layout, and so in
/// both the paint and the hit-test.
#[test]
fn a_foreign_frame_has_no_pill() {
    let t = ThemeTokens::jaguar();
    let l = window_chrome(&t, 400.0, 300.0, true);
    assert_eq!(l.rect(Gadget::Pill), None);
    assert_eq!(chrome_hit(&t, &l, 380.0, 11.0), ChromeHit::Title);
    assert_eq!(chrome_hit(&t, &window_chrome(&t, 400.0, 300.0, false), 380.0, 11.0), ChromeHit::Gadget(Gadget::Pill));
}

/// Every gadget laid out is hit at every point inside it, and no two
/// overlap: paint and hit-test read the same rects (§2.9).
#[test]
fn every_gadget_is_hit_where_it_is_laid_out() {
    for ini in ["", "[chrome]\nleft = close minimize zoom\nright = depth pill\ntitle = left", "[chrome]\nleft = depth\nright = zoom minimize close", "[chrome]\nleft = pill close\nright = depth"] {
        let t = tokens(ini);
        for foreign in [false, true] {
            let l = window_chrome(&t, 500.0, 300.0, foreign);
            for g in &l.gadgets {
                let mut dx = 0.5;
                while dx < g.rect.w {
                    assert_eq!(chrome_hit(&t, &l, g.rect.x + dx, g.rect.y + g.rect.h / 2.0), ChromeHit::Gadget(g.gadget), "{ini:?} {:?} at +{dx}", g.gadget);
                    dx += 1.0;
                }
            }
            for (i, a) in l.gadgets.iter().enumerate() {
                assert!(a.rect.y + a.rect.h <= l.title_bar.h);
                for b in &l.gadgets[i + 1..] {
                    assert!(a.rect.x + a.rect.w <= b.rect.x || b.rect.x + b.rect.w <= a.rect.x, "{ini:?}: {:?} overlaps {:?}", a.gadget, b.gadget);
                }
            }
        }
    }
}

/// The right side is laid from the edge inwards, in the order written.
#[test]
fn the_right_side_reads_left_to_right() {
    let t = tokens("[chrome]\nright = depth pill\ntitle = left\ntitleWeight = bold");
    let l = window_chrome(&t, 400.0, 300.0, false);
    let (depth, pill) = (l.rect(Gadget::Depth).unwrap(), l.rect(Gadget::Pill).unwrap());
    assert_eq!(pill.x + pill.w, 392.0);
    assert_eq!(depth.x + depth.w, pill.x - 7.0, "the lights' own gap");
    assert!(l.title_bold);
    assert_eq!(l.title_x, 63.0 + 7.0 + 4.0, "a left title starts after the lights");
    assert_eq!(chrome_hit(&t, &l, depth.x + 6.0, 11.0), ChromeHit::Gadget(Gadget::Depth));
}

#[test]
fn the_resize_band_is_the_themes() {
    let t = tokens("[metrics]\nchrome.resizeBand = 10\nchrome.resizeCorner = 20");
    let l = window_chrome(&t, 400.0, 300.0, false);
    assert_eq!(chrome_hit(&t, &l, 200.0, 291.0), ChromeHit::Resize(ChromeEdge::Bottom));
    assert_eq!(chrome_hit(&t, &l, 385.0, 285.0), ChromeHit::Resize(ChromeEdge::BottomRight));
    assert_eq!(chrome_hit(&t, &l, 200.0, 289.0), ChromeHit::Content);
}

#[test]
fn chrome_mistakes_are_refused_by_name() {
    assert_eq!(problems("[chrome]\nleft = close sparkle", None), ["[chrome] left = close sparkle: sparkle is not a gadget (close minimize zoom depth pill)"]);
    assert_eq!(problems("[chrome]\nleft = close\nright = close", None), ["[chrome] close is on the left already"]);
    assert_eq!(problems("[chrome]\ntitle = right", None), ["[chrome] title = right: want left or center"]);
    assert_eq!(problems("[chrome]\ntitleWeight = heavy", None), ["[chrome] titleWeight = heavy: want regular or bold"]);
    assert_eq!(problems("[chrome]\ngadgets = close", None), ["[chrome] gadgets is not a token"]);
}

// MARK: LegibilityTests

#[test]
fn ratios_are_wcags() {
    let (black, white) = (Color::new(0.0, 0.0, 0.0, 1.0), Color::new(1.0, 1.0, 1.0, 1.0));
    assert!((ratio(black, white) - 21.0).abs() < 0.01);
    assert!((ratio(white, white) - 1.0).abs() < 0.001);
    assert!(ratio(Color::hex(0x767676, 1.0), white) >= 4.5);
    assert!(ratio(Color::hex(0x777777, 1.0), white) < 4.5);
}

#[test]
fn translucent_text_is_measured_as_it_is_seen() {
    let white = Color::new(1.0, 1.0, 1.0, 1.0);
    let seen = ratio(over(Color::new(0.0, 0.0, 0.0, 0.2), white), white);
    assert!((seen - ratio(Color::new(0.8, 0.8, 0.8, 1.0), white)).abs() < 0.001);
}

#[test]
fn unreadable_body_text_refuses_and_says_why() {
    let mut t = ThemeTokens::jaguar();
    t.body_text = Color::hex(0xcccccc, 1.0);
    let (p, _) = legibility::check(&t);
    assert!(p.iter().any(|l| l.starts_with("[legibility] bodyText #cccccc on contentBackground #ececec is 1.3")), "{p:?}");
    assert!(p.iter().all(|l| l.contains("body text needs 4.5:1")));
    assert!(parse("[colors]\nbodyText = #cccccc", None, &none()).is_err(), "refused at load");
}

#[test]
fn dim_secondary_text_only_warns() {
    let t = parse("[colors]\nsecondaryText = #d0d0d0", None, &none()).unwrap();
    assert!(t.warnings.iter().any(|w| w.starts_with("legibility: secondaryText #d0d0d0 on contentBackground")), "{:?}", t.warnings);
}

#[test]
fn targets_a_pointer_cannot_hit_refuse() {
    assert_eq!(problems("[metrics]\ntrafficRadius = 4", None), ["[legibility] a title-bar gadget is 8 pt — a pointer needs 12"]);
    assert!(parse("[metrics]\nmenu.itemHeight = 12", None, &none()).is_err());
}

#[test]
fn the_palette_is_the_theme() {
    let aqua = legibility::palette_ini(&ThemeTokens::jaguar(), "Aqua", None);
    assert!(aqua.contains("color-scheme = 2\n"), "light");
    assert!(aqua.contains("accent-color = 0.2471 0.4353 0.8745\n"), "the menu blue the portal always said");
    assert!(aqua.contains("contrast = 0\n"));
    let mut dark = ThemeTokens::jaguar();
    dark.content_background = Color::hex(0x101010, 1.0);
    dark.body_text = Color::new(1.0, 1.0, 1.0, 1.0);
    assert!(legibility::palette_ini(&dark, "x", None).contains("color-scheme = 1\n"), "dark");
}
