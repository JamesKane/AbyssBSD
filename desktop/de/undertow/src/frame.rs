//! Server-side frames' arithmetic (Decorations.swift, P9.6), and which
//! cursor a frame's edge shows (Seat.swift, BACKLOG U.7).
//!
//! Everything must agree about where the frame is (placement, hit-test,
//! the move grab, the snap rectangle): two functions that disagreed by a
//! pixel would be a title bar you can see and cannot click. The title bar's
//! height and the border are the theme's, so a re-skin reaches the window
//! frames without a second implementation; until the theme is in Rust
//! they are handed in.

/// WLR_EDGE_* values.
pub const EDGE_TOP: u32 = 1;
pub const EDGE_BOTTOM: u32 = 2;
pub const EDGE_LEFT: u32 = 4;
pub const EDGE_RIGHT: u32 = 8;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FrameMetrics {
    /// The Aqua title bar, from the toolkit's theme.
    pub title_height: f64,
    /// The border on the other three sides (`chrome.border`).
    pub border: f64,
}

impl FrameMetrics {
    /// The frame's rectangle (x, y, w, h), given where the surface sits.
    pub fn frame(&self, x: i32, y: i32, width: i32, height: i32) -> (i32, i32, i32, i32) {
        let (t, b) = (self.title_height as i32, self.border as i32);
        (x - b, y - t, width + 2 * b, height + t + b)
    }

    /// Where a surface sits, given where its frame goes: the inverse, and
    /// the direction placement needs.
    pub fn surface(&self, x: i32, y: i32) -> (i32, i32) {
        (x + self.border as i32, y + self.title_height as i32)
    }
}

/// What a point on a server-side frame is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameHit {
    Close,
    Minimize,
    Zoom,
    Depth,
    Title,
    /// The edges it sizes, as WLR_EDGE_* bits.
    Resize(u32),
    Body,
}

/// The cursor a frame part shows: the edges that size have their arrows.
pub fn cursor_name(hit: FrameHit) -> &'static str {
    let FrameHit::Resize(edges) = hit else { return "default" };
    match (edges & EDGE_BOTTOM != 0, edges & EDGE_LEFT != 0, edges & EDGE_RIGHT != 0) {
        (true, true, _) => "nesw-resize",
        (true, _, true) => "nwse-resize",
        (true, _, _) => "ns-resize",
        _ => "ew-resize",
    }
}

/// Where a popup's surface goes (Popups.swift): its parent's surface
/// origin, plus the parent's window geometry offset (a client-side shadow),
/// plus the position the positioner gave, less the popup's own geometry
/// offset.
pub fn popup_origin(parent_surface: (i32, i32), parent_geometry: (i32, i32), popup_position: (i32, i32), popup_geometry: (i32, i32)) -> (i32, i32) {
    (
        parent_surface.0 + parent_geometry.0 + popup_position.0 - popup_geometry.0,
        parent_surface.1 + parent_geometry.1 + popup_position.1 - popup_geometry.1,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const M: FrameMetrics = FrameMetrics { title_height: 22.0, border: 1.0 };

    #[test]
    fn the_frame_and_the_surface_are_inverses_of_each_other() {
        let (fx, fy, _, _) = M.frame(100, 200, 400, 300);
        assert_eq!(M.surface(fx, fy), (100, 200));
    }

    #[test]
    fn the_frame_is_taller_by_a_title_bar_and_wider_by_its_borders() {
        let (x, y, w, h) = M.frame(0, 0, 400, 300);
        assert_eq!((w, h), (400 + 2, 300 + 22 + 1));
        assert_eq!((x, y), (-1, -22), "it starts above and to the left of the surface it wraps");
    }

    /// U.7: the frame's own edges show sizing arrows.
    #[test]
    fn the_frames_sizing_edges_have_their_arrows() {
        assert_eq!(cursor_name(FrameHit::Resize(EDGE_BOTTOM)), "ns-resize");
        assert_eq!(cursor_name(FrameHit::Resize(EDGE_BOTTOM | EDGE_RIGHT)), "nwse-resize");
        assert_eq!(cursor_name(FrameHit::Resize(EDGE_BOTTOM | EDGE_LEFT)), "nesw-resize");
        assert_eq!(cursor_name(FrameHit::Title), "default");
        assert_eq!(cursor_name(FrameHit::Close), "default");
    }

    #[test]
    fn a_popup_lands_where_its_parents_geometry_says() {
        // A layer surface: no geometry offset. The bar's File menu at x=94.
        assert_eq!(popup_origin((0, 0), (0, 0), (94, 22), (0, 0)), (94, 22));
        // A window at (140,100) with a 10px client shadow, and a popup with
        // a 4px shadow of its own.
        assert_eq!(popup_origin((140, 100), (10, 10), (30, 40), (4, 4)), (140 + 10 + 30 - 4, 100 + 10 + 40 - 4));
    }
}
