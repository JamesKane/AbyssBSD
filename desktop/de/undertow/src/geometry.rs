//! The placement rules, as pure functions: a layer surface's place and the
//! usable area it leaves (LayerShell.swift, PHASE6.md P6.6), edge snapping
//! (Snap.swift, P9.4), Ebb's grid (Ebb.swift, P13.5) and an island slide
//! (Islands.swift, P13.3). None needs a running desktop to verify, which is
//! §2.9's discipline: the rule that decides what a gesture *means* is tested
//! on its own.

/// A rectangle, in output coordinates.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, width: i32, height: i32) -> Rect {
        Rect { x, y, width, height }
    }
}

// MARK: layer shell (P6.6)

/// The anchor bits, the protocol's values, named so the arithmetic reads as
/// geometry.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LayerAnchor(pub u32);

impl LayerAnchor {
    pub const TOP: LayerAnchor = LayerAnchor(1);
    pub const BOTTOM: LayerAnchor = LayerAnchor(2);
    pub const LEFT: LayerAnchor = LayerAnchor(4);
    pub const RIGHT: LayerAnchor = LayerAnchor(8);

    pub fn contains(self, o: LayerAnchor) -> bool {
        self.0 & o.0 == o.0
    }

    /// Anchored to both edges of an axis means "span it".
    pub fn spans_horizontally(self) -> bool {
        self.contains(LayerAnchor::LEFT) && self.contains(LayerAnchor::RIGHT)
    }

    pub fn spans_vertically(self) -> bool {
        self.contains(LayerAnchor::TOP) && self.contains(LayerAnchor::BOTTOM)
    }

    /// Anchored to `a` and not to its opposite `b`.
    fn only(self, a: LayerAnchor, b: LayerAnchor) -> bool {
        self.contains(a) && !self.contains(b)
    }
}

impl std::ops::BitOr for LayerAnchor {
    type Output = LayerAnchor;
    fn bitor(self, o: LayerAnchor) -> LayerAnchor {
        LayerAnchor(self.0 | o.0)
    }
}

/// What a layer surface asks for, pulled out of the protocol state so the
/// placement rule is tested without a compositor or a client.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LayerRequest {
    pub anchor: LayerAnchor,
    pub desired_width: i32,
    pub desired_height: i32,
    pub margin_top: i32,
    pub margin_right: i32,
    pub margin_bottom: i32,
    pub margin_left: i32,
    /// Space to reserve along the anchored edge. `-1` means "ignore
    /// everyone else's reservations and take the whole output": what the
    /// desktop asks for, so the wallpaper paints under the menu bar
    /// (HANDOFF §2.26).
    pub exclusive_zone: i32,
}

impl LayerRequest {
    pub fn new(anchor: LayerAnchor, desired_width: i32, desired_height: i32) -> LayerRequest {
        LayerRequest { anchor, desired_width, desired_height, ..LayerRequest::default() }
    }
}

/// Where a surface goes, and what the usable area becomes afterwards.
/// Callers fold over their surfaces in order: one with an exclusive zone
/// shrinks the area for everyone arranged *after* it, which is why the menu
/// bar (first) reserves space and the Dock (later, zone 0) overlaps.
pub fn place_layer(req: &LayerRequest, usable: Rect, output: Rect) -> (Rect, Rect) {
    use LayerAnchor as A;
    // A zone of -1 lays out against the whole output and changes nothing
    // for anyone else.
    let b = if req.exclusive_zone < 0 { output } else { usable };
    let (a, ml, mr, mt, mb) = (req.anchor, req.margin_left, req.margin_right, req.margin_top, req.margin_bottom);
    // Zero means "you choose", which is the whole box; anchored to both
    // sides of an axis spans it.
    let mut w = if req.desired_width == 0 || a.spans_horizontally() { b.width - ml - mr } else { req.desired_width };
    let mut h = if req.desired_height == 0 || a.spans_vertically() { b.height - mt - mb } else { req.desired_height };
    w = w.max(0);
    h = h.max(0);
    let x = if a.only(A::LEFT, A::RIGHT) {
        b.x + ml
    } else if a.only(A::RIGHT, A::LEFT) {
        b.x + b.width - w - mr
    } else {
        b.x + (b.width - w) / 2 // centred, spanning or neither
    };
    let y = if a.only(A::TOP, A::BOTTOM) {
        b.y + mt
    } else if a.only(A::BOTTOM, A::TOP) {
        b.y + b.height - h - mb
    } else {
        b.y + (b.height - h) / 2
    };
    let rect = Rect::new(x, y, w, h);
    if req.exclusive_zone <= 0 {
        return (rect, usable);
    }
    // Reserve along the one edge it is anchored to. A surface anchored to
    // opposite edges reserves nothing: there is no unambiguous side.
    let (mut left, zone) = (usable, req.exclusive_zone);
    if a.only(A::TOP, A::BOTTOM) {
        let take = (zone + mt).min(left.height);
        left.y += take;
        left.height -= take;
    } else if a.only(A::BOTTOM, A::TOP) {
        left.height -= (zone + mb).min(left.height);
    } else if a.only(A::LEFT, A::RIGHT) {
        let take = (zone + ml).min(left.width);
        left.x += take;
        left.width -= take;
    } else if a.only(A::RIGHT, A::LEFT) {
        left.width -= (zone + mr).min(left.width);
    }
    left.width = left.width.max(0);
    left.height = left.height.max(0);
    (rect, left)
}

// MARK: edge snapping (P9.4)

/// Where a drag ending at the cursor would put a window: the one tiling
/// affordance this project offers on purpose (PLAN, "deliberately not on
/// this roadmap"), the gesture every desktop has converged on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SnapZone {
    Left,
    Right,
    /// The whole usable area: the top edge, as on Windows and GNOME.
    Maximize,
}

/// How close to an edge the cursor must be, in logical pixels: about a
/// finger's width of slop at 1x.
pub const SNAP_MARGIN: i32 = 16;

/// The zone a cursor is in, or None for "leave the window alone". `area` is
/// the **usable** area. The top edge wins at the two upper corners: a
/// corner that sometimes maximized and sometimes halved would be a coin
/// toss the person cannot see the edge of.
pub fn snap_zone(x: i32, y: i32, area: Rect) -> Option<SnapZone> {
    let m = SNAP_MARGIN;
    if area.width <= 0 || area.height <= 0 {
        return None;
    }
    // Outside the usable area entirely (under the menu bar, say) is not a snap.
    if x < area.x - m || x > area.x + area.width + m || y < area.y - m || y > area.y + area.height + m {
        return None;
    }
    if y <= area.y + m {
        Some(SnapZone::Maximize)
    } else if x <= area.x + m {
        Some(SnapZone::Left)
    } else if x >= area.x + area.width - 1 - m {
        Some(SnapZone::Right)
    } else {
        None
    }
}

/// The rectangle a zone means within `area`. Odd widths go to the left
/// half, so the halves tile the area exactly: no one-pixel gutter.
pub fn snap_rect(zone: SnapZone, area: Rect) -> Rect {
    let w = (area.width + 1) / 2;
    match zone {
        SnapZone::Maximize => area,
        SnapZone::Left => Rect::new(area.x, area.y, w, area.height),
        SnapZone::Right => Rect::new(area.x + w, area.y, area.width - w, area.height),
    }
}

// MARK: Ebb's grid (P13.5)

/// Which windows an Ebb shows: this island, every island of this display
/// (the archipelago), or this application's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EbbScope {
    Island,
    Archipelago,
    App,
}

impl EbbScope {
    pub fn from_name(s: &str) -> Option<EbbScope> {
        match s {
            "island" => Some(EbbScope::Island),
            "archipelago" => Some(EbbScope::Archipelago),
            "app" => Some(EbbScope::App),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            EbbScope::Island => "island",
            EbbScope::Archipelago => "archipelago",
            EbbScope::App => "app",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EbbItem {
    pub id: u32,
    pub width: i32,
    pub height: i32,
}

/// The grid. Its promises: no two slots overlap and every slot is inside
/// the area; a window keeps its aspect and is never drawn larger than it
/// is; and it is **stable**, windows placed in the order given, so a slot
/// does not jump when another window opens: it only shrinks.
pub fn ebb_arrange(items: &[EbbItem], area: Rect, gap: i32) -> Vec<(u32, Rect)> {
    let n = items.len();
    if n == 0 || area.width <= gap * 2 || area.height <= gap * 2 {
        return vec![];
    }
    let cells = |cols: usize| {
        let rows = n.div_ceil(cols);
        let cw = f64::from(area.width - gap * (cols as i32 + 1)) / cols as f64;
        let ch = f64::from(area.height - gap * (rows as i32 + 1)) / rows as f64;
        (rows, cw, ch)
    };
    let fit = |it: &EbbItem, cw: f64, ch: f64| 1f64.min(cw / f64::from(it.width.max(1))).min(ch / f64::from(it.height.max(1)));
    // The column count that shows the windows largest, all told; on a tie
    // (small windows fit any grid whole), the grid whose cells are most the
    // windows' own shape, so three windows sit in a row, not a tower.
    let shape = items.iter().map(|i| f64::from(i.width) / f64::from(i.height.max(1))).sum::<f64>() / n as f64;
    let (mut best_cols, mut best_score, mut best_misfit) = (1, -1.0, f64::INFINITY);
    for cols in 1..=n {
        let (_, cw, ch) = cells(cols);
        if cw <= 8.0 || ch <= 8.0 {
            continue;
        }
        let score: f64 = items.iter().map(|it| fit(it, cw, ch).powi(2) * f64::from(it.width) * f64::from(it.height)).sum();
        let misfit = ((cw / ch) / shape).ln().abs();
        if score > best_score * 1.0001 || (score >= best_score * 0.9999 && misfit < best_misfit) {
            (best_cols, best_score, best_misfit) = (cols, score, misfit);
        }
    }
    let cols = best_cols;
    let (rows, cw, ch) = cells(cols);
    let g = f64::from(gap);
    items
        .iter()
        .enumerate()
        .map(|(i, it)| {
            let (row, col) = (i / cols, i % cols);
            // A short last row is centred, as Exposé's was.
            let in_row = if row == rows - 1 { n - row * cols } else { cols };
            let inset = (cols - in_row) as f64 * (cw + g) / 2.0;
            let s = fit(it, cw, ch);
            let (w, h) = (f64::from(it.width) * s, f64::from(it.height) * s);
            let cx = f64::from(area.x) + g + inset + col as f64 * (cw + g) + (cw - w) / 2.0;
            let cy = f64::from(area.y) + g + row as f64 * (ch + g) + (ch - h) / 2.0;
            (it.id, Rect::new(cx.round() as i32, cy.round() as i32, w.floor() as i32, h.floor() as i32))
        })
        .collect()
}

// MARK: an island slide (P13.3)

/// A slide in progress on one display: the view moving from where it was
/// (an island position, fractional mid-slide) to the island now shown.
/// Decoration only: the switch itself was committed before it started (C6).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct IslandSlide {
    pub from: f64,
    pub to: i32,
    pub start: u64,
    pub duration_ns: u64,
}

impl IslandSlide {
    /// Ease-out cubic: fast away, settling in, so it reads as arriving.
    pub fn ease(t: f64) -> f64 {
        let u = 1.0 - t;
        1.0 - u * u * u
    }

    /// Where the view is at `now`, or None once it has arrived.
    pub fn view(&self, now: u64) -> Option<f64> {
        if now <= self.start {
            return Some(self.from);
        }
        let t = (now - self.start) as f64 / self.duration_ns as f64;
        (t < 1.0).then(|| self.from + (f64::from(self.to) - self.from) * IslandSlide::ease(t))
    }
}

// MARK: where the pointer is, and what is under it (Seat.swift, P6.4)

/// Clamp a position to the output: a cursor that can leave the screen can
/// address a surface nobody can see.
pub fn clamp_cursor(x: f64, y: f64, width: f64, height: f64) -> (f64, f64) {
    (x.clamp(0.0, (width - 1.0).max(0.0)), y.clamp(0.0, (height - 1.0).max(0.0)))
}

/// The topmost rect containing the point, and the point in its local
/// coordinates: (index, x, y). `rects` is bottom-to-top, so the search runs
/// backwards, the whole reason raising a window changes what a click hits.
/// Half-open bounds, so two windows sharing an edge never both claim a pixel.
pub fn hit(x: f64, y: f64, rects: &[Rect]) -> Option<(usize, f64, f64)> {
    rects.iter().enumerate().rev().find_map(|(i, r)| {
        let (lx, ly) = (x - f64::from(r.x), y - f64::from(r.y));
        (lx >= 0.0 && ly >= 0.0 && lx < f64::from(r.width) && ly < f64::from(r.height)).then_some((i, lx, ly))
    })
}

/// A layout rectangle in an output's buffer pixels (Scene.swift, P14.7a).
/// Edges are rounded, not the size, so two rectangles that touch in the
/// layout still touch on a scaled output.
pub fn project(r: Rect, origin_x: i32, origin_y: i32, scale: f64) -> Rect {
    if scale == 1.0 {
        return Rect::new(r.x - origin_x, r.y - origin_y, r.width, r.height);
    }
    let edge = |v: i32| (f64::from(v) * scale).round();
    let (x0, y0) = (edge(r.x - origin_x), edge(r.y - origin_y));
    let (x1, y1) = (edge(r.x - origin_x + r.width), edge(r.y - origin_y + r.height));
    Rect::new(x0 as i32, y0 as i32, (x1 - x0) as i32, (y1 - y0) as i32)
}
