//! The desktop (Wallpaper.swift): the shell's BACKGROUND layer surface. Its
//! look is `desktop.ini`, followed as it changes, and it carries the
//! desktop icons: the boot volume and ~/Desktop, from the top-right down.
//!
//! The `desktop` domain, highest precedence first:
//!
//! ```text
//! image      = /path/to/wallpaper.png    PNG, scaled to cover
//! grad_top, grad_bot = #aarrggbb         a vertical gradient
//! bg         = #aarrggbb                 a flat fill
//! (none)                                 the theme's Jaguar "Aqua Blue"
//! show_icons = true | false              the desktop icons (default true)
//! ```
//!
//! The Desktop folder is `$ABYSS_DESKTOP_DIR`, else `$HOME/Desktop`.
//!
//! On a Mac the desktop *is* the Finder: a folder opened from it is a
//! Finder window, in this process. Until the Finder is ported (R6) the
//! opening is a hook the owner sets; a folder is logged as opened either way.

use crate::context_menu::open_context_menu;
use crate::desktop_icons::{desktop_entries, desktop_index, paint_desktop_icons};
use crate::finder_model::{finder_join, FinderEntry, FinderItemKind};
use crate::finder_ops::{finder_create_directory, finder_exists, finder_is_directory, finder_new_folder_name};
use crate::launcher;
use crate::live_menu::LiveMenu;
use crate::toolkit::Toolkit;
use abyss_sys::{Pattern, Surface};
use aquadraw::canvas::Canvas;
use aquadraw::color::Color;
use aquadraw::drawlist::DrawState;
use aquadraw::runner::Rect;
use menu_model::{Command, Enablement, Menu, MenuItem};
use pool_config::Config;
use std::cell::RefCell;
use std::os::fd::AsRawFd;
use std::rc::{Rc, Weak};
use std::time::Instant;
use surface::layer::{anchor, KeyboardInteractivity, Layer};
use surface::{Display, LayerConfig, LayerSurface, LayerSurfaceDelegate, PopupDelegate, RenderTarget};

#[derive(Clone, Debug, PartialEq)]
pub enum DesktopFill {
    DefaultAqua,
    Flat(Color),
    Gradient(Color, Color),
    Image(String),
}

impl DesktopFill {
    /// From the `desktop` domain, by the precedence above. A malformed
    /// colour falls through, never an error.
    pub fn from(c: &Config) -> DesktopFill {
        let s = |k| c.string("desktop", k);
        if let Some(img) = s("image").filter(|i| !i.is_empty()) {
            return DesktopFill::Image(img.into());
        }
        if let (Some(top), Some(bot)) = (s("grad_top").and_then(Color::css_hex), s("grad_bot").and_then(Color::css_hex)) {
            return DesktopFill::Gradient(top, bot);
        }
        s("bg").and_then(Color::css_hex).map_or(DesktopFill::DefaultAqua, DesktopFill::Flat)
    }

    /// A tag for the log (the live tests read it).
    pub fn kind(&self) -> &'static str {
        match self {
            DesktopFill::DefaultAqua => "default",
            DesktopFill::Flat(_) => "flat",
            DesktopFill::Gradient(..) => "gradient",
            DesktopFill::Image(_) => "image",
        }
    }
}

/// The theme's Jaguar backdrop (shell.dl).
pub fn paint_wallpaper(c: &mut Canvas, w: f64, h: f64) {
    c.paint_simple("wallpaper", Rect::new(0.0, 0.0, w, h), DrawState::NORMAL)
}

/// The desktop's fill, `w`×`h` points. An image that will not load falls
/// back to the default.
pub fn paint_desktop(c: &mut Canvas, w: f64, h: f64, fill: &DesktopFill) {
    match fill {
        DesktopFill::DefaultAqua => paint_wallpaper(c, w, h),
        DesktopFill::Flat(k) => {
            c.cr.set_source_rgba(k.r, k.g, k.b, k.a);
            c.cr.paint()
        }
        DesktopFill::Gradient(top, bot) => {
            let g = Pattern::linear(0.0, 0.0, 0.0, h);
            g.add_color_stop_rgba(0.0, top.r, top.g, top.b, top.a);
            g.add_color_stop_rgba(1.0, bot.r, bot.g, bot.b, bot.a);
            c.cr.set_source(&g);
            c.cr.paint()
        }
        DesktopFill::Image(path) => {
            if !paint_image_cover(c, w, h, path) {
                paint_wallpaper(c, w, h)
            }
        }
    }
}

/// A PNG scaled to *cover* (aspect kept, centre-cropped: the Mac's "Fill
/// Screen"). False if it cannot be loaded.
fn paint_image_cover(c: &mut Canvas, w: f64, h: f64, path: &str) -> bool {
    let Some(img) = Surface::from_png(path) else { return false };
    let (iw, ih) = (img.width() as f64, img.height() as f64);
    if iw <= 0.0 || ih <= 0.0 {
        return false;
    }
    let s = (w / iw).max(h / ih);
    let cr = c.cr;
    cr.save();
    cr.translate((w - iw * s) / 2.0, (h - ih * s) / 2.0);
    cr.scale(s, s);
    cr.set_source_surface(&img, 0.0, 0.0, true, false);
    cr.paint();
    cr.restore();
    true
}

const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const DOUBLE_CLICK_MS: u128 = 450;

fn log(msg: &str) {
    eprintln!("Wallpaper: {msg}")
}

/// The desktop's own commands (P10.8).
pub fn desktop_context_menu() -> Menu {
    Menu::new(
        "Desktop",
        vec![
            MenuItem::Command(Command::new("desktop.new-folder", "New Folder", "Make an untitled folder on the desktop.")),
            MenuItem::Separator,
            MenuItem::Command(Command::new("desktop.change-background", "Change Desktop Background…", "Choose the desktop picture or colour.")),
        ],
    )
}

/// The folder whose contents are on the desktop.
pub fn desktop_directory() -> Option<String> {
    if let Ok(d) = std::env::var("ABYSS_DESKTOP_DIR")
        && !d.is_empty()
    {
        return Some(d);
    }
    let dir = format!("{}/Desktop", std::env::var("HOME").ok()?);
    finder_is_directory(&dir).then_some(dir)
}

/// The name under the volume's icon (the machine's, as on a Mac).
pub const VOLUME_NAME: &str = "AbyssBSD HD";

type OpenFolder = Rc<dyn Fn(&str)>;

struct State {
    fill: DesktopFill,
    entries: Vec<FinderEntry>,
    selection: Option<usize>,
    pointer: (f64, f64),
    last_click: Option<(usize, Instant)>,
    context: Option<Rc<LiveMenu>>,
}

pub struct Wallpaper {
    me: Weak<Wallpaper>,
    toolkit: Rc<Toolkit>,
    layer: RefCell<Option<Rc<LayerSurface>>>,
    show_icons: bool,
    folder: Option<String>,
    state: RefCell<State>,
    watchers: RefCell<Vec<pool_config::Watcher>>,
    open_folder: RefCell<Option<OpenFolder>>,
}

impl Wallpaper {
    /// Map the desktop; None without layer-shell. `desktop.ini` is read now
    /// and followed.
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Option<Rc<Wallpaper>> {
        let config = pool_config::load("desktop", None).unwrap_or_default();
        let fill = DesktopFill::from(&config);
        log(&format!("applied {}", fill.kind()));
        let w = Rc::new_cyclic(|me| Wallpaper {
            me: me.clone(),
            toolkit: toolkit.clone(),
            layer: RefCell::new(None),
            show_icons: config.bool("desktop", "show_icons").unwrap_or(true),
            folder: desktop_directory(),
            state: RefCell::new(State { fill, entries: vec![], selection: None, pointer: (0.0, 0.0), last_click: None, context: None }),
            watchers: RefCell::default(),
            open_folder: RefCell::new(None),
        });
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let config = LayerConfig { layer: Layer::Background, namespace: "abyss.wallpaper".into(), anchor: anchor::ALL, exclusive_zone: -1, keyboard: KeyboardInteractivity::None, ..LayerConfig::default() };
        let ls = LayerSurface::new(display, &config, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&w) as Weak<dyn LayerSurfaceDelegate>)?;
        *w.layer.borrow_mut() = Some(ls);
        // A rewrite of desktop.ini repaints, with no polling.
        w.watch(display, None, |w| w.config_changed());
        if w.show_icons {
            w.reload_icons();
            // The same on the Desktop folder: a file dropped there appears.
            if let Some(dir) = w.folder.clone() {
                w.watch(display, Some(&dir), |w| w.folder_changed());
            }
        }
        Some(w)
    }

    fn watch(&self, display: &Rc<Display>, dir: Option<&str>, f: fn(&Wallpaper)) {
        let Ok(watcher) = pool_config::Watcher::new(dir) else { return };
        let fd = watcher.as_raw_fd();
        self.watchers.borrow_mut().push(watcher);
        let me = self.me.clone();
        display.add_fd(fd, move || {
            if let Some(w) = me.upgrade() {
                if let Some(x) = w.watchers.borrow().iter().find(|x| x.as_raw_fd() == fd) {
                    x.drain();
                }
                f(&w)
            }
        });
    }

    /// Where a folder opened from the desktop goes: the Finder hosted here.
    pub fn on_open_folder(&self, f: impl Fn(&str) + 'static) {
        *self.open_folder.borrow_mut() = Some(Rc::new(f))
    }

    pub fn layer(&self) -> Option<Rc<LayerSurface>> {
        self.layer.borrow().clone()
    }

    fn redraw(&self) {
        let l = self.layer();
        if let Some(l) = l {
            l.set_needs_display()
        }
    }

    fn reload_icons(&self) {
        let entries = desktop_entries(VOLUME_NAME, self.folder.as_deref(), false);
        log(&format!("{} icons", entries.len()));
        let mut s = self.state.borrow_mut();
        if s.selection.is_some_and(|i| i >= entries.len()) {
            s.selection = None
        }
        s.entries = entries;
    }

    fn folder_changed(&self) {
        let before: Vec<String> = self.state.borrow().entries.iter().map(|e| e.name.clone()).collect();
        self.reload_icons();
        if self.state.borrow().entries.iter().map(|e| &e.name).ne(before.iter()) {
            self.redraw()
        }
    }

    fn config_changed(&self) {
        let fill = DesktopFill::from(&pool_config::load("desktop", None).unwrap_or_default());
        if fill == self.state.borrow().fill {
            return;
        }
        log(&format!("applied {}", fill.kind()));
        self.state.borrow_mut().fill = fill;
        self.redraw()
    }

    /// Where icons may go: the output, less the menu bar's strip.
    fn icon_bounds(&self) -> Rect {
        let (w, h) = self.layer().map_or((0, 0), |l| l.size());
        let top = self.toolkit.theme.borrow().tokens.desktop_top_inset;
        Rect::new(0.0, top, w as f64, h as f64 - top)
    }

    /// What was double-clicked: a folder (or the volume) in a Finder
    /// window; anything else to the Launcher.
    fn activate(&self, i: usize) {
        let Some(entry) = self.state.borrow().entries.get(i).cloned() else { return };
        let path = match (&entry.kind, &self.folder) {
            (FinderItemKind::Disk, _) => "/".to_string(),
            (_, Some(dir)) => finder_join(dir, &entry.name),
            _ => return,
        };
        if !entry.is_container() {
            return log(&format!("{} ({path})", launcher::open(&path)));
        }
        log(&format!("opened {path}"));
        let f = self.open_folder.borrow().clone();
        if let Some(f) = f {
            f(&path)
        }
    }

    /// A right-click (P10.8): on bare desktop, the desktop's own menu. On an
    /// icon Jaguar shows the Finder's item menu; until there is one, it
    /// selects the icon and opens nothing, rather than the desktop's.
    fn open_context(&self) {
        let old = self.state.borrow_mut().context.take();
        if let Some(m) = old {
            m.close_all()
        }
        let (px, py) = self.state.borrow().pointer;
        let count = self.state.borrow().entries.len();
        let t = self.toolkit.theme.borrow().tokens.clone();
        if let Some(hit) = desktop_index(&t, px, py, count, self.icon_bounds()) {
            self.state.borrow_mut().selection = Some(hit);
            return self.redraw();
        }
        let Some(layer) = self.layer() else { return };
        let folder = self.folder.clone();
        let has_folder = folder.is_some();
        let me = self.me.clone();
        let m = open_context_menu(
            &self.toolkit,
            &desktop_context_menu(),
            "desktop",
            &|c| match c.verb.as_str() {
                "desktop.new-folder" if has_folder => Enablement::Enabled,
                "desktop.new-folder" => Enablement::Disabled("there is no Desktop folder".into()),
                _ => Enablement::Disabled("not available yet".into()),
            },
            &log,
            |(w, h), lm| layer.open_popup((px as i32, py as i32, 1, 1), w, h, Rc::downgrade(lm) as Weak<dyn PopupDelegate>),
            move |c| {
                let (Some(dir), "desktop.new-folder") = (&folder, c.verb.as_str()) else { return };
                let name = finder_new_folder_name(|n| finder_exists(&finder_join(dir, n)));
                // The folder's watcher redraws the icons.
                let path = finder_join(dir, &name);
                log(&if finder_create_directory(&path) { format!("new folder {path}") } else { format!("could not create {name}") })
            },
            move || {
                if let Some(w) = me.upgrade() {
                    w.state.borrow_mut().context = None
                }
            },
        );
        self.state.borrow_mut().context = m;
    }
}

impl LayerSurfaceDelegate for Wallpaper {
    fn render(&self, _s: &LayerSurface, target: &RenderTarget) {
        let bounds = self.icon_bounds();
        let s = self.state.borrow();
        self.toolkit.draw(target, |c, w, h| {
            paint_desktop(c, w, h, &s.fill);
            if self.show_icons {
                paint_desktop_icons(c, bounds, &s.entries, s.selection)
            }
        })
    }

    fn pointer_moved(&self, _s: &LayerSurface, x: f64, y: f64) {
        self.state.borrow_mut().pointer = (x, y)
    }

    fn pointer_button(&self, _s: &LayerSurface, button: u32, pressed: bool) {
        if !self.show_icons || !pressed {
            return;
        }
        if button == BTN_RIGHT {
            return self.open_context();
        }
        if button != BTN_LEFT {
            return;
        }
        let t = self.toolkit.theme.borrow().tokens.clone();
        let bounds = self.icon_bounds();
        let activate = {
            let mut s = self.state.borrow_mut();
            let (px, py) = s.pointer;
            match desktop_index(&t, px, py, s.entries.len(), bounds) {
                Some(hit) => {
                    let double = s.last_click.is_some_and(|(i, at)| i == hit && at.elapsed().as_millis() <= DOUBLE_CLICK_MS);
                    if double {
                        s.last_click = None;
                        Some(hit)
                    } else {
                        s.last_click = Some((hit, Instant::now()));
                        s.selection = Some(hit);
                        log(&format!("selected {}", s.entries[hit].name));
                        None
                    }
                }
                // A click on bare desktop deselects.
                None => {
                    s.last_click = None;
                    s.selection = None;
                    None
                }
            }
        };
        if let Some(i) = activate {
            self.activate(i)
        }
        self.redraw()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use abyss_sys::{Context, FORMAT_ARGB32};

    #[test]
    fn color_css_hex() {
        let rgb = Color::css_hex("#20304a").unwrap();
        assert!((rgb.r - 0x20 as f64 / 255.0).abs() < 1e-3 && (rgb.b - 0x4a as f64 / 255.0).abs() < 1e-3 && rgb.a == 1.0);
        let argb = Color::css_hex("#80ff0000").unwrap();
        assert!((argb.a - 0x80 as f64 / 255.0).abs() < 1e-3 && argb.r == 1.0 && argb.g == 0.0);
        assert_eq!(Color::css_hex("112233"), Color::css_hex("#112233"));
        assert_eq!(Color::css_hex("#xyz"), None);
        assert_eq!(Color::css_hex("#12345"), None);
    }

    #[test]
    fn desktop_style_precedence() {
        let mut c = Config::new();
        assert_eq!(DesktopFill::from(&c), DesktopFill::DefaultAqua);
        c.set("desktop", "bg", "#ff112233");
        assert_eq!(DesktopFill::from(&c).kind(), "flat");
        c.set("desktop", "grad_top", "#ff000000").set("desktop", "grad_bot", "#ffffffff");
        assert_eq!(DesktopFill::from(&c).kind(), "gradient");
        c.set("desktop", "image", "/tmp/wall.png");
        assert_eq!(DesktopFill::from(&c), DesktopFill::Image("/tmp/wall.png".into()));
        let mut bad = Config::new();
        bad.set("desktop", "bg", "not-a-color");
        assert_eq!(DesktopFill::from(&bad), DesktopFill::DefaultAqua);
    }

    /// B, G, R, A at (x, y) of `fill` painted `w`×`h`, on the default theme.
    fn sample(fill: &DesktopFill, w: i32, h: i32, at: &[(i32, i32)]) -> Vec<[u8; 4]> {
        let mut runner = aquadraw::scene::runner(1).expect("fonts");
        let mut theme = aquadraw::theme::Theme::default();
        theme.load_current(None, Some(&mut runner));
        let s = Surface::image(FORMAT_ARGB32, w, h);
        {
            let cr = Context::new(&s);
            let mut c = Canvas::new(&cr, &mut runner, &theme);
            paint_desktop(&mut c, w as f64, h as f64, fill);
        }
        let px = s.argb_pixels(w, h);
        at.iter().map(|&(x, y)| px[(y * w + x) as usize].to_le_bytes()).collect()
    }

    /// Opaque everywhere, blue over red, darker at the bottom.
    #[test]
    fn wallpaper_paints_opaque_blue() {
        let (w, h) = (64, 48);
        let at = [(0, 0), (w - 1, 0), (w / 2, h / 2), (0, h - 1), (w - 1, h - 1), (w / 2, 0)];
        let px = sample(&DesktopFill::DefaultAqua, w, h, &at);
        for p in &px[..5] {
            assert_eq!(p[3], 255);
            assert!(p[0] > p[2], "blue over red: {p:?}")
        }
        assert!(px[3][0] < px[5][0] || px[4][0] < px[5][0], "deeper at the bottom");
    }

    #[test]
    fn paint_desktop_flat_and_gradient() {
        assert_eq!(sample(&DesktopFill::Flat(Color::new(1.0, 0.0, 0.0, 1.0)), 32, 32, &[(16, 16)])[0][..3], [0, 0, 255]);
        let g = DesktopFill::Gradient(Color::new(0.0, 0.0, 0.0, 1.0), Color::new(1.0, 1.0, 1.0, 1.0));
        let p = sample(&g, 32, 32, &[(16, 1), (16, 30)]);
        assert!(p[0][2] < p[1][2]);
    }

    #[test]
    fn paint_desktop_image_and_fallback() {
        let path = std::env::temp_dir().join(format!("aqua-wall-{}.png", std::process::id()));
        let path = path.to_str().unwrap().to_string();
        let img = Surface::image(FORMAT_ARGB32, 4, 4);
        {
            let cr = Context::new(&img);
            cr.set_source_rgba(0.0, 1.0, 0.0, 1.0);
            cr.paint();
        }
        assert!(img.write_png(&path));
        let p = sample(&DesktopFill::Image(path.clone()), 16, 16, &[(8, 8)])[0];
        assert_eq!((p[1], p[2]), (255, 0), "green, not red");
        let f = sample(&DesktopFill::Image("/no/such.png".into()), 16, 16, &[(8, 8)])[0];
        assert!(f[0] > f[2], "the fallback is blue");
        let _ = std::fs::remove_file(&path);
    }
}
