// SPDX-License-Identifier: BSD-2-Clause

//! The view arena, the retained tree, and the layout / paint / input
//! drivers (`docs/design/toolkit.md` §4–§6, §8, §10).

use abyss_render::{Canvas, Rect, Size};

use crate::event::{InputEvent, UiEvent};
use crate::widget::{MeasureCtx, PaintCtx, Widget};

/// A generational handle to a view (§4): a 16-bit index and a 16-bit
/// generation. A handle that outlives its view — the slot emptied or
/// reused — resolves to `None`. (After 65 536 reuses of one slot the
/// generation wraps; a stale handle could then alias — acceptable churn
/// for a desktop, §4.)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ViewId(u32);

impl ViewId {
    fn new(index: u16, generation: u16) -> ViewId {
        ViewId(u32::from(generation) << 16 | u32::from(index))
    }

    fn index(self) -> usize {
        (self.0 & 0xFFFF) as usize
    }

    fn generation(self) -> u16 {
        (self.0 >> 16) as u16
    }
}

/// One node of the retained view tree (§5).
struct View {
    widget: Box<dyn Widget>,
    children: Vec<ViewId>,
    bounds: Rect,
    measured: Size,
    needs_paint: bool,
}

/// A slot in the arena's generational slotmap.
struct Slot {
    generation: u16,
    view: Option<View>,
}

/// A window's view hierarchy — the §4 arena, the §5 retained tree, and
/// the layout / paint / input drivers, in one per-window object.
pub struct ViewTree {
    slots: Vec<Slot>,
    free: Vec<u16>,
    root: ViewId,
    needs_layout: bool,
}

impl ViewTree {
    /// A new tree whose root is `root`.
    pub fn new(root: impl Widget) -> ViewTree {
        let mut tree = ViewTree {
            slots: Vec::new(),
            free: Vec::new(),
            root: ViewId(0),
            needs_layout: true,
        };
        tree.root = tree.insert(Box::new(root));
        tree
    }

    /// The root view's id.
    #[must_use]
    pub fn root(&self) -> ViewId {
        self.root
    }

    /// Add `widget` as the last child of `parent`. Returns its id, or
    /// `None` if `parent` is not a live view.
    pub fn add_child(&mut self, parent: ViewId, widget: impl Widget) -> Option<ViewId> {
        self.view(parent)?;
        let id = self.insert(Box::new(widget));
        self.view_mut(parent)
            .expect("parent checked live")
            .children
            .push(id);
        self.needs_layout = true;
        Some(id)
    }

    /// The assigned bounds of `id` after the last [`layout`](Self::layout).
    #[must_use]
    pub fn bounds(&self, id: ViewId) -> Option<Rect> {
        self.view(id).map(|v| v.bounds)
    }

    /// Typed access to a view's widget — `None` if `id` is stale or the
    /// widget is not a `W`.
    #[must_use]
    pub fn widget<W: Widget>(&self, id: ViewId) -> Option<&W> {
        self.view(id)?.widget.as_any().downcast_ref::<W>()
    }

    /// Mutable typed access. Marks the view for repaint and the tree for
    /// re-layout — getting `&mut` to a widget means it is about to change.
    pub fn widget_mut<W: Widget>(&mut self, id: ViewId) -> Option<&mut W> {
        self.needs_layout = true;
        let view = self.view_mut(id)?;
        view.needs_paint = true;
        view.widget.as_any_mut().downcast_mut::<W>()
    }

    /// Whether the tree has changed shape or content since the last
    /// [`layout`](Self::layout).
    #[must_use]
    pub fn needs_layout(&self) -> bool {
        self.needs_layout
    }

    /// The region changed since the last [`paint`](Self::paint) — the
    /// union of every dirty view's bounds, or `None` if nothing is dirty.
    #[must_use]
    pub fn damage(&self) -> Option<Rect> {
        let mut acc: Option<Rect> = None;
        for slot in &self.slots {
            let Some(view) = &slot.view else { continue };
            if view.needs_paint && !view.bounds.is_empty() {
                acc = Some(match acc {
                    Some(r) => union(r, view.bounds),
                    None => view.bounds,
                });
            }
        }
        acc
    }

    // --- layout (§6) -------------------------------------------------------

    /// Lay the whole tree out within `available`: measure bottom-up, then
    /// arrange top-down.
    pub fn layout(&mut self, available: Size, ctx: &MeasureCtx<'_>) {
        let root = self.root;
        self.measure_view(root, ctx);
        self.arrange_view(root, Rect::new(0.0, 0.0, available.w, available.h));
        self.needs_layout = false;
    }

    fn measure_view(&mut self, id: ViewId, ctx: &MeasureCtx<'_>) -> Size {
        let children = self.children_of(id);
        let mut child_sizes = Vec::with_capacity(children.len());
        for &child in &children {
            child_sizes.push(self.measure_view(child, ctx));
        }
        let size = match self.view(id) {
            Some(view) => view.widget.measure(&child_sizes, ctx),
            None => Size::new(0.0, 0.0),
        };
        if let Some(view) = self.view_mut(id) {
            view.measured = size;
        }
        size
    }

    fn arrange_view(&mut self, id: ViewId, bounds: Rect) {
        if let Some(view) = self.view_mut(id) {
            view.bounds = bounds;
        }
        let children = self.children_of(id);
        if children.is_empty() {
            return;
        }
        let child_sizes: Vec<Size> = children
            .iter()
            .map(|&c| self.view(c).map_or(Size::new(0.0, 0.0), |v| v.measured))
            .collect();
        let rects = match self.view(id) {
            Some(view) => view.widget.arrange(bounds, &child_sizes),
            None => Vec::new(),
        };
        for (&child, &rect) in children.iter().zip(&rects) {
            self.arrange_view(child, rect);
        }
    }

    // --- paint (§10) -------------------------------------------------------

    /// Paint the tree into `canvas`, then clear every view's dirty flag.
    /// A full repaint each call is correct; partial repaint from
    /// [`damage`](Self::damage) is a later optimization (§10).
    pub fn paint(&mut self, canvas: &mut Canvas<'_>, ctx: &mut PaintCtx<'_>) {
        let root = self.root;
        self.paint_view(root, canvas, ctx);
    }

    fn paint_view(&mut self, id: ViewId, canvas: &mut Canvas<'_>, ctx: &mut PaintCtx<'_>) {
        let Some((bounds, children)) = self.view(id).map(|v| (v.bounds, v.children.clone())) else {
            return;
        };
        if let Some(view) = self.view(id) {
            view.widget.paint(bounds, canvas, ctx);
        }
        if let Some(view) = self.view_mut(id) {
            view.needs_paint = false;
        }
        for child in children {
            self.paint_view(child, canvas, ctx);
        }
    }

    // --- input (§8) --------------------------------------------------------

    /// Route `event` to the deepest view it lands on, returning any UI
    /// events the widget emitted. The hit view is marked for repaint.
    pub fn dispatch_input(&mut self, event: &InputEvent) -> Vec<UiEvent> {
        let Some(hit) = self.hit_test(self.root, event.point()) else {
            return Vec::new();
        };
        let bounds = self
            .view(hit)
            .map_or(Rect::new(0.0, 0.0, 0.0, 0.0), |v| v.bounds);
        let events = match self.view_mut(hit) {
            Some(view) => view.widget.on_input(hit, event, bounds),
            None => Vec::new(),
        };
        if let Some(view) = self.view_mut(hit) {
            view.needs_paint = true;
        }
        events
    }

    fn hit_test(&self, id: ViewId, point: abyss_render::Point) -> Option<ViewId> {
        let view = self.view(id)?;
        if !view.bounds.contains(point) {
            return None;
        }
        for &child in view.children.iter().rev() {
            if let Some(hit) = self.hit_test(child, point) {
                return Some(hit);
            }
        }
        Some(id)
    }

    // --- the slotmap (§4) --------------------------------------------------

    fn insert(&mut self, widget: Box<dyn Widget>) -> ViewId {
        let view = View {
            widget,
            children: Vec::new(),
            bounds: Rect::new(0.0, 0.0, 0.0, 0.0),
            measured: Size::new(0.0, 0.0),
            needs_paint: true,
        };
        if let Some(index) = self.free.pop() {
            let slot = &mut self.slots[index as usize];
            slot.view = Some(view);
            ViewId::new(index, slot.generation)
        } else {
            let index = u16::try_from(self.slots.len()).expect("view count exceeds 65535");
            self.slots.push(Slot {
                generation: 0,
                view: Some(view),
            });
            ViewId::new(index, 0)
        }
    }

    /// Remove `id` and its whole subtree.
    pub fn remove(&mut self, id: ViewId) {
        for child in self.children_of(id) {
            self.remove(child);
        }
        if let Some(slot) = self.slots.get_mut(id.index())
            && slot.generation == id.generation()
            && slot.view.is_some()
        {
            slot.view = None;
            slot.generation = slot.generation.wrapping_add(1);
            self.free.push(id.index() as u16);
        }
        self.needs_layout = true;
    }

    fn children_of(&self, id: ViewId) -> Vec<ViewId> {
        self.view(id)
            .map(|v| v.children.clone())
            .unwrap_or_default()
    }

    fn view(&self, id: ViewId) -> Option<&View> {
        let slot = self.slots.get(id.index())?;
        if slot.generation == id.generation() {
            slot.view.as_ref()
        } else {
            None
        }
    }

    fn view_mut(&mut self, id: ViewId) -> Option<&mut View> {
        let slot = self.slots.get_mut(id.index())?;
        if slot.generation == id.generation() {
            slot.view.as_mut()
        } else {
            None
        }
    }
}

/// The smallest rectangle covering both inputs.
fn union(a: Rect, b: Rect) -> Rect {
    let x = a.x.min(b.x);
    let y = a.y.min(b.y);
    Rect::new(
        x,
        y,
        a.right().max(b.right()) - x,
        a.bottom().max(b.bottom()) - y,
    )
}
