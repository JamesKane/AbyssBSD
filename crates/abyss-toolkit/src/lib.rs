//! AbyssBSD Interface Kit — the retained view tree, layout, and widgets.
//!
//! Implements `docs/design/toolkit.md` §4–§10: the view arena and
//! generational [`ViewId`]; the retained tree; the two-pass box layout;
//! the curated widget set; input routing and [`UiEvent`]s; the [`Theme`];
//! and damage tracking.
//!
//! The toolkit is a *library* over a [`ViewTree`] — the arena, layout,
//! widgets, and painting are ordinary functions, which is what makes them
//! host-testable. Binding a tree to a looper handler is a thin later
//! layer (§11).

#![forbid(unsafe_code)]

mod event;
mod theme;
mod tree;
mod widget;
mod widgets;

pub use abyss_render::{Canvas, Color, CpuBackend, Font, GlyphCache, Pixmap, Point, Rect, Size};
pub use event::{InputEvent, UiEvent};
pub use theme::Theme;
pub use tree::{ViewId, ViewTree};
pub use widget::{MeasureCtx, PaintCtx, Widget};
pub use widgets::{Axis, Button, Label, Linear};
