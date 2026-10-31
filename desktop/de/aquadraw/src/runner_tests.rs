//! DrawListTests, CursorTests, TextRoleTests, ThemeSetTests and
//! ThemeSwitchTests (Tests/AquaTests), ported, with AquaTests' toolkit
//! basics (colour, rect, shaping). A child of `runner`, so a test can see
//! the runner's caches, as Swift's could see DrawListRunner's statics.

use super::*;
use crate::cursor;
use crate::scene;
use crate::text::Style;
use crate::theme::{self, Outcome, Theme};
use crate::xcursor;
use std::collections::{BTreeMap, BTreeSet};

const ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");

fn runner() -> Runner {
    scene::runner(1).expect("no font on this host")
}

fn parse(s: &str) -> Result<DrawListFile, DrawListError> {
    DrawListFile::parse(s)
}

fn error(s: &str) -> Option<DrawListError> {
    parse(s).err()
}

/// (r, g, b, a) at (x, y), premultiplied as cairo stores them.
struct Pixels {
    w: usize,
    px: Vec<u32>,
}

impl Pixels {
    fn at(&self, x: usize, y: usize) -> (u32, u32, u32, u32) {
        let p = self.px[y * self.w + x];
        ((p >> 16) & 0xff, (p >> 8) & 0xff, p & 0xff, p >> 24)
    }
    fn inked(&self) -> usize {
        self.px.iter().filter(|p| **p != 0).count()
    }
}

#[derive(Clone, Copy)]
struct Opts<'a> {
    w: i32,
    h: i32,
    state: DrawState,
    label: &'a str,
    params: &'a [(&'a str, f64)],
}

const PLAIN: Opts<'static> = Opts { w: 40, h: 20, state: DrawState::NORMAL, label: "", params: &[] };

/// Render the list `t` of `src` into a w×h surface.
fn render_with(r: &mut Runner, src: &str, o: Opts) -> Pixels {
    let f = parse(src).unwrap_or_else(|e| panic!("{src}: {e}"));
    let list = f.get("t").expect("no list t");
    let s = Surface::image(ffi::FORMAT_ARGB32, o.w, o.h);
    {
        let cr = Context::new(&s);
        let mut ctx = DrawContext::new(Rect::new(0.0, 0.0, o.w as f64, o.h as f64), o.state, o.label);
        ctx.parameters = o.params.iter().map(|(k, v)| ((*k).to_owned(), *v)).collect();
        r.run(list, &cr, &ctx);
    }
    s.flush();
    Pixels { w: o.w as usize, px: s.argb_pixels(o.w, o.h) }
}

fn render(src: &str, o: Opts) -> Pixels {
    render_with(&mut runner(), src, o)
}

// MARK: AquaTests — the toolkit's basics

#[test]
fn color_hex() {
    let c = Color::hex(0xFF8040, 1.0);
    assert!((c.r - 1.0).abs() < 0.001 && (c.g - 128.0 / 255.0).abs() < 0.001 && (c.b - 64.0 / 255.0).abs() < 0.001 && (c.a - 1.0).abs() < 0.001);
}

#[test]
fn color_with_alpha() {
    assert!((Color::hex(0x000000, 1.0).with_a(0.5).a - 0.5).abs() < 0.001);
}

#[test]
fn rect_contains() {
    let r = Rect::new(10.0, 10.0, 100.0, 50.0);
    assert!(r.contains(20.0, 20.0));
    assert!(r.contains(10.0, 10.0), "edge inclusive");
    assert!(r.contains(110.0, 60.0), "far edge inclusive");
    assert!(!r.contains(5.0, 5.0));
    assert!(!r.contains(200.0, 200.0));
}

#[test]
fn shape_empty_is_empty() {
    assert!(runner().text.shape("", 13, Style::Regular, Role::Interface).is_empty());
}

#[test]
fn shape_produces_glyphs() {
    let mut r = runner();
    let g = r.text.shape("Displays", 13, Style::Regular, Role::Interface);
    assert_eq!(g.len(), 8, "one glyph per Latin letter");
    assert!(g.iter().all(|g| g.face == 0), "Latin covered by the primary face");
    assert!(g.iter().all(|g| g.x_advance > 0.0), "every glyph advances the pen");
    assert_ne!(g[0].index, std::os::raw::c_ulong::from(b'D'), "a glyph index, not the codepoint");
}

#[test]
fn bold_style_shapes_and_is_wider() {
    let mut r = runner();
    let s = "Delete this item?";
    let reg = r.text.shape(s, 15, Style::Regular, Role::Interface);
    let bold = r.text.shape(s, 15, Style::Bold, Role::Interface);
    assert_eq!(reg.len(), bold.len(), "same glyph count across weights");
    // A host without a bold face falls back to regular: equal, not narrower.
    assert!(Text::width(&bold) >= Text::width(&reg));
    let again = r.text.shape(s, 15, Style::Bold, Role::Interface);
    assert_eq!(again.len(), bold.len());
    assert!((Text::width(&again) - Text::width(&bold)).abs() < 0.001, "shaping is deterministic");
}

#[test]
fn width_scales_and_metrics_positive() {
    let mut r = runner();
    let narrow = Text::width(&r.text.shape("ii", 13, Style::Regular, Role::Interface));
    let wide = Text::width(&r.text.shape("WW", 13, Style::Regular, Role::Interface));
    assert!(wide > narrow, "W is wider than i");
    let m = Text::metrics(13, Role::Interface);
    assert!(m.ascent > 0.0 && m.descent > 0.0);
}

#[test]
fn segment_rects_cover_the_rect_in_equal_adjacent_parts() {
    let r = Rect::new(10.0, 20.0, 240.0, 22.0);
    let segs = crate::canvas::segment_rects(r, 3);
    assert_eq!(segs.len(), 3);
    assert!((segs[0].x - r.x).abs() < 0.01);
    assert!((segs[2].x + segs[2].w - (r.x + r.w)).abs() < 0.01);
    for i in 1..segs.len() {
        assert!((segs[i].x - (segs[i - 1].x + segs[i - 1].w)).abs() < 0.01);
        assert!((segs[i].w - segs[0].w).abs() < 0.01);
    }
    assert!(crate::canvas::segment_rects(r, 0).is_empty());
}

// MARK: DrawListTests — parsing

#[test]
fn every_mistake_names_its_line() {
    assert_eq!(error("list a\n  frobnicate 1\nend").map(|e| e.line), Some(2));
    assert!(error("list a\n  frobnicate 1\nend").unwrap().message.contains("is not an op"));
    assert_eq!(error("list a\n  rect 0 0 w\nend").map(|e| e.line), Some(2));
    assert_eq!(error("list a\n  rect 0 0 w h\n  fill notAToken\nend").unwrap().message, "notAToken is not a colour token");
    assert_eq!(error("list a\n  when sleepy fill #ffffff\nend").map(|e| e.line), Some(2));
    assert_eq!(error("list a\n  rect 0 0 (w-2 h\nend").unwrap().message, "(w-2 h: a ( is not closed");
    assert_eq!(error("list a\n  rect 0 0 w*z h\nend").unwrap().message, "w*z: z is not an operand (a number, w, h, @metric, $parameter, textw, min or max)");
    assert_eq!(error("list a\n  rect 0 0 @tall h\nend").map(|e| e.line), Some(2), "an unknown metric is refused when parsed");
    assert_eq!(error("list a\n  fill shift(menuText, 3)\nend").unwrap().message, "shift(menuText, 3): want shift(colour, -1…1)");
    assert_eq!(error("list a\n  rect 0 0 w h\n").unwrap().message, "list a has no end");
    assert_eq!(error("fill #ffffff").unwrap().message, "fill outside a list");
    assert_eq!(error("list a\nend\nlist a\nend").unwrap().message, "a second list called a");
    assert_eq!(error("list a # a comment\n  rect 0 0 w h  # another\n  fill #102030 # and here\nend"), None, "a # that is not a colour starts a comment");
}

// MARK: DrawListTests — pixels

#[test]
fn a_solid_fill_is_exact() {
    let px = render("list t\n  rect 0 0 w h\n  fill #3f6fdf\nend", PLAIN);
    assert_eq!(px.at(10, 10), (0x3f, 0x6f, 0xdf, 255));
}

#[test]
fn a_token_is_read_from_the_current_theme_when_the_list_runs() {
    let mut r = runner();
    let mut t = ThemeTokens::jaguar();
    t.menu_highlight = Color::hex(0x102030, 1.0);
    r.use_theme(&t, &HashMap::new());
    let px = render_with(&mut r, "list t\n  rect 0 0 w h\n  fill menuHighlight\nend", PLAIN);
    assert_eq!(px.at(5, 5).0, 0x10, "a theme change reaches a list parsed before it");
}

#[test]
fn states_pick_their_ops() {
    let src = "list t\n  rect 0 0 w h\n  fill #ff0000\n  when pressed fill #0000ff\n  unless disabled,pressed fill #00ff00\nend";
    assert_eq!(render(src, PLAIN).at(5, 5).1, 255, "normal: the unless applies");
    assert_eq!(render(src, Opts { state: DrawState::PRESSED, ..PLAIN }).at(5, 5).2, 255, "pressed: blue");
    assert_eq!(render(src, Opts { state: DrawState::DISABLED, ..PLAIN }).at(5, 5).0, 255, "disabled: only the base");
    let normal_only = "list t\n  rect 0 0 w h\n  when normal fill #ff0000\nend";
    assert_eq!(render(normal_only, PLAIN).at(5, 5).0, 255);
    assert_eq!(render(normal_only, Opts { state: DrawState::HOVER, ..PLAIN }).at(5, 5).3, 0, "`when normal` is the empty set only");
}

#[test]
fn a_bevel_lights_top_left_and_shades_bottom_right() {
    let px = render("list t\n  rect 0 0 w h\n  fill #808080\n  bevel 1 #ffffff #000000\nend", PLAIN);
    assert_eq!(px.at(10, 0).0, 255, "top edge light");
    assert_eq!(px.at(0, 10).0, 255, "left edge light");
    assert_eq!(px.at(10, 19).0, 0, "bottom edge shade");
    assert_eq!(px.at(39, 10).0, 0, "right edge shade");
    assert_eq!(px.at(10, 10).0, 0x80, "the face is untouched");
}

#[test]
fn operands_can_use_the_size_metrics_and_parameters() {
    let src = "list t\n  rect w/2 0 1 h\n  fill #ff0000\n  rect 2*$gap 0 1 h\n  fill #00ff00\n  rect 0 @titleBarHeight 1 1\n  fill #0000ff\nend";
    let px = render(src, Opts { w: 40, h: 30, params: &[("gap", 3.0)], ..PLAIN });
    assert_eq!(px.at(20, 5).0, 255);
    assert_eq!(px.at(19, 5).0, 0);
    assert_eq!(px.at(6, 5).1, 255);
    assert_eq!(px.at(0, 22).2, 255, "@titleBarHeight is Jaguar's 22");
}

#[test]
fn arithmetic_is_calc_not_a_language() {
    let mut r = runner();
    let mut ctx = DrawContext::new(Rect::new(0.0, 0.0, 40.0, 30.0), DrawState::NORMAL, "");
    ctx.parameters.insert("v".into(), 0.5);
    let mut v = |s: &str| r.eval(&operand(s, 1).unwrap_or_else(|e| panic!("{s}: {e}")), &ctx);
    assert_eq!(v("w-h/2-3"), 22.0, "* before -, left to right");
    assert_eq!(v("(w-h)/2"), 5.0);
    assert_eq!(v("min(w,h)*0.5"), 15.0);
    assert_eq!(v("max(h, $v*w)"), 30.0);
    assert_eq!(v("-h+1"), -29.0);
    assert_eq!(v("@fontSize*0.35"), 13.0 * 0.35);
    assert_eq!(v("@finder.rowHeight*2"), 36.0, "a layer-3 metric, by its dotted name");
    assert_eq!(v("w/0"), 0.0, "a division by zero is 0, not a trap");
}

#[test]
fn a_linear_gradient_runs_end_to_end() {
    let px = render("list t\n  rect 0 0 w h\n  fill linear 0 0 w 0 stops 0 #000000 1 #ffffff\nend", Opts { w: 100, ..PLAIN });
    assert!(px.at(0, 5).0 < 5);
    assert!(px.at(99, 5).0 > 250);
    assert!((px.at(50, 5).0 as f64 - 128.0).abs() <= 4.0);
}

#[test]
fn a_conic_sweep_is_right_at_its_quarters() {
    let px = render("list t\n  rect 0 0 w h\n  fill conic 50 50 50 stops 0 #ff0000 0.5 #0000ff 1 #ff0000\nend", Opts { w: 100, h: 100, ..PLAIN });
    assert!(px.at(95, 51).0 > 240, "0° red");
    assert!(px.at(5, 50).2 > 240, "180° blue");
    let q = px.at(51, 95); // 90°: half way red→blue
    assert!((q.0 as f64 - 128.0).abs() <= 12.0 && (q.2 as f64 - 128.0).abs() <= 12.0, "{q:?}");
}

#[test]
fn stripes_alternate() {
    let px = render("list t\n  rect 0 0 w h\n  fill stripes 0 2 #ffffff 2 #000000\nend", PLAIN);
    assert_eq!([0, 1, 2, 3, 4].map(|x| px.at(x, 5).0), [255, 255, 0, 0, 255], "and repeat");
    let across = render("list t\n  rect 0 0 w h\n  fill stripes 90 1 #ffffff 2 #000000\nend", PLAIN);
    assert_eq!(across.at(7, 0).0, 255);
    assert_eq!(across.at(7, 1).0, 0);
    assert_eq!(across.at(7, 3).0, 255, "90° runs the bands across, as brushed metal wants");
    assert_eq!(across.at(30, 3).0, 255);
}

#[test]
fn noise_is_deterministic_and_seeded() {
    let mut r = runner();
    let mut grab = |seed: u32| {
        let px = render_with(&mut r, &format!("list t\n  rect 0 0 w h\n  fill noise {seed} 0.5\nend"), PLAIN);
        (0..20).map(|x| px.at(x, 3).3).collect::<Vec<_>>()
    };
    assert_eq!(grab(7), grab(7), "the same seed is the same tile: goldens depend on it");
    assert_ne!(grab(7), grab(8));
    assert!(grab(7).iter().all(|a| *a <= 128), "alpha 0.5 bounds the noise");
}

#[test]
fn a_glow_reaches_outside_its_shape_and_fades() {
    let mut r = runner();
    let src = "list t\n  rect 20 20 20 20\n  glow #00e5ff 8\nend";
    let px = render_with(&mut r, src, Opts { w: 60, h: 60, ..PLAIN });
    let (near, far) = (px.at(18, 30).3, px.at(8, 30).3);
    assert!(near > 0, "the halo reaches past the edge");
    assert!(near > far, "and fades with distance");
    assert_eq!(px.at(0, 0).3, 0, "and ends");
    let made = r.glows_computed;
    render_with(&mut r, src, Opts { w: 60, h: 60, ..PLAIN });
    assert_eq!(r.glows_computed, made, "the second draw of the same glow is cached");
}

#[test]
fn tracking_widens_text_and_upper_changes_case() {
    let mut r = runner();
    let mut ink_right = |opts: &str| {
        let px = render_with(&mut r, &format!("list t\n  rect 0 0 w h\n  text \"abc\" 0 h/2 {opts} color=#ffffff\nend"), Opts { w: 120, h: 20, ..PLAIN });
        (0..120).rev().find(|&x| (0..20).any(|y| px.at(x, y).3 > 0)).unwrap_or(0) as i64
    };
    let plain = ink_right("");
    let tracked = ink_right("tracking=4");
    assert!(tracked - plain >= 7, "two gaps of 4 px (the last glyph's is outside the ink): {plain} → {tracked}");
    assert!(ink_right("upper") > plain, "ABC is wider than abc");
}

/// P11.5's additions: curves in a path, arcs, faded colours, dashes.
#[test]
fn curves_arcs_fades_and_dashes() {
    let mut r = runner();
    let bulge = render_with(&mut r, "list t\n  path 10 0 curve 30 5 30 15 10 20 close\n  fill #ffffff\nend", PLAIN);
    assert!(bulge.at(18, 10).3 > 200);
    assert_eq!(bulge.at(5, 10).3, 0);
    let arc = render_with(&mut r, "list t\n  arc 20 0 10 0 1.5707963\n  stroke #ffffff 2\nend", PLAIN);
    assert!(arc.at(27, 7).3 > 100, "on the quarter");
    assert_eq!(arc.at(13, 7).3, 0, "not the lower-left quarter");
    let half = render_with(&mut r, "list t\n  rect 0 0 w h\n  fill fade(#ffffff, $p)\nend", Opts { params: &[("p", 0.5)], ..PLAIN });
    assert!((half.at(5, 5).3 as f64 - 128.0).abs() <= 1.0);
    assert_eq!(render_with(&mut r, "list t\n  rect 0 0 w h\n  fill fade(#ffffff, $p)\nend", PLAIN).at(5, 5).3, 0, "an absent parameter fades to nothing");
    let dash = render_with(&mut r, "list t\n  path 0 10.5 40 10.5\n  stroke #ffffff 1 dash=2,2\nend", PLAIN);
    assert_eq!([0, 2, 4].map(|x| dash.at(x, 10).3), [255, 0, 255]);
    let after = render_with(&mut r, "list t\n  path 0 5.5 40 5.5\n  stroke #ffffff 1 dash=2,2\n  path 0 10.5 40 10.5\n  stroke #ffffff 1\nend", PLAIN);
    assert_eq!(after.at(2, 10).3, 255, "the dash does not leak into the next stroke");
    assert_eq!(error("list t\n  path 0 0 curve 1 2 3\nend").map(|e| e.line), Some(2), "a curve wants six operands");
    assert_eq!(error("list t\n  path 0 0 1 1\n  stroke #ffffff 1 dash=\nend").unwrap().message, "dash=: want dash=on,off,… in pixels");
}

/// A cast shadow (P11.8): the shape's blurred mask, moved.
#[test]
fn a_cast_shadow_falls_where_it_is_cast() {
    let px = render("list t\n  rect 20 20 12 12\n  shadow #000000/0.8 6 6 3\nend", Opts { w: 60, h: 60, ..PLAIN });
    assert!(px.at(35, 35).3 > 100, "down and right: under the moved square, outside the shape");
    assert_eq!(px.at(16, 16).3, 0, "nothing up and left");
}

fn sample_sheet() -> DrawListFile {
    parse(&std::fs::read_to_string(format!("{ROOT}/abyss/tests/drawlist-sample.dl")).unwrap()).unwrap()
}

#[test]
fn the_sample_sheet_parses() {
    let f = sample_sheet();
    let keys: BTreeSet<&str> = f.lists.keys().map(String::as_str).collect();
    assert_eq!(keys, BTreeSet::from(["mui-button", "brushed", "anodized", "knob", "led", "lcd"]));
}

/// The bench (P11.3): the bound only catches an interpreter gone quadratic.
#[test]
fn the_interpreter_is_cheap_enough_to_draw_every_frame() {
    let f = sample_sheet();
    let mut r = runner();
    let s = Surface::image(ffi::FORMAT_ARGB32, 260, 120);
    let cr = Context::new(&s);
    for (name, w, h) in [("anodized", 200.0, 110.0), ("brushed", 260.0, 26.0), ("knob", 54.0, 54.0), ("lcd", 120.0, 40.0), ("led", 14.0, 14.0), ("mui-button", 90.0, 24.0)] {
        let list = f.get(name).unwrap();
        let ctx = DrawContext::new(Rect::new(0.0, 0.0, w, h), DrawState::FOCUSED, "Save");
        r.run(list, &cr, &ctx); // warm the glow cache
        let n = 200;
        let t0 = std::time::Instant::now();
        for _ in 0..n {
            r.run(list, &cr, &ctx)
        }
        let us = t0.elapsed().as_secs_f64() * 1e6 / n as f64;
        println!("drawlist bench: {name} {w}x{h} {us:.1} µs/run");
        // Swift's bound was 5 ms; a debug build of this is slower, so ten.
        assert!(us < 10_000.0, "{name}: {us} µs");
    }
}

// MARK: CursorTests

#[test]
fn a_list_header_may_name_a_hotspot_in_its_own_coordinates() {
    let f = parse("list cursor.t hotspot w/4 h-2\n  rect 0 0 w h\n  fill #000000\nend\n").unwrap();
    let (hx, hy) = f.get("cursor.t").unwrap().hotspot.clone().expect("a hotspot");
    let ctx = DrawContext::new(Rect::new(0.0, 0.0, 24.0, 24.0), DrawState::NORMAL, "");
    let mut r = runner();
    assert_eq!((r.eval(&hx, &ctx), r.eval(&hy, &ctx)), (6.0, 22.0));
    assert!(parse("list plain\n  rect 0 0 w h\nend\n").unwrap().get("plain").unwrap().hotspot.is_none());
}

#[test]
fn a_malformed_header_is_refused_with_the_shape_it_wants() {
    for bad in ["list c hotspot 1\nend\n", "list c spot 1 2\nend\n", "list c hotspot 1 2 3\nend\n"] {
        assert_eq!(error(bad).map(|e| e.message).as_deref(), Some("want: list <name> [hotspot <x> <y>]"), "{bad}");
    }
}

/// Jaguar draws 18 shapes; every one of cursor-shape-v1's 34 names lands on
/// one of them.
#[test]
fn every_shape_name_resolves_to_a_shape_jaguar_draws() {
    let t = Theme::default();
    assert_eq!(cursor::SHAPE_NAMES.len(), 34);
    for n in cursor::SHAPE_NAMES {
        assert!(t.lists.get(&format!("cursor.{}", cursor::resolve(&t, n))).is_some(), "{n}");
    }
    for (n, want) in [("text", "text"), ("col-resize", "ew-resize"), ("se-resize", "nwse-resize"), ("vertical-text", "text"), ("zoom-in", "default"), ("no-such-shape", "default")] {
        assert_eq!(cursor::resolve(&t, n), want, "{n}");
    }
}

#[test]
fn the_arrows_hotspot_is_its_tip_and_it_is_drawn_there() {
    let t = Theme::default();
    let mut r = runner();
    assert_eq!(cursor::hotspot(&mut r, &t, "default"), (5.0, 3.0));
    assert_eq!(cursor::hotspot(&mut r, &t, "text").0, 12.0);
    let s = Surface::image(ffi::FORMAT_ARGB32, 24, 24);
    {
        let cr = Context::new(&s);
        cursor::draw(&mut r, &t, "default", &cr, 0.0, 0.0);
    }
    s.flush();
    let px = Pixels { w: 24, px: s.argb_pixels(24, 24) };
    assert_eq!((px.at(7, 9).0, px.at(7, 9).3), (0, 255), "the body is black just below-right of the tip");
    assert_eq!(px.at(22, 2).3, 0, "and the cell's far corner is empty");
}

/// BACKLOG U.7b: the XCursor file libXcursor and libwayland-cursor read.
#[test]
fn the_file_is_libxcursors_format_one_image_per_size() {
    let t = Theme::default();
    let mut r = runner();
    let images: Vec<_> = xcursor::SIZES.iter().filter_map(|&s| cursor::rasterise(&mut r, &t, "default", s as f64 / 24.0)).collect();
    assert_eq!(images.iter().map(|i| i.size).collect::<Vec<_>>(), [24, 32, 48, 64]);
    let b = xcursor::encode(&images);
    let u32_at = |at: usize| u32::from_le_bytes(b[at..at + 4].try_into().unwrap());
    assert_eq!(&b[0..4], b"Xcur");
    assert_eq!((u32_at(4), u32_at(8), u32_at(12)), (16, 0x10000, 4));
    // The second table entry points at the 32-point image, whose chunk
    // header says so, with the arrow's hotspot scaled (5,3 × 4/3).
    assert_eq!(u32_at(16 + 12 + 4), 32);
    let at = u32_at(16 + 12 + 8) as usize;
    assert_eq!([0, 4, 16, 20, 24, 28].map(|o| u32_at(at + o)), [36, 0xfffd0002, 32, 32, 7, 4]);
    assert_eq!(b.len(), 16 + 12 * 4 + 36 * 4 + 4 * (24 * 24 + 32 * 32 + 48 * 48 + 64 * 64));
}

// MARK: TextRoleTests (P11.7)

/// Fonts from the tree's `fonts/`, and the roles a theme would set.
fn roles(r: &mut Runner, set: &[(Role, &str)]) -> ThemeTokens {
    abyss_sys::font_add_dir(&format!("{ROOT}/fonts"));
    let mut t = ThemeTokens::jaguar();
    for (role, fam) in set {
        let f = (*fam).to_owned();
        match role {
            Role::Interface => t.font_interface = f,
            Role::Chrome => t.font_chrome = f,
            Role::Readout => t.font_readout = f,
            Role::Mono => t.font_mono = f,
        }
    }
    r.use_theme(&t, &HashMap::new());
    t
}

/// What a role resolved to: whether it is the family asked for, the family,
/// the file.
fn resolved(role: Role, want: &str) -> (bool, String, String) {
    let (fam, file) = abyss_sys::font_role_resolved(role as i32);
    (fam.eq_ignore_ascii_case(want), fam, file)
}

#[test]
fn a_vendored_family_is_found_by_name() {
    let mut r = runner();
    roles(&mut r, &[(Role::Chrome, "Chakra Petch"), (Role::Readout, "VT323")]);
    let (c_wanted, c_fam, c_file) = resolved(Role::Chrome, "Chakra Petch");
    assert!(c_wanted && c_fam == "Chakra Petch", "{c_fam}");
    assert!(c_file.ends_with("fonts/chakrapetch/ChakraPetch-Regular.ttf"), "{c_file}");
    let (r_wanted, _, r_file) = resolved(Role::Readout, "VT323");
    assert!(r_wanted && r_file.ends_with("VT323-Regular.ttf"), "{r_file}");
}

/// A family that is not here is not replaced by whatever fontconfig likes
/// best: the role draws with the default chain.
#[test]
fn a_missing_family_falls_back_to_the_default_chain_not_a_substitute() {
    let mut r = runner();
    roles(&mut r, &[(Role::Chrome, "Lucida Grande")]);
    let (wanted, _, c_file) = resolved(Role::Chrome, "Lucida Grande");
    assert!(!wanted);
    assert_eq!(c_file, resolved(Role::Interface, "").2, "the default chain's primary, the same as every unmatched role");
    let chrome: Vec<_> = r.text.shape("AbyssBSD", 13, Style::Regular, Role::Chrome).iter().map(|g| g.index).collect();
    let interface: Vec<_> = r.text.shape("AbyssBSD", 13, Style::Regular, Role::Interface).iter().map(|g| g.index).collect();
    assert_eq!(chrome, interface, "Aqua's text is exactly what it was before roles");
}

#[test]
fn a_role_draws_in_its_own_face() {
    let mut r = runner();
    roles(&mut r, &[(Role::Chrome, "Chakra Petch"), (Role::Readout, "VT323")]);
    let s = "PLAN NEO 14:07";
    let plain = Text::width(&r.text.shape(s, 26, Style::Regular, Role::Interface));
    let chrome = Text::width(&r.text.shape(s, 26, Style::Regular, Role::Chrome));
    let lcd = Text::width(&r.text.shape(s, 26, Style::Regular, Role::Readout));
    assert!(plain != chrome && chrome != lcd);
    assert_ne!(Text::metrics(26, Role::Readout).ascent, Text::metrics(26, Role::Interface).ascent);
}

/// Bold comes from the family's own bold file; a family with no bold keeps
/// its typeface at regular weight.
#[test]
fn a_style_the_family_lacks_keeps_the_family() {
    let mut r = runner();
    roles(&mut r, &[(Role::Chrome, "Chakra Petch"), (Role::Readout, "VT323")]);
    let face = |r: &mut Runner, style, role| r.text.shape("A", 20, style, role)[0].face;
    assert_ne!(face(&mut r, Style::Bold, Role::Chrome), face(&mut r, Style::Regular, Role::Chrome), "Chakra Petch Bold is its own file");
    assert_eq!(face(&mut r, Style::Bold, Role::Readout), face(&mut r, Style::Regular, Role::Readout), "VT323 has no bold: its regular, not Noto Bold");
}

#[test]
fn the_chain_is_behind_every_role() {
    let mut r = runner();
    roles(&mut r, &[(Role::Readout, "VT323")]);
    let g = r.text.shape("1⌘", 20, Style::Regular, Role::Readout);
    assert_eq!(g.len(), 2);
    assert_ne!(g[0].face, g[1].face, "⌘ is not in VT323; it came from a fallback face");
}

#[test]
fn mono_falls_back_to_a_fixed_pitch_face() {
    let mut r = runner();
    roles(&mut r, &[]); // mono = Monaco, not here
    let (wanted, _, file) = resolved(Role::Mono, "Monaco");
    assert!(!wanted);
    assert_ne!(file, resolved(Role::Interface, "").2, "not the proportional default");
    let i = Text::width(&r.text.shape("iiii", 20, Style::Regular, Role::Mono));
    let w = Text::width(&r.text.shape("WWWW", 20, Style::Regular, Role::Mono));
    assert!((i - w).abs() <= 0.5, "fixed pitch: {i} {w}");
}

#[test]
fn a_draw_list_names_a_role() {
    assert!(parse("list a\n  text \"x\" 0 0 role=readout\nend").is_ok());
    assert_eq!(error("list a\n  text \"x\" 0 0 role=display\nend").unwrap().message, "display is not a role (interface chrome readout mono)");
}

// MARK: ThemeSetTests (P11.9)

#[test]
fn every_shipped_theme_loads_in_every_scheme_with_nothing_to_say() {
    let themes = format!("{ROOT}/themes");
    let mut names: Vec<String> = std::fs::read_dir(&themes).unwrap().filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| !n.starts_with('.') && std::path::Path::new(&format!("{themes}/{n}/theme.ini")).exists()).collect();
    names.sort();
    assert!(names.len() >= 2, "Aqua and a second theme: {names:?}");
    for n in &names {
        let text = std::fs::read_to_string(format!("{themes}/{n}/theme.ini")).unwrap();
        let base = theme::parse(&text, None, &BTreeMap::new()).unwrap_or_else(|e| panic!("{n}: {e:?}"));
        assert!(base.warnings.is_empty(), "{n}: {:?}", base.warnings);
        for s in &base.schemes {
            let t = theme::parse(&text, Some(s), &BTreeMap::new()).unwrap_or_else(|e| panic!("{n} {s}: {e:?}"));
            assert!(t.warnings.is_empty(), "{n} {s}: {:?}", t.warnings);
        }
        let (lists, w) = theme::load_lists(&format!("{themes}/{n}")).unwrap_or_else(|e| panic!("{n}: {e:?}"));
        assert!(w.is_empty(), "{n} ships a list the toolkit never draws: {w:?}");
        if n != "aqua" {
            assert!(lists.map_or(0, |l| l.lists.len()) > 60, "{n} is a look, not a few overrides");
        }
    }
}

#[test]
fn a_theme_parameter_reaches_a_list() {
    let t = theme::parse("[parameters]\nk = 0.5 0 1", None, &BTreeMap::new()).unwrap();
    let mut r = runner();
    r.use_theme(&t.tokens, &HashMap::from([("k".to_owned(), 0.5)]));
    let px = render_with(&mut r, "list t\n  rect 0 0 w h\n  fill fade(#ffffff, $k)\nend", Opts { w: 4, h: 4, ..PLAIN });
    assert!((px.at(0, 0).3 as f64 - 128.0).abs() <= 1.0);
    let mut ctx = DrawContext::new(Rect::new(0.0, 0.0, 1.0, 1.0), DrawState::NORMAL, "");
    ctx.parameters.insert("k".into(), 0.9);
    assert_eq!(r.eval(&Operand::Parameter("k".into()), &ctx), 0.9, "a widget's own value wins");
}

/// A role's case and tracking apply where it is shaped, so a measurement
/// and the drawing agree (§2.9).
#[test]
fn a_roles_case_and_tracking_are_in_the_measurement() {
    let mut r = runner();
    let plain = Text::width(&r.text.shape("abc", 20, Style::Regular, Role::Chrome));
    let mut t = ThemeTokens::jaguar();
    t.role_upper = BTreeSet::from(["chrome".to_owned()]);
    t.role_tracking = BTreeMap::from([("chrome".to_owned(), 0.1)]);
    r.use_theme(&t, &HashMap::new());
    let styled = r.text.shape("abc", 20, Style::Regular, Role::Chrome);
    let upper_only = r.text.shape("ABC", 20, Style::Regular, Role::Interface);
    assert_eq!(styled.iter().map(|g| g.index).collect::<Vec<_>>(), upper_only.iter().map(|g| g.index).collect::<Vec<_>>(), "upper-cased");
    assert!((Text::width(&styled) - (Text::width(&upper_only) + 3.0 * 2.0)).abs() < 0.01, "0.1 em × 20 px per glyph");
    assert_ne!(Text::width(&styled), plain);
}

#[test]
fn ghost_eights_dots_and_halo() {
    let mut r = runner();
    let o = Opts { w: 80, h: 30, label: "1:1", ..PLAIN };
    let lit = render_with(&mut r, "list t\n  text $label 4 h/2 color=#ffffff\nend", o);
    let ghosted = render_with(&mut r, "list t\n  text $label 4 h/2 color=#ffffff ghost=eights ghostalpha=0.5\nend", o);
    assert!(ghosted.inked() > lit.inked(), "8:8 under 1:1 adds ink");
    let dots = render_with(&mut r, "list t\n  rect 0 0 w h\n  fill dots 10 1.5 #ffffff\nend", Opts { w: 40, h: 40, ..PLAIN });
    assert!(dots.at(5, 5).3 > 200, "a dot at the tile's centre");
    assert_eq!(dots.at(0, 0).3, 0, "and nothing between");
    assert!(dots.at(25, 15).3 > 200, "repeating");
    let o = Opts { w: 80, h: 30, ..PLAIN };
    let plain = render_with(&mut r, "list t\n  text \"H\" 40 h/2 center color=#ffffff\nend", o);
    let halo = render_with(&mut r, "list t\n  text \"H\" 40 h/2 center color=#ffffff halo=#00e5ff halor=4\nend", o);
    assert!(halo.inked() > plain.inked(), "the halo reaches past the glyph");
}

// MARK: ThemeSwitchTests (PHASE14 P14.2)

/// Two tiny themes where a config directory's `themes/` finds them.
fn switch_fixture(tag: &str) -> String {
    let config = std::env::temp_dir().join(format!("abyss-switch-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&config);
    for (name, colour) in [("one", "#000001"), ("two", "#000002")] {
        let d = config.join("themes").join(name);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("theme.ini"), format!("[colors]\nmenuHighlight = {colour}\n[colors.dim]\nmenuHighlight = #000009\n[parameters]\nglow = 0.5 0 1\n")).unwrap();
    }
    config.to_string_lossy().into_owned()
}

fn loaded_name(o: Option<Outcome>) -> Option<String> {
    match o? {
        Outcome::Loaded(_, path) => path.rsplit('/').nth(1).map(str::to_owned),
        _ => None,
    }
}

fn put(theme: &str, scheme: Option<&str>, params: &[(&str, f64)], config: &str) {
    theme::store(theme, scheme, &params.iter().map(|(k, v)| ((*k).to_owned(), *v)).collect(), Some(config)).unwrap()
}

#[test]
fn a_changed_choice_reloads_and_an_unchanged_one_does_not() {
    let config = switch_fixture("reload");
    let c = Some(config.as_str());
    let mut r = runner();
    let mut th = Theme::default();
    put("one", None, &[], &config);
    assert_eq!(loaded_name(Some(th.load_current(c, Some(&mut r)))).as_deref(), Some("one"));
    assert_eq!(th.tokens.menu_highlight, Color::hex(0x000001, 1.0));
    let g = th.generation;

    assert!(th.reload_if_changed(c, Some(&mut r)).is_none(), "nothing changed");
    assert_eq!(th.generation, g, "and nothing was reloaded");

    put("two", None, &[], &config);
    assert_eq!(loaded_name(th.reload_if_changed(c, Some(&mut r))).as_deref(), Some("two"));
    assert_eq!(th.tokens.menu_highlight, Color::hex(0x000002, 1.0), "the theme reads the new file");
    assert!(th.generation > g);

    // A scheme is a change; so is a parameter.
    put("two", Some("dim"), &[], &config);
    assert!(th.reload_if_changed(c, Some(&mut r)).is_some());
    assert_eq!(th.tokens.menu_highlight, Color::hex(0x000009, 1.0));
    put("two", Some("dim"), &[("glow", 0.25)], &config);
    assert!(th.reload_if_changed(c, Some(&mut r)).is_some());
    assert_eq!(th.parameters.get("glow"), Some(&0.25));
    let _ = std::fs::remove_dir_all(&config);
}

/// Another process writes the choice; this one is told through a descriptor
/// it can wait on, and a write to another file there is not a theme change.
#[test]
fn the_watch_sees_a_choice_another_process_wrote_and_ignores_other_files() {
    let config = switch_fixture("watch");
    let c = Some(config.as_str());
    let mut r = runner();
    let mut th = Theme::default();
    put("one", None, &[], &config);
    th.load_current(c, Some(&mut r));
    let watch = pool_config::Watcher::new(c).expect("no watch");

    std::fs::write(format!("{config}/desktop.ini"), "[desktop]\nx = 1\n").unwrap();
    assert!(watch.wait(2000).unwrap(), "the directory changed");
    assert!(th.reload_if_changed(c, Some(&mut r)).is_none(), "but not the appearance");
    assert_eq!(th.tokens.menu_highlight, Color::hex(0x000001, 1.0));

    put("two", None, &[], &config);
    assert!(watch.wait(2000).unwrap(), "the watch did not see the choice being written");
    assert_eq!(loaded_name(th.reload_if_changed(c, Some(&mut r))).as_deref(), Some("two"));
    assert_eq!(th.tokens.menu_highlight, Color::hex(0x000002, 1.0));
    let _ = std::fs::remove_dir_all(&config);
}

/// **No mask outlives its theme** (PHASE14 §6.7); noise tiles are the same
/// in every theme, and stay.
#[test]
fn a_switch_forgets_glow_and_halo_masks_but_keeps_noise() {
    let mut r = runner();
    let mask = || Surface::image(ffi::FORMAT_A8, 4, 4);
    r.glow_cache.insert(GlowKey { shape: "x".into(), w: 4, h: 4, radius: 1, scale: 1 }, mask());
    r.halo_cache.insert(HaloKey { s: "x".into(), px: 12, style: 0, role: 0, radius: 1, scale: 1, tracking: 0 }, (mask(), 0.0, 0.0));
    assert!(r.noise_pattern(99, 0.5).is_some());
    let noise = r.noise_tiles.len();
    assert!(!r.glow_cache.is_empty());

    r.use_theme(&ThemeTokens::jaguar(), &HashMap::new());
    assert!(r.glow_cache.is_empty(), "a glow from the old theme survived");
    assert!(r.halo_cache.is_empty(), "a halo from the old theme survived");
    assert_eq!(r.noise_tiles.len(), noise, "noise is not theme-derived");
}
