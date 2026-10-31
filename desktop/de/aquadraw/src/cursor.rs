//! The pointer's shapes, as theme data (Cursors.swift, BACKLOG U.7).
//!
//! A cursor is a draw list called `cursor.<name>` in the theme's icons/
//! (Jaguar's in themes/aqua/icons/cursors.dl, compiled in behind every theme
//! as the rest of the icon set is), drawn in a `cursor.size` square, with its
//! hotspot in the list's header. The names are cursor-shape-v1's, which are
//! CSS's. A theme need not draw all 34 of them; a name it does not draw
//! falls back along a short chain to one it does, and finally to `default`.
//!
//! Painting is AquaDraw's; putting the picture on the screen is the
//! compositor's, which rasterises each shape once per scale and theme. The
//! XCursor theme writer is `abyss-theme`'s (R5).

use crate::drawlist::DrawState;
use crate::runner::{DrawContext, Rect, Runner};
use crate::theme::Theme;
use abyss_sys::{self as ffi, Context, Surface};

/// The names every theme is asked for, in cursor-shape-v1's order.
pub const SHAPE_NAMES: [&str; 34] = [
    "default", "context-menu", "help", "pointer", "progress", "wait", "cell", "crosshair",
    "text", "vertical-text", "alias", "copy", "move", "no-drop", "not-allowed", "grab",
    "grabbing", "e-resize", "n-resize", "ne-resize", "nw-resize", "s-resize", "se-resize",
    "sw-resize", "w-resize", "ew-resize", "ns-resize", "nesw-resize", "nwse-resize",
    "col-resize", "row-resize", "all-scroll", "zoom-in", "zoom-out",
];

/// Where a name goes when the theme does not draw it. Meaning, not look:
/// one edge's arrow is its axis's, a crosshair serves for a cell.
fn fallback(name: &str) -> Option<&'static str> {
    Some(match name {
        "e-resize" | "w-resize" | "col-resize" => "ew-resize",
        "n-resize" | "s-resize" | "row-resize" => "ns-resize",
        "ne-resize" | "sw-resize" => "nesw-resize",
        "nw-resize" | "se-resize" => "nwse-resize",
        "all-scroll" => "move",
        "vertical-text" => "text",
        "cell" => "crosshair",
        "no-drop" => "not-allowed",
        "progress" => "wait",
        "zoom-in" | "zoom-out" => "default",
        _ => return None,
    })
}

/// The shape cursor-shape-v1 calls `name`, as `theme` draws it: the name
/// of the list that will draw, after the fallbacks.
pub fn resolve(theme: &Theme, name: &str) -> String {
    let mut n = name;
    for _ in 0..4 {
        if theme.lists.get(&format!("cursor.{n}")).is_some() {
            return n.to_owned();
        }
        let Some(next) = fallback(n) else { break };
        n = next;
    }
    "default".to_owned()
}

/// The cell's size, in points.
pub fn size(theme: &Theme) -> f64 {
    theme.tokens.cursor_size
}

/// The hotspot of the shape `name` resolves to, in points from the cell's
/// top-left. The cell's centre if the list names none.
pub fn hotspot(runner: &mut Runner, theme: &Theme, name: &str) -> (f64, f64) {
    let s = size(theme);
    let Some(l) = theme.lists.get(&format!("cursor.{}", resolve(theme, name))) else { return (s / 2.0, s / 2.0) };
    let Some((hx, hy)) = &l.hotspot else { return (s / 2.0, s / 2.0) };
    let ctx = DrawContext::new(Rect::new(0.0, 0.0, s, s), DrawState::NORMAL, "");
    (runner.eval(hx, &ctx), runner.eval(hy, &ctx))
}

/// Draw the shape `name` resolves to, its cell's top-left at (x, y).
pub fn draw(runner: &mut Runner, theme: &Theme, name: &str, cr: &Context, x: f64, y: f64) {
    let Some(l) = theme.lists.get(&format!("cursor.{}", resolve(theme, name))) else { return };
    cr.new_path();
    let s = size(theme);
    runner.run(l, cr, &DrawContext::new(Rect::new(x, y, s, s), DrawState::NORMAL, ""));
}

/// One shape, rasterised: premultiplied ARGB, row-major, `size`×`size`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CursorImage {
    pub size: usize,
    pub pixels: Vec<u32>,
    /// The hotspot in these pixels.
    pub hot_x: i64,
    pub hot_y: i64,
}

/// The shape `name` resolves to, drawn at `scale`: the one rasteriser, so
/// the compositor's cursor and the XCursor theme a toolkit loads are the
/// same pixels.
pub fn rasterise(runner: &mut Runner, theme: &Theme, name: &str, scale: f64) -> Option<CursorImage> {
    let px = (size(theme) * scale).ceil() as i32;
    if px <= 0 {
        return None;
    }
    let surface = Surface::image(ffi::FORMAT_ARGB32, px, px);
    let cr = Context::new(&surface);
    cr.set_operator(ffi::OPERATOR_SOURCE);
    cr.set_source_rgba(0.0, 0.0, 0.0, 0.0);
    cr.paint();
    cr.set_operator(ffi::OPERATOR_OVER);
    cr.scale(scale, scale);
    let was = runner.text.render_scale;
    runner.text.render_scale = scale.ceil() as i32;
    draw(runner, theme, name, &cr, 0.0, 0.0);
    runner.text.render_scale = was;
    drop(cr);
    surface.flush();
    let pixels = surface.argb_pixels(px, px);
    let (hx, hy) = hotspot(runner, theme, name);
    Some(CursorImage { size: px as usize, pixels, hot_x: (hx * scale).round() as i64, hot_y: (hy * scale).round() as i64 })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scene;

    #[test]
    fn names_fall_back_by_meaning() {
        let t = Theme::default();
        for n in SHAPE_NAMES {
            assert!(t.lists.get(&format!("cursor.{}", resolve(&t, n))).is_some(), "{n} draws nothing");
        }
        assert_eq!(resolve(&t, "sparkle"), "default");
    }

    /// One rasteriser: the cell at the scale, its hotspot scaled with it.
    #[test]
    fn rasterising_scales_the_cell_and_the_hotspot() {
        let Some(mut runner) = scene::runner(1) else { return };
        let t = Theme::default();
        let one = rasterise(&mut runner, &t, "text", 1.0).unwrap();
        let two = rasterise(&mut runner, &t, "text", 2.0).unwrap();
        assert_eq!((one.size, two.size), (size(&t) as usize, 2 * size(&t) as usize));
        assert_eq!(two.pixels.len(), two.size * two.size);
        assert!(one.pixels.iter().any(|&p| p >> 24 != 0), "drew something");
        assert!((two.hot_x - 2 * one.hot_x).abs() <= 1 && (two.hot_y - 2 * one.hot_y).abs() <= 1);
        assert_eq!(runner.text.render_scale, 1, "the runner's scale is put back");
    }
}
