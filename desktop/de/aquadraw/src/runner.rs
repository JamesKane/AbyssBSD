//! DrawListRunner (DrawList.swift, "Running"): the same cairo call sequence,
//! the same Double arithmetic in the same order, and the same caches (glow
//! and halo masks, noise tiles) — a mask is made once per key, as in Swift.

use crate::color::{mix_oklch, Color};
use crate::drawlist::*;
use abyss_sys::{self as ffi, Context, Matrix, Pattern, Surface};
use crate::text::{Style, Text};
use crate::tokens::{ThemeTokens, COLOR_KEYS, METRIC_KEYS};
use std::collections::HashMap;
use std::f64::consts::PI;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect { x, y, w, h }
    }
}

pub struct DrawContext {
    pub rect: Rect,
    pub state: DrawState,
    pub label: String,
    pub placeholder: String,
    pub parameters: HashMap<String, f64>,
    pub colors: HashMap<String, Color>,
}

impl DrawContext {
    pub fn new(rect: Rect, state: DrawState, label: &str) -> DrawContext {
        DrawContext {
            rect,
            state,
            label: label.to_string(),
            placeholder: String::new(),
            parameters: HashMap::new(),
            colors: HashMap::new(),
        }
    }
}

#[derive(Clone, PartialEq, Eq, Hash)]
struct GlowKey {
    shape: String,
    w: i32,
    h: i32,
    radius: i32,
    scale: i32,
}

#[derive(Clone, PartialEq, Eq, Hash)]
struct HaloKey {
    s: String,
    px: i32,
    style: i32,
    role: i32,
    radius: i32,
    scale: i32,
    tracking: u64,
}

pub struct Runner {
    pub text: Text,
    /// The loaded theme's tokens by index (`ColorRef::Token`,
    /// `Operand::Metric`), and its parameters, which a list reads as
    /// `$name` when the widget passes none.
    colors: Vec<Color>,
    metrics: Vec<f64>,
    font_size: f64,
    theme_parameters: HashMap<String, f64>,
    glow_cache: HashMap<GlowKey, Surface>,
    halo_cache: HashMap<HaloKey, (Surface, f64, f64)>,
    noise_tiles: HashMap<u64, Surface>,
    pub glows_computed: usize,
}

fn set_color(cr: &Context, c: Color) {
    cr.set_source_rgba(c.r, c.g, c.b, c.a);
}

fn clear_paint(cr: &Context) {
    cr.set_source_rgba(0.0, 0.0, 0.0, 1.0);
}

/// Swift `min`/`max` on Double: `y < x ? y : x` / `y >= x ? y : x`.
fn smin(x: f64, y: f64) -> f64 {
    if y < x {
        y
    } else {
        x
    }
}
fn smax(x: f64, y: f64) -> f64 {
    if y >= x {
        y
    } else {
        x
    }
}

// MARK: Draw's path helpers (Drawing.swift)

fn rounded_rect(cr: &Context, r: Rect, radius: f64) {
    let rad = smin(radius, smin(r.w, r.h) / 2.0);
    let deg = PI / 180.0;
    cr.new_sub_path();
    cr.arc(r.x + r.w - rad, r.y + rad, rad, -90.0 * deg, 0.0);
    cr.arc(r.x + r.w - rad, r.y + r.h - rad, rad, 0.0, 90.0 * deg);
    cr.arc(r.x + rad, r.y + r.h - rad, rad, 90.0 * deg, 180.0 * deg);
    cr.arc(r.x + rad, r.y + rad, rad, 180.0 * deg, 270.0 * deg);
    cr.close_path();
}

fn rounded_rect_top(cr: &Context, r: Rect, radius: f64) {
    let rad = smin(radius, smin(r.w, r.h) / 2.0);
    let deg = PI / 180.0;
    cr.new_sub_path();
    cr.move_to(r.x, r.y + r.h);
    cr.line_to(r.x, r.y + rad);
    cr.arc(r.x + rad, r.y + rad, rad, 180.0 * deg, 270.0 * deg);
    cr.arc(r.x + r.w - rad, r.y + rad, rad, -90.0 * deg, 0.0);
    cr.line_to(r.x + r.w, r.y + r.h);
    cr.close_path();
}

fn rounded_rect_bottom(cr: &Context, r: Rect, radius: f64) {
    let rad = smin(radius, smin(r.w, r.h) / 2.0);
    let deg = PI / 180.0;
    cr.new_sub_path();
    cr.move_to(r.x, r.y);
    cr.line_to(r.x + r.w, r.y);
    cr.line_to(r.x + r.w, r.y + r.h - rad);
    cr.arc(r.x + r.w - rad, r.y + r.h - rad, rad, 0.0, 90.0 * deg);
    cr.arc(r.x + rad, r.y + r.h - rad, rad, 90.0 * deg, 180.0 * deg);
    cr.line_to(r.x, r.y);
    cr.close_path();
}

impl Runner {
    /// A runner drawing with the compiled Jaguar until told otherwise.
    pub fn new(text: Text) -> Runner {
        let mut r = Runner {
            text,
            colors: vec![],
            metrics: vec![],
            font_size: 0.0,
            theme_parameters: HashMap::new(),
            glow_cache: HashMap::new(),
            halo_cache: HashMap::new(),
            noise_tiles: HashMap::new(),
            glows_computed: 0,
        };
        r.use_theme(&ThemeTokens::jaguar(), &HashMap::new());
        r
    }

    /// Draw with `t` from now on (Theme.use's half that is the runner's):
    /// its tokens, parameters, role families, case and tracking. Masks made
    /// from the old theme's shapes and fonts go; noise tiles stay, a seed
    /// and a strength being the same picture in every theme.
    pub fn use_theme(&mut self, t: &ThemeTokens, parameters: &HashMap<String, f64>) {
        self.colors = (0..COLOR_KEYS.len()).map(|i| t.color(i)).collect();
        self.metrics = (0..METRIC_KEYS.len()).map(|i| t.metric(i)).collect();
        self.font_size = t.font_size;
        self.theme_parameters = parameters.clone();
        self.glow_cache.clear();
        self.halo_cache.clear();
        self.text.use_role_style(&t.role_upper, &t.role_tracking);
        self.text.use_roles(&[
            (Role::Interface, t.font_interface.as_str()),
            (Role::Chrome, t.font_chrome.as_str()),
            (Role::Readout, t.font_readout.as_str()),
            (Role::Mono, t.font_mono.as_str()),
        ]);
    }

    fn parameter(&self, p: &str, ctx: &DrawContext) -> f64 {
        ctx.parameters.get(p).or_else(|| self.theme_parameters.get(p)).copied().unwrap_or(0.0)
    }

    pub fn run(&mut self, list: &DrawList, cr: &Context, ctx: &DrawContext) {
        let mut shape: Option<&Shape> = None;
        let mut more: Vec<&Shape> = Vec::new();
        let mut depth = 0;
        cr.save();
        cr.translate(ctx.rect.x, ctx.rect.y);
        for step in &list.steps {
            if let Some(w) = step.when {
                let matches = if w.is_empty() { ctx.state.is_empty() } else { w.intersects(ctx.state) };
                if !matches {
                    continue;
                }
            }
            if let Some(u) = step.unless {
                if u.intersects(ctx.state) {
                    continue;
                }
            }
            match &step.op {
                Op::Shape(s) => {
                    shape = Some(s);
                    more.clear();
                }
                Op::AndShape(s) => {
                    if shape.is_none() {
                        shape = Some(s)
                    } else {
                        more.push(s)
                    }
                }
                Op::Fill(p) => {
                    let Some(s) = shape else { continue };
                    self.path(s, cr, ctx, &more);
                    self.set_paint(p, s, cr, ctx);
                    cr.fill();
                    clear_paint(cr);
                }
                Op::Stroke(p, width, round, dash) => {
                    let Some(s) = shape else { continue };
                    self.path(s, cr, ctx, &more);
                    self.set_paint(p, s, cr, ctx);
                    cr.set_line_width(self.eval(width, ctx));
                    if !dash.is_empty() {
                        cr.set_dash(dash, 0.0);
                    }
                    if *round {
                        cr.set_line_cap(ffi::LINE_CAP_ROUND);
                        cr.set_line_join(ffi::LINE_JOIN_ROUND);
                    }
                    cr.stroke();
                    clear_paint(cr);
                    if !dash.is_empty() {
                        cr.set_dash(&[], 0.0);
                    }
                    if *round {
                        cr.set_line_cap(ffi::LINE_CAP_BUTT);
                        cr.set_line_join(ffi::LINE_JOIN_MITER);
                    }
                }
                Op::Bevel(width, hi, lo) => {
                    let Some(Shape::Rect(x, y, w, h, _, _)) = shape else { continue };
                    let r = Rect::new(self.eval(x, ctx), self.eval(y, ctx), self.eval(w, ctx), self.eval(h, ctx));
                    let wd = self.eval(width, ctx);
                    let (hi, lo) = (self.resolve(hi, ctx), self.resolve(lo, ctx));
                    bevel(cr, r, wd, hi, lo);
                }
                Op::InnerShadow(c, size, extent) => {
                    let Some(s) = shape else { continue };
                    let b = self.bounds(s, ctx);
                    cr.save();
                    self.path(s, cr, ctx, &[]);
                    cr.clip();
                    let col = self.resolve(c, ctx);
                    let sz = self.eval(size, ctx);
                    let g = Pattern::linear(0.0, b.y, 0.0, b.y + sz);
                    g.add_color_stop_rgba(0.0, col.r, col.g, col.b, col.a);
                    g.add_color_stop_rgba(1.0, col.r, col.g, col.b, 0.0);
                    let eh = match extent {
                        Some(e) => self.eval(e, ctx),
                        None => sz,
                    };
                    cr.rectangle(b.x, b.y, b.w, eh);
                    cr.set_source(&g);
                    cr.fill();
                    drop(g);
                    cr.restore();
                }
                Op::Glow(c, radius, strength) => {
                    let Some(s) = shape else { continue };
                    let col = self.resolve(c, ctx);
                    let r = self.eval(radius, ctx);
                    let st = smax(0.0, smin(4.0, self.eval(strength, ctx)));
                    self.glow(s, cr, ctx, col, r, st, 0.0, 0.0);
                }
                Op::Shadow(c, dx, dy, blur) => {
                    let Some(s) = shape else { continue };
                    let col = self.resolve(c, ctx);
                    let bl = self.eval(blur, ctx);
                    let (dx, dy) = (self.eval(dx, ctx), self.eval(dy, ctx));
                    self.glow(s, cr, ctx, col, bl, 1.0, dx, dy);
                }
                Op::Rules(kind, from, every, until, p, width) => {
                    let Some(s) = shape else { continue };
                    let b = self.bounds(s, ctx);
                    let f = self.eval(from, ctx);
                    let e = self.eval(every, ctx);
                    let u = until.as_ref().map(|u| self.eval(u, ctx));
                    let w = self.eval(width, ctx);
                    self.rules(*kind, b, f, e, u, p, s, w, cr, ctx);
                }
                Op::Text(t) => self.draw_text(t, cr, ctx),
                Op::Move(dx, dy) => cr.translate(self.eval(dx, ctx), self.eval(dy, ctx)),
                Op::Rotate(a) => cr.rotate(self.eval(a, ctx)),
                Op::Scale(sx, sy) => cr.scale(self.eval(sx, ctx), self.eval(sy, ctx)),
                Op::Push => {
                    cr.save();
                    depth += 1;
                }
                Op::Pop => {
                    if depth > 0 {
                        cr.restore();
                        depth -= 1;
                    }
                }
                Op::Clip => {
                    let Some(s) = shape else { continue };
                    self.path(s, cr, ctx, &more);
                    cr.clip();
                }
            }
        }
        while depth > 0 {
            cr.restore();
            depth -= 1;
        }
        cr.restore();
    }

    /// Clip `cr` to the shape `list` describes (its shapes, the `and`s
    /// included) and **leave the clip set**, for a caller that draws more
    /// inside it (a window's gadgets and title inside its frame). The
    /// caller saves and restores around it.
    pub fn clip(&mut self, list: &DrawList, cr: &Context, ctx: &DrawContext) {
        let (mut shape, mut more): (Option<&Shape>, Vec<&Shape>) = (None, vec![]);
        for step in &list.steps {
            match &step.op {
                Op::Shape(s) => {
                    shape = Some(s);
                    more.clear();
                }
                Op::AndShape(s) => {
                    if shape.is_none() {
                        shape = Some(s)
                    } else {
                        more.push(s)
                    }
                }
                _ => {}
            }
        }
        let Some(s) = shape else { return };
        cr.save();
        cr.translate(ctx.rect.x, ctx.rect.y);
        // The path is in device space: it outlives the restore.
        self.path(s, cr, ctx, &more);
        cr.restore();
        cr.clip();
    }

    // MARK: operands and colours

    pub fn eval(&mut self, o: &Operand, ctx: &DrawContext) -> f64 {
        match o {
            Operand::Number(d) => *d,
            Operand::Width => ctx.rect.w,
            Operand::Height => ctx.rect.h,
            Operand::Metric(k) => self.metrics[*k],
            Operand::Parameter(p) => self.parameter(p, ctx),
            Operand::TextWidth(size, role) => {
                let sz = self.eval(size, ctx);
                self.text.text_width(&ctx.label, sz, Style::Regular, Role::from_raw(*role))
            }
            Operand::Negate(a) => -self.eval(a, ctx),
            Operand::Minimum(a, b) => {
                let (l, r) = (self.eval(a, ctx), self.eval(b, ctx));
                smin(l, r)
            }
            Operand::Maximum(a, b) => {
                let (l, r) = (self.eval(a, ctx), self.eval(b, ctx));
                smax(l, r)
            }
            Operand::Binary(a, op, b) => {
                let l = self.eval(a, ctx);
                let r = self.eval(b, ctx);
                match op {
                    '+' => l + r,
                    '-' => l - r,
                    '*' => l * r,
                    _ => {
                        if r == 0.0 {
                            0.0
                        } else {
                            l / r
                        }
                    }
                }
            }
        }
    }

    pub fn resolve(&self, c: &ColorRef, ctx: &DrawContext) -> Color {
        match c {
            ColorRef::Literal(col) => *col,
            ColorRef::Token(k) => self.colors[*k],
            ColorRef::Parameter(p) => ctx.colors.get(p).copied().unwrap_or(Color::new(0.0, 0.0, 0.0, 0.0)),
            ColorRef::Alpha(base, a) => self.resolve(base, ctx).with_a(*a),
            ColorRef::Shift(base, d) => {
                let b = self.resolve(base, ctx);
                let d = *d;
                if d < 0.0 {
                    Color::new(smax(0.0, b.r + d), smax(0.0, b.g + d), smax(0.0, b.b + d), b.a)
                } else {
                    Color::new(smin(1.0, b.r + d), smin(1.0, b.g + d), smin(1.0, b.b + d), b.a)
                }
            }
            ColorRef::Fade(base, p) => {
                let b = self.resolve(base, ctx);
                b.with_a(b.a * self.parameter(p, ctx))
            }
            ColorRef::Mix(a, b, t) => mix_oklch(self.resolve(a, ctx), self.resolve(b, ctx), *t),
        }
    }

    // MARK: shapes and paints

    fn path(&mut self, s: &Shape, cr: &Context, ctx: &DrawContext, more: &[&Shape]) {
        cr.new_path();
        self.subpath(s, cr, ctx);
        for sub in more {
            self.subpath(sub, cr, ctx);
        }
    }

    fn subpath(&mut self, s: &Shape, cr: &Context, ctx: &DrawContext) {
        cr.new_sub_path();
        match s {
            Shape::Rect(x, y, w, h, r, corners) => {
                let rect = Rect::new(self.eval(x, ctx), self.eval(y, ctx), self.eval(w, ctx), self.eval(h, ctx));
                let rad = match r {
                    Some(r) => self.eval(r, ctx),
                    None => 0.0,
                };
                if rad <= 0.0 {
                    cr.rectangle(rect.x, rect.y, rect.w, rect.h);
                } else {
                    match corners {
                        Corners::All => rounded_rect(cr, rect, rad),
                        Corners::Top => rounded_rect_top(cr, rect, rad),
                        Corners::Bottom => rounded_rect_bottom(cr, rect, rad),
                    }
                }
            }
            Shape::Ellipse(x, y, w, h) => {
                let ew = self.eval(w, ctx);
                let eh = self.eval(h, ctx);
                if !(ew > 0.0 && eh > 0.0) {
                    return;
                }
                cr.save();
                let tx = self.eval(x, ctx) + ew / 2.0;
                let ty = self.eval(y, ctx) + eh / 2.0;
                cr.translate(tx, ty);
                cr.scale(ew / 2.0, eh / 2.0);
                cr.arc(0.0, 0.0, 1.0, 0.0, 2.0 * PI);
                cr.restore();
            }
            Shape::Circle(cx, cy, r) => {
                let (x, y, r) = (self.eval(cx, ctx), self.eval(cy, ctx), self.eval(r, ctx));
                cr.arc(x, y, r, 0.0, 2.0 * PI);
            }
            Shape::Arc(cx, cy, r, a0, a1) => {
                let v = [self.eval(cx, ctx), self.eval(cy, ctx), self.eval(r, ctx), self.eval(a0, ctx), self.eval(a1, ctx)];
                cr.arc(v[0], v[1], v[2], v[3], v[4]);
            }
            Shape::Path(segs, closed) => {
                for seg in segs {
                    match seg {
                        PathSegment::Move(x, y) => {
                            let (x, y) = (self.eval(x, ctx), self.eval(y, ctx));
                            cr.move_to(x, y)
                        }
                        PathSegment::Line(x, y) => {
                            let (x, y) = (self.eval(x, ctx), self.eval(y, ctx));
                            cr.line_to(x, y)
                        }
                        PathSegment::Curve(x1, y1, x2, y2, x, y) => {
                            let v = [
                                self.eval(x1, ctx),
                                self.eval(y1, ctx),
                                self.eval(x2, ctx),
                                self.eval(y2, ctx),
                                self.eval(x, ctx),
                                self.eval(y, ctx),
                            ];
                            cr.curve_to(v[0], v[1], v[2], v[3], v[4], v[5]);
                        }
                        PathSegment::Arc(cx, cy, r, a0, a1) => {
                            let v = [self.eval(cx, ctx), self.eval(cy, ctx), self.eval(r, ctx), self.eval(a0, ctx), self.eval(a1, ctx)];
                            cr.arc(v[0], v[1], v[2], v[3], v[4]);
                        }
                    }
                }
                if *closed {
                    cr.close_path();
                }
            }
        }
    }

    fn bounds(&mut self, s: &Shape, ctx: &DrawContext) -> Rect {
        match s {
            Shape::Rect(x, y, w, h, _, _) | Shape::Ellipse(x, y, w, h) => {
                Rect::new(self.eval(x, ctx), self.eval(y, ctx), self.eval(w, ctx), self.eval(h, ctx))
            }
            Shape::Circle(cx, cy, r) | Shape::Arc(cx, cy, r, _, _) => {
                let rr = self.eval(r, ctx);
                Rect::new(self.eval(cx, ctx) - rr, self.eval(cy, ctx) - rr, rr * 2.0, rr * 2.0)
            }
            Shape::Path(segs, _) => {
                let (mut xs, mut ys): (Vec<f64>, Vec<f64>) = (Vec::new(), Vec::new());
                for seg in segs {
                    match seg {
                        PathSegment::Move(x, y) | PathSegment::Line(x, y) => {
                            xs.push(self.eval(x, ctx));
                            ys.push(self.eval(y, ctx));
                        }
                        PathSegment::Curve(x1, y1, x2, y2, x, y) => {
                            let v = [self.eval(x1, ctx), self.eval(x2, ctx), self.eval(x, ctx)];
                            xs.extend(v);
                            let v = [self.eval(y1, ctx), self.eval(y2, ctx), self.eval(y, ctx)];
                            ys.extend(v);
                        }
                        PathSegment::Arc(cx, cy, r, _, _) => {
                            let (x, y, rr) = (self.eval(cx, ctx), self.eval(cy, ctx), self.eval(r, ctx));
                            xs.extend([x - rr, x + rr]);
                            ys.extend([y - rr, y + rr]);
                        }
                    }
                }
                let lo = |v: &[f64]| v.iter().copied().reduce(smin);
                let hi = |v: &[f64]| v.iter().copied().reduce(smax);
                let x0 = lo(&xs).unwrap_or(0.0);
                let y0 = lo(&ys).unwrap_or(0.0);
                Rect::new(x0, y0, hi(&xs).unwrap_or(0.0) - x0, hi(&ys).unwrap_or(0.0) - y0)
            }
        }
    }

    fn add_stops(&self, pat: &Pattern, st: &Stops, ctx: &DrawContext) {
        for (o, c) in st {
            let col = self.resolve(c, ctx);
            pat.add_color_stop_rgba(*o, col.r, col.g, col.b, col.a);
        }
    }

    fn set_paint(&mut self, p: &Paint, s: &Shape, cr: &Context, ctx: &DrawContext) {
        match p {
            Paint::Solid(c) => set_color(cr, self.resolve(c, ctx)),
            Paint::Vertical(st) => {
                let b = self.bounds(s, ctx);
                let pat = Pattern::linear(0.0, b.y, 0.0, b.y + b.h);
                self.add_stops(&pat, st, ctx);
                cr.set_source(&pat);
            }
            Paint::Linear(x0, y0, x1, y1, st) => {
                let v = [self.eval(x0, ctx), self.eval(y0, ctx), self.eval(x1, ctx), self.eval(y1, ctx)];
                let pat = Pattern::linear(v[0], v[1], v[2], v[3]);
                self.add_stops(&pat, st, ctx);
                cr.set_source(&pat);
            }
            Paint::Radial(x0, y0, r0, x1, y1, r1, st) => {
                let v = [
                    self.eval(x0, ctx),
                    self.eval(y0, ctx),
                    self.eval(r0, ctx),
                    self.eval(x1, ctx),
                    self.eval(y1, ctx),
                    self.eval(r1, ctx),
                ];
                let pat = Pattern::radial(v[0], v[1], v[2], v[3], v[4], v[5]);
                self.add_stops(&pat, st, ctx);
                cr.set_source(&pat);
            }
            Paint::Conic(cx, cy, r, st) => {
                let (cx, cy, r) = (self.eval(cx, ctx), self.eval(cy, ctx), self.eval(r, ctx));
                let resolved: Vec<(f64, Color)> = st.iter().map(|(o, c)| (*o, self.resolve(c, ctx))).collect();
                let pat = conic_mesh(cx, cy, r, resolved);
                cr.set_source(&pat);
            }
            Paint::Stripes(angle, w1, c1, w2, c2) => {
                let a = smax(1.0, self.eval(w1, ctx));
                let b = smax(1.0, self.eval(w2, ctx));
                let across = angle % 360.0 == 90.0;
                let upright = across || angle % 360.0 == 0.0;
                let n = (a + b).ceil() as i32;
                let tile = Surface::image(ffi::FORMAT_ARGB32, if across { 1 } else { n }, if across { n } else { 1 });
                let tc = Context::new(&tile);
                set_color(&tc, self.resolve(c1, ctx));
                if across {
                    tc.rectangle(0.0, 0.0, 1.0, a)
                } else {
                    tc.rectangle(0.0, 0.0, a, 1.0)
                }
                tc.fill();
                set_color(&tc, self.resolve(c2, ctx));
                if across {
                    tc.rectangle(0.0, a, 1.0, b)
                } else {
                    tc.rectangle(a, 0.0, b, 1.0)
                }
                tc.fill();
                drop(tc);
                let pat = Pattern::for_surface(&tile);
                pat.set_extend_repeat();
                if !upright {
                    let m = Matrix::rotate(-angle * PI / 180.0);
                    pat.set_matrix(&m);
                }
                cr.set_source(&pat);
            }
            Paint::Noise(seed, alpha) => {
                if let Some(pat) = self.noise_pattern(*seed, *alpha) {
                    cr.set_source(&pat);
                }
            }
            Paint::Dots(spacing, radius, c) => {
                let sc = self.text.render_scale as f64;
                let sp = smax(2.0, self.eval(spacing, ctx));
                let r = self.eval(radius, ctx);
                let n = (sp * sc).round() as i32;
                let tile = Surface::image(ffi::FORMAT_ARGB32, n, n);
                let tc = Context::new(&tile);
                set_color(&tc, self.resolve(c, ctx));
                tc.arc(n as f64 / 2.0, n as f64 / 2.0, r * sc, 0.0, 2.0 * PI);
                tc.fill();
                drop(tc);
                let pat = Pattern::for_surface(&tile);
                pat.set_extend_repeat();
                pat.set_matrix(&Matrix::scale(sc, sc));
                cr.set_source(&pat);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn rules(&mut self, kind: RuleKind, b: Rect, from: f64, every: f64, until: Option<f64>, p: &Paint, s: &Shape, width: f64, cr: &Context, ctx: &DrawContext) {
        if !(every > 0.0) {
            return;
        }
        self.set_paint(p, s, cr, ctx);
        cr.set_line_width(width);
        let mut n = 0;
        match kind {
            RuleKind::Across => {
                let mut y = b.y + from;
                while y < b.y + b.h && n < 10_000 {
                    cr.move_to(b.x, y);
                    cr.line_to(b.x + b.w, y);
                    cr.stroke();
                    y += every;
                    n += 1;
                }
            }
            RuleKind::Slant => {
                let mut x = from;
                let limit = until.unwrap_or(b.x + b.w);
                while x < limit && n < 10_000 {
                    cr.move_to(x, b.y + b.h);
                    cr.line_to(x + b.h, b.y);
                    cr.stroke();
                    x += every;
                    n += 1;
                }
            }
        }
        clear_paint(cr);
    }

    fn noise_pattern(&mut self, seed: u32, alpha: f64) -> Option<Pattern> {
        let key = (seed as u64) << 16 | (alpha * 255.0) as u64;
        self.noise_tiles.entry(key).or_insert_with(|| {
            let s = Surface::image(ffi::FORMAT_A8, 128, 128);
            s.flush();
            s.noise_a8(128, 128, seed, (alpha * 255.0) as i32);
            s.mark_dirty();
            s
        });
        let tile = self.noise_tiles.get(&key)?;
        let rgba = Surface::image(ffi::FORMAT_ARGB32, 128, 128);
        let tc = Context::new(&rgba);
        tc.set_source_rgba(1.0, 1.0, 1.0, 1.0);
        tc.mask_surface(tile, 0.0, 0.0);
        drop(tc);
        let pat = Pattern::for_surface(&rgba);
        pat.set_extend_repeat();
        Some(pat)
    }

    #[allow(clippy::too_many_arguments)]
    fn glow(&mut self, s: &Shape, cr: &Context, ctx: &DrawContext, c: Color, radius: f64, strength: f64, dx: f64, dy: f64) {
        if !(radius > 0.0) {
            return;
        }
        let b = self.bounds(s, ctx);
        let scale = self.text.render_scale;
        let pad = radius * 2.0;
        let key = GlowKey { shape: format!("{s:?}"), w: b.w as i32, h: b.h as i32, radius: radius as i32, scale };
        if !self.glow_cache.contains_key(&key) {
            let sw = ((b.w + 2.0 * pad) * scale as f64).ceil() as i32;
            let sh = ((b.h + 2.0 * pad) * scale as f64).ceil() as i32;
            let mask = Surface::image(ffi::FORMAT_A8, sw, sh);
            let mc = Context::new(&mask);
            mc.scale(scale as f64, scale as f64);
            mc.translate(pad - b.x, pad - b.y);
            self.path(s, &mc, ctx, &[]);
            mc.set_source_rgba(0.0, 0.0, 0.0, 1.0);
            mc.fill();
            drop(mc);
            mask.flush();
            mask.blur_a8(sw, sh, (radius * scale as f64) as i32);
            mask.mark_dirty();
            self.glow_cache.insert(key.clone(), mask);
            self.glows_computed += 1;
        }
        let Some(mask) = self.glow_cache.get(&key) else { return };
        cr.save();
        let pat = Pattern::for_surface(mask);
        let mut m = Matrix::scale(scale as f64, scale as f64);
        m.translate(pad - b.x - dx, pad - b.y - dy);
        pat.set_matrix(&m);
        set_color(cr, c.with_a(smin(1.0, c.a * strength)));
        cr.mask(&pat);
        drop(pat);
        cr.restore();
    }

    #[allow(clippy::too_many_arguments)]
    fn text_halo(&mut self, s: &str, t: &TextOp, x: f64, y: f64, size: f64, style: Style, c: Color, radius: f64, cr: &Context) {
        if !(radius > 0.0) || s.is_empty() {
            return;
        }
        let sc = self.text.render_scale as f64;
        let px = self.text.px(size);
        let mut glyphs = self.text.shape(s, px, style, t.role);
        if t.tracking != 0.0 {
            for g in glyphs.iter_mut() {
                g.x_advance += t.tracking * sc;
            }
        }
        let width = Text::width(&glyphs) / sc;
        let m = Text::metrics(px, t.role);
        let asc = m.ascent / sc;
        let desc = m.descent / sc;
        let baseline = if t.baseline { y } else { y + (asc - desc) / 2.0 };
        let left = match t.align {
            TextAlign::Left => x,
            TextAlign::Center => x - width / 2.0,
            TextAlign::Right => x - width,
        };
        let pad = radius * 2.0;
        let key = HaloKey {
            s: s.to_string(),
            px,
            style: style as i32,
            role: t.role as i32,
            radius: (radius * 4.0) as i32,
            scale: sc as i32,
            tracking: t.tracking.to_bits(),
        };
        if !self.halo_cache.contains_key(&key) {
            let sw = ((width + 2.0 * pad) * sc).ceil() as i32;
            let sh = ((asc + desc + 2.0 * pad) * sc).ceil() as i32;
            let mask = Surface::image(ffi::FORMAT_A8, sw, sh);
            let mc = Context::new(&mask);
            mc.scale(sc, sc);
            mc.set_source_rgba(0.0, 0.0, 0.0, 1.0);
            self.text.draw_shaped(&mc, &glyphs, pad, pad + asc, px);
            drop(mc);
            mask.flush();
            mask.blur_a8(sw, sh, (radius * sc) as i32);
            mask.mark_dirty();
            self.halo_cache.insert(key.clone(), (mask, pad, asc));
        }
        let Some((mask, p, a)) = self.halo_cache.get(&key) else { return };
        cr.save();
        let pat = Pattern::for_surface(mask);
        let mut mt = Matrix::scale(sc, sc);
        mt.translate(p - left, p + a - baseline);
        pat.set_matrix(&mt);
        set_color(cr, c);
        cr.mask(&pat);
        drop(pat);
        cr.restore();
    }

    fn draw_text(&mut self, t: &TextOp, cr: &Context, ctx: &DrawContext) {
        let mut s = match &t.content {
            TextContent::Label => ctx.label.clone(),
            TextContent::Literal(l) => l.clone(),
        };
        let mut col = self.resolve(&t.color, ctx);
        if s.is_empty() && !ctx.placeholder.is_empty() {
            if let Some(ph) = &t.placeholder {
                s = ctx.placeholder.clone();
                col = self.resolve(ph, ctx);
            }
        }
        if t.upper {
            s = s.to_uppercase();
        }
        let size = match &t.size {
            Some(o) => self.eval(o, ctx),
            None => self.font_size,
        };
        let x = self.eval(&t.x, ctx);
        let y = self.eval(&t.y, ctx);
        let style = if t.bold { Style::Bold } else { Style::Regular };
        if let Some(halo) = &t.halo {
            let hc = self.resolve(halo, ctx);
            let hr = self.eval(&t.halo_radius, ctx);
            self.text_halo(&s, t, x, y, size, style, hc, hr, cr);
        }
        if let Some(g) = &t.ghost {
            let ghost = match g {
                Ghost::Eights => s.chars().map(|c| if c.is_numeric() { '8' } else { c }).collect(),
                Ghost::Literal(l) => l.clone(),
            };
            let ghost = if t.upper { ghost.to_uppercase() } else { ghost };
            self.text_run(t, cr, &ghost, col.with_a(col.a * t.ghost_alpha), x, y, size, style);
        }
        self.text_run(t, cr, &s, col, x, y, size, style);
    }

    #[allow(clippy::too_many_arguments)]
    fn text_run(&mut self, t: &TextOp, cr: &Context, s: &str, c: Color, x: f64, y: f64, size: f64, style: Style) {
        // The plain cases are Draw's own text calls.
        if t.tracking == 0.0 && t.align == TextAlign::Center && !t.baseline {
            self.text.draw_centered(cr, s, x, y, c, size, style, t.role);
            return;
        }
        if t.tracking == 0.0 && t.align == TextAlign::Left && t.baseline {
            self.text.draw_left(cr, s, x, y, c, size, style, t.role);
            return;
        }
        let px = self.text.px(size);
        let mut glyphs = self.text.shape(s, px, style, t.role);
        let sc = self.text.render_scale as f64;
        if t.tracking != 0.0 {
            let tr = t.tracking * sc;
            for g in glyphs.iter_mut() {
                g.x_advance += tr;
            }
        }
        let width = Text::width(&glyphs) / sc;
        let baseline = if t.baseline {
            y
        } else {
            let m = Text::metrics(px, t.role);
            y + (m.ascent - m.descent) / 2.0 / sc
        };
        let left = match t.align {
            TextAlign::Left => x,
            TextAlign::Center => x - width / 2.0,
            TextAlign::Right => x - width,
        };
        set_color(cr, c);
        self.text.draw_shaped(cr, &glyphs, left, baseline, px);
    }
}

/// The bevel that is the whole of MUI.
fn bevel(cr: &Context, r: Rect, width: f64, hi: Color, lo: Color) {
    if !(width > 0.0) {
        return;
    }
    set_color(cr, hi);
    cr.rectangle(r.x, r.y, r.w, width);
    cr.fill();
    cr.rectangle(r.x, r.y + width, width, r.h - width);
    cr.fill();
    set_color(cr, lo);
    cr.rectangle(r.x + width, r.y + r.h - width, r.w - width, width);
    cr.fill();
    cr.rectangle(r.x + r.w - width, r.y + width, width, r.h - 2.0 * width);
    cr.fill();
}

/// A conic sweep as quarter-or-smaller Coons patches around the centre.
fn conic_mesh(cx: f64, cy: f64, r: f64, stops: Vec<(f64, Color)>) -> Pattern {
    let pat = Pattern::mesh();
    let mut st = stops;
    st.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    if st[0].0 > 0.0 {
        let c = st[0].1;
        st.insert(0, (0.0, c));
    }
    if st[st.len() - 1].0 < 1.0 {
        let c = st[st.len() - 1].1;
        st.push((1.0, c));
    }
    let lerp = |a: Color, b: Color, t: f64| {
        Color::new(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
    };
    for i in 0..st.len() - 1 {
        let (o0, c0) = st[i];
        let (o1, c1) = st[i + 1];
        if !(o1 > o0) {
            continue;
        }
        let pieces = ((o1 - o0) * 4.0).ceil() as i64;
        for k in 0..pieces {
            let f0 = k as f64 / pieces as f64;
            let f1 = (k + 1) as f64 / pieces as f64;
            let a0 = (o0 + (o1 - o0) * f0) * 2.0 * PI;
            let a1 = (o0 + (o1 - o0) * f1) * 2.0 * PI;
            let col0 = lerp(c0, c1, f0);
            let col1 = lerp(c0, c1, f1);
            let kk = 4.0 / 3.0 * ((a1 - a0) / 4.0).tan();
            let x0 = cx + r * a0.cos();
            let y0 = cy + r * a0.sin();
            let x3 = cx + r * a1.cos();
            let y3 = cy + r * a1.sin();
            pat.mesh_begin_patch();
            pat.mesh_move_to(cx, cy);
            pat.mesh_line_to(x0, y0);
            pat.mesh_curve_to(
                x0 - kk * r * a0.sin(),
                y0 + kk * r * a0.cos(),
                x3 + kk * r * a1.sin(),
                y3 - kk * r * a1.cos(),
                x3,
                y3,
            );
            pat.mesh_line_to(cx, cy);
            for (corner, c) in [(0u32, col0), (1, col0), (2, col1), (3, col1)] {
                pat.mesh_set_corner_color_rgba(corner, c.r, c.g, c.b, c.a);
            }
            pat.mesh_end_patch();
        }
    }
    pat
}
