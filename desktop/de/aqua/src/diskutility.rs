//! Disk Utility: disks, ZFS datasets and their snapshots
//! (DiskUtilityApp.swift, P15.8).
//!
//! The disks the installer knows how to describe (probed without
//! privilege), the machine's datasets, and each one's snapshots, read in
//! the person's own process. Every change is a typed plan for the settings
//! helper (`VolumeAction`): take a snapshot, roll back to the latest one
//! (asked first: changes since are lost), mount and unmount. The helper
//! checks the thing still exists and refuses what would destroy more than
//! asked: a rollback past later snapshots, the system's own mounts.
//!
//! What a test reads (`ABYSS_DISKUTILITY_DUMP=1`): the sidebar's and the
//! snapshot list's rows and where they are drawn, the buttons, and what the
//! helper said.

use crate::commands::key_equivalent_of;
use crate::prefs::settings_client::{self as client, Apply};
use crate::toolkit::Toolkit;
use aquadraw::canvas::Canvas;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeEdge, ChromeHit, Gadget};
use aquadraw::color::Color;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use aquadraw::tokens::ThemeTokens;
use install::Disk;
use install_run::probe::{probe_machine, ProbeError};
use menu_model::{Command, CommandResult, Enablement, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use menu_wire::{MenuProvider, MenuService};
use settings::{SettingsPlan, VolumeAction};
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::{Rc, Weak};
use surface::{Display, KeyEvent, KeyModifiers, KeySym, RenderTarget, ResizeEdge, Window, WindowDelegate};
use volumes::{Dataset, Snapshot};

pub const VERB_ABOUT: &str = "app.about";
pub const VERB_QUIT: &str = "app.quit";
pub const VERB_CLOSE: &str = "window.close";
pub const VERB_MINIMIZE: &str = "window.minimize";
pub const VERB_SNAPSHOT: &str = "volume.snapshot";
pub const VERB_ROLLBACK: &str = "volume.rollback";
pub const VERB_MOUNT: &str = "volume.mount";
pub const VERB_REFRESH: &str = "view.refresh";

pub fn disk_utility_menu_bar() -> MenuBarModel {
    let c = |v: &str, t: &str, k: Option<char>, s: &str| {
        let cmd = Command::new(v, t, s);
        MenuItem::Command(match k {
            Some(ch) => cmd.with_key(KeyEquivalent::cmd(ch, Modifiers::NONE)),
            None => cmd,
        })
    };
    MenuBarModel::new(
        "Disk Utility",
        vec![
            Menu::new("Disk Utility", vec![c(VERB_ABOUT, "About Disk Utility", None, "Show Disk Utility's version."), MenuItem::Separator, c(VERB_QUIT, "Quit Disk Utility", Some('q'), "Close Disk Utility.")]),
            Menu::new("File", vec![c(VERB_CLOSE, "Close", Some('w'), "Close the window.")]),
            Menu::new(
                "Volume",
                vec![
                    c(VERB_MOUNT, "Mount or Unmount", Some('e'), "Mount or unmount the selected dataset."),
                    c(VERB_SNAPSHOT, "Take Snapshot", Some('t'), "Snapshot the selected dataset now."),
                    c(VERB_ROLLBACK, "Roll Back…", None, "Return the dataset to its latest snapshot."),
                    MenuItem::Separator,
                    c(VERB_REFRESH, "Refresh", Some('r'), "Read the disks and pools again."),
                ],
            ),
            Menu::new("Window", vec![c(VERB_MINIMIZE, "Minimize", Some('m'), "Put the window in the Dock.")]),
        ],
    )
}

/// What the sidebar lists: disks, then datasets.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VolumeItem {
    Disk(Disk),
    Dataset(Dataset),
}

impl VolumeItem {
    pub fn key(&self) -> String {
        match self {
            VolumeItem::Disk(d) => format!("disk:{}", d.name),
            VolumeItem::Dataset(d) => format!("ds:{}", d.name),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct DiskUtilityView {
    pub disks: Vec<Disk>,
    pub disks_unavailable: Option<String>,
    pub volumes: volumes::State,
    /// A `VolumeItem::key`.
    pub selected: Option<String>,
    pub selected_snapshot: Option<String>,
    pub status: String,
    /// Dates in UTC rather than local time: the golden scene's, so a
    /// picture does not depend on the machine's time zone.
    pub utc_dates: bool,
}

impl DiskUtilityView {
    pub fn items(&self) -> Vec<VolumeItem> {
        self.disks.iter().cloned().map(VolumeItem::Disk).chain(self.volumes.datasets.iter().cloned().map(VolumeItem::Dataset)).collect()
    }
    pub fn selected_item(&self) -> Option<VolumeItem> {
        self.items().into_iter().find(|i| Some(i.key()) == self.selected)
    }
    pub fn selected_dataset(&self) -> Option<Dataset> {
        match self.selected_item() {
            Some(VolumeItem::Dataset(d)) => Some(d),
            _ => None,
        }
    }
    fn latest_snapshot(&self, d: &Dataset) -> Option<Snapshot> {
        self.volumes.snapshots_of(&d.name).last().cloned()
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DiskUtilityLayout {
    pub sidebar: Rect,
    pub pane: Rect,
    pub row_height: f64,
    pub mount: Rect,
    pub snapshot: Rect,
    pub rollback: Rect,
    pub snapshots: Rect,
    pub footer: Rect,
}

impl DiskUtilityLayout {
    pub fn new(t: &ThemeTokens, w: f64, h: f64) -> DiskUtilityLayout {
        let top = t.title_bar_height;
        let footer = Rect::new(0.0, h - 26.0 - t.chrome_resize_band, w, 26.0);
        let pane = Rect::new(221.0, top, w - 221.0, footer.y - top);
        DiskUtilityLayout {
            sidebar: Rect::new(0.0, top, 220.0, footer.y - top),
            pane,
            row_height: 20.0,
            mount: Rect::new(pane.x + 16.0, top + 128.0, 110.0, 26.0),
            snapshot: Rect::new(pane.x + 136.0, top + 128.0, 130.0, 26.0),
            rollback: Rect::new(pane.x + 276.0, top + 128.0, 110.0, 26.0),
            snapshots: Rect::new(pane.x + 16.0, top + 186.0, pane.w - 32.0, (footer.y - top - 196.0).max(0.0)),
            footer,
        }
    }
}

/// "2026-10-01 09:05", local or UTC.
pub fn date_text(t: i64, utc: bool) -> String {
    abyss_sys::platform::civil_time(Some(t), utc).map_or(String::new(), |[y, mo, d, h, mi, _]| format!("{y}-{mo:02}-{d:02} {h:02}:{mi:02}"))
}

/// A size as Disk Utility writes it: TB and GB to two places, MB to one,
/// KB whole.
pub fn size_text(b: u64) -> String {
    let (k, v) = (1024.0, b as f64);
    let places = |x: f64, n: u32| {
        let p = 10i64.pow(n);
        let t = (x * p as f64).round() as i64;
        format!("{}.{:0width$}", t / p, (t % p).abs(), width = n as usize)
    };
    if v >= k * k * k * k {
        format!("{} TB", places(v / (k * k * k * k), 2))
    } else if v >= k * k * k {
        format!("{} GB", places(v / (k * k * k), 2))
    } else if v >= k * k {
        format!("{} MB", places(v / (k * k), 1))
    } else {
        format!("{} KB", (v / k).round() as i64)
    }
}

/// The sidebar's rows and their tops, as paint draws them.
fn sidebar_rows(v: &DiskUtilityView, l: &DiskUtilityLayout) -> Vec<(VolumeItem, f64)> {
    let mut y = l.sidebar.y + 8.0 + 18.0;
    let mut out = vec![];
    if v.disks_unavailable.is_some() {
        y += l.row_height
    }
    for d in &v.disks {
        out.push((VolumeItem::Disk(d.clone()), y));
        y += l.row_height
    }
    y += 6.0 + 18.0;
    if v.volumes.unavailable.is_some() {
        y += l.row_height
    }
    for d in &v.volumes.datasets {
        out.push((VolumeItem::Dataset(d.clone()), y));
        y += l.row_height
    }
    out
}

pub fn paint_disk_utility(c: &mut Canvas, w: f64, h: f64, v: &DiskUtilityView) -> DiskUtilityLayout {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, "Disk Utility", false, true);
    let t = c.theme.tokens.clone();
    let l = DiskUtilityLayout::new(&t, w, h);
    let fill = |c: &mut Canvas, k: Color, r: Rect| {
        c.set_color(k);
        c.cr.rectangle(r.x, r.y, r.w, r.h);
        c.cr.fill()
    };
    let text = |c: &mut Canvas, s: &str, x: f64, y: f64, k, size, style| c.text_left(s, x, y, k, size, style, Role::Interface);
    let (dim6, dim7, white, blue) = (t.body_text.with_a(0.6), t.body_text.with_a(0.7), Color::new(1.0, 1.0, 1.0, 1.0), Color::hex(0x3875D7, 1.0));
    fill(c, Color::hex(0xE8EDF3, 1.0), l.sidebar);
    fill(c, t.content_background, l.pane);
    // The sidebar.
    let mut y = l.sidebar.y + 8.0;
    let heading = |c: &mut Canvas, s: &str, y: &mut f64| {
        text(c, s, 10.0, *y + 13.0, dim6, 10.0, Style::Bold);
        *y += 18.0
    };
    let row = |c: &mut Canvas, item: &VolumeItem, s: &str, indent: f64, y: &mut f64| {
        let on = v.selected.as_deref() == Some(item.key().as_str());
        if on {
            fill(c, blue, Rect::new(0.0, *y, l.sidebar.w, l.row_height))
        }
        text(c, s, 12.0 + indent, *y + 14.0, if on { white } else { t.body_text }, 11.0, Style::Regular);
        *y += l.row_height
    };
    heading(c, "DISKS", &mut y);
    if let Some(why) = &v.disks_unavailable {
        text(c, why, 12.0, y + 14.0, dim6, 10.0, Style::Regular);
        y += l.row_height
    }
    for d in &v.disks {
        row(c, &VolumeItem::Disk(d.clone()), &format!("{}  {}", d.name, size_text(d.bytes)), 0.0, &mut y)
    }
    y += 6.0;
    heading(c, "ZFS", &mut y);
    if let Some(why) = &v.volumes.unavailable {
        text(c, why, 12.0, y + 14.0, dim6, 10.0, Style::Regular);
        y += l.row_height
    }
    for d in &v.volumes.datasets {
        let name = if d.depth() == 0 { d.name.as_str() } else { d.leaf() };
        row(c, &VolumeItem::Dataset(d.clone()), name, d.depth() as f64 * 12.0, &mut y)
    }
    // The pane.
    let (px, top) = (l.pane.x + 16.0, t.title_bar_height);
    let line = |c: &mut Canvas, k: &str, val: &str, y: f64| {
        text(c, k, px, y, dim7, 11.0, Style::Regular);
        text(c, val, px + 110.0, y, t.body_text, 11.0, Style::Regular)
    };
    match v.selected_item() {
        Some(VolumeItem::Disk(d)) => {
            text(c, &d.name, px, top + 30.0, t.body_text, 15.0, Style::Bold);
            line(c, "Size:", &size_text(d.bytes), top + 56.0);
            line(c, "Description:", if d.description.is_empty() { "—" } else { &d.description }, top + 74.0);
            line(c, "Partitions:", &if d.partition_kinds.is_empty() { "none".into() } else { d.partition_kinds.join(", ") }, top + 92.0);
            line(c, "Mounted at:", &if d.mounted_at.is_empty() { "nothing".into() } else { d.mounted_at.join(", ") }, top + 110.0);
            if d.holds_running_root {
                line(c, "", "This disk holds the running system.", top + 128.0)
            }
        }
        Some(VolumeItem::Dataset(d)) => {
            text(c, &d.name, px, top + 30.0, t.body_text, 15.0, Style::Bold);
            line(c, "Mountpoint:", &d.mountpoint, top + 56.0);
            line(c, "Used:", &size_text(d.used), top + 74.0);
            line(c, "Available:", &size_text(d.available), top + 92.0);
            line(c, "Mounted:", if d.mounted { "yes" } else { "no" }, top + 110.0);
            c.gel_button(l.mount, if d.mounted { "Unmount" } else { "Mount" }, false, false);
            c.gel_button(l.snapshot, "Take Snapshot", false, false);
            c.gel_button(l.rollback, "Roll Back…", false, false);
            text(c, "Snapshots", px, top + 178.0, t.body_text, 11.0, Style::Bold);
            let s = l.snapshots;
            fill(c, white, s);
            let snaps: Vec<&Snapshot> = v.volumes.snapshots_of(&d.name).rev().collect();
            if snaps.is_empty() {
                text(c, "No snapshots yet.", s.x + 8.0, s.y + 15.0, dim6, 11.0, Style::Regular)
            }
            for (i, snap) in snaps.iter().enumerate().take_while(|(i, _)| (*i + 1) as f64 * l.row_height <= s.h) {
                let ry = s.y + i as f64 * l.row_height;
                let on = v.selected_snapshot.as_ref() == Some(&snap.name);
                if on {
                    fill(c, blue, Rect::new(s.x, ry, s.w, l.row_height))
                }
                let fg = if on { white } else { t.body_text };
                text(c, snap.short(), s.x + 8.0, ry + 14.0, fg, 11.0, Style::Regular);
                text(c, &date_text(snap.created, v.utc_dates), s.x + s.w - 210.0, ry + 14.0, fg, 11.0, Style::Regular);
                text(c, &size_text(snap.used), s.x + s.w - 70.0, ry + 14.0, fg, 11.0, Style::Regular)
            }
        }
        None => text(c, "Choose a disk or a dataset.", px, top + 30.0, dim6, 12.0, Style::Regular),
    }
    fill(c, Color::hex(0xE4E4E4, 1.0), l.footer);
    text(c, &v.status, 12.0, l.footer.y + 17.0, t.body_text, 11.0, Style::Regular);
    l
}

/// "Roll back to …?": the changes since the snapshot are lost.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RollbackSheetLayout {
    pub panel: Rect,
    pub rollback: Rect,
    pub cancel: Rect,
}

impl RollbackSheetLayout {
    pub fn new(title_bar: f64, w: f64) -> RollbackSheetLayout {
        let (pw, ph) = (460.0f64.min(w - 40.0), 116.0);
        let panel = Rect::new((w - pw) / 2.0, title_bar, pw, ph);
        let rollback = Rect::new(panel.x + pw - 112.0, panel.y + ph - 40.0, 98.0, 26.0);
        RollbackSheetLayout { panel, rollback, cancel: Rect::new(rollback.x - 92.0, panel.y + ph - 40.0, 82.0, 26.0) }
    }
}

fn paint_rollback_sheet(c: &mut Canvas, w: f64, snapshot: &str) -> RollbackSheetLayout {
    let t = c.theme.tokens.clone();
    let l = RollbackSheetLayout::new(t.title_bar_height, w);
    let p = l.panel;
    c.set_color(Color::new(0.0, 0.0, 0.0, 0.18));
    c.cr.rectangle(p.x + 2.0, p.y, p.w, p.h + 3.0);
    c.cr.fill();
    c.set_color(Color::hex(0xECECEC, 1.0));
    c.cr.rectangle(p.x, p.y, p.w, p.h);
    c.cr.fill();
    c.text_left(&format!("Roll back to {snapshot}?"), p.x + 18.0, p.y + 30.0, t.body_text, t.font_size, Style::Bold, Role::Interface);
    c.text_left("Everything changed in it since the snapshot will be lost.", p.x + 18.0, p.y + 50.0, t.body_text, t.font_size - 1.0, Style::Regular, Role::Interface);
    c.gel_button(l.cancel, "Cancel", false, false);
    c.gel_button(l.rollback, "Roll Back", true, false);
    l
}

/// The golden scene's machine: one disk, a pool, a dataset with two
/// snapshots, one selected.
pub fn sample_view() -> DiskUtilityView {
    let ds = |name: &str, used, mp: &str, mounted| Dataset { name: name.into(), used, available: 45_561_032_704, mountpoint: mp.into(), mounted };
    let snap = |name: &str, created, used| Snapshot { name: name.into(), created, used };
    DiskUtilityView {
        disks: vec![Disk { name: "nvd0".into(), bytes: 1_000_204_886_016, description: "Samsung SSD 980 PRO 1TB".into(), mounted_at: vec!["/".into()], holds_running_root: true, partition_kinds: vec!["efi".into(), "freebsd-swap".into(), "freebsd-zfs".into()], ..Disk::default() }],
        volumes: volumes::State {
            datasets: vec![ds("zroot", 42_719_010_816, "none", false), ds("zroot/ROOT", 13_056_704_512, "none", false), ds("zroot/ROOT/default", 13_056_270_336, "/", true), ds("zroot/home", 6_774_800_384, "/home", true)],
            snapshots: vec![snap("zroot/home@abyss-2026-09-30-180000", 1_790_791_200, 1_310_720), snap("zroot/home@abyss-2026-10-01-090507", 1_790_845_507, 98_304)],
            unavailable: None,
        },
        selected: Some("ds:zroot/home".into()),
        selected_snapshot: Some("zroot/home@abyss-2026-10-01-090507".into()),
        status: "snapshot zroot/home@abyss-2026-10-01-090507: done.".into(),
        utc_dates: true,
        ..DiskUtilityView::default()
    }
}

fn log(s: &str) {
    eprintln!("Disk Utility: {s}")
}

// MARK: - The application

pub struct DiskUtility {
    me: Weak<DiskUtility>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    window: RefCell<Option<Rc<Window>>>,
    view: RefCell<DiskUtilityView>,
    menu_service: RefCell<Option<MenuService>>,
    pointer: Cell<(f64, f64)>,
    asking_rollback: RefCell<Option<String>>,
    applying: RefCell<Option<Rc<Apply>>>,
    dump: bool,
    last_dump: RefCell<String>,
}

struct Provider<'a>(&'a DiskUtility);

impl MenuProvider for Provider<'_> {
    fn menu_model(&self) -> MenuBarModel {
        disk_utility_menu_bar()
    }
    fn menu_validate(&self, c: &Command) -> Enablement {
        self.0.validate(&c.verb)
    }
    fn menu_perform(&mut self, c: &Command, _a: &BTreeMap<String, String>) -> CommandResult {
        if let Enablement::Disabled(why) = self.0.validate(&c.verb) {
            return CommandResult::Refused(why);
        }
        self.0.perform(&c.verb)
    }
}

impl DiskUtility {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Option<Rc<DiskUtility>> {
        let app = Rc::new_cyclic(|me| DiskUtility { me: me.clone(), display: display.clone(), toolkit: toolkit.clone(), window: RefCell::new(None), view: RefCell::default(), menu_service: RefCell::new(None), pointer: Cell::new((0.0, 0.0)), asking_rollback: RefCell::new(None), applying: RefCell::new(None), dump: std::env::var_os("ABYSS_DISKUTILITY_DUMP").is_some(), last_dump: RefCell::default() });
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let win = Window::new(display, "Disk Utility", "org.abyssbsd.diskutility", 700, 480, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&app) as Weak<dyn WindowDelegate>)?;
        let name = menu_wire::service_name("DiskUtility", std::process::id() as i32);
        if let Ok(s) = MenuService::new(&name) {
            let me = app.me.clone();
            display.add_fd(s.fd(), move || {
                if let Some(a) = me.upgrade() {
                    a.serve()
                }
            });
            *app.menu_service.borrow_mut() = Some(s);
            win.publish_menus(&name);
        }
        *app.window.borrow_mut() = Some(win);
        app.refresh();
        Some(app)
    }

    fn serve(&self) {
        let svc = self.menu_service.borrow_mut().take();
        let Some(mut svc) = svc else { return };
        svc.service_readable(&mut Provider(self));
        *self.menu_service.borrow_mut() = Some(svc)
    }

    fn redraw(&self) {
        if let Some(w) = self.window.borrow().as_ref() {
            w.set_needs_display()
        }
    }

    fn refresh(&self) {
        let probed = probe_machine();
        let state = volumes::read();
        {
            let mut v = self.view.borrow_mut();
            match probed {
                Ok(inv) => (v.disks, v.disks_unavailable) = (inv.disks, None),
                Err(ProbeError::NotSupported(_)) => (v.disks, v.disks_unavailable) = (vec![], Some("disks are FreeBSD's to list".into())),
                Err(e) => (v.disks, v.disks_unavailable) = (vec![], Some(e.to_string())),
            }
            v.volumes = state;
            if v.selected_snapshot.as_ref().is_some_and(|s| !v.volumes.snapshots.iter().any(|x| &x.name == s)) {
                v.selected_snapshot = None
            }
            if self.dump {
                log(&v.volumes.unavailable.as_ref().map_or_else(|| format!("volumes: {} datasets, {} snapshots", v.volumes.datasets.len(), v.volumes.snapshots.len()), |u| format!("volumes: unavailable: {u}")))
            }
        }
        self.redraw()
    }

    fn set_status(&self, s: String) {
        self.view.borrow_mut().status = s;
        self.redraw()
    }

    // MARK: changes, through the helper

    fn send(&self, action: VolumeAction, what: String) {
        let me = self.me.clone();
        let w2 = what.clone();
        let started = Apply::begin(&self.display, &client::apply_request(&SettingsPlan::Volume(action)), |_| {}, move |ok, said| {
            let Some(a) = me.upgrade() else { return };
            *a.applying.borrow_mut() = None;
            let err = said.strip_prefix("Not applied: ").unwrap_or(&said).to_string();
            log(&format!("{w2}: {}", if ok { "done".into() } else { format!("refused: {err}") }));
            a.view.borrow_mut().status = if ok { format!("{w2}: done.") } else { format!("{w2}: {err}") };
            a.refresh()
        });
        match started {
            Some(h) => {
                *self.applying.borrow_mut() = Some(h);
                log(&format!("{what}: asked the helper"));
                self.set_status(format!("{what}…"))
            }
            None => {
                log(&format!("{what}: no settings helper"));
                self.set_status("The settings helper is not running, so nothing can be changed.".into())
            }
        }
    }

    fn validate(&self, verb: &str) -> Enablement {
        let d = self.view.borrow().selected_dataset();
        match verb {
            VERB_ABOUT => Enablement::Disabled("Disk Utility has no About box yet".into()),
            VERB_SNAPSHOT | VERB_MOUNT if d.is_none() => Enablement::Disabled("no dataset is selected".into()),
            VERB_ROLLBACK => match d {
                None => Enablement::Disabled("no dataset is selected".into()),
                Some(d) if self.view.borrow().latest_snapshot(&d).is_none() => Enablement::Disabled("it has no snapshots".into()),
                Some(_) => Enablement::Enabled,
            },
            _ => Enablement::Enabled,
        }
    }

    fn perform(&self, verb: &str) -> CommandResult {
        let ok = CommandResult::Ok(None);
        let none = || CommandResult::Refused("no dataset is selected".into());
        match verb {
            VERB_QUIT | VERB_CLOSE => std::process::exit(0),
            VERB_MINIMIZE => {
                if let Some(w) = self.window.borrow().as_ref() {
                    w.minimize();
                }
                ok
            }
            VERB_REFRESH => {
                self.refresh();
                ok
            }
            VERB_SNAPSHOT => {
                let Some(d) = self.view.borrow().selected_dataset() else { return none() };
                let [y, mo, day, h, mi, s] = abyss_sys::platform::civil_time(None, false).unwrap_or([1970, 1, 1, 0, 0, 0]);
                let name = volumes::snapshot_name(y, mo, day, h, mi, s);
                let what = format!("snapshot {}@{name}", d.name);
                self.send(VolumeAction::Snapshot { dataset: d.name, name }, what);
                ok
            }
            VERB_MOUNT => {
                let Some(d) = self.view.borrow().selected_dataset() else { return none() };
                let what = format!("{} {}", if d.mounted { "unmount" } else { "mount" }, d.name);
                self.send(if d.mounted { VolumeAction::UnmountDataset(d.name) } else { VolumeAction::MountDataset(d.name) }, what);
                ok
            }
            VERB_ROLLBACK => {
                let v = self.view.borrow();
                let Some(latest) = v.selected_dataset().and_then(|d| v.latest_snapshot(&d)) else { return CommandResult::Refused("there is no snapshot to roll back to".into()) };
                if v.selected_snapshot.as_ref().is_some_and(|s| *s != latest.name) {
                    return CommandResult::Refused(format!("only the latest snapshot ({}) can be rolled back to; the ones after it would be destroyed", latest.short()));
                }
                drop(v);
                log(&format!("asked to roll back to {}", latest.name));
                *self.asking_rollback.borrow_mut() = Some(latest.name);
                self.redraw();
                ok
            }
            v => CommandResult::Refused(format!("Disk Utility has no verb {v}")),
        }
    }

    fn report(&self, r: CommandResult) {
        if let CommandResult::Refused(why) = r {
            log(&format!("refused: {why}"));
            self.set_status(why)
        }
    }

    fn answer_rollback(&self, go: bool) {
        let Some(s) = self.asking_rollback.borrow_mut().take() else { return };
        if go {
            self.send(VolumeAction::Rollback { snapshot: s.clone() }, format!("roll back to {s}"))
        } else {
            log("rollback cancelled")
        }
        self.redraw()
    }

    fn dump_layout(&self, l: &DiskUtilityLayout, sheet: Option<RollbackSheetLayout>) {
        let at = |r: Rect| format!("{},{}", (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64);
        let v = self.view.borrow();
        let mut line = format!("buttons mount={} snapshot={} rollback={}; sidebar", at(l.mount), at(l.snapshot), at(l.rollback));
        for (item, y) in sidebar_rows(&v, l) {
            if let VolumeItem::Dataset(d) = item {
                line += &format!(" {}@{}", d.name, (y + l.row_height / 2.0) as i64)
            }
        }
        if let Some(d) = v.selected_dataset() {
            line += &format!("; snapshots of {}:", d.name);
            for (i, s) in v.volumes.snapshots_of(&d.name).rev().enumerate() {
                line += &format!(" {}@{}", s.short(), (l.snapshots.y + i as f64 * l.row_height + l.row_height / 2.0) as i64)
            }
        }
        if let Some(s) = sheet {
            line += &format!("; sheet rollback={} cancel={}", at(s.rollback), at(s.cancel))
        }
        if *self.last_dump.borrow() != line {
            log(&line);
            *self.last_dump.borrow_mut() = line
        }
    }
}

impl WindowDelegate for DiskUtility {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let v = self.view.borrow().clone();
        let asking = self.asking_rollback.borrow().clone();
        let (l, sheet) = self.toolkit.draw(target, |c, w, h| (paint_disk_utility(c, w, h, &v), asking.map(|s| paint_rollback_sheet(c, w, &s))));
        if self.dump {
            self.dump_layout(&l, sheet)
        }
    }

    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        self.pointer.set((x, y))
    }

    fn pointer_button(&self, w: &Window, button: u32, pressed: bool) {
        if !pressed {
            return;
        }
        let (x, y) = self.pointer.get();
        let (sw, sh) = w.size();
        let t = self.toolkit.theme.borrow().tokens.clone();
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(Gadget::Close) => std::process::exit(0),
            ChromeHit::Gadget(Gadget::Minimize) => {
                w.minimize();
                return;
            }
            ChromeHit::Gadget(Gadget::Zoom) => return w.set_maximized(!w.is_maximized()),
            ChromeHit::Gadget(Gadget::Depth) => {
                w.lower();
                return;
            }
            ChromeHit::Title => return w.begin_move(),
            ChromeHit::Resize(e) => {
                return w.begin_resize(match e {
                    ChromeEdge::Bottom => ResizeEdge::BOTTOM,
                    ChromeEdge::BottomLeft => ResizeEdge::BOTTOM_LEFT,
                    ChromeEdge::BottomRight => ResizeEdge::BOTTOM_RIGHT,
                })
            }
            ChromeHit::Gadget(Gadget::Pill) | ChromeHit::Content => {}
        }
        if button != 0x110 {
            return;
        }
        if self.asking_rollback.borrow().is_some() {
            let s = RollbackSheetLayout::new(t.title_bar_height, sw as f64);
            if s.rollback.contains(x, y) {
                self.answer_rollback(true)
            } else if s.cancel.contains(x, y) {
                self.answer_rollback(false)
            }
            return;
        }
        let l = DiskUtilityLayout::new(&t, sw as f64, sh as f64);
        if l.sidebar.contains(x, y) {
            let hit = sidebar_rows(&self.view.borrow(), &l).into_iter().find(|(_, ry)| y >= *ry && y < ry + l.row_height);
            if let Some((item, _)) = hit {
                {
                    let mut v = self.view.borrow_mut();
                    v.selected = Some(item.key());
                    v.selected_snapshot = None;
                }
                if let VolumeItem::Dataset(d) = item {
                    log(&format!("selected {}", d.name))
                }
                self.redraw()
            }
            return;
        }
        let Some(d) = self.view.borrow().selected_dataset() else { return };
        for (r, verb) in [(l.mount, VERB_MOUNT), (l.snapshot, VERB_SNAPSHOT), (l.rollback, VERB_ROLLBACK)] {
            if r.contains(x, y) {
                return self.report(self.perform(verb));
            }
        }
        if l.snapshots.contains(x, y) {
            let i = ((y - l.snapshots.y) / l.row_height) as usize;
            let name = self.view.borrow().volumes.snapshots_of(&d.name).rev().nth(i).map(|s| s.name.clone());
            if let Some(n) = name {
                self.view.borrow_mut().selected_snapshot = Some(n);
                self.redraw()
            }
        }
    }

    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        if !e.pressed {
            return;
        }
        if self.asking_rollback.borrow().is_some() {
            match e.keysym {
                KeySym::ENTER => self.answer_rollback(true),
                KeySym::ESCAPE => self.answer_rollback(false),
                _ => {}
            }
            return;
        }
        if e.modifiers.contains(KeyModifiers::COMMAND)
            && let Some(verb) = key_equivalent_of(e).and_then(|k| disk_utility_menu_bar().verb_for(&k).map(String::from))
        {
            self.report(self.perform(&verb))
        }
    }

    fn should_close(&self, _w: &Window) {
        std::process::exit(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_and_dates_as_disk_utility_writes_them() {
        assert_eq!(size_text(1_000_204_886_016), "931.51 GB");
        assert_eq!(size_text(1_310_720), "1.3 MB");
        assert_eq!(size_text(98_304), "96 KB");
        assert_eq!(size_text(2 << 40), "2.00 TB");
        assert_eq!(date_text(1_790_845_507, true), "2026-10-01 09:05");
    }

    #[test]
    fn the_sidebar_is_hit_where_it_is_drawn() {
        let v = sample_view();
        let t = aquadraw::tokens::ThemeTokens::default();
        let l = DiskUtilityLayout::new(&t, 700.0, 440.0);
        let rows = sidebar_rows(&v, &l);
        assert_eq!(rows.len(), 5);
        assert_eq!(rows[0].1, l.sidebar.y + 26.0);
        assert_eq!(rows[1].1, rows[0].1 + 20.0 + 24.0, "DISKS, a gap, then ZFS");
    }
}
