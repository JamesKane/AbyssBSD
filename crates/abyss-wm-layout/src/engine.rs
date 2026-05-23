// SPDX-License-Identifier: BSD-2-Clause

//! The layout engine — the §4 `LayoutEngine` seam and the default
//! [`TilingLayoutEngine`] that satisfies it.
//!
//! The engine is pure geometry: a tree and a work-area rectangle in, a
//! set of placements and headers out. No surfaces, no I/O, no
//! compositor state.

use crate::result::{DecorationMode, Header, HeaderKind, LayoutResult, Placement, TabEntry};
use crate::tree::{Container, ContainerLayout, TilingNode, TilingTree};
use crate::types::{Orientation, Rect};

/// The layout-policy seam (`docs/design/window-management.md` §4).
pub trait LayoutEngine {
    fn layout(&self, tree: &TilingTree, work_area: Rect) -> LayoutResult;
}

/// The default Sway/i3-style tiling engine
/// (`docs/design/window-management.md` §5).
///
/// Configurable pixel sizes for chrome that the engine reserves:
/// `header_height_px` is the strip a `Tabbed` / `Stacked` container
/// takes off the top of its rect for its header.
#[derive(Clone, Copy, Debug)]
pub struct TilingLayoutEngine {
    pub header_height_px: i32,
}

impl Default for TilingLayoutEngine {
    fn default() -> Self {
        Self {
            header_height_px: 24,
        }
    }
}

impl LayoutEngine for TilingLayoutEngine {
    fn layout(&self, tree: &TilingTree, work_area: Rect) -> LayoutResult {
        let mut out = LayoutResult::default();
        if let Some(node) = &tree.root {
            self.layout_node(node, work_area, &mut out);
        }
        out
    }
}

impl TilingLayoutEngine {
    fn layout_node(&self, node: &TilingNode, rect: Rect, out: &mut LayoutResult) {
        match node {
            TilingNode::Leaf(w) => out.placements.push(Placement {
                window: *w,
                rect,
                decoration: DecorationMode::LeafBorder,
            }),
            TilingNode::Container(c) => match c.layout {
                ContainerLayout::SplitH => {
                    self.layout_split(c, rect, Orientation::Horizontal, out);
                }
                ContainerLayout::SplitV => {
                    self.layout_split(c, rect, Orientation::Vertical, out);
                }
                ContainerLayout::Tabbed => self.layout_overlay(c, rect, HeaderKind::Tabs, out),
                ContainerLayout::Stacked => self.layout_overlay(c, rect, HeaderKind::Stack, out),
            },
        }
    }

    fn layout_split(&self, c: &Container, rect: Rect, orient: Orientation, out: &mut LayoutResult) {
        if c.children.is_empty() {
            return;
        }
        let total: f32 = c.children.iter().map(|ch| ch.ratio).sum();
        let denom = if total > 0.0 {
            total
        } else {
            c.children.len() as f32
        };
        let extent = match orient {
            Orientation::Horizontal => rect.width,
            Orientation::Vertical => rect.height,
        };

        let mut cursor: i32 = 0;
        let last = c.children.len() - 1;
        for (i, child) in c.children.iter().enumerate() {
            // Last child takes whatever's left — avoids rounding losing a pixel column.
            let size = if i == last {
                (extent - cursor).max(0)
            } else {
                let r = if child.ratio > 0.0 {
                    child.ratio / denom
                } else {
                    1.0 / c.children.len() as f32
                };
                let raw = (extent as f32 * r).round() as i32;
                raw.clamp(0, (extent - cursor).max(0))
            };
            let sub_rect = match orient {
                Orientation::Horizontal => Rect::new(rect.x + cursor, rect.y, size, rect.height),
                Orientation::Vertical => Rect::new(rect.x, rect.y + cursor, rect.width, size),
            };
            self.layout_node(&child.node, sub_rect, out);
            cursor += size;
        }
    }

    fn layout_overlay(&self, c: &Container, rect: Rect, kind: HeaderKind, out: &mut LayoutResult) {
        if c.children.is_empty() {
            return;
        }
        let header_h = self.header_height_px.min(rect.height).max(0);
        let header_rect = Rect::new(rect.x, rect.y, rect.width, header_h);
        let body_rect = Rect::new(
            rect.x,
            rect.y + header_h,
            rect.width,
            (rect.height - header_h).max(0),
        );

        // Each direct leaf child contributes a tab; nested containers don't.
        let tabs: Vec<TabEntry> = c
            .children
            .iter()
            .filter_map(|ch| match &ch.node {
                TilingNode::Leaf(w) => Some(TabEntry { window: *w }),
                TilingNode::Container(_) => None,
            })
            .collect();

        out.headers.push(Header {
            container: c.id,
            rect: header_rect,
            kind,
            tabs,
        });

        // Only the focused child is visible; the rest live in the header alone.
        let f = c.focused.min(c.children.len() - 1);
        self.layout_node(&c.children[f].node, body_rect, out);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::{TilingTree, root_container_mut};
    use crate::types::WindowId;

    fn w(n: u32) -> WindowId {
        WindowId(n)
    }

    fn work_area() -> Rect {
        Rect::new(0, 0, 800, 600)
    }

    #[test]
    fn empty_tree_yields_no_placements() {
        let tree = TilingTree::new();
        let res = TilingLayoutEngine::default().layout(&tree, work_area());
        assert!(res.placements.is_empty());
        assert!(res.headers.is_empty());
    }

    #[test]
    fn a_single_window_fills_the_work_area() {
        let mut tree = TilingTree::new();
        tree.insert(w(1));
        let res = TilingLayoutEngine::default().layout(&tree, work_area());
        assert_eq!(res.placements.len(), 1);
        assert_eq!(res.placements[0].window, w(1));
        assert_eq!(res.placements[0].rect, work_area());
        assert_eq!(res.placements[0].decoration, DecorationMode::LeafBorder);
        assert!(res.headers.is_empty());
    }

    #[test]
    fn two_windows_split_horizontally_50_50() {
        let mut tree = TilingTree::new();
        tree.insert(w(1));
        tree.insert(w(2));
        let res = TilingLayoutEngine::default().layout(&tree, work_area());
        assert_eq!(res.placements.len(), 2);
        assert_eq!(res.placements[0].rect, Rect::new(0, 0, 400, 600));
        assert_eq!(res.placements[1].rect, Rect::new(400, 0, 400, 600));
    }

    #[test]
    fn three_windows_split_into_thirds_with_rounding_swept_to_last() {
        let mut tree = TilingTree::new();
        tree.insert(w(1));
        tree.insert(w(2));
        tree.insert(w(3));
        let res = TilingLayoutEngine::default().layout(&tree, work_area());
        assert_eq!(res.placements.len(), 3);
        // The three rects must cover [0, 800) exactly with no gap or overlap.
        let mut cursor = 0;
        for p in &res.placements {
            assert_eq!(p.rect.x, cursor);
            assert_eq!(p.rect.y, 0);
            assert_eq!(p.rect.height, 600);
            cursor += p.rect.width;
        }
        assert_eq!(cursor, 800);
    }

    #[test]
    fn split_v_lays_children_top_to_bottom() {
        let mut tree = TilingTree::new();
        tree.insert(w(1));
        tree.insert(w(2));
        // The user-action API to flip the layout doesn't exist yet on the
        // engine side; reach in directly to flip it.
        root_container_mut(&mut tree).layout = ContainerLayout::SplitV;
        let res = TilingLayoutEngine::default().layout(&tree, work_area());
        assert_eq!(res.placements[0].rect, Rect::new(0, 0, 800, 300));
        assert_eq!(res.placements[1].rect, Rect::new(0, 300, 800, 300));
    }

    #[test]
    fn tabbed_container_emits_a_header_and_one_visible_placement() {
        let mut tree = TilingTree::new();
        tree.insert(w(1));
        tree.insert(w(2));
        tree.insert(w(3));
        let c = root_container_mut(&mut tree);
        c.layout = ContainerLayout::Tabbed;
        c.focused = 1;
        let res = TilingLayoutEngine::default().layout(&tree, work_area());
        assert_eq!(res.headers.len(), 1);
        assert_eq!(res.headers[0].kind, HeaderKind::Tabs);
        assert_eq!(res.headers[0].rect, Rect::new(0, 0, 800, 24));
        assert_eq!(res.headers[0].tabs.len(), 3);
        assert_eq!(res.headers[0].tabs[1].window, w(2));
        assert_eq!(res.placements.len(), 1);
        assert_eq!(res.placements[0].window, w(2));
        assert_eq!(res.placements[0].rect, Rect::new(0, 24, 800, 576));
    }

    #[test]
    fn stacked_container_uses_stack_header_kind() {
        let mut tree = TilingTree::new();
        tree.insert(w(1));
        tree.insert(w(2));
        root_container_mut(&mut tree).layout = ContainerLayout::Stacked;
        let res = TilingLayoutEngine::default().layout(&tree, work_area());
        assert_eq!(res.headers[0].kind, HeaderKind::Stack);
    }

    #[test]
    fn header_height_clamps_to_rect_height() {
        let mut tree = TilingTree::new();
        tree.insert(w(1));
        tree.insert(w(2));
        root_container_mut(&mut tree).layout = ContainerLayout::Tabbed;
        // Very thin work area — the header should clamp, not negative-overflow.
        let res = TilingLayoutEngine::default().layout(&tree, Rect::new(0, 0, 800, 10));
        assert_eq!(res.headers[0].rect.height, 10);
        assert_eq!(res.placements[0].rect.height, 0);
    }

    #[test]
    fn nested_split_inside_split_recurses_into_sub_rect() {
        // Build a tree manually: a SplitH with [Leaf(1), Container(SplitV[Leaf(2), Leaf(3)])].
        use crate::tree::{Child, Container};
        let inner = Container {
            id: crate::types::ContainerId(42),
            layout: ContainerLayout::SplitV,
            children: vec![
                Child {
                    node: TilingNode::Leaf(w(2)),
                    ratio: 0.5,
                },
                Child {
                    node: TilingNode::Leaf(w(3)),
                    ratio: 0.5,
                },
            ],
            focused: 0,
        };
        let outer = Container {
            id: crate::types::ContainerId(1),
            layout: ContainerLayout::SplitH,
            children: vec![
                Child {
                    node: TilingNode::Leaf(w(1)),
                    ratio: 0.5,
                },
                Child {
                    node: TilingNode::Container(inner),
                    ratio: 0.5,
                },
            ],
            focused: 0,
        };
        let tree = TilingTree::from_root(TilingNode::Container(outer));
        let res = TilingLayoutEngine::default().layout(&tree, work_area());
        assert_eq!(res.placements.len(), 3);
        // w(1) on the left half
        assert_eq!(res.placements[0].window, w(1));
        assert_eq!(res.placements[0].rect, Rect::new(0, 0, 400, 600));
        // w(2) and w(3) stacked on the right half
        assert_eq!(res.placements[1].window, w(2));
        assert_eq!(res.placements[1].rect, Rect::new(400, 0, 400, 300));
        assert_eq!(res.placements[2].window, w(3));
        assert_eq!(res.placements[2].rect, Rect::new(400, 300, 400, 300));
    }
}
