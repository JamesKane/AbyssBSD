//! The `Widget` trait — the behavior behind a view
//! (`docs/design/toolkit.md` §7).

use std::any::Any;

use abyss_render::{Canvas, Font, GlyphCache, Rect, Size};

use crate::event::{InputEvent, UiEvent};
use crate::theme::Theme;
use crate::tree::ViewId;

/// Context for [`Widget::measure`] — read-only font and theme.
pub struct MeasureCtx<'a> {
    pub font: &'a Font,
    pub theme: &'a Theme,
}

/// Context for [`Widget::paint`] — the theme, font, and the glyph cache
/// (mutable: painting text fills the cache).
pub struct PaintCtx<'a> {
    pub theme: &'a Theme,
    pub font: &'a Font,
    pub cache: &'a mut GlyphCache,
}

/// A widget — the behavior and state behind a view.
///
/// A widget defines how it **measures** (its preferred size), how it
/// **arranges** any children, how it **paints**, and how it **handles
/// input**. It stores no callbacks: input becomes a [`UiEvent`] value (§8).
///
/// `arrange`, `paint`, and `on_input` have leaf-widget defaults, so a
/// simple widget implements only `measure` and `paint`.
pub trait Widget: 'static {
    /// This widget's preferred size, given its children's measured sizes
    /// (empty for a leaf widget).
    fn measure(&self, children: &[Size], ctx: &MeasureCtx<'_>) -> Size;

    /// Rectangles for the children, within `bounds`. One per child; a leaf
    /// widget returns none.
    fn arrange(&self, _bounds: Rect, _children: &[Size]) -> Vec<Rect> {
        Vec::new()
    }

    /// Paint this widget (not its children) into `canvas` within `bounds`.
    fn paint(&self, _bounds: Rect, _canvas: &mut Canvas<'_>, _ctx: &mut PaintCtx<'_>) {}

    /// Handle an input event that hit this widget. `id` is this widget's
    /// view, for stamping into any [`UiEvent`] emitted.
    fn on_input(&mut self, _id: ViewId, _event: &InputEvent, _bounds: Rect) -> Vec<UiEvent> {
        Vec::new()
    }

    /// Upcast for typed widget access ([`ViewTree::widget`]). Every
    /// implementation is the one line `{ self }`.
    ///
    /// [`ViewTree::widget`]: crate::ViewTree::widget
    fn as_any(&self) -> &dyn Any;

    /// Mutable upcast — see [`as_any`](Widget::as_any).
    fn as_any_mut(&mut self) -> &mut dyn Any;
}
