//! The CPU render backend — a software anti-aliased rasterizer.
//!
//! Each pixel row is rasterized analytically in X and 4× supersampled in
//! Y: for each of four sub-scanlines, polygon edges are intersected with
//! the scanline, sorted, and swept by the winding rule; every inside span
//! contributes exact horizontal coverage. Correct and legible; a faster
//! active-edge rasterizer is a later optimization (`DESIGN.md` §3.5).

use crate::backend::{CoverageMask, RenderBackend};
use crate::color::Color;
use crate::geometry::{Point, Rect};
use crate::paint::{FillRule, Paint};
use crate::pixmap::Pixmap;

/// Sub-scanlines sampled per pixel row.
const SUBSAMPLES: usize = 4;

/// A software renderer targeting a [`Pixmap`].
pub struct CpuBackend {
    target: Pixmap,
}

impl CpuBackend {
    /// A backend over a fresh transparent pixmap of the given size.
    #[must_use]
    pub fn new(width: u32, height: u32) -> CpuBackend {
        CpuBackend {
            target: Pixmap::new(width, height),
        }
    }

    /// A backend over an existing pixmap.
    #[must_use]
    pub fn from_pixmap(target: Pixmap) -> CpuBackend {
        CpuBackend { target }
    }

    /// The render target.
    #[must_use]
    pub fn pixmap(&self) -> &Pixmap {
        &self.target
    }

    /// Consume the backend, yielding its render target.
    #[must_use]
    pub fn into_pixmap(self) -> Pixmap {
        self.target
    }
}

/// A non-horizontal polygon edge.
struct Edge {
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
}

impl RenderBackend for CpuBackend {
    fn dimensions(&self) -> (u32, u32) {
        (self.target.width(), self.target.height())
    }

    fn fill(&mut self, polygons: &[Vec<Point>], rule: FillRule, paint: &Paint, clip: Rect) {
        let bounds = Rect::new(
            0.0,
            0.0,
            self.target.width() as f32,
            self.target.height() as f32,
        );
        let clip = clip.intersect(&bounds);
        if clip.is_empty() {
            return;
        }

        // Edge list (horizontal edges drop out) and the polygon bounds.
        let mut edges: Vec<Edge> = Vec::new();
        let mut min_x = f32::MAX;
        let mut min_y = f32::MAX;
        let mut max_x = f32::MIN;
        let mut max_y = f32::MIN;
        for poly in polygons {
            if poly.len() < 2 {
                continue;
            }
            for i in 0..poly.len() {
                let a = poly[i];
                let b = poly[(i + 1) % poly.len()];
                for p in [a, b] {
                    min_x = min_x.min(p.x);
                    min_y = min_y.min(p.y);
                    max_x = max_x.max(p.x);
                    max_y = max_y.max(p.y);
                }
                if (a.y - b.y).abs() > f32::EPSILON {
                    edges.push(Edge {
                        ax: a.x,
                        ay: a.y,
                        bx: b.x,
                        by: b.y,
                    });
                }
            }
        }
        if edges.is_empty() {
            return;
        }

        // Pixel region: polygon bounds ∩ clip, snapped outward.
        let rx0 = min_x.max(clip.x).floor().max(0.0) as i32;
        let ry0 = min_y.max(clip.y).floor().max(0.0) as i32;
        let rx1 = (max_x.min(clip.right())).ceil().min(bounds.w) as i32;
        let ry1 = (max_y.min(clip.bottom())).ceil().min(bounds.h) as i32;
        if rx1 <= rx0 || ry1 <= ry0 {
            return;
        }
        let row_w = (rx1 - rx0) as usize;
        let origin = rx0 as f32;

        let mut cover = vec![0.0_f32; row_w];
        let mut crossings: Vec<(f32, i32)> = Vec::new();

        for py in ry0..ry1 {
            cover.fill(0.0);
            for sub in 0..SUBSAMPLES {
                let sy = py as f32 + (sub as f32 + 0.5) / SUBSAMPLES as f32;
                crossings.clear();
                for e in &edges {
                    let (lo, hi) = if e.ay < e.by {
                        (e.ay, e.by)
                    } else {
                        (e.by, e.ay)
                    };
                    if !(lo..hi).contains(&sy) {
                        continue;
                    }
                    let t = (sy - e.ay) / (e.by - e.ay);
                    let x = e.ax + t * (e.bx - e.ax);
                    let dir = if e.by > e.ay { 1 } else { -1 };
                    crossings.push((x, dir));
                }
                if crossings.len() < 2 {
                    continue;
                }
                crossings.sort_by(|a, b| a.0.total_cmp(&b.0));
                let mut winding = 0;
                for i in 0..crossings.len() - 1 {
                    winding += crossings[i].1;
                    let inside = match rule {
                        FillRule::NonZero => winding != 0,
                        FillRule::EvenOdd => winding % 2 != 0,
                    };
                    if inside {
                        add_span(&mut cover, crossings[i].0, crossings[i + 1].0, origin);
                    }
                }
            }

            for (ix, &raw) in cover.iter().enumerate() {
                let coverage = raw / SUBSAMPLES as f32;
                if coverage <= 0.0 {
                    continue;
                }
                let x = (rx0 + ix as i32) as u32;
                let y = py as u32;
                let center = Point::new(x as f32 + 0.5, y as f32 + 0.5);
                let src = paint.eval(center).scale_alpha(coverage.min(1.0));
                let blended = src.over(self.target.pixel(x, y));
                self.target.set_pixel(x, y, blended);
            }
        }
    }

    fn blit_coverage(&mut self, mask: &CoverageMask<'_>, color: Color, clip: Rect) {
        let bounds = Rect::new(
            0.0,
            0.0,
            self.target.width() as f32,
            self.target.height() as f32,
        );
        let clip = clip.intersect(&bounds);
        let len = mask.width as usize * mask.height as usize;
        if clip.is_empty() || mask.data.len() < len {
            return;
        }
        for row in 0..mask.height {
            let py = mask.y + row as i32;
            if py < 0 {
                continue;
            }
            let py = py as u32;
            if py >= self.target.height() {
                break;
            }
            if !(clip.y..clip.bottom()).contains(&(py as f32 + 0.5)) {
                continue;
            }
            for col in 0..mask.width {
                let px = mask.x + col as i32;
                if px < 0 {
                    continue;
                }
                let px = px as u32;
                if px >= self.target.width() {
                    break;
                }
                if !(clip.x..clip.right()).contains(&(px as f32 + 0.5)) {
                    continue;
                }
                let coverage = mask.data[(row * mask.width + col) as usize];
                if coverage == 0 {
                    continue;
                }
                let src = color.scale_alpha(f32::from(coverage) / 255.0);
                let blended = src.over(self.target.pixel(px, py));
                self.target.set_pixel(px, py, blended);
            }
        }
    }
}

/// Add a filled span's horizontal coverage into the row accumulator.
fn add_span(cover: &mut [f32], span_start: f32, span_end: f32, origin: f32) {
    if span_end <= span_start {
        return;
    }
    let lo = (span_start - origin).floor().max(0.0) as usize;
    let hi = (((span_end - origin).ceil()) as i64).clamp(0, cover.len() as i64) as usize;
    for (px, cell) in cover.iter_mut().enumerate().take(hi).skip(lo) {
        let cell_left = origin + px as f32;
        let left = span_start.max(cell_left);
        let right = span_end.min(cell_left + 1.0);
        if right > left {
            *cell += right - left;
        }
    }
}
