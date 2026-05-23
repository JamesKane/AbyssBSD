// SPDX-License-Identifier: BSD-2-Clause

//! The tiling tree — the data the engine lays out
//! (`docs/design/window-management.md` §5).
//!
//! A workspace's tiling layout is a tree of leaves and containers.
//! [`TilingTree`] owns the root and assigns container ids.
//!
//! Two surface-lifecycle operations live here — [`TilingTree::insert`]
//! and [`TilingTree::remove`] — the minimum the WM core needs to drive
//! layout from `on_surface_added` / `on_surface_destroyed`
//! (`window-management.md` §2.1). The user-action operations
//! (`focus_move`, `split`, `set_layout`, `move_leaf`, `resize`) are a
//! follow-up increment.

use crate::types::{ContainerId, WindowId};

/// A container's layout shape — `docs/design/window-management.md` §5.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContainerLayout {
    /// Children laid side by side, left to right; ratios used.
    SplitH,
    /// Children laid top to bottom; ratios used.
    SplitV,
    /// Children overlaid; one focused, the rest in a tab header.
    Tabbed,
    /// Children overlaid; one focused, the rest in a title stack.
    Stacked,
}

/// A node in the tiling tree — a window leaf, or a container.
#[derive(Clone, Debug, PartialEq)]
pub enum TilingNode {
    Leaf(WindowId),
    Container(Container),
}

/// An internal node — a layout container with children.
#[derive(Clone, Debug, PartialEq)]
pub struct Container {
    pub id: ContainerId,
    pub layout: ContainerLayout,
    /// Declaration order is visual order: children of a `SplitH`
    /// container appear left to right in this order.
    pub children: Vec<Child>,
    /// Index into `children` — the visible child of a `Tabbed` /
    /// `Stacked` container, and the insertion target for new windows
    /// ([`TilingTree::insert`]).
    pub focused: usize,
}

/// A container's child slot — a node plus its split ratio.
#[derive(Clone, Debug, PartialEq)]
pub struct Child {
    pub node: TilingNode,
    /// Fraction of the parent's extent this child occupies. Meaningful
    /// only for `SplitH` / `SplitV` parents; ignored by `Tabbed` /
    /// `Stacked`. Ratios within a split container should sum to 1; the
    /// engine renormalizes defensively if they don't.
    pub ratio: f32,
}

/// The workspace's tiling tree — the root, plus the bookkeeping needed
/// to assign fresh [`ContainerId`]s as containers come into being.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TilingTree {
    pub root: Option<TilingNode>,
    next_container_id: u32,
}

impl TilingTree {
    pub fn new() -> Self {
        Self::default()
    }

    /// Construct a tree from an explicit root node, with a container-id
    /// counter seeded above the highest id the tree already uses. The
    /// WM core needs this for deserialization and for the user-action
    /// operations that build sub-trees (`split`, `set_layout` —
    /// follow-up increment).
    pub fn from_root(root: TilingNode) -> Self {
        let max_id = max_container_id(&root).unwrap_or(0);
        Self {
            root: Some(root),
            next_container_id: max_id,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.root.is_none()
    }

    /// Mint the next container id. Monotonic per tree — ids are not
    /// reused.
    fn next_id(&mut self) -> ContainerId {
        self.next_container_id += 1;
        ContainerId(self.next_container_id)
    }

    /// Insert a window into the tree.
    ///
    /// The placement rule (`docs/design/window-management.md` §5, "New
    /// windows"): the new window becomes a sibling of the focused leaf,
    /// in the focused leaf's container, and itself becomes the focused
    /// child. If the tree is empty, the new window becomes the root
    /// leaf. If the root is a bare leaf, a `SplitH` container is
    /// created wrapping the existing leaf and the new one.
    pub fn insert(&mut self, window: WindowId) {
        match self.root.take() {
            None => self.root = Some(TilingNode::Leaf(window)),
            Some(TilingNode::Leaf(existing)) => {
                let id = self.next_id();
                self.root = Some(TilingNode::Container(Container {
                    id,
                    layout: ContainerLayout::SplitH,
                    children: vec![
                        Child {
                            node: TilingNode::Leaf(existing),
                            ratio: 0.5,
                        },
                        Child {
                            node: TilingNode::Leaf(window),
                            ratio: 0.5,
                        },
                    ],
                    focused: 1,
                }));
            }
            Some(TilingNode::Container(mut c)) => {
                insert_in_container(&mut c, window);
                self.root = Some(TilingNode::Container(c));
            }
        }
    }

    /// Remove a window from the tree.
    ///
    /// Returns `true` iff `window` was found. After removal: if a
    /// container has been left with one child, it is **flattened** into
    /// its parent (the child replaces the container in the parent's
    /// slot); if a container has been left with no children, it is
    /// removed; if the root container has been left with one child, the
    /// root becomes that child directly. Split ratios are renormalized.
    pub fn remove(&mut self, window: WindowId) -> bool {
        let (new_root, removed) = match self.root.take() {
            None => (None, false),
            Some(TilingNode::Leaf(w)) if w == window => (None, true),
            Some(TilingNode::Leaf(w)) => (Some(TilingNode::Leaf(w)), false),
            Some(TilingNode::Container(mut c)) => {
                let removed = remove_from_container(&mut c, window);
                let collapsed = collapse(TilingNode::Container(c));
                (collapsed, removed)
            }
        };
        self.root = new_root;
        removed
    }
}

/// Insert `window` next to the focused leaf inside `c`, recursing
/// through `children[focused]` until a leaf is reached.
fn insert_in_container(c: &mut Container, window: WindowId) {
    let f = c.focused.min(c.children.len().saturating_sub(1));
    match &mut c.children[f].node {
        TilingNode::Leaf(_) => {
            // Insert after the focused leaf, in the same container.
            let new_count = c.children.len() + 1;
            let new_ratio = 1.0 / new_count as f32;
            for ch in c.children.iter_mut() {
                ch.ratio = new_ratio;
            }
            c.children.insert(
                f + 1,
                Child {
                    node: TilingNode::Leaf(window),
                    ratio: new_ratio,
                },
            );
            c.focused = f + 1;
        }
        TilingNode::Container(inner) => {
            insert_in_container(inner, window);
        }
    }
}

/// Remove `window` from anywhere under `c`. Returns `true` iff found.
/// Cleans up empty / single-child child containers as it unwinds.
///
/// First pass scans for the hit and decides what post-pass action the
/// slot needs (remove the slot, flatten a single-child inner container,
/// or nothing); a second, borrow-free pass applies it. The two passes
/// keep the mutable borrow on `c.children[i].node` from blocking the
/// `c.children` mutation that follows.
fn remove_from_container(c: &mut Container, window: WindowId) -> bool {
    #[derive(Clone, Copy)]
    enum Action {
        RemoveSlot,
        FlattenSlot,
        None,
    }
    let mut hit: Option<(usize, Action)> = None;
    for i in 0..c.children.len() {
        match &mut c.children[i].node {
            TilingNode::Leaf(w) if *w == window => {
                hit = Some((i, Action::RemoveSlot));
                break;
            }
            TilingNode::Leaf(_) => continue,
            TilingNode::Container(inner) => {
                if remove_from_container(inner, window) {
                    let action = match inner.children.len() {
                        0 => Action::RemoveSlot,
                        1 => Action::FlattenSlot,
                        _ => Action::None,
                    };
                    hit = Some((i, action));
                    break;
                }
            }
        }
    }
    let Some((i, action)) = hit else {
        return false;
    };
    match action {
        Action::RemoveSlot => {
            c.children.remove(i);
            adjust_focus_after_remove(c, i);
            renormalize_ratios(c);
        }
        Action::FlattenSlot => {
            if let TilingNode::Container(inner) = &mut c.children[i].node {
                let only = inner.children.pop().expect("len was 1");
                c.children[i].node = only.node;
            }
        }
        Action::None => {}
    }
    true
}

/// Collapse a node: an empty container becomes `None`; a single-child
/// container becomes its only child's node; everything else is
/// unchanged.
fn collapse(node: TilingNode) -> Option<TilingNode> {
    match node {
        TilingNode::Container(c) if c.children.is_empty() => None,
        TilingNode::Container(mut c) if c.children.len() == 1 => {
            let only = c.children.pop().unwrap();
            Some(only.node)
        }
        n => Some(n),
    }
}

fn adjust_focus_after_remove(c: &mut Container, removed_index: usize) {
    if c.children.is_empty() {
        c.focused = 0;
        return;
    }
    if c.focused >= c.children.len() {
        c.focused = c.children.len() - 1;
    } else if removed_index < c.focused {
        c.focused -= 1;
    }
}

fn max_container_id(node: &TilingNode) -> Option<u32> {
    match node {
        TilingNode::Leaf(_) => None,
        TilingNode::Container(c) => {
            let here = c.id.0;
            let nested = c
                .children
                .iter()
                .filter_map(|ch| max_container_id(&ch.node))
                .max();
            Some(here.max(nested.unwrap_or(0)))
        }
    }
}

fn renormalize_ratios(c: &mut Container) {
    if c.children.is_empty() {
        return;
    }
    let total: f32 = c.children.iter().map(|ch| ch.ratio).sum();
    if total > 0.0 {
        let scale = 1.0 / total;
        for ch in c.children.iter_mut() {
            ch.ratio *= scale;
        }
    } else {
        let r = 1.0 / c.children.len() as f32;
        for ch in c.children.iter_mut() {
            ch.ratio = r;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(n: u32) -> WindowId {
        WindowId(n)
    }

    #[test]
    fn empty_tree_starts_with_no_root() {
        let t = TilingTree::new();
        assert!(t.is_empty());
        assert!(t.root.is_none());
    }

    #[test]
    fn first_insert_becomes_the_root_leaf() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        assert_eq!(t.root, Some(TilingNode::Leaf(w(1))));
    }

    #[test]
    fn second_insert_wraps_the_root_in_a_splith_container() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        match &t.root {
            Some(TilingNode::Container(c)) => {
                assert_eq!(c.layout, ContainerLayout::SplitH);
                assert_eq!(c.children.len(), 2);
                assert_eq!(c.focused, 1);
                assert!((c.children[0].ratio - 0.5).abs() < 1e-6);
                assert!((c.children[1].ratio - 0.5).abs() < 1e-6);
                assert_eq!(c.children[0].node, TilingNode::Leaf(w(1)));
                assert_eq!(c.children[1].node, TilingNode::Leaf(w(2)));
            }
            other => panic!("expected container, got {other:?}"),
        }
    }

    #[test]
    fn third_insert_appends_after_focused_and_renormalizes() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2)); // focused is now child 1 (w(2))
        t.insert(w(3));
        let Some(TilingNode::Container(c)) = &t.root else {
            panic!("not a container");
        };
        assert_eq!(c.children.len(), 3);
        assert_eq!(c.focused, 2);
        assert_eq!(c.children[2].node, TilingNode::Leaf(w(3)));
        for ch in &c.children {
            assert!((ch.ratio - 1.0 / 3.0).abs() < 1e-6, "ratio = {}", ch.ratio);
        }
    }

    #[test]
    fn remove_the_only_leaf_empties_the_tree() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        assert!(t.remove(w(1)));
        assert!(t.is_empty());
    }

    #[test]
    fn remove_missing_window_returns_false() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        assert!(!t.remove(w(99)));
        assert_eq!(t.root, Some(TilingNode::Leaf(w(1))));
    }

    #[test]
    fn removing_to_one_child_flattens_the_container() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        assert!(t.remove(w(2)));
        // Root should collapse from a 2-child container back to a bare leaf.
        assert_eq!(t.root, Some(TilingNode::Leaf(w(1))));
    }

    #[test]
    fn remove_renormalizes_remaining_ratios() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        t.insert(w(3));
        t.insert(w(4)); // four children, each 0.25
        assert!(t.remove(w(2)));
        let Some(TilingNode::Container(c)) = &t.root else {
            panic!("not a container");
        };
        assert_eq!(c.children.len(), 3);
        let sum: f32 = c.children.iter().map(|ch| ch.ratio).sum();
        assert!((sum - 1.0).abs() < 1e-6, "ratios sum to {sum}");
    }

    #[test]
    fn remove_adjusts_focused_index() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        t.insert(w(3)); // focused = 2
        assert!(t.remove(w(1))); // removing before focused shifts it down
        let Some(TilingNode::Container(c)) = &t.root else {
            panic!("not a container");
        };
        assert_eq!(c.focused, 1, "focused should shift from 2 to 1");
    }
}
