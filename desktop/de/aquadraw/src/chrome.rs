//! The window chrome, laid out (Chrome.swift, P9.6 and P11.6): the answer
//! every painter and hit-test reads, the toolkit's and undertow's alike, so
//! what is drawn is what is clickable (§2.9) on both sides.
//!
//! Since P11.6 the chrome is theme data: which gadgets, on which side,
//! where the title goes. `window_chrome` lays the frame out from that and
//! the chrome metrics, and nothing else computes it.

use crate::runner::Rect;
use crate::tokens::ThemeTokens;

/// A title-bar control. Jaguar has the first three; `depth` sends a window
/// to the back (Amiga's, and Plan Neo's); `pill` is the toolkit's toolbar
/// toggle, and only a window with a toolbar has one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Gadget {
    Close,
    Minimize,
    Zoom,
    Depth,
    Pill,
}

impl Gadget {
    pub const ALL: [Gadget; 5] = [Gadget::Close, Gadget::Minimize, Gadget::Zoom, Gadget::Depth, Gadget::Pill];

    pub fn name(self) -> &'static str {
        match self {
            Gadget::Close => "close",
            Gadget::Minimize => "minimize",
            Gadget::Zoom => "zoom",
            Gadget::Depth => "depth",
            Gadget::Pill => "pill",
        }
    }

    pub fn named(s: &str) -> Option<Gadget> {
        Gadget::ALL.into_iter().find(|g| g.name() == s)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TitleAlign {
    Left,
    Center,
}

impl TitleAlign {
    pub fn named(s: &str) -> Option<TitleAlign> {
        match s {
            "left" => Some(TitleAlign::Left),
            "center" => Some(TitleAlign::Center),
            _ => None,
        }
    }
}

/// A resize the frame offers: only along the bottom (P9.4 says why).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChromeEdge {
    Bottom,
    BottomLeft,
    BottomRight,
}

/// What is under a point in a window's frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChromeHit {
    Gadget(Gadget),
    /// Drag it to move the window.
    Title,
    Resize(ChromeEdge),
    /// Not chrome: the window's own business.
    Content,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlacedGadget {
    pub gadget: Gadget,
    pub rect: Rect,
}

/// A window frame, laid out.
#[derive(Clone, Debug, PartialEq)]
pub struct ChromeLayout {
    pub width: f64,
    pub height: f64,
    pub title_bar: Rect,
    pub gadgets: Vec<PlacedGadget>,
    /// The title's anchor: its centre (`Center`) or its left edge (`Left`).
    pub title_x: f64,
    pub title_align: TitleAlign,
    pub title_bold: bool,
    /// Below the title bar.
    pub body: Rect,
}

impl ChromeLayout {
    pub fn rect(&self, g: Gadget) -> Option<Rect> {
        self.gadgets.iter().find(|p| p.gadget == g).map(|p| p.rect)
    }
}

fn contains(r: Rect, x: f64, y: f64) -> bool {
    r.contains(x, y)
}

/// Lay out the frame of a `w`×`h` window from the theme `t`. `foreign` is
/// a frame undertow draws around a window it did not write: such a window
/// has no toolbar, so no pill (the pill P11.1 found painted there).
pub fn window_chrome(t: &ThemeTokens, w: f64, h: f64, foreign: bool) -> ChromeLayout {
    let (r, cy) = (t.traffic_radius, t.title_bar_height / 2.0);
    let gap = t.traffic_spacing - r * 2.0;
    let keep = |g: &&Gadget| !(foreign && **g == Gadget::Pill);
    let round = |cx: f64| Rect::new(cx - r, cy - r, r * 2.0, r * 2.0);
    let pill = |x: f64| Rect::new(x, cy - t.chrome_pill_height / 2.0, t.chrome_pill_width, t.chrome_pill_height);

    let mut placed = vec![];
    // Left: centres `spacing` apart from the inset, Jaguar's lights.
    let x0 = t.traffic_inset + r;
    let mut left_end = 0.0;
    for (i, &g) in t.chrome_left.iter().filter(keep).enumerate() {
        let rect = if g == Gadget::Pill { pill(left_end + if i == 0 { t.chrome_pill_inset } else { gap }) } else { round(x0 + i as f64 * t.traffic_spacing) };
        placed.push(PlacedGadget { gadget: g, rect });
        left_end = rect.x + rect.w;
    }
    // Right: the mirror, laid from the right edge inwards.
    let mut edge = w;
    let mut right = vec![];
    for (i, &g) in t.chrome_right.iter().filter(keep).rev().enumerate() {
        let rect = if g == Gadget::Pill {
            pill(edge - if i == 0 { t.chrome_pill_inset } else { gap } - t.chrome_pill_width)
        } else {
            round(edge - if i == 0 { t.traffic_inset } else { gap } - r)
        };
        right.insert(0, PlacedGadget { gadget: g, rect });
        edge = rect.x;
    }
    placed.extend(right);
    let title_x = if t.title_align == TitleAlign::Center { w / 2.0 } else { left_end + gap + 4.0 };
    ChromeLayout {
        width: w,
        height: h,
        title_bar: Rect::new(0.0, 0.0, w, t.title_bar_height),
        gadgets: placed,
        title_x,
        title_align: t.title_align,
        title_bold: t.title_bold,
        body: Rect::new(0.0, t.title_bar_height, w, h - t.title_bar_height),
    }
}

/// What is under (x, y) in a window laid out as `l`. **The bottom first**:
/// its band is the outermost few pixels, and a control overlapping it would
/// be unreachable from the other side. Only the bottom and its corners
/// resize: 10.2 resized from the corner grip, and a side band would take the
/// right 6 px of every scrollbar (P9.4).
pub fn chrome_hit(t: &ThemeTokens, l: &ChromeLayout, x: f64, y: f64) -> ChromeHit {
    let (corner, band) = (t.chrome_resize_corner, t.chrome_resize_band);
    let corner_band = y >= l.height - corner;
    if corner_band && x >= l.width - corner {
        return ChromeHit::Resize(ChromeEdge::BottomRight);
    }
    if corner_band && x <= corner {
        return ChromeHit::Resize(ChromeEdge::BottomLeft);
    }
    if y >= l.height - band {
        return ChromeHit::Resize(ChromeEdge::Bottom);
    }
    if y < l.title_bar.h {
        return l.gadgets.iter().find(|g| contains(g.rect, x, y)).map_or(ChromeHit::Title, |g| ChromeHit::Gadget(g.gadget));
    }
    ChromeHit::Content
}
