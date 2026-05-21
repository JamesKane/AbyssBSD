// SPDX-License-Identifier: BSD-2-Clause

//! 2D points, sizes, rectangles, and affine transforms.

/// A point in 2D space.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Point {
    pub x: f32,
    pub y: f32,
}

impl Point {
    #[must_use]
    pub const fn new(x: f32, y: f32) -> Point {
        Point { x, y }
    }
}

/// A 2D size.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Size {
    pub w: f32,
    pub h: f32,
}

impl Size {
    #[must_use]
    pub const fn new(w: f32, h: f32) -> Size {
        Size { w, h }
    }
}

/// An axis-aligned rectangle, by origin and extent.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rect {
    #[must_use]
    pub const fn new(x: f32, y: f32, w: f32, h: f32) -> Rect {
        Rect { x, y, w, h }
    }

    #[must_use]
    pub fn right(&self) -> f32 {
        self.x + self.w
    }

    #[must_use]
    pub fn bottom(&self) -> f32 {
        self.y + self.h
    }

    /// True if the rectangle has no area.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.w <= 0.0 || self.h <= 0.0
    }

    /// True if `p` lies within the rectangle (origin inclusive).
    #[must_use]
    pub fn contains(&self, p: Point) -> bool {
        p.x >= self.x && p.x < self.right() && p.y >= self.y && p.y < self.bottom()
    }

    /// The overlap of two rectangles — empty if they do not overlap.
    #[must_use]
    pub fn intersect(&self, other: &Rect) -> Rect {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let right = self.right().min(other.right());
        let bottom = self.bottom().min(other.bottom());
        Rect {
            x,
            y,
            w: (right - x).max(0.0),
            h: (bottom - y).max(0.0),
        }
    }
}

/// A 2D affine transform — the matrix `[a c e ; b d f ; 0 0 1]`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Transform {
    pub a: f32,
    pub b: f32,
    pub c: f32,
    pub d: f32,
    pub e: f32,
    pub f: f32,
}

impl Transform {
    pub const IDENTITY: Transform = Transform {
        a: 1.0,
        b: 0.0,
        c: 0.0,
        d: 1.0,
        e: 0.0,
        f: 0.0,
    };

    #[must_use]
    pub const fn translation(tx: f32, ty: f32) -> Transform {
        Transform {
            a: 1.0,
            b: 0.0,
            c: 0.0,
            d: 1.0,
            e: tx,
            f: ty,
        }
    }

    #[must_use]
    pub const fn scaling(sx: f32, sy: f32) -> Transform {
        Transform {
            a: sx,
            b: 0.0,
            c: 0.0,
            d: sy,
            e: 0.0,
            f: 0.0,
        }
    }

    /// `self ∘ inner` — the transform that applies `inner`, then `self`.
    #[must_use]
    pub fn concat(&self, inner: &Transform) -> Transform {
        Transform {
            a: self.a * inner.a + self.c * inner.b,
            b: self.b * inner.a + self.d * inner.b,
            c: self.a * inner.c + self.c * inner.d,
            d: self.b * inner.c + self.d * inner.d,
            e: self.a * inner.e + self.c * inner.f + self.e,
            f: self.b * inner.e + self.d * inner.f + self.f,
        }
    }

    /// Map a point through the transform.
    #[must_use]
    pub fn apply(&self, p: Point) -> Point {
        Point::new(
            self.a * p.x + self.c * p.y + self.e,
            self.b * p.x + self.d * p.y + self.f,
        )
    }

    /// The uniform scale the transform applies — `sqrt(|determinant|)`.
    /// Used to scale curve-flattening tolerance and gradient radii.
    #[must_use]
    pub fn scale_factor(&self) -> f32 {
        (self.a * self.d - self.b * self.c).abs().sqrt()
    }
}
