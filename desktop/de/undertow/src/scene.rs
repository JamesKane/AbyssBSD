//! The scene the present path reads (Scene.swift, PHASE6.md P6.3;
//! DESKTOP.md §4).
//!
//! Structure-of-arrays, not a widget tree: parallel arrays of rects and
//! texture handles, walked linearly, preallocated once and never grown. A
//! snapshot is a copy of a few arrays rather than a traversal of somebody
//! else's object graph, which is why C2 is affordable.
//!
//! **Latch, don't ask.** `latch_and_composite` copies the current window
//! list into the arrays and works only from them. It never calls back into
//! a client, never waits: everything it reads was already committed.
//!
//! Swift's scene reads the compositor directly. Here it reads a `World`,
//! which the compositor implements: the windows, layers and popups as plain
//! values, and the few things only the compositor can make (a frame's
//! texture, Ebb, an island slide).

use crate::backend::Painter;
use crate::displays::DisplayBox;
use crate::ebb::Ebb;
use crate::frame::FrameMetrics;
use crate::geometry::{project, Rect};
use crate::output::{FrameSink, FrameStats};
use abyss_sys::wlr::{self, Blend, RectDraw, RenderPass, Surface, Texture, TextureDraw, Timeline};
use std::cell::Cell;
use std::rc::Rc;

/// A colour, unpremultiplied.
pub type Rgba = (f32, f32, f32, f32);

/// A toplevel as the scene sees it.
#[derive(Clone, Debug, PartialEq)]
pub struct SceneWindow {
    pub id: u32,
    pub surface: Surface,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub mapped: bool,
    pub minimized: bool,
    pub decorated: bool,
    /// The display and island it lives on (PHASE13 P13.1).
    pub island_display: Rc<str>,
    pub island: u32,
    /// Its WindowPlaces key: what a shoal remembers it by.
    pub place_key: Rc<str>,
}

impl SceneWindow {
    fn drawable(&self) -> bool {
        self.mapped && !self.minimized && self.surface.has_buffer()
    }
}

/// A mapped layer surface: its layer (0 background … 3 overlay) and place.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneLayer {
    pub layer: u32,
    pub surface: Surface,
    pub rect: Rect,
}

/// A texture the compositor drew (a label), at its size in layout points.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Label {
    pub texture: Texture,
    pub width: i32,
    pub height: i32,
}

/// What the scene latches from: the compositor's side of the seam.
pub trait World {
    /// An island switch asked for on `display` since it last latched: the
    /// frame that draws it carries the stamp (C6). 0 if none.
    fn take_island_input(&mut self, display: &str) -> u64;
    fn is_locked(&self) -> bool;
    /// The session lock's mapped surfaces, each with its display's origin.
    fn lock_surfaces(&self) -> Vec<(Surface, i32, i32)>;
    /// Mapped layer surfaces with buffers, sorted by layer.
    fn mapped_layers(&self) -> Vec<SceneLayer>;
    /// Every toplevel, bottom of the stack first.
    fn toplevels(&self) -> Vec<SceneWindow>;
    fn is_on_active_island(&self, w: &SceneWindow) -> bool;
    /// Ebb on `display`, if open there (and forgotten once it has closed).
    fn ebb_frame(&mut self, display: &str, now: u64) -> Option<Ebb>;
    /// The view mid-slide on `display` (P13.3), in islands.
    fn island_view(&mut self, display: &str, now: u64) -> Option<f64>;
    /// The Shoals strip's tiles on `display` (P13.6): shoal index and rect.
    fn strip_tiles(&self, display: &str) -> Vec<(usize, Rect)>;
    /// A shoal's name and members (window place keys).
    fn shoal(&self, index: usize) -> (String, Vec<String>);
    /// The frame undertow draws for a decorated window, as it is now
    /// (focused or not); None to draw none.
    fn frame_texture(&mut self, w: &SceneWindow) -> Option<Texture>;
    fn ebb_label(&mut self, w: &SceneWindow) -> Option<Label>;
    fn strip_label(&mut self, name: &str) -> Option<Label>;
    /// Mapped popups (menus), parent before child, at their origins.
    fn mapped_popups(&self) -> Vec<(Surface, i32, i32)>;
    /// An input method's candidate popups (U.5).
    fn input_method_popups(&self) -> Vec<(Surface, i32, i32)>;
    /// What the renderer waits for before reading `s` (U.3b), if its
    /// client uses explicit sync.
    fn acquire(&self, s: Surface) -> Option<(Timeline, u64)>;
    /// The cursor, as one number: a frame redraws when it moves.
    fn cursor_signature(&self) -> u64;
    /// The theme's generation: a new theme redraws every frame.
    fn theme_generation(&self) -> u64;
}

/// FNV-1a over 64-bit words: cheap, no allocation, and enough to tell one
/// frame from the next (M.1). A collision skips one frame that changed, and
/// the next change redraws it.
#[derive(Clone, Copy)]
pub struct FrameHash(pub u64);

impl Default for FrameHash {
    fn default() -> FrameHash {
        FrameHash(0xcbf2_9ce4_8422_2325)
    }
}

impl FrameHash {
    #[inline(always)]
    pub fn add(&mut self, v: u64) {
        self.0 = (self.0 ^ v).wrapping_mul(0x0000_0100_0000_01b3)
    }
}

const NORMAL: i32 = 0; // WL_OUTPUT_TRANSFORM_NORMAL

/// The compositor's scene for one output: windows latched from the world,
/// composited into a wlroots render pass.
pub struct SurfaceScene<W: World> {
    pub world: W,
    pub capacity: usize,
    pub count: usize,
    texture: Vec<Option<Texture>>,
    x: Vec<i32>,
    y: Vec<i32>,
    w: Vec<i32>,
    h: Vec<i32>,
    /// The client surface each entry was drawn from: None for what the
    /// compositor draws itself. What presentation-time is told was shown.
    source: Vec<Option<Surface>>,
    /// The part of each texture drawn, in buffer pixels (U.8): all zero is
    /// the whole texture.
    crop: Vec<[f64; 4]>,
    /// The inverse of each buffer's transform.
    turn: Vec<i32>,
    wait: Vec<Option<(Timeline, u64)>>,
    /// How opaque each entry is drawn (P13.5).
    alpha: Vec<f32>,
    /// A solid colour instead of a texture, premultiplied at draw.
    fill: Vec<Option<Rgba>>,
    last_signature: u64,
    dirty: Rc<Cell<bool>>,
    walk: (i32, i32),
    walk_scale: f64,
    walk_alpha: f32,
    ebb_shown: bool,
    /// Textures drawn behind an acquire wait, all told.
    pub acquire_waits: u64,
    /// The rectangle of the layout this scene shows (P14.7a): everything is
    /// latched in layout coordinates; the draw subtracts the origin and
    /// multiplies by the scale.
    pub origin: (i32, i32),
    pub output_size: (i32, i32),
    pub scale: f64,
    /// Its display's name: the key an island switch is stamped under (C6).
    pub display_name: String,
    /// The frame's size around a window: the theme's.
    pub metrics: FrameMetrics,
    /// What a locked display shows where its lock surface is not: a dark
    /// slate, unlike any colour the desktop draws.
    pub locked: bool,
}

pub const LOCKED_COLOUR: Rgba = (0.09, 0.10, 0.13, 1.0);

impl<W: World> SurfaceScene<W> {
    pub fn new(world: W, display: &DisplayBox, metrics: FrameMetrics, capacity: usize) -> SurfaceScene<W> {
        let dirty = Rc::new(Cell::new(true));
        SurfaceScene {
            world,
            capacity,
            count: 0,
            texture: vec![None; capacity],
            x: vec![0; capacity],
            y: vec![0; capacity],
            w: vec![0; capacity],
            h: vec![0; capacity],
            source: vec![None; capacity],
            crop: vec![[0.0; 4]; capacity],
            turn: vec![NORMAL; capacity],
            wait: vec![None; capacity],
            alpha: vec![1.0; capacity],
            fill: vec![None; capacity],
            last_signature: 0,
            dirty,
            walk: (0, 0),
            walk_scale: 1.0,
            walk_alpha: 1.0,
            ebb_shown: false,
            acquire_waits: 0,
            origin: (display.x, display.y),
            output_size: (display.width, display.height),
            scale: display.scale,
            display_name: display.name.clone(),
            metrics,
            locked: false,
        }
    }

    /// The output moved, changed mode or scale (P14.7b).
    pub fn show(&mut self, display: &DisplayBox) {
        self.origin = (display.x, display.y);
        self.output_size = (display.width, display.height);
        self.scale = display.scale;
        self.display_name = display.name.clone();
    }

    /// Draw the next frame even if nothing in it changed.
    pub fn invalidate(&self) {
        self.dirty.set(true)
    }

    /// What the latch produced, entry `i`: texture (or fill) and its rect.
    pub fn entry(&self, i: usize) -> (Option<Texture>, Option<Rgba>, Rect) {
        (self.texture[i], self.fill[i], Rect::new(self.x[i], self.y[i], self.w[i], self.h[i]))
    }

    fn push(&mut self, tex: Option<Texture>, fill: Option<Rgba>, r: Rect, alpha: f32) {
        let c = self.count;
        self.texture[c] = tex;
        self.fill[c] = fill;
        self.source[c] = None;
        self.crop[c] = [0.0; 4];
        self.turn[c] = NORMAL;
        self.wait[c] = None;
        self.alpha[c] = alpha;
        (self.x[c], self.y[c], self.w[c], self.h[c]) = (r.x, r.y, r.width, r.height);
        self.count += 1;
    }

    fn add_fill(&mut self, r: Rect, c: Rgba) {
        if self.count < self.capacity {
            self.push(None, Some(c), r, 1.0);
        }
    }

    fn add_label(&mut self, l: Label, x: i32, y: i32) {
        if self.count < self.capacity {
            self.push(Some(l.texture), None, Rect::new(x, y, l.width, l.height), 1.0);
        }
    }

    /// A window, and the frame undertow draws for it, `dx` to the side.
    /// **The frame goes under the window it frames** (P9.6): one entry in
    /// the same arrays, so the present path learns nothing new.
    fn add_window(&mut self, t: &SceneWindow, dx: i32) {
        if t.decorated
            && let Some(frame) = self.world.frame_texture(t)
        {
            let (x, y, w, h) = self.metrics.frame(t.x + dx, t.y, t.width, t.height);
            self.push(Some(frame), None, Rect::new(x, y, w, h), 1.0);
            if self.count >= self.capacity {
                return;
            }
        }
        self.add_tree(t.surface, t.x + dx, t.y);
    }

    /// A window drawn into `r`, scaled: its frame too, as the frame it is.
    fn add_window_into(&mut self, t: &SceneWindow, r: Rect, a: f32) {
        let s = if t.width > 0 { r.width as f64 / t.width as f64 } else { 1.0 };
        if t.decorated
            && let Some(frame) = self.world.frame_texture(t)
        {
            let (bx, by, bw, bh) = self.metrics.frame(t.x, t.y, t.width, t.height);
            let sc = |v: i32| (v as f64 * s).round() as i32;
            self.push(Some(frame), None, Rect::new(r.x + sc(bx - t.x), r.y + sc(by - t.y), sc(bw), sc(bh)), a);
            if self.count >= self.capacity {
                return;
            }
        }
        (self.walk_scale, self.walk_alpha) = (s, a);
        self.add_tree(t.surface, r.x, r.y);
        (self.walk_scale, self.walk_alpha) = (1.0, 1.0);
    }

    /// A surface **and its subsurfaces**, in paint order: wlroots keeps the
    /// tree and its stacking, and a child placed below its parent is painted
    /// first. Undertow advertised wl_subcompositor from Phase 6 and drew no
    /// subsurface until API-STUDY §1.3 found it.
    fn add_tree(&mut self, root: Surface, ox: i32, oy: i32) {
        self.walk = (ox, oy);
        root.for_each_surface(|s, sx, sy| self.add_leaf(s, sx, sy));
    }

    fn add_leaf(&mut self, s: Surface, sx: i32, sy: i32) {
        if self.count >= self.capacity {
            return;
        }
        let Some(tex) = s.texture() else { return };
        let c = self.count;
        self.texture[c] = Some(tex);
        self.source[c] = Some(s);
        self.alpha[c] = self.walk_alpha;
        self.fill[c] = None;
        // The size on screen is the surface's: wlroots has applied the
        // buffer scale, transform and a viewport's destination. A thumbnail
        // scales the whole tree, offsets included.
        let k = self.walk_scale;
        if k == 1.0 {
            (self.x[c], self.y[c], self.w[c], self.h[c]) = (self.walk.0 + sx, self.walk.1 + sy, s.width(), s.height());
        } else {
            let sc = |v: i32| (v as f64 * k).round() as i32;
            (self.x[c], self.y[c], self.w[c], self.h[c]) = (self.walk.0 + sc(sx), self.walk.1 + sc(sy), sc(s.width()), sc(s.height()));
        }
        // **What part of the buffer (U.8)**: a viewport may crop it.
        self.crop[c] = s.source_box();
        self.turn[c] = wlr::transform_invert(s.transform());
        // Not before the GPU has finished drawing it (U.3b).
        self.wait[c] = self.world.acquire(s);
        self.count += 1;
    }

    /// Ebb on this display (P13.5): the desktop dimmed, and every window in
    /// scope drawn into its slot, moving there while it opens and home while
    /// it closes. Other displays' windows are drawn as ever.
    fn add_ebb(&mut self, e: &Ebb, windows: &[SceneWindow], now: u64) {
        self.ebb_shown = true;
        let p = e.progress(now);
        let (ox, oy) = self.origin;
        let (ow, oh) = self.output_size;
        self.add_fill(Rect::new(ox, oy, ow, oh), (0.0, 0.0, 0.0, (0.5 * p) as f32));
        for t in windows {
            if *t.island_display != *self.display_name && self.world.is_on_active_island(t) && t.drawable() {
                if self.count >= self.capacity {
                    return;
                }
                self.add_window(t, 0);
            }
        }
        for s in &e.slots {
            if self.count >= self.capacity {
                return;
            }
            let Some(t) = windows.iter().find(|w| w.id == s.window) else { continue };
            // A window of an island not shown has no home on screen to fly
            // from: it fades in at its slot instead, and out the same way.
            let home = self.world.is_on_active_island(t);
            let r = if home { e.rect(s, now) } else { s.slot };
            let a = if home { 1.0 } else { p as f32 };
            if a <= 0.01 {
                continue;
            }
            if e.hovered == Some(t.id) && !e.closing() {
                self.add_fill(Rect::new(r.x - 4, r.y - 4, r.width + 8, r.height + 8), (0.20, 0.45, 0.85, 0.9));
            }
            self.add_window_into(t, r, a);
        }
        if let Some(id) = e.hovered
            && !e.closing()
            && p > 0.99
            && let Some(s) = e.slots.iter().find(|s| s.window == id)
            && let Some(t) = windows.iter().find(|w| w.id == id)
            && let Some(label) = self.world.ebb_label(t)
        {
            let lx = s.slot.x + (s.slot.width - label.width) / 2;
            let ly = s.slot.y + s.slot.height - label.height - 8;
            self.add_label(label, lx, ly);
        }
    }

    /// The Shoals strip (P13.6): a tile per shoal of this display's island,
    /// down the left edge: a dark plate, up to three of its windows stacked
    /// and live, and its name. Above the windows, under the menu bar.
    fn add_strip(&mut self, windows: &[SceneWindow]) {
        for (index, r) in self.world.strip_tiles(&self.display_name) {
            if self.count + 8 >= self.capacity {
                return;
            }
            self.add_fill(r, (0.08, 0.10, 0.16, 0.78));
            let (name, members) = self.world.shoal(index);
            let found: Vec<&SceneWindow> = members.iter().filter_map(|k| windows.iter().find(|t| t.mapped && *t.place_key == **k && t.surface.has_buffer())).collect();
            // Stacked: each a little lower and to the right of the one before.
            let shown = &found[found.len().saturating_sub(3)..];
            let step = 8;
            let spread = step * (shown.len() as i32 - 1).max(0);
            let (box_w, box_h) = (r.width - 24 - spread, r.height - 34 - spread);
            for (n, t) in shown.iter().enumerate() {
                if t.width <= 0 || t.height <= 0 {
                    continue;
                }
                let k = (box_w as f64 / t.width as f64).min(box_h as f64 / t.height as f64).min(1.0);
                let into = Rect::new(r.x + 12 + step * n as i32, r.y + 10 + step * n as i32, (t.width as f64 * k) as i32, (t.height as f64 * k) as i32);
                self.add_window_into(t, into, 1.0);
                if self.count + 2 >= self.capacity {
                    return;
                }
            }
            if let Some(label) = self.world.strip_label(&name) {
                self.add_label(label, r.x + (r.width - label.width) / 2, r.y + r.height - label.height - 4);
            }
        }
    }

    /// The cull's arithmetic and the frame's stats, and whether anything a
    /// person could see changed since the last frame presented (M.1).
    fn finish(&mut self, input_at: u64) -> FrameStats {
        let sig = self.signature();
        let unchanged = !self.dirty.get() && sig == self.last_signature;
        if !unchanged {
            self.last_signature = sig;
            self.dirty.set(false);
        }
        let (ox, oy) = self.origin;
        let (ow, oh) = self.output_size;
        let (mut painted, mut area) = (0, 0i64);
        for i in 0..self.count {
            let (lx, ly) = (self.x[i] - ox, self.y[i] - oy);
            let (r, b) = (lx + self.w[i], ly + self.h[i]);
            if r <= 0 || b <= 0 || lx >= ow || ly >= oh {
                continue;
            }
            let (cw, ch) = (r.min(ow) - lx.max(0), b.min(oh) - ly.max(0));
            if cw > 0 && ch > 0 {
                area += cw as i64 * ch as i64;
                painted += 1;
            }
        }
        FrameStats { surfaces: painted, damage_area: if unchanged { 0 } else { area }, degraded: false, input_at, unchanged }
    }

    /// Everything this frame would draw, as one number: each entry's
    /// texture, its client surface and commit (a texture updated in place
    /// keeps its pointer, never its commit), where, what part, which way up,
    /// how opaque, a fill's colour; and the cursor, the lock, the output's
    /// size and scale, the theme. Built from what is latched, so a change
    /// nobody thought to report still redraws.
    fn signature(&self) -> u64 {
        let mut h = FrameHash::default();
        h.add(self.count as u64);
        h.add(self.locked as u64);
        h.add(self.output_size.0 as u32 as u64);
        h.add(self.output_size.1 as u32 as u64);
        h.add(self.scale.to_bits());
        h.add(self.world.theme_generation());
        h.add(self.world.cursor_signature());
        let pair = |a: i32, b: i32| ((a as u32 as u64) << 32) | b as u32 as u64;
        for i in 0..self.count {
            h.add(self.texture[i].map_or(0, |t| t.addr() as u64));
            if let Some(s) = self.source[i] {
                h.add(s.addr() as u64);
                h.add(s.seq() as u64);
            }
            h.add(pair(self.x[i], self.y[i]));
            h.add(pair(self.w[i], self.h[i]));
            for v in self.crop[i] {
                h.add(v.to_bits());
            }
            h.add(self.turn[i] as u32 as u64);
            h.add(self.alpha[i].to_bits() as u64);
            if let Some((r, g, b, a)) = self.fill[i] {
                h.add(((r.to_bits() as u64) << 32) | g.to_bits() as u64);
                h.add(((b.to_bits() as u64) << 32) | a.to_bits() as u64);
            }
        }
        h.0
    }

    /// A layout rectangle in this output's buffer pixels.
    pub fn project(&self, r: Rect) -> Rect {
        project(r, self.origin.0, self.origin.1, self.scale)
    }
}

impl<W: World> FrameSink for SurfaceScene<W> {
    /// Latch the window list and compute what is visible. Linear in the
    /// count, and every branch arithmetic on values already held.
    fn latch_and_composite(&mut self, now: u64, _target: u64) -> FrameStats {
        self.count = 0;
        let input_at = self.world.take_island_input(&self.display_name);
        self.locked = self.world.is_locked();
        // **Locked: the lock surface for this display, and nothing else**
        // (PHASE16 P16.2): no wallpaper, window, menu or popup. With no lock
        // surface, the lock colour alone, never the desktop.
        if self.locked {
            for (s, x, y) in self.world.lock_surfaces() {
                if (x, y) == self.origin {
                    self.add_tree(s, x, y);
                }
            }
            return self.finish(input_at);
        }
        // Paint order is the shell's whole visual grammar: background and
        // bottom layers, the windows, then top and overlay. A menu bar a
        // window could cover is not a menu bar.
        let layers = self.world.mapped_layers();
        for l in layers.iter().filter(|l| l.layer <= 1) {
            self.add_tree(l.surface, l.rect.x, l.rect.y);
        }
        let windows = self.world.toplevels();
        if let Some(ebb) = self.world.ebb_frame(&self.display_name, now) {
            self.add_ebb(&ebb, &windows, now);
        } else if let Some(view) = self.world.island_view(&self.display_name, now) {
            // **Mid-slide (P13.3)**: this display's islands within one width
            // of the view, each shifted by its distance from it. Input and
            // focus already belong to the new island (C6): this is only
            // where pixels go.
            let width = self.output_size.0 as f64;
            for t in &windows {
                if self.count >= self.capacity {
                    break;
                }
                if !t.drawable() {
                    continue;
                }
                if *t.island_display == *self.display_name {
                    let off = (t.island as f64 - view) * width;
                    if off.abs() < width {
                        self.add_window(t, off.round() as i32);
                    }
                } else if self.world.is_on_active_island(t) {
                    self.add_window(t, 0);
                }
            }
        } else {
            for t in &windows {
                if self.count >= self.capacity {
                    break; // bounded, never grows
                }
                if t.drawable() && self.world.is_on_active_island(t) {
                    self.add_window(t, 0);
                }
            }
        }
        if !self.ebb_shown {
            self.add_strip(&windows);
        }
        for l in layers.iter().filter(|l| l.layer >= 2) {
            self.add_tree(l.surface, l.rect.x, l.rect.y);
        }
        if self.ebb_shown {
            self.ebb_shown = false;
            return self.finish(input_at);
        }
        // Menus above everything, parent before child (P10.4); an input
        // method's candidates over them (U.5).
        for (s, x, y) in self.world.mapped_popups().into_iter().chain(self.world.input_method_popups()) {
            self.add_tree(s, x, y);
        }
        self.finish(input_at)
    }
}

impl<W: World> Painter for SurfaceScene<W> {
    /// Draw the latched scene: the renderer's budget, apart from the latch's,
    /// which is what lets one latch be both captured and presented.
    fn render(&mut self, pass: &mut RenderPass, _out: wlr::Output, background: Rgba) {
        let full = |v: i32| (v as f64 * self.scale).round() as i32;
        let bg = if self.locked { LOCKED_COLOUR } else { background };
        pass.add_rect(&RectDraw::new(0, 0, full(self.output_size.0), full(self.output_size.1), bg, Blend::None));
        for i in 0..self.count {
            let r = self.project(Rect::new(self.x[i], self.y[i], self.w[i], self.h[i]));
            if let Some((cr, cg, cb, ca)) = self.fill[i] {
                // Premultiplied: the colour carries its own alpha.
                pass.add_rect(&RectDraw::new(r.x, r.y, r.width, r.height, (cr * ca, cg * ca, cb * ca, ca), Blend::Premultiplied));
                continue;
            }
            let Some(tex) = self.texture[i] else { continue };
            let mut d = TextureDraw::new(tex, (r.x, r.y, r.width, r.height));
            d.src = self.crop[i];
            d.transform = self.turn[i];
            if let Some((t, point)) = self.wait[i] {
                d = d.wait(t, point);
                self.acquire_waits += 1;
            }
            if self.alpha[i] < 1.0 {
                d.alpha = self.alpha[i];
            }
            pass.add_texture(&d);
        }
    }

    /// Tell presentation-time which client surfaces this frame shows (U.4):
    /// wlroots answers their feedback from the output's present event, and
    /// cannot know which surfaces were in a frame unless told.
    fn mark_presented(&mut self, out: wlr::Output) {
        for s in self.source[..self.count].iter().flatten() {
            s.textured_on_output(out);
        }
    }

    fn latch_now(&mut self, now: u64) {
        self.latch_and_composite(now, now);
    }

    fn dirty(&self) -> Rc<Cell<bool>> {
        self.dirty.clone()
    }
}

#[cfg(test)]
#[path = "scene_tests.rs"]
mod tests;
