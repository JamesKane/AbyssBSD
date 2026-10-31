//! Map a layer surface, a bar across the top, and exit once its first frame
//! is shown: the layer-shell handshake, checked on a live compositor.
//!
//!     WAYLAND_DISPLAY=… cargo run -p surface --example layer_probe

use std::rc::{Rc, Weak};
use surface::layer::{anchor, Layer};
use surface::{Display, LayerConfig, LayerSurface, LayerSurfaceDelegate, RenderTarget};

struct Bar;

impl LayerSurfaceDelegate for Bar {
    fn render(&self, _s: &LayerSurface, target: &RenderTarget) {
        let cr = abyss_sys::Context::new(target.surface);
        cr.set_source_rgb(0.9, 0.9, 0.9);
        cr.paint();
    }
    fn did_render_frame(&self, s: &LayerSurface) {
        let (w, h) = s.size();
        println!("layer_probe: shown {w}x{h} at {}x", s.scale());
        s.display().stop()
    }
}

fn main() {
    let Some(d) = Display::connect() else {
        eprintln!("layer_probe: no compositor");
        std::process::exit(1)
    };
    let bar = Rc::new(Bar);
    let config = LayerConfig { layer: Layer::Top, namespace: "probe".into(), height: 22, anchor: anchor::TOP | anchor::LEFT | anchor::RIGHT, exclusive_zone: 22, ..LayerConfig::default() };
    let Some(_s) = LayerSurface::new(&d, &config, 1, true, Rc::downgrade(&bar) as Weak<dyn LayerSurfaceDelegate>) else {
        eprintln!("layer_probe: no layer shell");
        std::process::exit(1)
    };
    d.run()
}
