//! Paints — solid colors and gradients — and the fill rule.

use crate::color::Color;
use crate::geometry::{Point, Transform};

/// Whether a fill counts winding non-zero or even-odd.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FillRule {
    /// Inside where the winding number is non-zero. Holes are made by an
    /// inner contour wound the opposite way.
    NonZero,
    /// Inside where the winding number is odd.
    EvenOdd,
}

/// One color stop of a gradient. Stops are kept sorted by `offset`.
#[derive(Debug, Clone, Copy)]
pub struct GradientStop {
    pub offset: f32,
    pub color: Color,
}

impl GradientStop {
    #[must_use]
    pub const fn new(offset: f32, color: Color) -> GradientStop {
        GradientStop { offset, color }
    }
}

/// How a region is colored.
#[derive(Debug, Clone)]
pub enum Paint {
    /// One color everywhere.
    Solid(Color),
    /// A linear gradient along the `start`→`end` axis.
    Linear {
        start: Point,
        end: Point,
        stops: Vec<GradientStop>,
    },
    /// A radial gradient from `center` out to `radius`.
    Radial {
        center: Point,
        radius: f32,
        stops: Vec<GradientStop>,
    },
}

impl Paint {
    #[must_use]
    pub fn solid(color: Color) -> Paint {
        Paint::Solid(color)
    }

    /// The paint with its coordinates mapped through `t` — used to carry a
    /// user-space paint into device space.
    #[must_use]
    pub fn transformed(&self, t: &Transform) -> Paint {
        match self {
            Paint::Solid(c) => Paint::Solid(*c),
            Paint::Linear { start, end, stops } => Paint::Linear {
                start: t.apply(*start),
                end: t.apply(*end),
                stops: stops.clone(),
            },
            Paint::Radial {
                center,
                radius,
                stops,
            } => Paint::Radial {
                center: t.apply(*center),
                radius: radius * t.scale_factor(),
                stops: stops.clone(),
            },
        }
    }

    /// The color of the paint at point `p`.
    #[must_use]
    pub fn eval(&self, p: Point) -> Color {
        match self {
            Paint::Solid(c) => *c,
            Paint::Linear { start, end, stops } => {
                let dx = end.x - start.x;
                let dy = end.y - start.y;
                let len2 = dx * dx + dy * dy;
                let t = if len2 <= f32::EPSILON {
                    0.0
                } else {
                    ((p.x - start.x) * dx + (p.y - start.y) * dy) / len2
                };
                sample_stops(stops, t)
            }
            Paint::Radial {
                center,
                radius,
                stops,
            } => {
                let dx = p.x - center.x;
                let dy = p.y - center.y;
                let dist = (dx * dx + dy * dy).sqrt();
                let t = if *radius <= f32::EPSILON {
                    0.0
                } else {
                    dist / radius
                };
                sample_stops(stops, t)
            }
        }
    }
}

/// Sample a sorted stop list at `t` (clamped to `0..=1`).
fn sample_stops(stops: &[GradientStop], t: f32) -> Color {
    let Some(first) = stops.first() else {
        return Color::TRANSPARENT;
    };
    let last = stops[stops.len() - 1];
    let t = t.clamp(0.0, 1.0);
    if t <= first.offset {
        return first.color;
    }
    if t >= last.offset {
        return last.color;
    }
    for pair in stops.windows(2) {
        let (lo, hi) = (pair[0], pair[1]);
        if t >= lo.offset && t <= hi.offset {
            let span = hi.offset - lo.offset;
            let local = if span <= f32::EPSILON {
                0.0
            } else {
                (t - lo.offset) / span
            };
            return lo.color.lerp(hi.color, local);
        }
    }
    last.color
}
