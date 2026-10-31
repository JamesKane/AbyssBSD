//! PHASE11 P11.8: SVG artwork becomes a draw list at build time — strictly.
//! Ported from Tests/AquaTests/SVGImportTests.swift, with the cases where
//! this port parts from the Swift.

use super::*;
use abyss_sys::{Context, FORMAT_ARGB32, Surface};
use aquadraw::drawlist::{DrawListFile, DrawState};
use aquadraw::runner::{DrawContext, Rect};

const SIZE: i32 = 40;

/// The list drawn at 40×40: (r, g, b, a) per pixel.
fn pixels(list: &str, name: &str) -> impl Fn(usize, usize) -> (u32, u32, u32, u32) {
    let file = DrawListFile::parse(list).expect("the list parses");
    let l = file.get(name).expect("the list is there");
    let mut runner = aquadraw::scene::runner(1).expect("a font loads");
    let s = Surface::image(FORMAT_ARGB32, SIZE, SIZE);
    let cr = Context::new(&s);
    let ctx = DrawContext::new(Rect::new(0.0, 0.0, SIZE as f64, SIZE as f64), DrawState::NORMAL, "");
    runner.run(l, &cr, &ctx);
    drop(cr);
    s.flush();
    let px = s.argb_pixels(SIZE, SIZE);
    move |x, y| {
        let p = px[y * SIZE as usize + x];
        ((p >> 16) & 0xff, (p >> 8) & 0xff, p & 0xff, p >> 24)
    }
}

fn error(svg: &str) -> Option<String> {
    draw_list("t", svg).err().map(|e| e.to_string())
}

/// The committed sample is what the importer makes of the committed SVG —
/// so a change to the importer shows as a change to its output, and the
/// golden `svg-beacon@2x` pictures that output.
#[test]
fn the_sample_imports_to_the_committed_list() {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../abyss/tests/svg/");
    let svg = std::fs::read_to_string(format!("{dir}beacon.svg")).unwrap();
    let dl = std::fs::read_to_string(format!("{dir}beacon.dl")).unwrap();
    assert_eq!(
        draw_list("icon.beacon", &svg).unwrap(),
        dl,
        "re-run: svg2dl icon.beacon abyss/tests/svg/beacon.svg > abyss/tests/svg/beacon.dl"
    );
    assert!(DrawListFile::parse(&dl).is_ok());
}

#[test]
fn a_shape_lands_where_the_view_box_puts_it() {
    let dl = draw_list("t", r##"<svg viewBox="0 0 100 100"><rect x="50" y="0" width="50" height="50" fill="#ff0000"/></svg>"##)
        .unwrap();
    let px = pixels(&dl, "t");
    assert_eq!(px(30, 10).0, 255, "top-right quarter is red");
    assert_eq!(px(30, 10).3, 255);
    assert_eq!(px(10, 10).3, 0);
    assert_eq!(px(30, 30).3, 0);
}

/// Two arcs make a circle: filled at the centre, empty at the corner, and
/// round (the midpoint of an edge is inside, the box's corner is not).
#[test]
fn arcs_become_curves_that_are_round() {
    let dl = draw_list(
        "t",
        r##"<svg viewBox="0 0 40 40"><path d="M 4 20 A 16 16 0 1 1 36 20 A 16 16 0 1 1 4 20 Z" fill="#0000ff"/></svg>"##,
    )
    .unwrap();
    let px = pixels(&dl, "t");
    assert_eq!(px(20, 20).2, 255);
    assert_eq!(px(20, 5).3, 255, "the top of the circle");
    assert_eq!(px(6, 6).3, 0, "the box's corner is outside a circle");
}

#[test]
fn transforms_groups_and_inheritance() {
    let dl = draw_list(
        "t",
        r##"<svg viewBox="0 0 40 40"><g fill="#00ff00" transform="translate(20 0)"><rect width="10" height="10"/></g></svg>"##,
    )
    .unwrap();
    let px = pixels(&dl, "t");
    assert_eq!(px(25, 5).1, 255, "moved right by 20, green from the group");
    assert_eq!(px(5, 5).3, 0);
}

#[test]
fn what_is_outside_the_subset_is_refused_by_name() {
    assert_eq!(
        error("<svg viewBox=\"0 0 1 1\"><text>hi</text></svg>").as_deref(),
        Some("<text> is not in the subset svg2dl imports (svg g path rect circle ellipse line polyline polygon linearGradient)")
    );
    assert_eq!(
        error("<svg viewBox=\"0 0 1 1\"><path d=\"M0 0 L1 1\" fill-rule=\"evenodd\"/></svg>").as_deref(),
        Some("<path> fill-rule=evenodd: the draw-list format fills nonzero only")
    );
    assert_eq!(
        error("<svg viewBox=\"0 0 1 1\"><g transform=\"perspective(45)\"/></svg>").as_deref(),
        Some("transform perspective() is not in the subset (translate, scale, rotate, skewX, skewY, matrix)")
    );
    assert_eq!(
        error("<svg viewBox=\"0 0 1 1\"><rect width=\"1\" height=\"1\" fill=\"hsl(1,2,3)\"/></svg>").as_deref(),
        Some("hsl(1,2,3) is not a colour svg2dl reads (#rgb #rrggbb rgb() none url(#id))")
    );
    assert_eq!(error("<svg><rect/></svg>").as_deref(), Some("<svg> has neither a viewBox nor a width and height"));
    assert_eq!(error("<html/>").as_deref(), Some("the document is <html>, not <svg>"));
}

/// Each of these changes the picture, so importing without it would draw
/// something else: refused by name, as anything outside the subset is.
#[test]
fn clipping_masks_filters_and_gradient_tricks_are_refused_not_dropped() {
    let shape = |attr: &str| error(&format!("<svg viewBox=\"0 0 1 1\"><rect width=\"1\" height=\"1\" {attr}/></svg>"));
    assert_eq!(shape("clip-path=\"url(#c)\"").as_deref(), Some("<rect> clip-path=\"url(#c)\": svg2dl does not import clip-path"));
    assert_eq!(shape("mask=\"url(#m)\"").as_deref(), Some("<rect> mask=\"url(#m)\": svg2dl does not import mask"));
    assert_eq!(shape("style=\"filter: url(#f)\"").as_deref(), Some("<rect> filter=\"url(#f)\": svg2dl does not import filter"));
    // `none` is what no attribute means.
    assert_eq!(shape("clip-path=\"none\" mask=\"none\" filter=\"none\""), None);
    let gradient = |attr: &str| {
        error(&format!(
            "<svg viewBox=\"0 0 1 1\"><defs><linearGradient id=\"g\" {attr}><stop offset=\"0\"/><stop offset=\"1\"/></linearGradient></defs><rect width=\"1\" height=\"1\" fill=\"url(#g)\"/></svg>"
        ))
    };
    assert_eq!(gradient("gradientTransform=\"rotate(90)\"").as_deref(), Some("<linearGradient id=\"g\"> gradientTransform: svg2dl does not import gradientTransform"));
    assert_eq!(gradient("xlink:href=\"#h\"").as_deref(), Some("<linearGradient id=\"g\"> xlink:href: svg2dl does not import xlink:href"));
    assert_eq!(gradient("href=\"#h\"").as_deref(), Some("<linearGradient id=\"g\"> href: svg2dl does not import href"));
    assert_eq!(gradient(""), None);
    // A missing radial gradient is not called a linear one.
    assert_eq!(
        error("<svg viewBox=\"0 0 1 1\"><rect width=\"1\" height=\"1\" fill=\"url(#nope)\"/></svg>").as_deref(),
        Some("url(#nope): no gradient with that id")
    );
}

/// Round joins and round caps inherit separately, and a child can turn
/// either off; the list's one `round` is either of them.
#[test]
fn a_child_can_turn_round_strokes_off() {
    let list = |g: &str, p: &str| {
        draw_list("t", &format!("<svg viewBox=\"0 0 10 10\"><g {g}><path d=\"M0 0 L10 10\" fill=\"none\" stroke=\"#000\" {p}/></g></svg>")).unwrap()
    };
    let round = |g: &str, p: &str| list(g, p).contains(" round");
    assert!(round("stroke-linejoin=\"round\"", ""));
    assert!(round("stroke-linecap=\"round\"", ""));
    assert!(!round("stroke-linejoin=\"round\"", "stroke-linejoin=\"miter\""));
    assert!(!round("stroke-linecap=\"round\"", "stroke-linecap=\"butt\""));
    assert!(round("stroke-linejoin=\"round\" stroke-linecap=\"round\"", "stroke-linejoin=\"miter\""), "the cap is still round");
    assert!(!round("", ""));
}

// MARK: the port's own

/// Swift's `Double(String)`: strtod's whole-string forms, and nothing with
/// space around it.
#[test]
fn numbers_parse_as_swift_reads_them() {
    for (s, v) in [("+1", 1.0), ("1.", 1.0), (".5", 0.5), ("1.e5", 1e5), ("0x10", 16.0), ("0x1p3", 8.0), ("0X.8", 0.5)] {
        assert_eq!(swift_double(s), Some(v), "{s}");
    }
    for s in [" 1", "1 ", ".", "-", "1e", "e5", "0x", "1_0", "", "0x1p", "infin"] {
        assert_eq!(swift_double(s), None, "{s}");
    }
    assert!(swift_double("nan(1)").unwrap().is_nan());
    assert_eq!(swift_double("-Infinity"), Some(f64::NEG_INFINITY));
    assert_eq!(numbers("1-2.5.5e-3,4"), vec![1.0, -2.5, 0.0005, 4.0]);
}

#[test]
fn coordinates_are_five_decimals_without_trailing_zeros() {
    let c = Converter::default();
    assert_eq!(c.fmt(0.5), "0.5");
    assert_eq!(c.fmt(-0.000004), "0");
    assert_eq!(c.fmt(-0.123456), "-0.12346");
    assert_eq!(c.fmt(1.000005), "1.00001");
    assert_eq!(c.fmt(12.0), "12");
    assert!(c.unwritable.get().is_none());
}

/// The Swift traps on a number Int64 cannot hold, and loops for ever on
/// numbers after a Z: both are refusals here.
#[test]
fn what_the_swift_trapped_on_is_refused() {
    assert_eq!(
        error(r#"<svg viewBox="0 0 1 1"><rect width="1e300" height="1"/></svg>"#).as_deref(),
        Some("1e300 is a number the draw-list format cannot write")
    );
    assert_eq!(
        error(r#"<svg viewBox="0 0 1 1"><path d="M0 0 L1 1 Z 5 5"/></svg>"#).as_deref(),
        Some("path d: expected a command at 12")
    );
    assert_eq!(
        error(r#"<svg viewBox="0 0 1 1"><g transform="a)b("/></svg>"#).as_deref(),
        Some("transform=\"a)b(\" is not understood")
    );
}

/// A fill on the root `<svg>` reaches its shapes, as SVG has it.
#[test]
fn the_root_svg_styles_its_children() {
    let dl = draw_list("t", r#"<svg viewBox="0 0 1 1" fill="none" stroke="white"><rect width="1" height="1"/></svg>"#).unwrap();
    assert_eq!(dl, "list t\n  path w*0 h*0 w*1 h*0 w*1 h*1 w*0 h*1 close\n  stroke rgba(1, 1, 1, 1) w*1\nend\n");
}

#[test]
fn a_signed_hex_colour_is_not_a_colour() {
    assert!(error(r##"<svg viewBox="0 0 1 1"><rect width="1" height="1" fill="#+12345"/></svg>"##).is_some());
    assert!(color("#abc").is_some());
}
