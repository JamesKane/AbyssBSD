// SPDX-License-Identifier: BSD-2-Clause

//! Shared identifiers and geometry primitives.
//!
//! [`Rect`] is **output-logical pixels** (`docs/interfaces/display.md` —
//! `Rect`'s coordinate space). It is integer-valued: a window's geometry
//! is a count of pixels on the display, not a sub-pixel quantity.
//! `abyss-render`'s float-valued `Rect` is a different concept and is not
//! reused here.

/// A top-level surface the WM model manages.
///
/// Corresponds to a display-protocol `SurfaceId` whose role is `toplevel`
/// (`docs/interfaces/display.md`). The layout engine treats it as opaque.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct WindowId(pub u32);

/// A container in the tiling tree.
///
/// Assigned by [`TilingTree`](crate::TilingTree) when a container is
/// created. The engine treats it as opaque — it appears in
/// [`Header`](crate::Header) so the compositor can correlate a header
/// rect with its container across relayouts.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ContainerId(pub u32);

/// An axis-aligned rectangle in output-logical pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, width: i32, height: i32) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }
}

/// Directional input — focus/move (`docs/design/window-management.md` §5).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

/// A split container's axis (`docs/design/window-management.md` §5).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Orientation {
    Horizontal,
    Vertical,
}

/// A container edge — the side a resize gesture adjusts
/// (`docs/design/window-management.md` §5).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}
