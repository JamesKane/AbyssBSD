//! The render-backend seam (`docs/design/toolkit.md` §3.2).

use crate::geometry::{Point, Rect};
use crate::paint::{FillRule, Paint};

/// A device that rasterizes filled polygons — the seam between the
/// [`Canvas`](crate::Canvas) API and a concrete renderer (the CPU backend
/// now, a GLES backend at Phase 6).
pub trait RenderBackend {
    /// The target's pixel dimensions, `(width, height)`.
    fn dimensions(&self) -> (u32, u32);

    /// Fill `polygons` — device-space contours, one `Vec` each — under
    /// `paint`, by winding `rule`, restricted to the `clip` rectangle.
    fn fill(&mut self, polygons: &[Vec<Point>], rule: FillRule, paint: &Paint, clip: Rect);
}
