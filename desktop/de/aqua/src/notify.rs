//! The notification centre (NotifyCenter.swift and Toast.swift, P7.4).
//!
//! Jaguar had no system-wide notification style (Growl came later, and
//! third-party), so the toast is built from the era's own vocabulary: a
//! translucent rounded panel in the sheet idiom, a bold summary over a
//! lighter body, under the menu bar at the top right.
//!
//! The centre hosts a `notify` service and draws what arrives on an OVERLAY
//! layer surface. Two properties it must have:
//!
//! - **It never takes focus**: `keyboard_interactivity: none`, so a toast
//!   appearing while you type cannot swallow keystrokes.
//! - **It covers only itself**: an OVERLAY surface takes pointer input
//!   wherever it extends, so it is sized to the stack and destroyed when the
//!   last toast goes.
//!
//! A jailed app never holds this service's socket: it asks the portal,
//! which relays here.

use crate::toolkit::Toolkit;
use aquadraw::canvas::Canvas;
use aquadraw::drawlist::{DrawState, Role};
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use aquadraw::tokens::ThemeTokens;
use current_ipc::{Msg, Server};
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use std::time::Instant;
use surface::layer::{anchor, KeyboardInteractivity, Layer};
use surface::{Display, LayerConfig, LayerSurface, LayerSurfaceDelegate, RenderTarget};

/// One notification on screen.
#[derive(Clone, Debug, PartialEq)]
pub struct Toast {
    pub id: u64,
    pub summary: String,
    pub body: Option<String>,
    /// Monotonic seconds when it should go.
    pub expires_at: f64,
}

/// Wrap `text` to `width` at spaces, at most `max_lines`; the last line is
/// elided rather than dropped, so text is never lost without a sign.
pub fn toast_wrap(text: &str, width: f64, max_lines: usize, measure: &mut dyn FnMut(&str) -> f64) -> Vec<String> {
    if text.is_empty() || max_lines == 0 {
        return vec![];
    }
    let (mut lines, mut current) = (Vec::<String>::new(), String::new());
    for word in text.split(' ').filter(|w| !w.is_empty()) {
        let candidate = if current.is_empty() { word.to_string() } else { format!("{current} {word}") };
        if current.is_empty() || measure(&candidate) <= width {
            current = candidate
        } else {
            lines.push(std::mem::replace(&mut current, word.to_string()));
            if lines.len() == max_lines {
                break;
            }
        }
    }
    if lines.len() < max_lines && !current.is_empty() {
        lines.push(current.clone())
    }
    if lines.len() == max_lines && !current.is_empty() && lines.last() != Some(&current) {
        lines[max_lines - 1] += "…"
    }
    lines
}

/// The height one toast needs, given its wrapped body.
pub fn toast_height(t: &ThemeTokens, body_lines: usize) -> f64 {
    t.toast_base_height + body_lines as f64 * t.toast_line_height
}

/// Where each toast sits, newest first, stacked downward; and the surface
/// size that holds them. Sized to the stack on purpose (see above).
pub fn toast_layout(t: &ThemeTokens, heights: &[f64]) -> (Vec<Rect>, f64, f64) {
    let mut y = 0.0;
    let rects: Vec<Rect> = heights
        .iter()
        .map(|h| {
            let r = Rect::new(0.0, y, t.toast_width, *h);
            y += h + t.toast_gap;
            r
        })
        .collect();
    let total = if rects.is_empty() { 0.0 } else { y - t.toast_gap };
    (rects, t.toast_width, total)
}

/// Which toast a click at `y` lands on; None in the gaps.
pub fn toast_index(y: f64, rects: &[Rect]) -> Option<usize> {
    rects.iter().position(|r| y >= r.y && y < r.y + r.h)
}

/// Everything still live at `now`, in display order.
pub fn live_toasts(toasts: &[Toast], now: f64) -> Vec<Toast> {
    toasts.iter().filter(|t| t.expires_at > now).cloned().collect()
}

/// The body's wrapped lines, as the toast draws them.
pub fn body_lines(t: &ThemeTokens, toast: &Toast, measure: &mut dyn FnMut(&str) -> f64) -> Vec<String> {
    toast.body.as_deref().map_or(vec![], |b| toast_wrap(b, t.toast_width - t.toast_pad_x * 2.0 - 20.0, t.toast_max_body_lines as usize, measure))
}

/// One toast: the theme's panel and mark, a bold summary, a lighter body.
pub fn paint_toast(c: &mut Canvas, r: Rect, toast: &Toast, lines: &[String]) {
    let t = c.theme.tokens.clone();
    c.paint_simple("toast", r, DrawState::NORMAL);
    c.paint_simple("toast.mark", Rect::new(r.x + t.toast_pad_x, r.y + t.toast_pad_y + 1.0, 13.0, 13.0), DrawState::NORMAL);
    let x = r.x + t.toast_pad_x + 20.0;
    c.text_left(&toast.summary, x, r.y + t.toast_pad_y + 11.0, t.body_text, t.toast_summary_size, Style::Bold, Role::Interface);
    for (i, line) in lines.iter().enumerate() {
        c.text_left(line, x, r.y + t.toast_pad_y + 11.0 + (i + 1) as f64 * t.toast_line_height, t.body_text.with_a(0.75), t.toast_body_size, Style::Regular, Role::Interface)
    }
}

/// The golden scene's stack: two toasts at the top right of `w`.
pub fn paint_sample(c: &mut Canvas, w: f64) {
    let t = c.theme.tokens.clone();
    let sample = [Toast { id: 1, summary: "Build finished".into(), body: Some("all tests green".into()), expires_at: f64::INFINITY }, Toast { id: 2, summary: "Disk ejected".into(), body: Some("AbyssBSD HD may now be safely removed".into()), expires_at: f64::INFINITY }];
    let lines: Vec<Vec<String>> = sample.iter().map(|s| body_lines(&t, s, &mut |x| c.text_width(x, t.toast_body_size, Style::Regular, Role::Interface))).collect();
    let heights: Vec<f64> = lines.iter().map(|l| toast_height(&t, l.len())).collect();
    let (rects, _, _) = toast_layout(&t, &heights);
    for ((s, l), r) in sample.iter().zip(&lines).zip(rects) {
        paint_toast(c, Rect::new(w - t.toast_width - 12.0, r.y + 8.0, r.w, r.h), s, l)
    }
}

fn log(s: &str) {
    eprintln!("Notify: {s}")
}

/// Monotonic seconds: a toast must not outlive its timeout because the wall
/// clock moved.
fn monotonic_now() -> f64 {
    static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

/// The surface the stack is drawn on, while there is one.
struct Stack {
    center: Weak<NotifyCenter>,
    layer: RefCell<Option<Rc<LayerSurface>>>,
    pointer_y: Cell<f64>,
}

impl LayerSurfaceDelegate for Stack {
    fn render(&self, _s: &LayerSurface, target: &RenderTarget) {
        let Some(c) = self.center.upgrade() else { return };
        let toasts = c.toasts.borrow().clone();
        let rects = c.toolkit.draw(target, |canvas, _w, _h| {
            let t = canvas.theme.tokens.clone();
            let lines: Vec<Vec<String>> = toasts.iter().map(|x| body_lines(&t, x, &mut |s| canvas.text_width(s, t.toast_body_size, Style::Regular, Role::Interface))).collect();
            let heights: Vec<f64> = lines.iter().map(|l| toast_height(&t, l.len())).collect();
            let (rects, _, _) = toast_layout(&t, &heights);
            for ((toast, l), r) in toasts.iter().zip(&lines).zip(&rects) {
                paint_toast(canvas, *r, toast, l)
            }
            rects
        });
        *c.rects.borrow_mut() = rects
    }
    fn pointer_moved(&self, _s: &LayerSurface, _x: f64, y: f64) {
        self.pointer_y.set(y)
    }
    /// Click to dismiss.
    fn pointer_button(&self, _s: &LayerSurface, _button: u32, pressed: bool) {
        let Some(c) = self.center.upgrade().filter(|_| pressed) else { return };
        let id = toast_index(self.pointer_y.get(), &c.rects.borrow()).and_then(|i| c.toasts.borrow().get(i).map(|t| t.id));
        if let Some(id) = id {
            c.dismiss(id)
        }
    }
}

pub struct NotifyCenter {
    me: Weak<NotifyCenter>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    toasts: RefCell<Vec<Toast>>,
    rects: RefCell<Vec<Rect>>,
    next_id: Cell<u64>,
    server: RefCell<Option<Server>>,
    stack: RefCell<Option<Rc<Stack>>>,
    default_timeout: f64,
}

impl NotifyCenter {
    /// What one app can put on screen: notifications are shared, and fifty
    /// of them must not own the display.
    pub const MAX_VISIBLE: usize = 5;

    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Rc<NotifyCenter> {
        Rc::new_cyclic(|me| NotifyCenter { me: me.clone(), display: display.clone(), toolkit: toolkit.clone(), toasts: RefCell::default(), rects: RefCell::default(), next_id: Cell::new(1), server: RefCell::new(None), stack: RefCell::new(None), default_timeout: 5.0 })
    }

    /// Bind the service into the run loop, and the timer that expires toasts.
    pub fn start(&self, service: &str) -> bool {
        let s = match Server::new(service).and_then(|s| s.set_nonblocking(true).map(|_| s)) {
            Ok(s) => s,
            Err(e) => {
                log(&format!("no notify service ({e:?})"));
                return false;
            }
        };
        log(&format!("serving {}", s.path));
        let me = self.me.clone();
        self.display.add_fd(s.fd(), move || {
            if let Some(c) = me.upgrade() {
                c.accept_one()
            }
        });
        *self.server.borrow_mut() = Some(s);
        let me = self.me.clone();
        self.display.add_timer(500, move || {
            if let Some(c) = me.upgrade() {
                c.tick()
            }
        });
        true
    }

    fn accept_one(&self) {
        let server = self.server.borrow_mut().take();
        let Some(server) = server else { return };
        let _ = server.serve_one(&mut |request: &mut Msg| {
            let mut reply = Msg::new();
            match request.string("method").unwrap_or("notify") {
                "notify" => {
                    let summary = request.string("summary").unwrap_or("").to_string();
                    if summary.is_empty() {
                        reply.set_bool("ok", false);
                        reply.set_string("error", "notify needs a summary");
                        return reply;
                    }
                    let timeout = request.u64("timeout").unwrap_or(0) as f64;
                    let id = self.post(&summary, request.string("body").map(String::from), if timeout > 0.0 { timeout } else { self.default_timeout });
                    reply.set_bool("ok", true);
                    reply.set_u64("id", id)
                }
                "dismiss" => {
                    if let Some(id) = request.u64("id") {
                        self.dismiss(id)
                    }
                    reply.set_bool("ok", true)
                }
                _ => {
                    reply.set_bool("ok", false);
                    reply.set_string("error", "unknown method")
                }
            }
            reply
        });
        *self.server.borrow_mut() = Some(server)
    }

    /// Show a notification; its id. Oldest out first when the screen is full.
    pub fn post(&self, summary: &str, body: Option<String>, timeout: f64) -> u64 {
        let id = self.next_id.replace(self.next_id.get() + 1);
        {
            let mut t = self.toasts.borrow_mut();
            t.push(Toast { id, summary: summary.into(), body, expires_at: monotonic_now() + timeout });
            let excess = t.len().saturating_sub(Self::MAX_VISIBLE);
            t.drain(..excess);
        }
        log(&format!("posted #{id}: {summary}"));
        self.rebuild();
        id
    }

    pub fn dismiss(&self, id: u64) {
        self.toasts.borrow_mut().retain(|t| t.id != id);
        log(&format!("dismissed #{id}"));
        self.rebuild()
    }

    fn tick(&self) {
        let (before, live) = {
            let t = self.toasts.borrow();
            (t.len(), live_toasts(&t, monotonic_now()))
        };
        if live.len() != before {
            *self.toasts.borrow_mut() = live;
            self.rebuild()
        }
    }

    /// Create, replace or drop the surface to match what is on screen.
    /// Replaced rather than resized: toasts change seconds apart, and a
    /// resize path nothing else needs is not worth it.
    fn rebuild(&self) {
        let old = self.stack.borrow_mut().take();
        if let Some(l) = old.and_then(|s| s.layer.borrow_mut().take()) {
            l.close()
        }
        if self.toasts.borrow().is_empty() {
            return log("surface released (no toasts)");
        }
        let t = self.toolkit.theme.borrow().tokens.clone();
        let heights: Vec<f64> = {
            let mut runner = self.toolkit.runner.borrow_mut();
            self.toasts.borrow().iter().map(|x| toast_height(&t, body_lines(&t, x, &mut |s| runner.text.text_width(s, t.toast_body_size, Style::Regular, Role::Interface)).len())).collect()
        };
        let (rects, w, h) = toast_layout(&t, &heights);
        *self.rects.borrow_mut() = rects;
        let config = LayerConfig { layer: Layer::Overlay, namespace: "abyss.notify".into(), width: w as i32, height: h as i32, anchor: anchor::TOP | anchor::RIGHT, exclusive_zone: 0, keyboard: KeyboardInteractivity::None, margin: (t.toast_top_inset as i32, t.toast_right_inset as i32, 0, 0) };
        let stack = Rc::new(Stack { center: self.me.clone(), layer: RefCell::new(None), pointer_y: Cell::new(0.0) });
        if let Some(l) = LayerSurface::new(&self.display, &config, 1, true, Rc::downgrade(&stack) as Weak<dyn LayerSurfaceDelegate>) {
            l.set_needs_display();
            *stack.layer.borrow_mut() = Some(l)
        }
        *self.stack.borrow_mut() = Some(stack)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn by_chars(s: &str) -> f64 {
        s.chars().count() as f64
    }

    #[test]
    fn a_body_wraps_at_spaces_and_the_last_line_is_elided() {
        assert_eq!(toast_wrap("one two three", 7.0, 4, &mut by_chars), ["one two", "three"]);
        assert_eq!(toast_wrap("aa bb cc dd", 2.0, 2, &mut by_chars), ["aa", "bb…"]);
        assert_eq!(toast_wrap("averyverylongword", 3.0, 2, &mut by_chars), ["averyverylongword"], "a word too long for a line is a line");
    }

    #[test]
    fn the_stack_is_sized_to_its_toasts_and_hit_where_drawn() {
        let t = ThemeTokens::default();
        let (rects, w, h) = toast_layout(&t, &[40.0, 60.0]);
        assert_eq!((w, h), (t.toast_width, 100.0 + t.toast_gap));
        assert_eq!(toast_index(45.0 + t.toast_gap, &rects), Some(1));
        assert_eq!(toast_index(40.0 + t.toast_gap / 2.0, &rects), None, "the gap is no one's");
        let toasts = [Toast { id: 1, summary: "a".into(), body: None, expires_at: 1.0 }, Toast { id: 2, summary: "b".into(), body: None, expires_at: 3.0 }];
        assert_eq!(live_toasts(&toasts, 2.0).len(), 1);
    }
}
