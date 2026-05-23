// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD window-manager tiling layout — pure geometry.
//!
//! Implements the **layout-policy seam** of `docs/design/window-management.md`
//! §4: the [`LayoutEngine`] trait the WM core calls per workspace per
//! relayout, and the default [`TilingLayoutEngine`] that satisfies it
//! Sway/i3-style. Tree types ([`TilingTree`], [`TilingNode`], [`Container`])
//! and the basic surface-lifecycle mutations ([`TilingTree::insert`] /
//! [`TilingTree::remove`]) from §5 also live here — they are the smallest
//! mutation set the WM core needs to drive layout from `on_surface_added`
//! and `on_surface_destroyed` (§2.1).
//!
//! User-action mutations — `focus_move`, `split`, `set_layout`,
//! `move_leaf`, `resize` — are a follow-up increment.
//!
//! Pure Rust, no FreeBSD: this crate is host-built and host-tested
//! alongside `abyss-msg`, `abyss-render`, and `abyss-toolkit`. It is the
//! first piece of Phase 5 code, landing before the FreeBSD
//! `abyss-compositor` crate exists (`docs/ROADMAP.md` §5).

#![forbid(unsafe_code)]

mod engine;
mod result;
mod tree;
mod types;

pub use engine::{LayoutEngine, TilingLayoutEngine};
pub use result::{DecorationMode, Header, HeaderKind, LayoutResult, Placement, TabEntry};
pub use tree::{Child, Container, ContainerLayout, TilingNode, TilingTree};
pub use types::{ContainerId, Direction, Edge, Orientation, Rect, WindowId};
