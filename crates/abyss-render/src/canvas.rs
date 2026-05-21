//! The `Canvas` — a NanoVG-style immediate 2D drawing API
//! (`docs/design/toolkit.md` §3.1).
//!
//! The canvas retains no scene: each call flattens, transforms, and hands
//! device-space geometry to the [`RenderBackend`]. Retention is the
//! toolkit's view tree.

use abyss_font::Font;

use crate::backend::{CoverageMask, RenderBackend};
use crate::color::Color;
use crate::geometry::{Point, Rect, Transform};
use crate::paint::{FillRule, Paint};
use crate::path::Path;
use crate::text::GlyphCache;

/// Device-space error budget for curve flattening, in pixels.
const FLATTEN_TOLERANCE: f32 = 0.2;

#[derive(Clone, Copy)]
struct State {
    transform: Transform,
    clip: Rect,
}

/// A 2D drawing surface over a [`RenderBackend`].
pub struct Canvas<'a> {
    backend: &'a mut dyn RenderBackend,
    state: State,
    saved: Vec<State>,
}

impl<'a> Canvas<'a> {
    /// A canvas drawing to `backend`, the clip set to the full target.
    pub fn new(backend: &'a mut dyn RenderBackend) -> Canvas<'a> {
        let (w, h) = backend.dimensions();
        Canvas {
            backend,
            state: State {
                transform: Transform::IDENTITY,
                clip: Rect::new(0.0, 0.0, w as f32, h as f32),
            },
            saved: Vec::new(),
        }
    }

    /// Push the current transform and clip onto the state stack.
    pub fn save(&mut self) {
        self.saved.push(self.state);
    }

    /// Pop the state stack, restoring the transform and clip. A `restore`
    /// with nothing saved is a no-op.
    pub fn restore(&mut self) {
        if let Some(state) = self.saved.pop() {
            self.state = state;
        }
    }

    /// Translate the coordinate system.
    pub fn translate(&mut self, dx: f32, dy: f32) {
        self.state.transform = self.state.transform.concat(&Transform::translation(dx, dy));
    }

    /// Scale the coordinate system.
    pub fn scale(&mut self, sx: f32, sy: f32) {
        self.state.transform = self.state.transform.concat(&Transform::scaling(sx, sy));
    }

    /// Apply an arbitrary transform to the coordinate system.
    pub fn transform(&mut self, t: &Transform) {
        self.state.transform = self.state.transform.concat(t);
    }

    /// Intersect the clip with `rect` (in the current coordinate space).
    /// For a rotated transform the clip becomes the rect's bounding box.
    pub fn clip_rect(&mut self, rect: Rect) {
        let device = device_bounds(&self.state.transform, rect);
        self.state.clip = self.state.clip.intersect(&device);
    }

    /// Fill `path` with `paint` under the given winding rule.
    pub fn fill(&mut self, path: &Path, paint: &Paint, rule: FillRule) {
        if self.state.clip.is_empty() {
            return;
        }
        let scale = self.state.transform.scale_factor().max(1e-3);
        let contours = path.flatten(FLATTEN_TOLERANCE / scale);
        let device: Vec<Vec<Point>> = contours
            .into_iter()
            .map(|contour| {
                contour
                    .into_iter()
                    .map(|p| self.state.transform.apply(p))
                    .collect()
            })
            .collect();
        let device_paint = paint.transformed(&self.state.transform);
        self.backend
            .fill(&device, rule, &device_paint, self.state.clip);
    }

    /// Fill a rectangle — a non-zero fill of [`Path::rect`].
    pub fn fill_rect(&mut self, rect: Rect, paint: &Paint) {
        self.fill(&Path::rect(rect), paint, FillRule::NonZero);
    }

    /// Draw `text` in `color`, with the text baseline starting at `origin`.
    ///
    /// `cache` is the glyph cache paired with `font` (one cache per font).
    /// Glyph masks are blitted at integer device pixels; the canvas
    /// transform's translation places them, but a scaling transform does
    /// not scale the text — it stays at `size_px` (re-rasterizing at the
    /// device scale is a later refinement, `docs/design/toolkit.md` §3.3).
    pub fn text(
        &mut self,
        origin: Point,
        text: &str,
        font: &Font,
        size_px: f32,
        color: Color,
        cache: &mut GlyphCache,
    ) {
        if self.state.clip.is_empty() {
            return;
        }
        let device = self.state.transform.apply(origin);
        let mut pen_x = device.x;
        for shaped in font.shape(text, size_px) {
            let glyph = cache.entry(font, shaped.glyph, size_px);
            if glyph.width > 0 && glyph.height > 0 {
                let mask = CoverageMask {
                    x: (pen_x + shaped.x_offset + glyph.left as f32).round() as i32,
                    y: (device.y - shaped.y_offset - glyph.top as f32).round() as i32,
                    width: glyph.width,
                    height: glyph.height,
                    data: &glyph.coverage,
                };
                self.backend.blit_coverage(&mask, color, self.state.clip);
            }
            pen_x += shaped.x_advance;
        }
    }
}

/// The axis-aligned device-space bounds of `rect` under `t`.
fn device_bounds(t: &Transform, rect: Rect) -> Rect {
    let corners = [
        t.apply(Point::new(rect.x, rect.y)),
        t.apply(Point::new(rect.right(), rect.y)),
        t.apply(Point::new(rect.x, rect.bottom())),
        t.apply(Point::new(rect.right(), rect.bottom())),
    ];
    let min_x = corners.iter().map(|p| p.x).fold(f32::MAX, f32::min);
    let min_y = corners.iter().map(|p| p.y).fold(f32::MAX, f32::min);
    let max_x = corners.iter().map(|p| p.x).fold(f32::MIN, f32::max);
    let max_y = corners.iter().map(|p| p.y).fold(f32::MIN, f32::max);
    Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
}
