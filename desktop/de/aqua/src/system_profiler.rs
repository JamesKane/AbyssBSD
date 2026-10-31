//! System Profiler: what this computer is (SystemProfilerApp.swift; Jaguar's
//! Apple System Profiler, fastfetch's report).
//!
//! One window: the machine's name and who is using it, then two boxes of
//! `Label  value` rows: Software (OS, kernel, uptime, packages, shell,
//! desktop, window manager, theme, terminal, locale) and Hardware (host,
//! CPU, GPU, memory, swap, disk, displays, address, battery). Copy (⌘C)
//! puts the fastfetch-shaped text on the clipboard; Refresh (⌘R) reads it
//! all again.
//!
//! The reading is here, the parsing in `system-facts` (pure, tested). Every
//! reading has a fallback for a machine unlike a PC (the device tree's
//! model where there is no SMBIOS, the bound DRM driver where the GPU is no
//! PCI device), and one that fails stays **unknown**, shown as such.

use crate::toolkit::Toolkit;
use abyss_sys::{self as ffi, Context, Surface};
use aquadraw::canvas::Canvas;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeHit, Gadget};
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::{Rect, Runner};
use aquadraw::text::Style;
use aquadraw::theme::Theme;
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use std::time::Duration;
use surface::display_config::{DisplayConfigurator, Head};
use surface::{Display, KeyEvent, KeyModifiers, RenderTarget, Window, WindowDelegate};
use system_facts::{format, parse, Fact, Section, SystemFacts};
use vents::{sysctl, Battery};

// MARK: - Gathering

fn run(argv: &[&str]) -> Option<String> {
    let r = spawn::run(argv);
    r.succeeded().then(|| r.stdout_text())
}

fn env(k: &str) -> Option<String> {
    std::env::var(k).ok().filter(|v| !v.is_empty())
}

/// Everything, read now. `displays` comes from the compositor
/// (wlr-output-management), or None.
pub fn gather(displays: Option<&[Head]>) -> SystemFacts {
    let me = ffi::vents::user_name(ffi::users::uid()).unwrap_or_else(|| "user".into());
    let (sysname, urelease, umachine) = ffi::platform::uname();
    let arch = sysctl::string("hw.machine_arch").unwrap_or(umachine);
    let release = sysctl::string("kern.osrelease").unwrap_or(urelease);
    let mut f = vec![];
    let mut add = |s: Section, label: &str, v: Option<String>| f.push(Fact::new(s, label, v.as_deref()));
    let sw = Section::Software;

    // Software
    add(sw, "OS", Some(format!("AbyssBSD on {sysname} {release} {arch}")));
    add(sw, "Kernel", Some(format!("{sysname} {release}")));
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64);
    let uptime = sysctl::raw("kern.boottime").and_then(|raw| parse::boot_seconds(&raw)).map(|boot| now - boot).or_else(|| std::fs::read_to_string("/proc/uptime").ok().and_then(|t| t.split(' ').next()?.parse::<f64>().ok()).map(|s| s as i64));
    add(sw, "Uptime", uptime.map(format::uptime));
    add(sw, "Packages", run(&["pkg", "info", "-q"]).map(|t| format!("{} (pkg)", t.lines().filter(|l| !l.is_empty()).count())));
    add(sw, "Shell", env("SHELL").map(|s| s.rsplit('/').next().unwrap_or("").to_string()));
    add(sw, "Desktop", Some("AbyssBSD Aqua".into()));
    add(sw, "Window Manager", env("WAYLAND_DISPLAY").map(|_| "undertow".into()));
    add(sw, "Theme", Some(crate::prefs::appearance_catalogue::current().name));
    add(sw, "Terminal", Some("Terminal".into()));
    add(sw, "Locale", Some(env("LC_ALL").or_else(|| env("LANG")).unwrap_or_else(|| "C".into())));

    // Hardware
    let hw = Section::Hardware;
    let machine = vents::kenv::machine().map(|(maker, product)| format!("{maker} {product}")).or_else(|| run(&["ofwdump", "-P", "model", "-R", "/"]).and_then(|t| parse::ofw_model(&t).map(String::from)));
    add(hw, "Host", machine);
    let cpu = sysctl::string("hw.model").map(|m| system_facts::trimmed(&m).to_string()).filter(|m| !m.is_empty()).map(|mut s| {
        if let Some(n) = sysctl::int("hw.ncpu") {
            s += &format!(" ({n})")
        }
        if let Some(mhz) = sysctl::int("dev.cpu.0.freq").filter(|m| *m > 0) {
            s += &format!(" @ {}", format::frequency(mhz))
        }
        s
    });
    add(hw, "CPU", cpu);
    let mut gpus = run(&["pciconf", "-lv"]).map(|t| parse::pci_displays(&t)).unwrap_or_default();
    if gpus.is_empty()
        && let Some(d) = run(&["kldstat"]).and_then(|k| parse::drm_driver(&k))
    {
        gpus = vec![d.to_string()]
    }
    add(hw, "GPU", (!gpus.is_empty()).then(|| gpus.join(", ")));
    let page = |n: &str| sysctl::int(n).map(|v| v as u64);
    let mem = (|| {
        let (ps, pages, free, inactive) = (page("hw.pagesize")?, page("vm.stats.vm.v_page_count")?, page("vm.stats.vm.v_free_count")?, page("vm.stats.vm.v_inactive_count")?);
        let laundry = page("vm.stats.vm.v_laundry_count").unwrap_or(0);
        Some(format::usage(parse::memory_used(ps, pages, free, inactive, laundry), ps * pages))
    })();
    add(hw, "Memory", mem);
    let swapinfo = run(&["swapinfo", "-k"]);
    add(hw, "Swap", swapinfo.as_deref().and_then(parse::swap).map(|(used, total)| format::usage(used, total)).or(swapinfo.map(|_| "none".into())));
    let disk = ffi::platform::volume_usage("/").map(|(total, used)| format::usage(used, total) + &ffi::platform::fs_type("/").map_or(String::new(), |t| format!(" - {t}")));
    add(hw, "Disk (/)", disk);
    let shown: Vec<String> = displays
        .unwrap_or(&[])
        .iter()
        .filter(|h| h.enabled)
        .filter_map(|h| {
            let m = h.current?;
            let hz = (m.refresh_mhz as f64 / 1000.0).round() as i64;
            Some(format!("{} {}×{} @ {hz} Hz{}", h.name, m.width, m.height, if h.scale != 1.0 { format!(" (×{})", h.scale) } else { String::new() }))
        })
        .collect();
    add(hw, "Display", (!shown.is_empty()).then(|| shown.join(", ")));
    let local = vents::network::interfaces().into_iter().find(|i| !i.loopback && !i.ipv4.is_empty()).map(|i| format!("{}/{} ({})", i.ipv4[0].address, i.ipv4[0].prefix, i.name));
    add(hw, "Local IP", local);
    let battery = match Battery::read() {
        Some(b) => Some(format!("{}{}", b.percent.map_or("unknown charge".into(), |p| format!("{p}%")), if b.is_charging { " (charging)" } else { "" })),
        None => sysctl::is_supported().then(|| "none".into()),
    };
    add(hw, "Battery", battery);
    SystemFacts { title: format!("{me}@{}", ffi::platform::hostname()), facts: f }
}

// MARK: - Layout and paint

pub const ROW_HEIGHT: f64 = 19.0;
pub const WIDTH: i32 = 620;

/// The window's height for `facts`: every row, both boxes, the buttons.
pub fn height_for(title_bar: f64, facts: &SystemFacts) -> f64 {
    title_bar + 104.0 + facts.facts.len() as f64 * ROW_HEIGHT + 2.0 * 44.0 + 56.0
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProfilerLayout {
    pub icon: Rect,
    pub boxes: Vec<(Section, Rect)>,
    pub rows: Vec<Rect>,
    pub copy: Rect,
    pub refresh: Rect,
}

impl ProfilerLayout {
    pub fn new(title_bar: f64, w: f64, facts: &SystemFacts) -> ProfilerLayout {
        let top = title_bar;
        let (mut boxes, mut rows) = (vec![], vec![]);
        let mut y = top + 104.0;
        for section in [Section::Software, Section::Hardware] {
            let n = facts.facts.iter().filter(|f| f.section == section).count();
            let b = Rect::new(20.0, y, w - 40.0, n as f64 * ROW_HEIGHT + 32.0);
            rows.extend((0..n).map(|i| Rect::new(b.x + 12.0, b.y + 22.0 + i as f64 * ROW_HEIGHT, b.w - 24.0, ROW_HEIGHT)));
            boxes.push((section, b));
            y = b.y + b.h + 12.0
        }
        ProfilerLayout { icon: Rect::new(24.0, top + 18.0, 64.0, 64.0), boxes, rows, copy: Rect::new(w - 20.0 - 100.0 - 12.0 - 100.0, y + 6.0, 100.0, 22.0), refresh: Rect::new(w - 20.0 - 100.0, y + 6.0, 100.0, 22.0) }
    }
}

pub fn paint_system_profiler(c: &mut Canvas, w: f64, h: f64, facts: &SystemFacts) -> ProfilerLayout {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, "System Profiler", false, true);
    let t = c.theme.tokens.clone();
    c.set_color(t.content_background);
    c.cr.rectangle(0.0, t.title_bar_height, w, h - t.title_bar_height);
    c.cr.fill();
    let l = ProfilerLayout::new(t.title_bar_height, w, facts);
    c.icon("icon.displays", l.icon);
    let x = l.icon.x + l.icon.w + 18.0;
    c.text_left(facts.value("Host").unwrap_or("This Computer"), x, l.icon.y + 26.0, t.body_text, 20.0, Style::Bold, Role::Interface);
    c.text_left(&format!("{} — {}", facts.title, facts.value("OS").unwrap_or("AbyssBSD")), x, l.icon.y + 50.0, t.secondary_text, 12.0, Style::Regular, Role::Interface);
    let mut rows = l.rows.iter();
    for (section, b) in &l.boxes {
        c.group_box(*b, section.as_str());
        for fact in facts.facts.iter().filter(|f| f.section == *section) {
            let Some(r) = rows.next() else { break };
            let lw = c.text_width(&fact.label, 12.0, Style::Bold, Role::Interface);
            c.text_left(&fact.label, r.x + 120.0 - lw, r.y + 14.0, t.body_text, 12.0, Style::Bold, Role::Interface);
            c.text_left(fact.value.as_deref().unwrap_or("unknown"), r.x + 132.0, r.y + 14.0, if fact.value.is_none() { t.secondary_text } else { t.body_text }, 12.0, Style::Regular, Role::Interface)
        }
    }
    c.gel_button(l.copy, "Copy", false, false);
    c.gel_button(l.refresh, "Refresh", true, false);
    l
}

/// The window as the golden gate pictures it: a fixed machine, so the
/// picture is the same on every computer that draws it.
pub fn render_png(path: &str, scale: i32, runner: &mut Runner, theme: &Theme) -> bool {
    let facts = SystemFacts::sample();
    let (w, h) = (WIDTH, height_for(theme.tokens.title_bar_height, &facts) as i32);
    let cs = Surface::image(ffi::FORMAT_ARGB32, w * scale, h * scale);
    {
        let cr = Context::new(&cs);
        cr.scale(scale as f64, scale as f64);
        let was = runner.text.render_scale;
        runner.text.render_scale = scale;
        let mut c = Canvas::new(&cr, runner, theme);
        paint_system_profiler(&mut c, w as f64, h as f64, &facts);
        runner.text.render_scale = was;
    }
    cs.flush();
    cs.write_png(path)
}

fn log(s: &str) {
    eprintln!("System Profiler: {s}")
}

// MARK: - The application

pub struct SystemProfiler {
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    window: RefCell<Option<Rc<Window>>>,
    facts: RefCell<SystemFacts>,
    /// Its own connection, as the Displays pane's: its requests pump their
    /// own loop.
    configurator: Option<DisplayConfigurator>,
    pointer: Cell<(f64, f64)>,
    logged: Cell<bool>,
}

impl SystemProfiler {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Option<Rc<SystemProfiler>> {
        let configurator = DisplayConfigurator::new(Duration::from_secs(2));
        let facts = gather(configurator.as_ref().map(|c| c.displays()).as_deref());
        let h = height_for(toolkit.theme.borrow().tokens.title_bar_height, &facts) as i32;
        let app = Rc::new(SystemProfiler { display: display.clone(), toolkit: toolkit.clone(), window: RefCell::new(None), facts: RefCell::new(facts), configurator, pointer: Cell::new((0.0, 0.0)), logged: Cell::new(false) });
        let win = Window::new(display, "System Profiler", "org.abyssbsd.systemprofiler", WIDTH, h, 1, true, Rc::downgrade(&app) as Weak<dyn WindowDelegate>)?;
        *app.window.borrow_mut() = Some(win);
        app.log_facts();
        Some(app)
    }

    fn log_facts(&self) {
        let f = self.facts.borrow();
        log(&format!("facts {}: {}", f.facts.len(), f.facts.iter().map(|x| format!("{}={}", x.label, x.value.as_deref().unwrap_or("unknown"))).collect::<Vec<_>>().join(" | ")))
    }

    fn copy(&self) {
        let text = self.facts.borrow().text();
        let ok = self.display.clipboard().is_some_and(|c| c.write_text(&text));
        log(&if ok { format!("copied {} bytes", text.len()) } else { "the clipboard would not take it".into() })
    }

    fn refresh(&self) {
        *self.facts.borrow_mut() = gather(self.configurator.as_ref().map(|c| c.displays()).as_deref());
        self.log_facts();
        if let Some(w) = self.window.borrow().as_ref() {
            w.set_needs_display()
        }
    }

    fn quit(&self) {
        self.display.stop()
    }
}

impl WindowDelegate for SystemProfiler {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let facts = self.facts.borrow().clone();
        let l = self.toolkit.draw(target, |c, w, h| paint_system_profiler(c, w, h, &facts));
        if !self.logged.replace(true) {
            let at = |r: Rect| format!("{},{}", (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64);
            log(&format!("buttons copy={} refresh={}", at(l.copy), at(l.refresh)))
        }
    }

    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        self.pointer.set((x, y))
    }

    fn pointer_button(&self, w: &Window, _button: u32, pressed: bool) {
        if !pressed {
            return;
        }
        let (x, y) = self.pointer.get();
        let (sw, sh) = w.size();
        let t = self.toolkit.theme.borrow().tokens.clone();
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(Gadget::Close) => return self.quit(),
            ChromeHit::Gadget(Gadget::Minimize) => {
                w.minimize();
                return;
            }
            ChromeHit::Title => return w.begin_move(),
            _ => {}
        }
        let l = ProfilerLayout::new(t.title_bar_height, sw as f64, &self.facts.borrow());
        if l.copy.contains(x, y) {
            self.copy()
        } else if l.refresh.contains(x, y) {
            self.refresh()
        }
    }

    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        if !e.pressed || !e.modifiers.contains(KeyModifiers::COMMAND) {
            return;
        }
        match e.text.to_lowercase().as_str() {
            "c" => self.copy(),
            "r" => self.refresh(),
            "q" | "w" => self.quit(),
            _ => {}
        }
    }

    fn should_close(&self, _w: &Window) {
        self.quit()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_fact_has_a_row_inside_its_box() {
        let facts = SystemFacts::sample();
        let l = ProfilerLayout::new(22.0, 620.0, &facts);
        assert_eq!(l.rows.len(), facts.facts.len());
        let (_, hw) = l.boxes[1];
        assert!(l.rows.last().is_some_and(|r| r.y + r.h <= hw.y + hw.h));
        assert!(l.refresh.y + l.refresh.h <= height_for(22.0, &facts));
    }
}
