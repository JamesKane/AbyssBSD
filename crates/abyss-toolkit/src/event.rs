// SPDX-License-Identifier: BSD-2-Clause

//! Input events into the toolkit, and UI events out of it
//! (`docs/design/toolkit.md` §8).

use abyss_render::Point;

use crate::tree::ViewId;

/// An input event delivered to the toolkit. Keyboard events join this set
/// when a widget needs them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum InputEvent {
    /// A pointer button was pressed at `(x, y)`.
    PointerDown { x: f32, y: f32 },
    /// A pointer button was released at `(x, y)`.
    PointerUp { x: f32, y: f32 },
    /// The pointer moved to `(x, y)`.
    PointerMove { x: f32, y: f32 },
}

impl InputEvent {
    /// The event's location.
    #[must_use]
    pub fn point(self) -> Point {
        match self {
            InputEvent::PointerDown { x, y }
            | InputEvent::PointerUp { x, y }
            | InputEvent::PointerMove { x, y } => Point::new(x, y),
        }
    }
}

/// An event a widget emits in response to input — a *value*, never a
/// stored callback (`docs/design/toolkit.md` §8). The widget set grows
/// this enum as new widgets need new events.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UiEvent {
    /// The [`Button`](crate::Button) with this id was clicked.
    Clicked(ViewId),
}
