// SPDX-License-Identifier: BSD-2-Clause

//! The curated widget set (`docs/design/toolkit.md` §7).
//!
//! `Linear`, `Label`, and `Button` — a container, a display widget, and
//! an interactive one: enough to build and prove a real UI. The remaining
//! §7 widgets are mechanical population on this same `Widget` interface,
//! done as the M3 desktop and M4 apps need them.

use std::any::Any;

use abyss_render::{Canvas, FillRule, Paint, Path, Point, Rect, Size};

use crate::event::{InputEvent, UiEvent};
use crate::tree::ViewId;
use crate::widget::{MeasureCtx, PaintCtx, Widget};

/// The axis a [`Linear`] container lays its children along.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    Horizontal,
    Vertical,
}

/// A container that lays its children out in a line. Each child takes its
/// measured size along the axis and fills the container across it.
/// (Expand / alignment are a later layout refinement, §6.)
pub struct Linear {
    axis: Axis,
    gap: f32,
}

impl Linear {
    /// A vertical container — a column.
    #[must_use]
    pub fn column() -> Linear {
        Linear {
            axis: Axis::Vertical,
            gap: 0.0,
        }
    }

    /// A horizontal container — a row.
    #[must_use]
    pub fn row() -> Linear {
        Linear {
            axis: Axis::Horizontal,
            gap: 0.0,
        }
    }

    /// Set the gap placed between adjacent children.
    #[must_use]
    pub fn with_gap(mut self, gap: f32) -> Linear {
        self.gap = gap;
        self
    }
}

impl Widget for Linear {
    fn measure(&self, children: &[Size], _ctx: &MeasureCtx<'_>) -> Size {
        let total_gap = self.gap * children.len().saturating_sub(1) as f32;
        match self.axis {
            Axis::Vertical => Size::new(
                children.iter().map(|s| s.w).fold(0.0, f32::max),
                children.iter().map(|s| s.h).sum::<f32>() + total_gap,
            ),
            Axis::Horizontal => Size::new(
                children.iter().map(|s| s.w).sum::<f32>() + total_gap,
                children.iter().map(|s| s.h).fold(0.0, f32::max),
            ),
        }
    }

    fn arrange(&self, bounds: Rect, children: &[Size]) -> Vec<Rect> {
        let mut rects = Vec::with_capacity(children.len());
        match self.axis {
            Axis::Vertical => {
                let mut y = bounds.y;
                for child in children {
                    rects.push(Rect::new(bounds.x, y, bounds.w, child.h));
                    y += child.h + self.gap;
                }
            }
            Axis::Horizontal => {
                let mut x = bounds.x;
                for child in children {
                    rects.push(Rect::new(x, bounds.y, child.w, bounds.h));
                    x += child.w + self.gap;
                }
            }
        }
        rects
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}

/// A line of static text.
pub struct Label {
    text: String,
}

impl Label {
    /// A label showing `text`.
    pub fn new(text: impl Into<String>) -> Label {
        Label { text: text.into() }
    }

    /// The label's text.
    #[must_use]
    pub fn text(&self) -> &str {
        &self.text
    }

    /// Replace the label's text.
    pub fn set_text(&mut self, text: impl Into<String>) {
        self.text = text.into();
    }
}

impl Widget for Label {
    fn measure(&self, _children: &[Size], ctx: &MeasureCtx<'_>) -> Size {
        let width = ctx.font.measure(&self.text, ctx.theme.font_size);
        let metrics = ctx.font.metrics(ctx.theme.font_size);
        Size::new(width, metrics.line_height)
    }

    fn paint(&self, bounds: Rect, canvas: &mut Canvas<'_>, ctx: &mut PaintCtx<'_>) {
        let metrics = ctx.font.metrics(ctx.theme.font_size);
        let baseline = Point::new(bounds.x, bounds.y + metrics.ascent);
        canvas.text(
            baseline,
            &self.text,
            ctx.font,
            ctx.theme.font_size,
            ctx.theme.text,
            ctx.cache,
        );
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}

/// A clickable button with a text label. A press inside, then a release
/// inside, emits [`UiEvent::Clicked`].
pub struct Button {
    label: String,
    pressed: bool,
}

impl Button {
    /// A button labelled `label`.
    pub fn new(label: impl Into<String>) -> Button {
        Button {
            label: label.into(),
            pressed: false,
        }
    }

    /// Whether the button is currently held down.
    #[must_use]
    pub fn is_pressed(&self) -> bool {
        self.pressed
    }
}

impl Widget for Button {
    fn measure(&self, _children: &[Size], ctx: &MeasureCtx<'_>) -> Size {
        let text_width = ctx.font.measure(&self.label, ctx.theme.font_size);
        let metrics = ctx.font.metrics(ctx.theme.font_size);
        let pad = ctx.theme.padding * 2.0;
        Size::new(text_width + pad, metrics.line_height + pad)
    }

    fn paint(&self, bounds: Rect, canvas: &mut Canvas<'_>, ctx: &mut PaintCtx<'_>) {
        let face = if self.pressed {
            ctx.theme.surface_active
        } else {
            ctx.theme.surface
        };
        canvas.fill(
            &Path::rounded_rect(bounds, ctx.theme.corner_radius),
            &Paint::solid(face),
            FillRule::NonZero,
        );
        let metrics = ctx.font.metrics(ctx.theme.font_size);
        let baseline = Point::new(
            bounds.x + ctx.theme.padding,
            bounds.y + ctx.theme.padding + metrics.ascent,
        );
        canvas.text(
            baseline,
            &self.label,
            ctx.font,
            ctx.theme.font_size,
            ctx.theme.text,
            ctx.cache,
        );
    }

    fn on_input(&mut self, id: ViewId, event: &InputEvent, bounds: Rect) -> Vec<UiEvent> {
        match event {
            InputEvent::PointerDown { .. } => {
                self.pressed = true;
                Vec::new()
            }
            InputEvent::PointerUp { x, y } => {
                let was_pressed = self.pressed;
                self.pressed = false;
                if was_pressed && bounds.contains(Point::new(*x, *y)) {
                    vec![UiEvent::Clicked(id)]
                } else {
                    Vec::new()
                }
            }
            InputEvent::PointerMove { .. } => Vec::new(),
        }
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}
