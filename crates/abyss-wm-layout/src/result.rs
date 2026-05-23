// SPDX-License-Identifier: BSD-2-Clause

//! The engine's output — what the WM core consumes
//! (`docs/design/window-management.md` §4).
//!
//! [`DecorationMode`] is named here because it appears on every
//! [`Placement`] the engine produces; it is *also* part of the WM core's
//! `WmEvent::Decorate` variant (§2.1), which a future `abyss-wm-core`
//! crate will re-export from here.

use crate::types::{ContainerId, Rect, WindowId};

/// The full result of one `layout()` call.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LayoutResult {
    /// One placement per **visible** leaf in the tree. Hidden tabs and
    /// stack entries (the non-focused children of a `Tabbed` / `Stacked`
    /// container) appear in [`Self::headers`] but not here — they have
    /// no geometry to render until they become focused.
    pub placements: Vec<Placement>,
    /// One header per `Tabbed` / `Stacked` container in the tree.
    pub headers: Vec<Header>,
}

/// A window's placement — the rectangle the compositor configures the
/// client to and the decoration the compositor draws around it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Placement {
    pub window: WindowId,
    pub rect: Rect,
    pub decoration: DecorationMode,
}

/// A container header — the tab strip or title stack reserved above a
/// `Tabbed` or `Stacked` container's body.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Header {
    pub container: ContainerId,
    pub rect: Rect,
    pub kind: HeaderKind,
    /// One entry per direct **leaf** child, in declaration order. Nested
    /// container children are not listed — they have no single title to
    /// show. (M1 doc note: this can grow later if nested headers prove
    /// useful.)
    pub tabs: Vec<TabEntry>,
}

/// What a `Header` looks like — tabs across the top, or a stack of
/// titles.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeaderKind {
    Tabs,
    Stack,
}

/// A single entry in a header. The compositor looks up the window's
/// title from its own `SetTitle` state — the engine does not carry text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TabEntry {
    pub window: WindowId,
}

/// The decoration the compositor draws around a placed window.
///
/// Set by the engine (the container the window lives in determines it);
/// drawn by the compositor's chrome pass; never crosses the display
/// protocol wire (`docs/interfaces/display.md` — *No decoration on the
/// wire*).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DecorationMode {
    /// A tiled or floating leaf — a thin border.
    LeafBorder,
    /// The body of a `Tabbed` or `Stacked` container — the container's
    /// header is the [`Header`] entry; the body has no border of its own.
    ContainerBody(HeaderKind),
    /// **M3** — the full GNOME-2 title bar on a floating window.
    /// Reserved; not produced by the M1 tiling engine.
    TitleBar,
}
