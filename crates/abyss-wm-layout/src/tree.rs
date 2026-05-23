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

use crate::types::{ContainerId, Direction, Edge, Orientation, WindowId};

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

    /// The window currently focused, by walking `children[focused]` from
    /// the root. `None` iff the tree is empty.
    pub fn focused_window(&self) -> Option<WindowId> {
        let mut node = self.root.as_ref()?;
        loop {
            match node {
                TilingNode::Leaf(w) => return Some(*w),
                TilingNode::Container(c) => {
                    if c.children.is_empty() {
                        return None;
                    }
                    let i = c.focused.min(c.children.len() - 1);
                    node = &c.children[i].node;
                }
            }
        }
    }

    /// Move focus in `dir`.
    ///
    /// Walks up from the focused leaf looking for the deepest ancestor
    /// whose layout matches `dir` (SplitH / Tabbed match Left/Right;
    /// SplitV / Stacked match Up/Down) and where a sibling exists in
    /// the direction. The matched ancestor's `focused` index steps; the
    /// new focused leaf is then reached by descending `children[focused]`.
    ///
    /// Returns the new focused window, or `None` if no movement was
    /// possible (the leaf is at the edge of every matching container).
    pub fn focus_move(&mut self, dir: Direction) -> Option<WindowId> {
        let path = focused_path(self)?;
        let (depth, new_index) = find_focus_move_target(self, &path, dir)?;
        if let Some(c) = container_at_mut(self, &path[..depth]) {
            c.focused = new_index;
        }
        self.focused_window()
    }

    /// Wrap the focused leaf in a fresh container of orientation
    /// `orient`. The next [`Self::insert`] will pair the new window
    /// with the focused leaf inside this container — the i3 model.
    ///
    /// A no-op on an empty tree.
    pub fn split(&mut self, orient: Orientation) {
        let layout = match orient {
            Orientation::Horizontal => ContainerLayout::SplitH,
            Orientation::Vertical => ContainerLayout::SplitV,
        };
        let Some(path) = focused_path(self) else {
            return;
        };
        let new_id = self.next_id();
        if path.is_empty() {
            // Root is a bare leaf — wrap it directly.
            let Some(TilingNode::Leaf(w)) = self.root.take() else {
                return;
            };
            self.root = Some(TilingNode::Container(Container {
                id: new_id,
                layout,
                children: vec![Child {
                    node: TilingNode::Leaf(w),
                    ratio: 1.0,
                }],
                focused: 0,
            }));
            return;
        }
        // Walk to the focused leaf's parent and wrap the slot.
        let leaf_index = path[path.len() - 1];
        let Some(parent) = container_at_mut(self, &path[..path.len() - 1]) else {
            return;
        };
        let Some(slot) = parent.children.get_mut(leaf_index) else {
            return;
        };
        let TilingNode::Leaf(w) = slot.node else {
            return;
        };
        slot.node = TilingNode::Container(Container {
            id: new_id,
            layout,
            children: vec![Child {
                node: TilingNode::Leaf(w),
                ratio: 1.0,
            }],
            focused: 0,
        });
    }

    /// Change the focused leaf's parent container's layout.
    ///
    /// A no-op on an empty tree or when the root itself is a bare leaf
    /// (no parent container to relayout — use [`Self::split`] first to
    /// create one).
    pub fn set_layout(&mut self, layout: ContainerLayout) {
        let Some(path) = focused_path(self) else {
            return;
        };
        if path.is_empty() {
            return;
        }
        if let Some(parent) = container_at_mut(self, &path[..path.len() - 1]) {
            parent.layout = layout;
        }
    }

    /// Move the focused leaf within the tree by direction.
    ///
    /// M1: swap with the adjacent sibling in the focused leaf's parent
    /// container, if the parent's layout matches the direction
    /// (`SplitH`/`Tabbed` for Left/Right, `SplitV`/`Stacked` for
    /// Up/Down) and a sibling exists in the direction. Otherwise a
    /// no-op.
    ///
    /// A follow-up may extend this to "escape outward" — moving a leaf
    /// out of its container and into a grandparent — but that adds tree
    /// rewriting that the M1 keyboard set does not strictly need.
    pub fn move_leaf(&mut self, dir: Direction) {
        let Some(path) = focused_path(self) else {
            return;
        };
        if path.is_empty() {
            return;
        }
        let leaf_index = path[path.len() - 1];
        let Some(parent) = container_at_mut(self, &path[..path.len() - 1]) else {
            return;
        };
        if !matches_direction(parent.layout, dir) {
            return;
        }
        let new_index = leaf_index as i32 + dir_step(dir);
        if new_index < 0 || (new_index as usize) >= parent.children.len() {
            return;
        }
        let new_index = new_index as usize;
        parent.children.swap(leaf_index, new_index);
        parent.focused = new_index;
    }

    /// Adjust split ratios at the focused leaf's edge.
    ///
    /// `delta` is a fraction: the focused leaf grows by `delta` at the
    /// named edge, and its adjacent sibling on that edge shrinks by the
    /// same amount. Positive `delta` grows the focused leaf; negative
    /// shrinks it.
    ///
    /// A no-op when the focused leaf's parent's layout doesn't match
    /// the edge (`Edge::Left`/`Right` need `SplitH`; `Top`/`Bottom`
    /// need `SplitV`), when there is no sibling on the named edge, or
    /// when the requested change would push a ratio non-positive.
    pub fn resize(&mut self, edge: Edge, delta: f32) {
        let Some(path) = focused_path(self) else {
            return;
        };
        if path.is_empty() {
            return;
        }
        let leaf_index = path[path.len() - 1];
        let (needed_layout, sibling_offset) = match edge {
            Edge::Left => (ContainerLayout::SplitH, -1_i32),
            Edge::Right => (ContainerLayout::SplitH, 1),
            Edge::Top => (ContainerLayout::SplitV, -1),
            Edge::Bottom => (ContainerLayout::SplitV, 1),
        };
        let Some(parent) = container_at_mut(self, &path[..path.len() - 1]) else {
            return;
        };
        if parent.layout != needed_layout {
            return;
        }
        let sibling_index = leaf_index as i32 + sibling_offset;
        if sibling_index < 0 || (sibling_index as usize) >= parent.children.len() {
            return;
        }
        let sibling_index = sibling_index as usize;
        let new_focus = parent.children[leaf_index].ratio + delta;
        let new_sibling = parent.children[sibling_index].ratio - delta;
        if new_focus <= 0.0 || new_sibling <= 0.0 {
            return;
        }
        parent.children[leaf_index].ratio = new_focus;
        parent.children[sibling_index].ratio = new_sibling;
    }
}

/// The path of child indices from the root to the focused leaf.
/// `Some(vec)` even for a bare-leaf root (returns an empty vec —
/// "no descents needed"); `None` only for an empty tree.
fn focused_path(tree: &TilingTree) -> Option<Vec<usize>> {
    let mut node = tree.root.as_ref()?;
    let mut path = Vec::new();
    loop {
        match node {
            TilingNode::Leaf(_) => return Some(path),
            TilingNode::Container(c) => {
                if c.children.is_empty() {
                    return Some(path);
                }
                let i = c.focused.min(c.children.len() - 1);
                path.push(i);
                node = &c.children[i].node;
            }
        }
    }
}

/// Walk `indices` from the root and return the container at the tip.
fn container_at_mut<'a>(tree: &'a mut TilingTree, indices: &[usize]) -> Option<&'a mut Container> {
    let mut node = tree.root.as_mut()?;
    for &i in indices {
        match node {
            TilingNode::Container(c) => {
                let child = c.children.get_mut(i)?;
                node = &mut child.node;
            }
            TilingNode::Leaf(_) => return None,
        }
    }
    match node {
        TilingNode::Container(c) => Some(c),
        TilingNode::Leaf(_) => None,
    }
}

/// Immutable counterpart of [`container_at_mut`].
fn container_at<'a>(tree: &'a TilingTree, indices: &[usize]) -> Option<&'a Container> {
    let mut node = tree.root.as_ref()?;
    for &i in indices {
        match node {
            TilingNode::Container(c) => {
                node = &c.children.get(i)?.node;
            }
            TilingNode::Leaf(_) => return None,
        }
    }
    match node {
        TilingNode::Container(c) => Some(c),
        TilingNode::Leaf(_) => None,
    }
}

/// Find the deepest ancestor of the focused leaf whose layout matches
/// `dir` and where a sibling exists in the direction. Returns
/// `(depth, new_index)` — the depth of the container to mutate, and the
/// child index its `focused` should become.
fn find_focus_move_target(
    tree: &TilingTree,
    path: &[usize],
    dir: Direction,
) -> Option<(usize, usize)> {
    let step = dir_step(dir);
    for depth in (0..path.len()).rev() {
        let Some(container) = container_at(tree, &path[..depth]) else {
            continue;
        };
        if !matches_direction(container.layout, dir) {
            continue;
        }
        let curr = path[depth];
        let candidate = curr as i32 + step;
        if candidate >= 0 && (candidate as usize) < container.children.len() {
            return Some((depth, candidate as usize));
        }
    }
    None
}

/// Which directional inputs a layout responds to. `SplitH` and `Tabbed`
/// participate in left/right navigation; `SplitV` and `Stacked` in
/// up/down. The Tabbed/Stacked mapping matches i3's tab cycling.
fn matches_direction(layout: ContainerLayout, dir: Direction) -> bool {
    matches!(
        (layout, dir),
        (
            ContainerLayout::SplitH | ContainerLayout::Tabbed,
            Direction::Left | Direction::Right
        ) | (
            ContainerLayout::SplitV | ContainerLayout::Stacked,
            Direction::Up | Direction::Down
        )
    )
}

fn dir_step(dir: Direction) -> i32 {
    match dir {
        Direction::Left | Direction::Up => -1,
        Direction::Right | Direction::Down => 1,
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

    // ---- focused_window ----

    #[test]
    fn focused_window_is_none_for_empty_tree() {
        let t = TilingTree::new();
        assert_eq!(t.focused_window(), None);
    }

    #[test]
    fn focused_window_descends_children_focused() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        t.insert(w(3)); // focused = 2 → w(3)
        assert_eq!(t.focused_window(), Some(w(3)));
    }

    // ---- focus_move ----

    #[test]
    fn focus_move_right_in_splith_steps_focus() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        t.insert(w(3)); // focused = 2 (rightmost)
        // Move focus left twice → w(1)
        assert_eq!(t.focus_move(Direction::Left), Some(w(2)));
        assert_eq!(t.focus_move(Direction::Left), Some(w(1)));
        // Already at left edge — no further movement.
        assert_eq!(t.focus_move(Direction::Left), None);
    }

    #[test]
    fn focus_move_up_in_splith_is_a_noop() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        // SplitH parent doesn't respond to Up/Down.
        assert_eq!(t.focus_move(Direction::Up), None);
    }

    #[test]
    fn focus_move_escapes_outward_through_matching_ancestor() {
        // Tree: SplitH [ Leaf(1), SplitV [ Leaf(2), Leaf(3) ] ]
        // Focus the inner v's top child (w(2)). focus_move(Left) should
        // escape the SplitV (which doesn't match Left/Right) up to the
        // outer SplitH, and step left → w(1).
        let inner = Container {
            id: ContainerId(2),
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
            focused: 0, // w(2)
        };
        let outer = Container {
            id: ContainerId(1),
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
            focused: 1, // descend into the SplitV
        };
        let mut t = TilingTree::from_root(TilingNode::Container(outer));
        assert_eq!(t.focused_window(), Some(w(2)));
        assert_eq!(t.focus_move(Direction::Left), Some(w(1)));
    }

    #[test]
    fn focus_move_in_tabbed_cycles_tabs() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        t.insert(w(3));
        if let Some(TilingNode::Container(c)) = &mut t.root {
            c.layout = ContainerLayout::Tabbed;
            c.focused = 0;
        }
        assert_eq!(t.focus_move(Direction::Right), Some(w(2)));
        assert_eq!(t.focus_move(Direction::Right), Some(w(3)));
        assert_eq!(t.focus_move(Direction::Right), None);
    }

    // ---- split ----

    #[test]
    fn split_on_root_leaf_wraps_in_a_single_child_container() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.split(Orientation::Vertical);
        let Some(TilingNode::Container(c)) = &t.root else {
            panic!("expected root container after split");
        };
        assert_eq!(c.layout, ContainerLayout::SplitV);
        assert_eq!(c.children.len(), 1);
        assert_eq!(c.children[0].node, TilingNode::Leaf(w(1)));
    }

    #[test]
    fn insert_after_split_pairs_inside_the_new_container() {
        // Start: w(1), w(2) in a SplitH root (the default).
        // split(Vertical) on focused w(2) wraps it in a SplitV container.
        // Then insert(w(3)) — w(3) should pair with w(2) in the SplitV,
        // not as a third child of the outer SplitH.
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        t.split(Orientation::Vertical);
        t.insert(w(3));
        let Some(TilingNode::Container(outer)) = &t.root else {
            panic!("outer not a container");
        };
        assert_eq!(outer.layout, ContainerLayout::SplitH);
        assert_eq!(outer.children.len(), 2, "still two outer slots");
        // Outer slot 1 should be the SplitV holding w(2) and w(3).
        let TilingNode::Container(inner) = &outer.children[1].node else {
            panic!("expected SplitV at outer[1]");
        };
        assert_eq!(inner.layout, ContainerLayout::SplitV);
        assert_eq!(inner.children.len(), 2);
        assert_eq!(inner.children[0].node, TilingNode::Leaf(w(2)));
        assert_eq!(inner.children[1].node, TilingNode::Leaf(w(3)));
        assert_eq!(t.focused_window(), Some(w(3)));
    }

    #[test]
    fn split_assigns_a_fresh_container_id() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        let outer_id = if let Some(TilingNode::Container(c)) = &t.root {
            c.id
        } else {
            panic!()
        };
        t.split(Orientation::Vertical);
        // Inner container's id should differ from the outer's.
        let inner_id = if let Some(TilingNode::Container(outer)) = &t.root {
            if let TilingNode::Container(inner) = &outer.children[1].node {
                inner.id
            } else {
                panic!()
            }
        } else {
            panic!()
        };
        assert_ne!(outer_id, inner_id);
    }

    // ---- set_layout ----

    #[test]
    fn set_layout_changes_the_focused_leafs_parent_layout() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        t.set_layout(ContainerLayout::SplitV);
        let Some(TilingNode::Container(c)) = &t.root else {
            panic!("not a container");
        };
        assert_eq!(c.layout, ContainerLayout::SplitV);
    }

    #[test]
    fn set_layout_is_a_noop_for_a_bare_leaf_root() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.set_layout(ContainerLayout::Tabbed); // no parent — no-op
        assert_eq!(t.root, Some(TilingNode::Leaf(w(1))));
    }

    // ---- move_leaf ----

    #[test]
    fn move_leaf_right_swaps_focused_with_right_sibling() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        t.insert(w(3)); // focused = 2 (rightmost)
        // Step focus left so the focused leaf is in the middle.
        t.focus_move(Direction::Left);
        assert_eq!(t.focused_window(), Some(w(2)));
        t.move_leaf(Direction::Right);
        let Some(TilingNode::Container(c)) = &t.root else {
            panic!()
        };
        // Order should be [w(1), w(3), w(2)] and focused should track w(2).
        assert_eq!(c.children[0].node, TilingNode::Leaf(w(1)));
        assert_eq!(c.children[1].node, TilingNode::Leaf(w(3)));
        assert_eq!(c.children[2].node, TilingNode::Leaf(w(2)));
        assert_eq!(c.focused, 2);
        assert_eq!(t.focused_window(), Some(w(2)));
    }

    #[test]
    fn move_leaf_against_mismatched_layout_is_a_noop() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2)); // SplitH parent
        let before = t.clone();
        t.move_leaf(Direction::Up); // SplitH doesn't respond to Up
        assert_eq!(t, before);
    }

    // ---- resize ----

    #[test]
    fn resize_left_grows_focused_and_shrinks_left_sibling() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2)); // focused = 1 (right), both 0.5
        t.resize(Edge::Left, 0.1);
        let Some(TilingNode::Container(c)) = &t.root else {
            panic!()
        };
        assert!(
            (c.children[0].ratio - 0.4).abs() < 1e-6,
            "left = {}",
            c.children[0].ratio
        );
        assert!(
            (c.children[1].ratio - 0.6).abs() < 1e-6,
            "right = {}",
            c.children[1].ratio
        );
    }

    #[test]
    fn resize_with_no_sibling_on_the_named_edge_is_a_noop() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2)); // focused = 1, no right sibling
        let before = t.clone();
        t.resize(Edge::Right, 0.1);
        assert_eq!(t, before);
    }

    #[test]
    fn resize_against_mismatched_orientation_is_a_noop() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2)); // SplitH parent
        let before = t.clone();
        t.resize(Edge::Top, 0.1); // Top needs SplitV
        assert_eq!(t, before);
    }

    #[test]
    fn resize_that_would_zero_a_sibling_is_a_noop() {
        let mut t = TilingTree::new();
        t.insert(w(1));
        t.insert(w(2));
        let before = t.clone();
        t.resize(Edge::Left, 0.6); // would push left sibling to -0.1
        assert_eq!(t, before);
    }
}
