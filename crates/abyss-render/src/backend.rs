//! The render-backend seam (`docs/design/toolkit.md` §3.2).

use crate::color::Color;
use crate::geometry::{Point, Rect};
use crate::paint::{FillRule, Paint};

/// An 8-bit coverage mask to composite at a device position — the
/// rendered form of one glyph (`docs/design/toolkit.md` §3.3).
pub struct CoverageMask<'a> {
    /// Device x of the mask's left edge.
    pub x: i32,
    /// Device y of the mask's top edge.
    pub y: i32,
    /// Mask width in pixels.
    pub width: u32,
    /// Mask height in pixels.
    pub height: u32,
    /// `width * height` coverage bytes, row-major.
    pub data: &'a [u8],
}

/// A device that rasterizes filled polygons and composites coverage masks
/// — the seam between the [`Canvas`](crate::Canvas) API and a concrete
/// renderer (the CPU backend now, a GLES backend at Phase 6).
pub trait RenderBackend {
    /// The target's pixel dimensions, `(width, height)`.
    fn dimensions(&self) -> (u32, u32);

    /// Fill `polygons` — device-space contours, one `Vec` each — under
    /// `paint`, by winding `rule`, restricted to the `clip` rectangle.
    fn fill(&mut self, polygons: &[Vec<Point>], rule: FillRule, paint: &Paint, clip: Rect);

    /// Composite `mask`, colored with `color`, restricted to `clip`.
    fn blit_coverage(&mut self, mask: &CoverageMask<'_>, color: Color, clip: Rect);
}
