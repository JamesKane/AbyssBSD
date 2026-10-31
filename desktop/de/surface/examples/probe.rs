//! Each surface protocol, checked on a live compositor, one at a time:
//!
//!     WAYLAND_DISPLAY=… cargo run -p surface --example probe -- layer|lock|toplevels|idle|shot|paste|copy
//!
//! - `layer`: map a bar across the top, exit once its first frame shows.
//! - `lock`: lock the session, and once the compositor says it is locked,
//!   unlock it.
//! - `toplevels`: list the open windows, as the Dock hears them.
//! - `idle`: wait for one second of nobody touching the seat.
//! - `shot`: capture the first output, and say its size and centre pixel.
//! - `copy TEXT`: open a window; a click in it puts TEXT on the clipboard,
//!   served until the window is closed.
//! - `paste`: open a window; a click in it prints what the clipboard holds.
//!   (The selection is sent only to a client with the keyboard: one with
//!   no surface is never told.)

use std::cell::Cell;
use std::rc::{Rc, Weak};
use surface::layer::{anchor, Layer};
use surface::{Window, WindowDelegate, Display, ForeignToplevels, IdleNotification, LayerConfig, LayerSurface, LayerSurfaceDelegate, LockSurface, RenderTarget, SessionLock, SessionLockDelegate};

fn grey(target: &RenderTarget) {
    let cr = abyss_sys::Context::new(target.surface);
    cr.set_source_rgb(0.9, 0.9, 0.9);
    cr.paint();
}

struct Bar;

impl LayerSurfaceDelegate for Bar {
    fn render(&self, _s: &LayerSurface, target: &RenderTarget) {
        grey(target)
    }
    fn did_render_frame(&self, s: &LayerSurface) {
        let (w, h) = s.size();
        println!("probe: layer shown {w}x{h} at {}x", s.scale());
        s.display().stop()
    }
}

struct Locker {
    lock: std::cell::RefCell<Option<Rc<SessionLock>>>,
    display: Rc<Display>,
    drawn: Cell<u32>,
}

impl SessionLockDelegate for Locker {
    fn render(&self, s: &LockSurface, target: &RenderTarget) {
        self.drawn.set(self.drawn.get() + 1);
        let (w, h) = s.size();
        println!("probe: lock surface {} drawn {w}x{h}", s.index);
        grey(target)
    }
    fn locked(&self) {
        println!("probe: locked, after {} lock surface frame(s)", self.drawn.get());
        let l = self.lock.borrow().clone();
        if let Some(l) = l {
            l.unlock()
        }
        println!("probe: unlocked");
        self.display.stop()
    }
    fn finished(&self) {
        println!("probe: the compositor refused the lock");
        self.display.stop()
    }
}

/// `copy` with text, `paste` without.
struct Copier {
    text: Option<String>,
}

impl WindowDelegate for Copier {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        grey(target)
    }
    fn pointer_button(&self, w: &Window, _button: u32, pressed: bool) {
        let Some(c) = w.display().clipboard().filter(|_| pressed) else { return };
        match &self.text {
            Some(t) if c.write_text(t) => println!("probe: copied"),
            Some(_) => println!("probe: could not copy"),
            None => match c.read_text() {
                Some(t) => println!("probe: pasted {t:?}"),
                None => println!("probe: the clipboard is empty"),
            },
        }
    }
}

fn main() {
    let what = std::env::args().nth(1).unwrap_or_default();
    let Some(d) = Display::connect() else {
        eprintln!("probe: no compositor");
        std::process::exit(1)
    };
    let fail = |m: &str| -> ! {
        eprintln!("probe: {m}");
        std::process::exit(1)
    };
    match what.as_str() {
        "layer" => {
            let bar = Rc::new(Bar);
            let config = LayerConfig { layer: Layer::Top, namespace: "probe".into(), height: 22, anchor: anchor::TOP | anchor::LEFT | anchor::RIGHT, exclusive_zone: 22, ..LayerConfig::default() };
            let _s = LayerSurface::new(&d, &config, 1, true, Rc::downgrade(&bar) as Weak<dyn LayerSurfaceDelegate>).unwrap_or_else(|| fail("no layer shell"));
            d.run()
        }
        "lock" => {
            let l = Rc::new(Locker { lock: Default::default(), display: d.clone(), drawn: Cell::new(0) });
            let lock = SessionLock::new(&d, Rc::downgrade(&l) as Weak<dyn SessionLockDelegate>).unwrap_or_else(|| fail("no session lock"));
            *l.lock.borrow_mut() = Some(lock);
            d.run()
        }
        "toplevels" => {
            let ft = ForeignToplevels::new(&d, |_| {}).unwrap_or_else(|| fail("no foreign toplevels"));
            d.roundtrip();
            d.roundtrip();
            for t in ft.current() {
                println!("probe: toplevel {} \"{}\"{}", t.app_id, t.title, if t.activated { " activated" } else { "" })
            }
        }
        "idle" => {
            let dd = d.clone();
            let _n = IdleNotification::new(&d, 1000, move || {
                println!("probe: idle");
                dd.stop()
            }, || {})
            .unwrap_or_else(|| fail("no idle notifier"));
            d.run()
        }
        "shot" => {
            let c = d.capture_output(0, false, std::time::Duration::from_secs(5)).unwrap_or_else(|e| fail(&e.to_string()));
            let px = |x: usize, y: usize| &c.pixels[(y * c.width + x) * 4..(y * c.width + x) * 4 + 4];
            println!("probe: captured {}x{}, B,G,R,A at a corner {:?} and the centre {:?}", c.width, c.height, px(2, c.height - 3), px(c.width / 2, c.height / 2));
            if let (Some(x), Some(y)) = (std::env::args().nth(2).and_then(|v| v.parse().ok()), std::env::args().nth(3).and_then(|v| v.parse().ok())) {
                println!("probe: at {x},{y} {:?}", px(x, y))
            }
        }
        "copy" | "paste" => {
            let me = Rc::new(Copier { text: std::env::args().nth(2).filter(|_| what == "copy") });
            let _w = Window::new(&d, "probe", "org.abyssbsd.probe", 200, 150, 1, true, Rc::downgrade(&me) as Weak<dyn WindowDelegate>).unwrap_or_else(|| fail("no window"));
            d.run()
        }
        _ => fail("say layer, lock, toplevels, idle, shot, paste or copy"),
    }
}
