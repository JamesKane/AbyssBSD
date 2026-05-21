//! 2D paths — a command list, flattened to polyline contours for the
//! rasterizer.

use crate::geometry::{Point, Rect};

/// The cubic-Bézier control-point factor for a quarter-circle arc.
const KAPPA: f32 = 0.552_284_8;

/// Cap on flattening recursion depth — a guard against degenerate input.
const MAX_DEPTH: u32 = 16;

#[derive(Debug, Clone)]
enum Cmd {
    Move(Point),
    Line(Point),
    Quad(Point, Point),
    Cubic(Point, Point, Point),
    Close,
}

/// A 2D path: a list of move/line/curve/close commands.
#[derive(Debug, Clone, Default)]
pub struct Path {
    cmds: Vec<Cmd>,
}

impl Path {
    #[must_use]
    pub fn new() -> Path {
        Path::default()
    }

    pub fn move_to(&mut self, p: Point) -> &mut Self {
        self.cmds.push(Cmd::Move(p));
        self
    }

    pub fn line_to(&mut self, p: Point) -> &mut Self {
        self.cmds.push(Cmd::Line(p));
        self
    }

    pub fn quad_to(&mut self, ctrl: Point, end: Point) -> &mut Self {
        self.cmds.push(Cmd::Quad(ctrl, end));
        self
    }

    pub fn cubic_to(&mut self, c1: Point, c2: Point, end: Point) -> &mut Self {
        self.cmds.push(Cmd::Cubic(c1, c2, end));
        self
    }

    pub fn close(&mut self) -> &mut Self {
        self.cmds.push(Cmd::Close);
        self
    }

    /// A rectangle, wound clockwise.
    #[must_use]
    pub fn rect(r: Rect) -> Path {
        let mut p = Path::new();
        p.move_to(Point::new(r.x, r.y))
            .line_to(Point::new(r.right(), r.y))
            .line_to(Point::new(r.right(), r.bottom()))
            .line_to(Point::new(r.x, r.bottom()))
            .close();
        p
    }

    /// A rectangle with rounded corners; `radius` is clamped to half the
    /// shorter side.
    #[must_use]
    pub fn rounded_rect(r: Rect, radius: f32) -> Path {
        let radius = radius.clamp(0.0, (r.w.min(r.h)) / 2.0);
        if radius <= 0.0 {
            return Path::rect(r);
        }
        let k = radius * KAPPA;
        let (l, t, ri, bo) = (r.x, r.y, r.right(), r.bottom());
        let mut p = Path::new();
        p.move_to(Point::new(l + radius, t))
            .line_to(Point::new(ri - radius, t))
            .cubic_to(
                Point::new(ri - radius + k, t),
                Point::new(ri, t + radius - k),
                Point::new(ri, t + radius),
            )
            .line_to(Point::new(ri, bo - radius))
            .cubic_to(
                Point::new(ri, bo - radius + k),
                Point::new(ri - radius + k, bo),
                Point::new(ri - radius, bo),
            )
            .line_to(Point::new(l + radius, bo))
            .cubic_to(
                Point::new(l + radius - k, bo),
                Point::new(l, bo - radius + k),
                Point::new(l, bo - radius),
            )
            .line_to(Point::new(l, t + radius))
            .cubic_to(
                Point::new(l, t + radius - k),
                Point::new(l + radius - k, t),
                Point::new(l + radius, t),
            )
            .close();
        p
    }

    /// An ellipse centered at `center` with the given radii.
    #[must_use]
    pub fn ellipse(center: Point, rx: f32, ry: f32) -> Path {
        let (cx, cy) = (center.x, center.y);
        let (kx, ky) = (rx * KAPPA, ry * KAPPA);
        let mut p = Path::new();
        p.move_to(Point::new(cx + rx, cy))
            .cubic_to(
                Point::new(cx + rx, cy + ky),
                Point::new(cx + kx, cy + ry),
                Point::new(cx, cy + ry),
            )
            .cubic_to(
                Point::new(cx - kx, cy + ry),
                Point::new(cx - rx, cy + ky),
                Point::new(cx - rx, cy),
            )
            .cubic_to(
                Point::new(cx - rx, cy - ky),
                Point::new(cx - kx, cy - ry),
                Point::new(cx, cy - ry),
            )
            .cubic_to(
                Point::new(cx + kx, cy - ry),
                Point::new(cx + rx, cy - ky),
                Point::new(cx + rx, cy),
            )
            .close();
        p
    }

    /// Flatten to closed contours of line segments. Curves are subdivided
    /// until no point deviates from the true curve by more than `tol`.
    #[must_use]
    pub fn flatten(&self, tol: f32) -> Vec<Vec<Point>> {
        let tol = tol.max(1e-4);
        let mut contours: Vec<Vec<Point>> = Vec::new();
        let mut current: Vec<Point> = Vec::new();
        let mut pos = Point::new(0.0, 0.0);
        let mut start = Point::new(0.0, 0.0);

        let finish = |current: &mut Vec<Point>, contours: &mut Vec<Vec<Point>>| {
            if current.len() >= 2 {
                contours.push(std::mem::take(current));
            } else {
                current.clear();
            }
        };

        for cmd in &self.cmds {
            match *cmd {
                Cmd::Move(p) => {
                    finish(&mut current, &mut contours);
                    current.push(p);
                    pos = p;
                    start = p;
                }
                Cmd::Line(p) => {
                    current.push(p);
                    pos = p;
                }
                Cmd::Quad(ctrl, end) => {
                    flatten_quad(pos, ctrl, end, tol, 0, &mut current);
                    pos = end;
                }
                Cmd::Cubic(c1, c2, end) => {
                    flatten_cubic(pos, c1, c2, end, tol, 0, &mut current);
                    pos = end;
                }
                Cmd::Close => {
                    finish(&mut current, &mut contours);
                    pos = start;
                }
            }
        }
        finish(&mut current, &mut contours);
        contours
    }
}

fn midpoint(a: Point, b: Point) -> Point {
    Point::new((a.x + b.x) * 0.5, (a.y + b.y) * 0.5)
}

/// Perpendicular distance from `p` to the line through `a` and `b`.
fn line_distance(p: Point, a: Point, b: Point) -> f32 {
    let dx = b.x - a.x;
    let dy = b.y - a.y;
    let len = (dx * dx + dy * dy).sqrt();
    if len <= f32::EPSILON {
        let (ex, ey) = (p.x - a.x, p.y - a.y);
        return (ex * ex + ey * ey).sqrt();
    }
    ((p.x - a.x) * dy - (p.y - a.y) * dx).abs() / len
}

fn flatten_quad(p0: Point, ctrl: Point, p2: Point, tol: f32, depth: u32, out: &mut Vec<Point>) {
    if depth >= MAX_DEPTH || line_distance(ctrl, p0, p2) <= tol {
        out.push(p2);
        return;
    }
    let p01 = midpoint(p0, ctrl);
    let p12 = midpoint(ctrl, p2);
    let mid = midpoint(p01, p12);
    flatten_quad(p0, p01, mid, tol, depth + 1, out);
    flatten_quad(mid, p12, p2, tol, depth + 1, out);
}

fn flatten_cubic(
    p0: Point,
    c1: Point,
    c2: Point,
    p3: Point,
    tol: f32,
    depth: u32,
    out: &mut Vec<Point>,
) {
    let flat = line_distance(c1, p0, p3).max(line_distance(c2, p0, p3)) <= tol;
    if depth >= MAX_DEPTH || flat {
        out.push(p3);
        return;
    }
    let p01 = midpoint(p0, c1);
    let p12 = midpoint(c1, c2);
    let p23 = midpoint(c2, p3);
    let p012 = midpoint(p01, p12);
    let p123 = midpoint(p12, p23);
    let mid = midpoint(p012, p123);
    flatten_cubic(p0, p01, p012, mid, tol, depth + 1, out);
    flatten_cubic(mid, p123, p23, p3, tol, depth + 1, out);
}
