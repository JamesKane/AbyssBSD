//! The Installer (Installer.swift, InstallerView.swift, InstallerClient.swift
//! and its part of AquaWindow.swift, P5.4): the hub, its spokes, the plan
//! they add up to, its pixels, and its window.
//!
//! **A hub, not a wizard.** Anaconda's shape: a summary page whose spokes
//! are entered and left in any order, each with its one-line status, and
//! Install inert until every required one is done.
//!
//! The model is pure, so a test can check the plan it builds with no
//! compositor, service or disk. The window links `install-wire` and not the
//! code that runs `gpart`: there is no path from a click here to a
//! partition table. The plan goes to `abyss-install`, and its events come
//! back through the run loop.

use crate::toolkit::Toolkit;
use crate::window::chrome_press;
use aquadraw::canvas::Canvas;
use aquadraw::drawlist::{DrawState, Role};
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use current_ipc::Msg;
use install::{keymaps, Account, Disk, DiskInventory, InstallPlan, PlanRefusal};
use install_wire::RunEvent;
use std::cell::{Cell, RefCell};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::rc::{Rc, Weak};
use surface::{Display, KeyEvent, KeySym, RenderTarget, Window, WindowDelegate};

// MARK: - The model

/// One spoke off the hub.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Spoke {
    Keyboard,
    Disk,
    Timezone,
    Account,
}

impl Spoke {
    pub const ALL: [Spoke; 4] = [Spoke::Keyboard, Spoke::Disk, Spoke::Timezone, Spoke::Account];

    pub fn title(self) -> &'static str {
        match self {
            Spoke::Keyboard => "Keyboard",
            Spoke::Disk => "Installation Disk",
            Spoke::Timezone => "Date & Time",
            Spoke::Account => "User Account",
        }
    }

    /// The title as a thing to choose, with its article, said by sound and
    /// not by letter: "a user account", never "an user account".
    pub fn to_choose(self) -> &'static str {
        match self {
            Spoke::Keyboard => "a keyboard",
            Spoke::Disk => "an installation disk",
            Spoke::Timezone => "a date & time",
            Spoke::Account => "a user account",
        }
    }

    /// Whether Install waits for it: require what cannot be guessed, default
    /// what can.
    pub fn required(self) -> bool {
        matches!(self, Spoke::Disk | Spoke::Account)
    }
}

/// Where the installer is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Page {
    Hub,
    Spoke(Spoke),
    /// **Erasing a disk that has something on it**, named, with its contents.
    /// A stop of its own: this asks "shall I destroy what is here", and a
    /// person who has answered still gets "shall I install".
    EraseConfirm(String),
    /// The point of no return, with the disk named in the sentence.
    Confirm,
    Installing,
    Done { ok: bool, error: String },
}

/// The time zones offered: the common ones, and UTC.
pub const TIMEZONES: [&str; 10] = ["UTC", "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York", "Europe/London", "Europe/Paris", "Europe/Berlin", "Asia/Tokyo", "Australia/Sydney"];

/// The keyboard layouts offered, as the `kbdmap` names rc.conf takes, and
/// what each is called.
pub fn keymap_files() -> Vec<String> {
    keymaps::offered().into_iter().map(|k| k.kbdmap).collect()
}
pub fn keymap_names() -> Vec<String> {
    keymaps::offered().into_iter().map(|k| k.name).collect()
}

/// Everything the installer knows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstallerModel {
    pub inventory: DiskInventory,
    /// What the service said when asked for the disks, if it could not.
    pub inventory_error: String,
    pub keymap: String,
    /// The disk to install onto; see `set_disk`.
    disk: String,
    /// Permission to destroy what is on `disk`, granted only by the sheet.
    erase_confirmed: bool,
    pub timezone: String,
    pub hostname: String,
    pub account_name: String,
    pub account_full_name: String,
    pub account_password: String,
    pub account_confirm: String,
    pub account_is_administrator: bool,
    pub page: Page,
    /// The highlighted row inside the current spoke.
    pub selection: usize,
    pub step_index: u64,
    pub step_total: u64,
    pub step_what: String,
}

impl Default for InstallerModel {
    fn default() -> InstallerModel {
        InstallerModel::new(DiskInventory::default())
    }
}

/// What the Aqua installer installs: FreeBSD **and this desktop**.
pub fn sets() -> Vec<String> {
    vec!["base.txz".into(), "kernel.txz".into(), InstallPlan::DESKTOP_SET.into()]
}

/// The account's groups. `wheel` and `operator` make an administrator;
/// **`audio` is everyone's**: FreeBSD 16's sound devices are `root:audio`.
pub fn groups(administrator: bool) -> Vec<String> {
    let g: &[&str] = if administrator { &["wheel", "operator", "audio"] } else { &["audio"] };
    g.iter().map(|s| s.to_string()).collect()
}

pub fn gib(bytes: u64) -> String {
    let tenths = u128::from(bytes) * 10 / (1 << 30);
    format!("{}.{} GB", tenths / 10, tenths % 10)
}

impl InstallerModel {
    pub fn new(inventory: DiskInventory) -> InstallerModel {
        InstallerModel {
            inventory,
            inventory_error: String::new(),
            keymap: String::new(),
            disk: String::new(),
            erase_confirmed: false,
            timezone: String::new(),
            hostname: "abyss".into(),
            account_name: String::new(),
            account_full_name: String::new(),
            account_password: String::new(),
            account_confirm: String::new(),
            account_is_administrator: true,
            page: Page::Hub,
            selection: 0,
            step_index: 0,
            step_total: 0,
            step_what: String::new(),
        }
    }

    pub fn disk(&self) -> &str {
        &self.disk
    }
    pub fn erase_confirmed(&self) -> bool {
        self.erase_confirmed
    }

    /// **Choosing a different disk withdraws any erase confirmation**: a
    /// person who agreed to destroy `nda1` has not agreed to destroy `nda0`.
    pub fn set_disk(&mut self, d: &str) {
        if d != self.disk {
            self.erase_confirmed = false
        }
        self.disk = d.into()
    }

    /// The one-line status under a spoke's title. **Every spoke says
    /// something**, the unfinished ones most of all.
    pub fn status(&self, spoke: Spoke) -> String {
        match spoke {
            Spoke::Keyboard if self.keymap.is_empty() => format!("{} (default)", keymaps::display_name("us.kbd")),
            Spoke::Keyboard => keymaps::display_name(&self.keymap),
            Spoke::Disk if self.disk.is_empty() => {
                if !self.inventory_error.is_empty() {
                    self.inventory_error.clone()
                } else if self.inventory.disks.is_empty() {
                    "No disk on this machine can be installed to".into()
                } else {
                    "Choose a disk to install onto".into()
                }
            }
            Spoke::Disk => match self.inventory.disk(&self.disk) {
                None => format!("{} is no longer there", self.disk),
                Some(d) => format!("{} — {}{}", d.name, gib(d.bytes), if d.description.is_empty() { String::new() } else { format!(" ({})", d.description) }),
            },
            Spoke::Timezone if self.timezone.is_empty() => "UTC (default)".into(),
            Spoke::Timezone => self.timezone.clone(),
            Spoke::Account if self.account_name.is_empty() => "No account will be created".into(),
            Spoke::Account if !self.password_problem().is_empty() => self.password_problem().into(),
            Spoke::Account if self.account_is_administrator => format!("{} — can administer this computer", self.account_name),
            Spoke::Account => self.account_name.clone(),
        }
    }

    pub fn complete(&self, spoke: Spoke) -> bool {
        match spoke {
            Spoke::Keyboard | Spoke::Timezone => true, // defaults are answers
            Spoke::Disk => !self.disk.is_empty() && self.inventory.disk(&self.disk).is_some(),
            Spoke::Account => !self.account_name.is_empty() && self.password_problem().is_empty(),
        }
    }

    /// What is wrong with the password; empty when it is fine.
    pub fn password_problem(&self) -> &'static str {
        if self.account_name.is_empty() {
            ""
        } else if self.account_password.is_empty() {
            "This account has no password"
        } else if self.account_password != self.account_confirm {
            "The passwords do not match"
        } else {
            ""
        }
    }

    pub fn outstanding(&self) -> Vec<Spoke> {
        Spoke::ALL.into_iter().filter(|s| s.required() && !self.complete(*s)).collect()
    }

    /// One predicate over the statuses the person can see.
    pub fn can_install(&self) -> bool {
        self.outstanding().is_empty()
    }

    /// The sentence beneath the Install button.
    pub fn readiness(&self) -> String {
        if self.can_install() {
            return format!("Ready to install onto {}. This will erase everything on it.", self.disk);
        }
        match self.outstanding().as_slice() {
            [one] => format!("Choose {} before installing.", one.to_choose()),
            all => format!("Still to do: {}.", all.iter().map(|s| s.title().to_lowercase()).collect::<Vec<_>>().join(", ")),
        }
    }

    /// The disk spoke's list: every disk, the unusable ones too, **with the
    /// reason beside them**: a picker that omits your disk is argued with.
    pub fn installable_disks(&self) -> &[Disk] {
        &self.inventory.disks
    }

    /// The refusals a trial plan on `d` meets. `erase: false`: the row tells
    /// the truth about a disk whether or not someone agreed to destroy it.
    fn trial(&self, d: &Disk) -> Vec<PlanRefusal> {
        install::problems(&self.plan(Some(&d.name), "$6$x", Some(false)), &self.inventory)
    }

    /// Why this disk cannot be chosen, or empty. Only the refusals about
    /// *this disk*: a missing account is its own spoke's. Matched in full,
    /// so a refusal added to `install` must be placed here.
    pub fn objection(&self, d: &Disk) -> String {
        use PlanRefusal::*;
        for p in self.trial(d) {
            match p {
                DiskHoldsRunningRoot(_) | DiskIsMounted { .. } | DiskTooSmall { .. } | NotAWholeDisk(_) | DiskIsFull { .. } => return p.message(),
                EmptyDisk | NoSuchDisk { .. } | BadPoolName { .. } | PoolNameInUse(_) | NoSets | BaseSetNotFirst(_) | SizeNotWholeMiB { .. } | RelativePath { .. } | NoAdministrator => continue,
            }
        }
        String::new()
    }

    /// Whether something no sentence can answer stops this disk. A full disk
    /// is not blocked: whether to make room is the person's decision.
    pub fn is_blocked(&self, d: &Disk) -> bool {
        use PlanRefusal::*;
        self.trial(d).iter().any(|p| match p {
            DiskHoldsRunningRoot(_) | DiskIsMounted { .. } | DiskTooSmall { .. } | NotAWholeDisk(_) => true,
            DiskIsFull { .. } | EmptyDisk | NoSuchDisk { .. } | BadPoolName { .. } | PoolNameInUse(_) | NoSets | BaseSetNotFirst(_) | SizeNotWholeMiB { .. } | RelativePath { .. } | NoAdministrator => false,
        })
    }

    /// Whether choosing this disk means destroying what is on it.
    pub fn needs_erasing(&self, d: &Disk) -> bool {
        self.trial(d).iter().any(|p| matches!(p, PlanRefusal::DiskIsFull { .. }))
    }

    /// The plan this model describes. The hash is the caller's, so the model
    /// stays pure; the plaintext password **never** reaches a plan.
    ///
    /// `erase` overrides the granted permission: the predicates asking what
    /// is wrong with a disk pass `Some(false)`. **Consent belongs to `disk`**,
    /// so a plan for another disk carries none of it.
    pub fn plan(&self, disk: Option<&str>, password_hash: &str, erase: Option<bool>) -> InstallPlan {
        let mut p = InstallPlan::new(disk.unwrap_or(&self.disk));
        p.sets = sets();
        p.dist_directory = std::env::var("ABYSS_DIST_DIR").unwrap_or_else(|_| "/usr/freebsd-dist".into());
        p.hostname = self.hostname.clone();
        p.timezone = self.timezone.clone();
        p.keymap = self.keymap.clone();
        // The account is the administrator; root gets no password of its own.
        p.root_password_hash = "*".into();
        if !self.account_name.is_empty() {
            p.accounts.push(Account { name: self.account_name.clone(), full_name: self.account_full_name.clone(), password_hash: password_hash.into(), groups: groups(self.account_is_administrator), shell: "/bin/sh".into() })
        }
        p.erase_existing_data = erase.unwrap_or(self.erase_confirmed && disk.is_none_or(|d| d == self.disk));
        p
    }

    /// The rows inside the current spoke.
    pub fn spoke_row_count(&self) -> usize {
        match self.page {
            Page::Spoke(Spoke::Keyboard) => keymap_files().len(),
            Page::Spoke(Spoke::Timezone) => TIMEZONES.len(),
            Page::Spoke(Spoke::Disk) => self.installable_disks().len(),
            _ => 0,
        }
    }

    /// Open a spoke on what is already chosen.
    pub fn enter(&mut self, spoke: Spoke) {
        self.page = Page::Spoke(spoke);
        self.selection = match spoke {
            Spoke::Keyboard => keymap_files().iter().position(|k| *k == self.keymap).unwrap_or(0),
            Spoke::Timezone => TIMEZONES.iter().position(|t| *t == self.timezone).unwrap_or(0),
            Spoke::Disk => self.installable_disks().iter().position(|d| d.name == self.disk).unwrap_or(0),
            Spoke::Account => 0,
        }
    }

    /// Commit the highlighted row; whether it took. **A choice that does
    /// not take does not leave the spoke**, where the reason is written.
    pub fn choose_selection(&mut self) -> bool {
        let Page::Spoke(s) = self.page else { return false };
        match s {
            Spoke::Keyboard => {
                let Some(k) = keymap_files().get(self.selection).cloned() else { return false };
                self.keymap = k
            }
            Spoke::Timezone => {
                let Some(t) = TIMEZONES.get(self.selection) else { return false };
                self.timezone = t.to_string()
            }
            Spoke::Disk => {
                let Some(d) = self.installable_disks().get(self.selection).cloned() else { return false };
                if self.is_blocked(&d) {
                    return false;
                }
                // A full disk asks first; consent is an answer about `disk`
                // only, never one carried over from another.
                if self.needs_erasing(&d) && !(self.erase_confirmed && self.disk == d.name) {
                    self.page = Page::EraseConfirm(d.name);
                    return false;
                }
                self.set_disk(&d.name)
            }
            Spoke::Account => {}
        }
        self.page = Page::Hub;
        true
    }

    pub fn back(&mut self) {
        self.page = Page::Hub
    }

    /// The disk the erase sheet asks about.
    pub fn erase_subject(&self) -> Option<&Disk> {
        match &self.page {
            Page::EraseConfirm(n) => self.inventory.disk(n),
            _ => None,
        }
    }

    /// Yes: destroy what is on it, and take it. The disk first: its setter
    /// withdraws consent when the disk changes.
    pub fn confirm_erase(&mut self) {
        let Page::EraseConfirm(name) = self.page.clone() else { return };
        self.set_disk(&name);
        self.erase_confirmed = true;
        self.page = Page::Hub
    }

    /// No: back to the list, nothing chosen and nothing granted.
    pub fn cancel_erase(&mut self) {
        if matches!(self.page, Page::EraseConfirm(_)) {
            self.erase_confirmed = false;
            self.page = Page::Spoke(Spoke::Disk)
        }
    }
}

/// A fixed synthetic machine, so the picture is the same on any box.
pub fn sample_model() -> InstallerModel {
    let disk = |name: &str, bytes, desc: &str| Disk { name: name.into(), bytes, description: desc.into(), ..Disk::default() };
    let mut inv = DiskInventory::new(vec![Disk { mounted_at: vec!["/".into()], holds_running_root: true, ..disk("ada0", 500 << 30, "APPLE SSD SM0512F") }, disk("ada1", 256 << 30, "Crucial CT256MX100"), disk("da0", 2 << 30, "SanDisk Cruzer")]);
    inv.imported_pools = vec!["zroot".into()];
    let mut m = InstallerModel::new(inv);
    m.set_disk("ada1");
    m.timezone = "America/Chicago".into();
    m.account_name = "jkane".into();
    m.account_full_name = "J Kane".into();
    m.account_password = "secret".into();
    m.account_confirm = "secret".into();
    m
}

/// The sample at the page `AQUA_INSTALLER_PAGE` names, and the field with
/// focus.
pub fn sample_at(page: Option<&str>) -> (InstallerModel, Option<AccountField>) {
    let mut m = sample_model();
    match page {
        Some("empty") => m = InstallerModel::new(m.inventory),
        Some("disk") => m.enter(Spoke::Disk),
        Some("account") => m.enter(Spoke::Account),
        Some("keyboard") => m.enter(Spoke::Keyboard),
        Some("confirm") => m.page = Page::Confirm,
        Some("installing") => {
            m.page = Page::Installing;
            (m.step_index, m.step_total, m.step_what) = (24, 39, "extract base.txz".into())
        }
        Some("done") => m.page = Page::Done { ok: true, error: String::new() },
        _ => {}
    }
    (m, (page == Some("account")).then_some(AccountField::Password))
}

// MARK: - Layout

/// The account spoke's fields, in Tab order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccountField {
    FullName,
    Name,
    Password,
    Confirm,
}

impl AccountField {
    pub const ALL: [AccountField; 4] = [AccountField::FullName, AccountField::Name, AccountField::Password, AccountField::Confirm];
    pub fn label(self) -> &'static str {
        match self {
            AccountField::FullName => "Name:",
            AccountField::Name => "Short Name:",
            AccountField::Password => "Password:",
            AccountField::Confirm => "Verify:",
        }
    }
    pub fn secret(self) -> bool {
        matches!(self, AccountField::Password | AccountField::Confirm)
    }
    fn value(self, m: &mut InstallerModel) -> &mut String {
        match self {
            AccountField::FullName => &mut m.account_full_name,
            AccountField::Name => &mut m.account_name,
            AccountField::Password => &mut m.account_password,
            AccountField::Confirm => &mut m.account_confirm,
        }
    }
}

/// Every rect the installer has, for the page it is on: what the painter
/// drew is what the hit-tester reads.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct InstallerLayout {
    /// The hub: one per spoke.
    pub spoke_rows: Vec<Rect>,
    /// A list spoke: one per choice.
    pub list_rows: Vec<Rect>,
    /// The account spoke's fields.
    pub fields: Vec<Rect>,
    pub admin_check: Rect,
    /// Install / Choose / Erase / Restart.
    pub primary: Rect,
    /// Quit / Back / Cancel.
    pub secondary: Rect,
    pub primary_label: String,
    pub secondary_label: String,
    pub progress: Rect,
}

const PAD: f64 = 20.0;
const ROW_H: f64 = 46.0;
const BUTTON_W: f64 = 108.0;
const BUTTON_H: f64 = 24.0;

/// `width` measures a button label at button size.
pub fn installer_layout(w: f64, h: f64, m: &InstallerModel, width: &mut dyn FnMut(&str) -> f64) -> InstallerLayout {
    let mut l = InstallerLayout::default();
    let (p, s) = match &m.page {
        Page::Hub => ("Install\u{2026}".to_string(), "Quit"),
        Page::Spoke(s) => (if *s == Spoke::Account { "Done" } else { "Choose" }.to_string(), "Back"),
        // **The destructive verb, and the disk's name, on the button**: a
        // sentence somebody can disagree with.
        Page::EraseConfirm(d) => (format!("Erase {d}"), "Cancel"),
        Page::Confirm => ("Erase and Install".to_string(), "Cancel"),
        Page::Installing => (String::new(), ""),
        Page::Done { ok, .. } => (if *ok { "Restart" } else { "Quit" }.to_string(), ""),
    };
    (l.primary_label, l.secondary_label) = (p, s.to_string());
    // A gel button is as wide as its words need.
    let bottom = h - PAD - BUTTON_H;
    let pw = BUTTON_W.max(width(&l.primary_label) + 34.0);
    let sw = BUTTON_W.max(width(&l.secondary_label) + 34.0);
    l.primary = Rect::new(w - PAD - pw, bottom, pw, BUTTON_H);
    if !l.secondary_label.is_empty() {
        l.secondary = Rect::new(w - PAD - pw - 10.0 - sw, bottom, sw, BUTTON_H)
    }
    match m.page {
        Page::Hub => l.spoke_rows = (0..Spoke::ALL.len()).map(|i| Rect::new(PAD, PAD + 52.0 + i as f64 * (ROW_H + 8.0), w - PAD * 2.0, ROW_H)).collect(),
        Page::Spoke(Spoke::Account) => {
            l.fields = (0..4).map(|i| Rect::new(PAD + 120.0, PAD + 60.0 + i as f64 * 34.0, w - PAD * 2.0 - 130.0, 22.0)).collect();
            l.admin_check = Rect::new(PAD + 120.0, PAD + 60.0 + 4.0 * 34.0 + 4.0, 16.0, 16.0)
        }
        Page::Spoke(_) => l.list_rows = (0..m.spoke_row_count()).map(|i| Rect::new(PAD, PAD + 52.0 + i as f64 * 27.0, w - PAD * 2.0, 26.0)).collect(),
        Page::Installing => l.progress = Rect::new(PAD, h / 2.0, w - PAD * 2.0, 14.0),
        Page::EraseConfirm(_) | Page::Confirm | Page::Done { .. } => {}
    }
    l
}

// MARK: - Paint

fn text(c: &mut Canvas, s: &str, x: f64, y: f64, k: aquadraw::color::Color, size: f64, style: Style) {
    c.text_left(s, x, y, k, size, style, Role::Interface)
}

/// Paint the installer and return the layout it used.
pub fn paint_installer(c: &mut Canvas, w: f64, h: f64, m: &InstallerModel, focus: Option<AccountField>, pressed: bool) -> InstallerLayout {
    let l = installer_layout(w, h, m, &mut |s| c.text_width(s, 12.0, Style::Regular, Role::Interface));
    let t = c.theme.tokens.clone();
    // Aqua's pale, with the pinstripe at the top, as a Jaguar utility wears it.
    c.paint_simple("installer", Rect::new(0.0, 0.0, w, h), DrawState::NORMAL);
    let title = |c: &mut Canvas, s: &str| text(c, s, PAD, 26.0, t.body_text, 15.0, Style::Bold);
    match &m.page {
        Page::Hub => {
            title(c, "Install AbyssBSD");
            for (r, spoke) in l.spoke_rows.iter().zip(Spoke::ALL) {
                paint_spoke_row(c, *r, spoke, m)
            }
            // The readiness line sits with the button it governs.
            text(c, &m.readiness(), PAD, h - PAD - 6.0, if m.can_install() { t.body_text } else { t.attention_text }, 11.0, Style::Regular);
            c.gel_button(l.secondary, &l.secondary_label, false, false);
            c.gel_button(l.primary, &l.primary_label, m.can_install(), pressed);
            // Spent, not missing: the person needs to see where it starts.
            if !m.can_install() {
                c.paint_simple("installer.veil", l.primary, DrawState::NORMAL)
            }
        }
        Page::Spoke(s) => {
            title(c, s.title());
            if *s == Spoke::Account {
                paint_account_spoke(c, &l, m, focus)
            } else {
                paint_list_spoke(c, &l, *s, m)
            }
            c.gel_button(l.secondary, &l.secondary_label, false, false);
            c.gel_button(l.primary, &l.primary_label, true, pressed)
        }
        // **Cancel is the blue one**: the default on a sheet that destroys
        // somebody's data is not doing that.
        Page::EraseConfirm(_) => {
            paint_erase_confirm(c, m);
            c.gel_button(l.secondary, &l.secondary_label, true, false);
            c.gel_button(l.primary, &l.primary_label, false, pressed)
        }
        Page::Confirm => {
            paint_confirm(c, m);
            c.gel_button(l.secondary, &l.secondary_label, true, false);
            c.gel_button(l.primary, &l.primary_label, false, pressed)
        }
        Page::Installing => {
            title(c, "Installing AbyssBSD");
            c.progress_bar(l.progress, if m.step_total > 0 { m.step_index as f64 / m.step_total as f64 } else { 0.0 });
            text(c, &m.step_what, PAD, l.progress.y - 10.0, t.body_text, 12.0, Style::Regular);
            text(c, &format!("Step {} of {}", m.step_index, m.step_total), PAD, l.progress.y + 34.0, t.secondary_text, 11.0, Style::Regular)
        }
        Page::Done { ok, error } => {
            title(c, if *ok { "AbyssBSD is installed" } else { "The installation failed" });
            text(c, if *ok { "Restart, and remove the installation medium." } else { error }, PAD, 80.0, if *ok { t.body_text } else { t.attention_text }, 12.0, Style::Regular);
            c.gel_button(l.primary, &l.primary_label, true, pressed)
        }
    }
    l
}

fn paint_spoke_row(c: &mut Canvas, r: Rect, spoke: Spoke, m: &InstallerModel) {
    let t = c.theme.tokens.clone();
    let done = m.complete(spoke);
    c.paint_simple(if done { "installer.spoke" } else { "installer.spoke.attention" }, r, DrawState::NORMAL);
    text(c, spoke.title(), r.x + 12.0, r.y + 19.0, t.body_text, 12.0, Style::Bold);
    text(c, &m.status(spoke), r.x + 12.0, r.y + 36.0, if done { t.secondary_text } else { t.attention_text }, 11.0, Style::Regular);
    // Required and unanswered wears a mark.
    if spoke.required() && !done {
        c.text("!", r.x + r.w - 18.0, r.y + r.h / 2.0, t.attention_text, 15.0, Style::Bold, Role::Interface)
    }
}

fn paint_list_spoke(c: &mut Canvas, l: &InstallerLayout, s: Spoke, m: &InstallerModel) {
    let t = c.theme.tokens.clone();
    let names = keymap_names();
    for (i, row) in l.list_rows.iter().enumerate() {
        let selected = i == m.selection;
        let (label, detail, refused) = match s {
            Spoke::Keyboard => (names[i].clone(), String::new(), false),
            Spoke::Timezone => (TIMEZONES[i].to_string(), String::new(), false),
            Spoke::Disk => {
                let d = &m.installable_disks()[i];
                let why = m.objection(d);
                let label = if d.description.is_empty() { d.name.clone() } else { format!("{} — {}", d.name, d.description) };
                (label, if why.is_empty() { gib(d.bytes) } else { why.clone() }, !why.is_empty())
            }
            Spoke::Account => continue,
        };
        if selected {
            c.paint_simple("installer.row", *row, if refused { DrawState::DISABLED } else { DrawState::NORMAL })
        }
        // A disk that cannot be used is greyed, WITH its reason: never hidden.
        text(c, &label, row.x + 10.0, row.y + 18.0, if refused { t.secondary_text } else if selected { t.menu_text_on_highlight } else { t.body_text }, 12.0, Style::Regular);
        if !detail.is_empty() {
            let w = c.text_width(&detail, 11.0, Style::Regular, Role::Interface);
            text(c, &detail, row.x + row.w - 10.0 - w, row.y + 18.0, if refused { t.attention_text } else if selected { t.menu_text_on_highlight } else { t.secondary_text }, 11.0, Style::Regular)
        }
    }
}

fn paint_account_spoke(c: &mut Canvas, l: &InstallerLayout, m: &InstallerModel, focus: Option<AccountField>) {
    let t = c.theme.tokens.clone();
    let mut m2 = m.clone();
    for (f, r) in AccountField::ALL.into_iter().zip(&l.fields) {
        text(c, f.label(), PAD, r.y + 15.0, t.body_text, 12.0, Style::Regular);
        let v = f.value(&mut m2).clone();
        let shown = if f.secret() { "•".repeat(v.chars().count()) } else { v };
        c.text_field(*r, &shown, focus == Some(f), "")
    }
    c.checkbox(l.admin_check, m.account_is_administrator);
    text(c, "Allow this account to administer this computer", l.admin_check.x + 24.0, l.admin_check.y + 13.0, t.body_text, 12.0, Style::Regular);
    if !m.password_problem().is_empty() {
        text(c, m.password_problem(), PAD, l.admin_check.y + 44.0, t.attention_text, 11.0, Style::Regular)
    }
}

/// The sheet between a full disk and its being chosen: the disk, so it can
/// be recognised, and **what is on it, one item per line**: a list reads as
/// an inventory and gets counted.
fn paint_erase_confirm(c: &mut Canvas, m: &InstallerModel) {
    let Some(d) = m.erase_subject().cloned() else { return };
    let t = c.theme.tokens.clone();
    text(c, &format!("Erase {}?", d.name), PAD, 26.0, t.body_text, 15.0, Style::Bold);
    text(c, &format!("{} — {}", gib(d.bytes), if d.description.is_empty() { "disk" } else { &d.description }), PAD, 52.0, t.secondary_text, 12.0, Style::Regular);
    let mut y = 84.0;
    text(c, "This disk contains:", PAD, y, t.body_text, 12.0, Style::Regular);
    y += 20.0;
    let contents = d.contents();
    let items = if contents.is_empty() { vec!["existing partitions".to_string()] } else { contents };
    for item in items {
        text(c, &format!("\u{2022}  {item}"), PAD + 12.0, y, t.attention_text, 12.0, Style::Regular);
        y += 18.0
    }
    y += 10.0;
    for line in ["Installing AbyssBSD here erases the whole disk.", "This cannot be undone."] {
        text(c, line, PAD, y, t.body_text, 12.0, Style::Regular);
        y += 18.0
    }
}

/// The point of no return: **the disk named in the sentence**, with its
/// size and description.
fn paint_confirm(c: &mut Canvas, m: &InstallerModel) {
    let t = c.theme.tokens.clone();
    text(c, &format!("Erase {}?", m.disk), PAD, 26.0, t.body_text, 15.0, Style::Bold);
    let mut lines = vec![format!("Everything on {} will be erased and cannot be recovered.", m.disk)];
    if let Some(d) = m.inventory.disk(&m.disk) {
        lines.push(format!("{} is a {} disk{}", m.disk, gib(d.bytes), if d.description.is_empty() { ".".into() } else { format!(" — {}.", d.description) }));
        if !d.mounted_at.is_empty() {
            lines.push(format!("It is currently in use at {}.", d.mounted_at.join(", ")))
        }
    }
    lines.push(format!("AbyssBSD will be installed on it, and {} will be the name of this computer.", m.hostname));
    for (i, line) in lines.iter().enumerate() {
        text(c, line, PAD, 80.0 + i as f64 * 22.0, t.body_text, 12.0, Style::Regular)
    }
}

// MARK: - Talking to abyss-install

pub fn service() -> String {
    std::env::var("ABYSS_INSTALL_SERVICE").unwrap_or_else(|_| "install".into())
}

/// The machine's disks, or the reason there are none to show: "could not
/// look" is not "this machine has none".
pub fn disks() -> (DiskInventory, String) {
    let mut m = Msg::new();
    m.set_string("method", "disks");
    match current_ipc::call(&service(), &m) {
        Err(_) => (DiskInventory::default(), "The installer service is not running on this machine".into()),
        Ok(r) if r.bool("ok") != Some(true) => (DiskInventory::default(), r.string("error").unwrap_or("unknown error").into()),
        Ok(r) => (install_wire::decode_inventory(&r), String::new()),
    }
}

/// Start an install; the socket its events arrive on.
pub fn begin(plan: &InstallPlan) -> Option<UnixStream> {
    let mut m = Msg::new();
    m.set_string("method", "install");
    install_wire::encode_plan(plan, &mut m);
    let sock = current_ipc::connect(&service()).ok()?;
    current_ipc::send(&m, &sock).ok()?;
    Some(sock)
}

/// One event, or None when it is done. A refusal is the finish it means.
pub fn next(sock: &UnixStream) -> Option<RunEvent> {
    let m = current_ipc::receive(sock).ok()?;
    install_wire::decode_event(&m).or_else(|| (m.bool("ok") == Some(false)).then(|| RunEvent::Finished { ok: false, error: m.string("error").unwrap_or("refused").into() }))
}

/// Hash a password the way the installed system checks it, here, so no
/// plaintext crosses to the privileged half. A failure must not become an
/// account with no password: `*` matches nothing.
pub fn hash(password: &str) -> String {
    abyss_sys::platform::crypt_sha512(password).unwrap_or_else(|| "*".into())
}

// MARK: - The window

const BTN_LEFT: u32 = 0x110;

/// Unbuffered, so a log-watching test sees it when it happens.
fn say(s: &str) {
    eprintln!("Installer: {s}")
}

fn centre(r: &Rect) -> String {
    format!("{},{}", (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64)
}

pub struct InstallerApp {
    me: Weak<InstallerApp>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    window: RefCell<Option<Rc<Window>>>,
    pub model: RefCell<InstallerModel>,
    layout: RefCell<InstallerLayout>,
    focus: Cell<Option<AccountField>>,
    pressed: Cell<bool>,
    pointer: Cell<(f64, f64)>,
    dump: bool,
    dumped: RefCell<Option<Page>>,
    socket: RefCell<Option<UnixStream>>,
}

impl InstallerApp {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>, title: &str, width: i32, height: i32, model: InstallerModel) -> Option<Rc<InstallerApp>> {
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let app = Rc::new_cyclic(|me| InstallerApp {
            me: me.clone(),
            display: display.clone(),
            toolkit: toolkit.clone(),
            window: RefCell::new(None),
            model: RefCell::new(model),
            layout: RefCell::default(),
            focus: Cell::new(None),
            pressed: Cell::new(false),
            pointer: Cell::new((0.0, 0.0)),
            dump: std::env::var_os("ABYSS_INSTALLER_DUMP").is_some(),
            dumped: RefCell::new(None),
            socket: RefCell::new(None),
        });
        let w = Window::new(display, title, "org.abyssbsd.aquademo", width, height, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&app) as Weak<dyn WindowDelegate>)?;
        *app.window.borrow_mut() = Some(w);
        Some(app)
    }

    fn redraw(&self) {
        let w = self.window.borrow().clone();
        if let Some(w) = w {
            w.set_needs_display()
        }
    }

    fn quit(&self) -> ! {
        std::process::exit(0)
    }

    /// Every rect on the page, so a test clicks by name (§2.46). The size
    /// first: a caller has to know where the window is.
    fn dump_layout(&self, w: f64, h: f64) {
        let l = self.layout.borrow();
        let mut parts = vec![format!("size={}x{}", w as i64, h as i64), format!("primary={}", centre(&l.primary))];
        if l.secondary.w > 0.0 {
            parts.push(format!("secondary={}", centre(&l.secondary)))
        }
        let named = [("spoke", &l.spoke_rows), ("row", &l.list_rows), ("field", &l.fields)];
        for (name, rows) in named {
            parts.extend(rows.iter().enumerate().map(|(i, r)| format!("{name}{i}={}", centre(r))))
        }
        if l.admin_check.w > 0.0 {
            parts.push(format!("admin={}", centre(&l.admin_check)))
        }
        say(&format!("layout {}", parts.join(" ")))
    }

    /// Commit: the plan goes to `abyss-install`, and its socket into the
    /// run loop, so the progress screen keeps painting.
    fn start_install(&self) {
        let plan = {
            let mut m = self.model.borrow_mut();
            m.page = Page::Installing;
            m.plan(None, &hash(&m.account_password), None)
        };
        let Some(sock) = begin(&plan) else {
            self.model.borrow_mut().page = Page::Done { ok: false, error: "The installer service is not running on this machine".into() };
            return;
        };
        eprintln!("AquaDemo: install started on {}", plan.disk);
        let fd = sock.as_raw_fd();
        *self.socket.borrow_mut() = Some(sock);
        let me = self.me.clone();
        self.display.add_fd(fd, move || {
            let Some(app) = me.upgrade() else { return };
            let e = app.socket.borrow().as_ref().and_then(next);
            match e {
                // Unregister before closing, never after.
                None => {
                    app.display.remove_fd(fd);
                    *app.socket.borrow_mut() = None;
                    return;
                }
                Some(RunEvent::Starting { index, total, what, .. }) => {
                    let mut m = app.model.borrow_mut();
                    (m.step_index, m.step_total, m.step_what) = (index + 1, total, what)
                }
                Some(RunEvent::Ok { .. } | RunEvent::Failed { .. }) => {}
                Some(RunEvent::Finished { ok, error }) => {
                    eprintln!("AquaDemo: install {}", if ok { "finished".into() } else { format!("failed: {error}") });
                    app.model.borrow_mut().page = Page::Done { ok, error }
                }
            }
            app.redraw()
        })
    }

    fn press(&self) {
        let l = self.layout.borrow().clone();
        let (x, y) = self.pointer.get();
        self.pressed.set(l.primary.contains(x, y));
        let page = self.model.borrow().page.clone();
        let primary = l.primary.contains(x, y);
        let secondary = l.secondary.contains(x, y);
        match page {
            Page::Hub => {
                if let Some(i) = l.spoke_rows.iter().position(|r| r.contains(x, y)) {
                    self.model.borrow_mut().enter(Spoke::ALL[i]);
                    return say(&format!("entered {}", Spoke::ALL[i].title()));
                }
                if primary {
                    // Drawn spent and does nothing: both, not either.
                    let mut m = self.model.borrow_mut();
                    if m.can_install() {
                        m.page = Page::Confirm;
                        say(&format!("confirming: erase {}", m.disk))
                    } else {
                        say(&format!("install is not armed: {}", m.readiness()))
                    }
                } else if secondary {
                    self.quit()
                }
            }
            Page::Spoke(spoke) => {
                if let Some(i) = l.list_rows.iter().position(|r| r.contains(x, y)) {
                    self.model.borrow_mut().selection = i;
                    return;
                }
                if spoke == Spoke::Account {
                    if let Some(i) = l.fields.iter().position(|r| r.contains(x, y)) {
                        return self.focus.set(Some(AccountField::ALL[i]));
                    }
                    if l.admin_check.contains(x, y) {
                        let mut m = self.model.borrow_mut();
                        m.account_is_administrator = !m.account_is_administrator
                    }
                }
                if primary {
                    self.choose(spoke);
                    self.focus.set(None)
                } else if secondary {
                    self.model.borrow_mut().back();
                    self.focus.set(None)
                }
            }
            Page::EraseConfirm(_) => {
                let mut m = self.model.borrow_mut();
                if primary {
                    m.confirm_erase();
                    // Confirming *is* choosing: said in the words the other
                    // path uses.
                    say(&format!("erasing {} was confirmed", m.disk));
                    say(&format!("disk is {}", m.disk));
                    say(if m.can_install() { "ready to install" } else { "not ready" })
                } else if secondary {
                    m.cancel_erase();
                    say("erasing was cancelled")
                }
            }
            Page::Confirm => {
                if primary {
                    self.start_install()
                } else if secondary {
                    self.model.borrow_mut().page = Page::Hub
                }
            }
            Page::Installing => {} // nothing to click; it is happening
            Page::Done { .. } => {
                if primary {
                    self.quit()
                }
            }
        }
    }

    /// The spoke's primary button, said aloud: a click leaves no trace.
    fn choose(&self, spoke: Spoke) {
        let mut m = self.model.borrow_mut();
        if spoke == Spoke::Account {
            m.back();
            let p = m.password_problem();
            say(&format!("account is {}{}", if m.account_name.is_empty() { "(none)" } else { &m.account_name }, if p.is_empty() { String::new() } else { format!(" — {p}") }))
        } else {
            let took = m.choose_selection();
            match spoke {
                Spoke::Disk => {
                    if took {
                        say(&format!("disk is {}", m.disk))
                    } else if let Page::EraseConfirm(d) = &m.page {
                        // A question, not a refusal.
                        say(&format!("asking before erasing {d}"))
                    } else if let Some(d) = m.installable_disks().get(m.selection) {
                        say(&format!("refused that disk: {}", m.objection(d)))
                    }
                }
                Spoke::Keyboard => {
                    say(&format!("keyboard is {}", m.keymap));
                    // **And this session types it now** (T.2): the password
                    // is typed on the medium, before rc.conf exists.
                    match pool_config::KeyboardPrefs::new(&m.keymap).store(None) {
                        Ok(()) => say(&format!("this session types {} now", keymaps::display_name(&m.keymap))),
                        Err(e) => say(&format!("could not set this session's keyboard: {e}")),
                    }
                }
                Spoke::Timezone => say(&format!("time zone is {}", m.timezone)),
                Spoke::Account => {}
            }
        }
        say(if m.can_install() { "ready to install" } else { "not ready" })
    }

    fn key(&self, e: &KeyEvent) {
        // A text field swallows the keys a list would otherwise use.
        let page = self.model.borrow().page.clone();
        if let (Page::Spoke(Spoke::Account), Some(f)) = (&page, self.focus.get()) {
            match e.keysym {
                KeySym::BACKSPACE => {
                    f.value(&mut self.model.borrow_mut()).pop();
                    return;
                }
                KeySym::TAB => return self.focus.set(Some(AccountField::ALL[(f as usize + 1) % 4])),
                KeySym::ENTER => {
                    self.focus.set(None);
                    return self.model.borrow_mut().back();
                }
                KeySym::ESCAPE => return self.focus.set(None),
                _ if !e.text.is_empty() && e.text.chars().all(|c| c as u32 >= 0x20 && c as u32 != 0x7f) => {
                    *f.value(&mut self.model.borrow_mut()) += &e.text;
                    return;
                }
                _ => {}
            }
        }
        match e.keysym {
            KeySym::DOWN => {
                let mut m = self.model.borrow_mut();
                let n = m.spoke_row_count();
                if n > 0 {
                    m.selection = (m.selection + 1).min(n - 1)
                }
            }
            KeySym::UP => {
                let mut m = self.model.borrow_mut();
                m.selection = m.selection.saturating_sub(1)
            }
            KeySym::ENTER => match page {
                Page::Hub => {
                    let mut m = self.model.borrow_mut();
                    if m.can_install() {
                        m.page = Page::Confirm
                    }
                }
                Page::Spoke(Spoke::Account) => self.model.borrow_mut().back(),
                Page::Spoke(_) => {
                    self.model.borrow_mut().choose_selection();
                }
                // Return is the default button, and the default is Cancel:
                // the key people press to dismiss things erases nothing.
                Page::EraseConfirm(_) => self.model.borrow_mut().cancel_erase(),
                Page::Confirm => self.start_install(),
                Page::Installing => {}
                Page::Done { .. } => self.quit(),
            },
            KeySym::ESCAPE => {
                let mut m = self.model.borrow_mut();
                match page {
                    Page::Spoke(_) => m.back(),
                    Page::EraseConfirm(_) => m.cancel_erase(),
                    Page::Confirm => m.page = Page::Hub,
                    _ => {}
                }
            }
            _ => {}
        }
    }
}

impl WindowDelegate for InstallerApp {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let m = self.model.borrow().clone();
        let (focus, pressed) = (self.focus.get(), self.pressed.get());
        let mut size = (0.0, 0.0);
        let l = self.toolkit.draw(target, |c, w, h| {
            size = (w, h);
            paint_installer(c, w, h, &m, focus, pressed)
        });
        *self.layout.borrow_mut() = l;
        // Published whenever the page changes, so a test clicks what was
        // drawn rather than coordinates copied into a script.
        if self.dump && self.dumped.borrow().as_ref() != Some(&m.page) {
            *self.dumped.borrow_mut() = Some(m.page.clone());
            self.dump_layout(size.0, size.1)
        }
    }

    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        self.pointer.set((x, y))
    }

    fn pointer_button(&self, w: &Window, button: u32, pressed: bool) {
        if button != BTN_LEFT {
            return;
        }
        let (x, y) = self.pointer.get();
        if pressed && chrome_press(&self.toolkit, w, x, y) {
            return;
        }
        if pressed {
            self.press()
        } else {
            self.pressed.set(false)
        }
        w.set_needs_display()
    }

    fn key_event(&self, w: &Window, e: &KeyEvent) {
        if !e.pressed {
            return;
        }
        eprintln!("AquaWindow: key {}{}", e.keysym, if e.text.is_empty() { String::new() } else { format!(" '{}'", e.text) });
        self.key(e);
        w.set_needs_display()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full(name: &str) -> Disk {
        Disk { name: name.into(), bytes: 500 << 30, has_partition_table: true, partition_kinds: vec!["ntfs".into()], ..Disk::default() }
    }

    #[test]
    fn the_hub_says_what_is_left_and_install_waits_for_it() {
        let m = InstallerModel::new(sample_model().inventory);
        assert!(!m.can_install());
        assert_eq!(m.readiness(), "Still to do: installation disk, user account.");
        assert_eq!(m.status(Spoke::Timezone), "UTC (default)");
        let m = sample_model();
        assert!(m.can_install(), "{:?}", m.outstanding());
        assert_eq!(m.status(Spoke::Disk), "ada1 — 256.0 GB (Crucial CT256MX100)");
        let mut m = sample_model();
        m.account_confirm = "x".into();
        assert_eq!(m.readiness(), "Choose a user account before installing.", "a, by sound");
        let mut m = sample_model();
        m.set_disk("");
        assert_eq!(m.readiness(), "Choose an installation disk before installing.");
    }

    #[test]
    fn a_disk_that_cannot_be_used_is_shown_with_its_reason_and_does_not_take() {
        let mut m = sample_model();
        let root = m.inventory.disks[0].clone();
        assert!(m.is_blocked(&root) && !m.objection(&root).is_empty());
        m.enter(Spoke::Disk);
        m.selection = 0;
        assert!(!m.choose_selection());
        assert_eq!(m.page, Page::Spoke(Spoke::Disk), "stays where the reason is written");
        assert_eq!(m.disk(), "ada1");
    }

    #[test]
    fn consent_to_erase_belongs_to_the_disk_it_was_given_for() {
        let mut m = InstallerModel::new(DiskInventory::new(vec![full("nda0"), full("nda1")]));
        m.enter(Spoke::Disk);
        m.selection = 1;
        assert!(!m.choose_selection());
        assert_eq!(m.page, Page::EraseConfirm("nda1".into()));
        m.confirm_erase();
        assert!(m.erase_confirmed() && m.disk() == "nda1");
        assert!(m.plan(None, "h", None).erase_existing_data);
        assert!(!m.plan(Some("nda0"), "h", None).erase_existing_data, "a yes for nda1 is not one for nda0");
        m.enter(Spoke::Disk);
        m.selection = 0;
        assert!(!m.choose_selection(), "nda0 asks for itself");
        m.cancel_erase();
        assert!(!m.erase_confirmed());
    }

    #[test]
    fn the_plan_carries_a_hash_and_the_desktop() {
        let p = sample_model().plan(None, "$6$abc", None);
        assert_eq!(p.accounts[0].password_hash, "$6$abc");
        assert_eq!(p.accounts[0].groups, ["wheel", "operator", "audio"]);
        assert!(p.installs_desktop());
        assert_eq!(p.root_password_hash, "*");
    }

    #[test]
    fn one_layout_for_paint_and_hit() {
        let (m, _) = sample_at(Some("account"));
        let l = installer_layout(620.0, 460.0, &m, &mut |s| s.len() as f64 * 7.0);
        assert_eq!((l.fields.len(), l.primary_label.as_str(), l.secondary_label.as_str()), (4, "Done", "Back"));
        let (m, _) = sample_at(Some("confirm"));
        let l = installer_layout(620.0, 460.0, &m, &mut |s| s.len() as f64 * 7.0);
        assert!(l.primary.w > BUTTON_W, "Erase and Install is as wide as its words");
    }

    // InstallerTests.swift, the rest of it.

    fn disk(name: &str, gib: u64, description: &str) -> Disk {
        Disk { name: name.into(), bytes: gib << 30, description: description.into(), ..Disk::default() }
    }

    fn machine() -> DiskInventory {
        let mut inv = DiskInventory::new(vec![
            Disk { mounted_at: vec!["/".into(), "/home".into()], holds_running_root: true, ..disk("ada0", 500, "APPLE SSD") },
            Disk { mounted_at: vec!["/media/photos".into()], ..disk("ada1", 256, "Scratch") },
            disk("ada2", 128, "Crucial CT128"),
            disk("da0", 2, "SanDisk Cruzer"),
        ]);
        inv.imported_pools = vec!["zroot".into()];
        inv
    }

    fn with_account(mut m: InstallerModel, password: &str) -> InstallerModel {
        m.account_name = "jkane".into();
        m.account_full_name = "J Kane".into();
        m.account_password = password.into();
        m.account_confirm = password.into();
        m
    }

    fn ready() -> InstallerModel {
        let mut m = with_account(InstallerModel::new(machine()), "hunter2");
        m.set_disk("ada2");
        m
    }

    fn named<'a>(m: &'a InstallerModel, n: &str) -> &'a Disk {
        m.inventory.disk(n).unwrap()
    }

    /// **The live-medium case, at the screen**: a disk holding an unimported
    /// pool is choosable only after being asked about, and says what is on it.
    #[test]
    fn the_disk_picker_shows_a_disk_that_already_holds_a_system() {
        let inv = DiskInventory::new(vec![
            Disk { existing_pools: vec!["zroot".into()], partition_kinds: vec!["efi".into(), "freebsd-zfs".into()], free_bytes: 1 << 20, has_partition_table: true, ..disk("nvd0", 900, "Samsung SSD 980") },
            disk("da0", 64, "SanDisk Cruzer"),
        ]);
        let mut m = with_account(InstallerModel::new(inv), "x");
        let occupied = named(&m, "nvd0").clone();
        assert!(m.needs_erasing(&occupied), "it needs erasing —");
        assert!(!m.is_blocked(&occupied), "— but nothing makes it impossible");
        assert!(m.objection(&occupied).contains("zroot"), "the row names what would be destroyed: {}", m.objection(&occupied));
        m.enter(Spoke::Disk);
        m.selection = 0;
        assert!(!m.choose_selection(), "it must ask before taking it");
        assert_eq!(m.page, Page::EraseConfirm("nvd0".into()));
        let stick = named(&m, "da0").clone();
        assert_eq!(m.objection(&stick), "");
        assert!(!m.is_blocked(&stick) && !m.needs_erasing(&stick), "the empty stick beside it is still choosable");
    }

    fn crowded_machine() -> DiskInventory {
        DiskInventory::new(vec![
            Disk { partition_kinds: ["efi", "ms-reserved", "ms-basic-data", "ms-recovery"].map(String::from).into(), free_bytes: 1_776_128, has_partition_table: true, ..disk("nda0", 931, "WD_BLACK SN850X") },
            Disk { existing_pools: vec!["zroot".into()], partition_kinds: ["efi", "freebsd-boot", "freebsd-swap", "freebsd-zfs"].map(String::from).into(), free_bytes: 728_576, has_partition_table: true, ..disk("nda1", 931, "Samsung SSD 990 PRO") },
            Disk { mounted_at: vec!["/".into()], holds_running_root: true, partition_kinds: vec!["efi".into(), "freebsd-ufs".into()], free_bytes: 0, has_partition_table: true, ..disk("da0", 14, "Kingston DataTraveler") },
        ])
    }

    fn at_disk_spoke() -> InstallerModel {
        let mut m = with_account(InstallerModel::new(crowded_machine()), "x");
        m.enter(Spoke::Disk);
        m
    }

    fn asked_about(n: usize) -> InstallerModel {
        let mut m = at_disk_spoke();
        m.selection = n;
        assert!(!m.choose_selection());
        m
    }

    /// **The dead end this replaces**: a full disk opens a sheet.
    #[test]
    fn a_full_disk_asks_instead_of_doing_nothing() {
        let m = asked_about(0);
        assert_eq!(m.page, Page::EraseConfirm("nda0".into()));
        assert_eq!(m.disk(), "", "nothing is chosen until the sheet is answered");
    }

    /// The sheet names the disk and what is on it; the words around them are
    /// painted (installer.rs paint_erase_confirm), not a model string.
    #[test]
    fn the_sheet_names_the_disk_and_what_is_on_it() {
        let m = asked_about(0);
        let d = m.erase_subject().unwrap();
        assert_eq!(d.name, "nda0");
        assert!(d.contents().contains(&"ms-basic-data".to_string()), "{:?}", d.contents());
        assert!(asked_about(1).erase_subject().unwrap().contents().contains(&"ZFS pool zroot".to_string()), "our own disk names its pool");
    }

    #[test]
    fn confirming_takes_the_disk_and_grants_the_permission() {
        let mut m = asked_about(1);
        m.confirm_erase();
        assert_eq!((m.disk(), m.erase_confirmed(), &m.page), ("nda1", true, &Page::Hub));
        assert!(m.plan(None, "$6$x", None).erase_existing_data, "the permission reaches the plan");
    }

    #[test]
    fn cancelling_grants_nothing_and_chooses_nothing() {
        let mut m = asked_about(1);
        m.cancel_erase();
        assert_eq!((m.disk(), m.erase_confirmed()), ("", false));
        assert_eq!(m.page, Page::Spoke(Spoke::Disk), "back to the list, not to the hub");
    }

    #[test]
    fn consent_does_not_follow_the_person_to_another_disk() {
        let mut m = asked_about(1);
        m.confirm_erase();
        m.enter(Spoke::Disk);
        m.selection = 0;
        assert!(!m.choose_selection(), "it must ask again");
        assert_eq!(m.page, Page::EraseConfirm("nda0".into()));
        assert!(m.erase_confirmed(), "nda1's own answer survives being asked about another disk");
        assert!(!m.plan(Some("nda0"), "$6$x", None).erase_existing_data, "a plan for another disk inherits no permission");
        assert!(m.plan(Some("nda1"), "$6$x", None).erase_existing_data, "the disk it was given for still has it");
        m.cancel_erase();
        assert_eq!(m.disk(), "nda1");
        assert!(!m.erase_confirmed(), "cancelling withdraws the pending question's consent");
    }

    #[test]
    fn confirming_a_second_disk_moves_the_consent_to_it() {
        let mut m = asked_about(1);
        m.confirm_erase();
        m.enter(Spoke::Disk);
        m.selection = 0;
        assert!(!m.choose_selection());
        m.confirm_erase();
        assert_eq!((m.disk(), m.erase_confirmed()), ("nda0", true));
        assert!(m.plan(None, "$6$x", None).erase_existing_data);
    }

    /// The guarantee lives in the setter: the screen is not the only caller.
    #[test]
    fn assigning_the_disk_directly_also_withdraws_consent() {
        let mut m = asked_about(1);
        m.confirm_erase();
        m.set_disk("nda0");
        assert!(!m.erase_confirmed());
    }

    #[test]
    fn a_disk_nothing_can_make_installable_is_still_just_refused() {
        let mut m = at_disk_spoke();
        m.selection = 2;
        assert!(m.is_blocked(&m.installable_disks()[2].clone()));
        assert!(!m.choose_selection());
        assert_eq!(m.page, Page::Spoke(Spoke::Disk), "no sheet: there is nothing to ask");
    }

    #[test]
    fn the_sheets_default_button_is_cancel() {
        let m = asked_about(0);
        let l = installer_layout(520.0, 380.0, &m, &mut |s| s.len() as f64 * 7.0);
        assert_eq!(l.secondary_label, "Cancel");
        assert!(l.primary_label.contains("nda0"), "the destructive button names the disk: {}", l.primary_label);
    }

    #[test]
    fn the_install_button_is_dead_until_the_required_spokes_are_answered() {
        let mut m = InstallerModel::new(machine());
        assert!(!m.can_install());
        assert_eq!(m.outstanding(), [Spoke::Disk, Spoke::Account]);
        m.set_disk("ada2");
        assert!(!m.can_install(), "a disk alone is not enough");
        assert_eq!(m.outstanding(), [Spoke::Account]);
        let m = with_account(m, "hunter2");
        assert!(m.can_install());
        assert!(m.outstanding().is_empty());
    }

    #[test]
    fn keyboard_and_time_zone_are_not_required_because_they_have_real_defaults() {
        let m = ready();
        assert!(m.can_install(), "an unvisited keyboard spoke blocked the install");
        assert_eq!(m.status(Spoke::Keyboard), "U.S. (default)");
        assert_eq!(m.status(Spoke::Timezone), "UTC (default)");
        assert!(m.complete(Spoke::Keyboard) && m.complete(Spoke::Timezone));
    }

    #[test]
    fn every_spoke_says_something_including_the_ones_that_are_not_done() {
        let m = InstallerModel::new(machine());
        for s in Spoke::ALL {
            assert!(m.status(s).chars().count() > 8, "{s:?}: {}", m.status(s));
        }
        assert_eq!(m.status(Spoke::Disk), "Choose a disk to install onto");
        assert_eq!(m.status(Spoke::Account), "No account will be created");
    }

    #[test]
    fn the_readiness_line_names_what_is_missing_and_then_what_will_happen() {
        let mut m = InstallerModel::new(machine());
        assert!(m.readiness().contains("disk") && m.readiness().contains("account"), "{}", m.readiness());
        m.set_disk("ada2");
        assert!(m.readiness().contains("account") && !m.readiness().contains("disk"), "{}", m.readiness());
        let m = with_account(InstallerModel::new(machine()), "x");
        assert_eq!(m.readiness(), "Choose an installation disk before installing.");
        let r = ready().readiness();
        assert!(r.contains("ada2") && r.to_lowercase().contains("erase"), "{r}");
    }

    #[test]
    fn every_disk_is_shown_even_the_ones_that_cannot_be_used() {
        let m = InstallerModel::new(machine());
        assert_eq!(m.installable_disks().iter().map(|d| d.name.as_str()).collect::<Vec<_>>(), ["ada0", "ada1", "ada2", "da0"]);
    }

    #[test]
    fn the_disk_you_booted_from_is_shown_with_the_reason_and_cannot_be_chosen() {
        let mut m = InstallerModel::new(machine());
        let root = named(&m, "ada0").clone();
        assert!(m.is_blocked(&root));
        assert!(m.objection(&root).contains("running from"), "{}", m.objection(&root));
        m.enter(Spoke::Disk);
        m.selection = 0;
        assert!(!m.choose_selection());
        assert_eq!(m.disk(), "", "the installer accepted the disk it is running from");
        assert_eq!(m.page, Page::Spoke(Spoke::Disk), "a refused choice left the spoke as if it had worked");
        m.selection = 2;
        assert!(m.choose_selection());
        assert_eq!((m.disk(), &m.page), ("ada2", &Page::Hub));
    }

    #[test]
    fn a_disk_in_use_and_a_disk_too_small_each_say_why() {
        let m = InstallerModel::new(machine());
        assert!(m.objection(named(&m, "ada1")).contains("in use"), "{}", m.objection(named(&m, "ada1")));
        assert!(m.objection(named(&m, "da0")).contains("needs at least"), "{}", m.objection(named(&m, "da0")));
        assert_eq!(m.objection(named(&m, "ada2")), "");
    }

    /// The disk spoke shows only objections about the disk, or every row
    /// grows a complaint about a password.
    #[test]
    fn a_missing_account_is_not_the_disks_fault() {
        let m = InstallerModel::new(machine());
        assert_eq!(m.objection(named(&m, "ada2")), "");
    }

    #[test]
    fn the_chosen_disk_is_described_by_what_it_is_not_by_its_name() {
        let mut m = ready();
        let s = m.status(Spoke::Disk);
        assert!(s.contains("ada2") && s.contains("128.0 GB") && s.contains("Crucial"), "{s}");
        m.inventory = DiskInventory::new(vec![]);
        assert!(m.status(Spoke::Disk).contains("no longer there"), "{}", m.status(Spoke::Disk));
        assert!(!m.can_install(), "a vanished disk still counted as chosen");
    }

    #[test]
    fn a_password_that_does_not_match_is_said_on_the_hub_not_swallowed() {
        let mut m = ready();
        m.account_confirm = "hunter3".into();
        assert!(!m.can_install());
        assert_eq!(m.password_problem(), "The passwords do not match");
        assert_eq!(m.status(Spoke::Account), "The passwords do not match", "the hub hid the reason the install is blocked");
    }

    #[test]
    fn an_account_with_no_password_is_refused() {
        let m = with_account(ready(), "");
        assert!(!m.can_install());
        assert!(m.status(Spoke::Account).contains("no password"), "{}", m.status(Spoke::Account));
    }

    #[test]
    fn the_account_says_whether_it_can_administer() {
        let mut m = ready();
        assert!(m.status(Spoke::Account).contains("administer"));
        m.account_is_administrator = false;
        assert!(!m.status(Spoke::Account).contains("administer"));
    }

    #[test]
    fn spokes_can_be_visited_in_any_order_and_remember_where_you_left_off() {
        let mut m = InstallerModel::new(machine());
        let pick = |m: &mut InstallerModel, s: Spoke, i: usize| {
            m.enter(s);
            m.selection = i;
            m.choose_selection()
        };
        pick(&mut m, Spoke::Timezone, 3);
        assert_eq!((m.timezone.as_str(), &m.page), (TIMEZONES[3], &Page::Hub));
        pick(&mut m, Spoke::Disk, 2);
        assert_eq!(m.disk(), "ada2");
        pick(&mut m, Spoke::Keyboard, 6);
        assert_eq!(m.keymap, keymap_files()[6]);
        for (s, expected) in [(Spoke::Timezone, 3), (Spoke::Disk, 2), (Spoke::Keyboard, 6)] {
            m.enter(s);
            assert_eq!(m.selection, expected, "{s:?} opened at {}, forgetting the choice already made", m.selection);
        }
    }

    #[test]
    fn leaving_a_spoke_without_choosing_changes_nothing() {
        let mut m = ready();
        m.enter(Spoke::Disk);
        m.selection = 0;
        m.back();
        assert_eq!((m.disk(), &m.page), ("ada2", &Page::Hub));
    }

    /// What the person chose is what gets run, against a plan built by hand.
    #[test]
    fn the_plan_says_what_the_screens_said() {
        let mut m = ready();
        m.hostname = "jaguar".into();
        m.enter(Spoke::Keyboard);
        m.selection = 1;
        m.choose_selection();
        m.enter(Spoke::Timezone);
        m.selection = 3;
        m.choose_selection();
        let mut expected = InstallPlan::new("ada2");
        expected.sets = vec!["base.txz".into(), "kernel.txz".into(), "abyss.tzst".into()];
        expected.dist_directory = "/usr/freebsd-dist".into();
        expected.hostname = "jaguar".into();
        expected.timezone = "America/Chicago".into();
        expected.keymap = "uk.kbd".into();
        expected.root_password_hash = "*".into();
        expected.accounts = vec![Account { name: "jkane".into(), full_name: "J Kane".into(), password_hash: "$6$fake".into(), groups: vec!["wheel".into(), "operator".into(), "audio".into()], shell: "/bin/sh".into() }];
        let mut built = m.plan(None, "$6$fake", None);
        built.dist_directory = "/usr/freebsd-dist".into(); // $ABYSS_DIST_DIR may say otherwise here
        assert_eq!(built, expected);
    }

    #[test]
    fn the_aqua_installer_installs_this_desktop() {
        let p = ready().plan(None, "$6$fake", None);
        assert!(p.installs_desktop(), "the Aqua installer did not install the desktop");
        assert_eq!(p.sets[0], "base.txz", "base still has to be first");
        let rc = install::rc_conf(&p);
        assert!(rc.contains("abyss_loginwindow_greeter=\"YES\""), "{rc}");
        assert!(!rc.contains("abyss_desktop_user"));
    }

    #[test]
    fn the_trial_plan_behind_an_objection_matches_the_real_one() {
        let mut m = ready();
        m.set_disk("");
        assert_eq!(m.objection(named(&m, "ada2")), "");
        m.set_disk("ada2");
        assert_eq!(install::problems(&m.plan(None, "$6$x", None), &m.inventory), []);
    }

    #[test]
    fn the_plan_the_gui_builds_is_one_the_installer_will_accept() {
        let m = ready();
        assert_eq!(install::problems(&m.plan(None, "$6$fake", None), &m.inventory), []);
        assert!(install::compile(&m.plan(None, "$6$fake", None), &m.inventory).is_ok());
    }

    #[test]
    fn an_incomplete_hub_cannot_produce_an_installable_plan() {
        let mut m = InstallerModel::new(machine());
        m.set_disk("ada2");
        assert!(!m.can_install());
        assert!(install::problems(&m.plan(None, "$6$fake", None), &m.inventory).contains(&PlanRefusal::NoAdministrator));
    }

    #[test]
    fn root_gets_no_password_and_the_user_gets_wheel() {
        let p = ready().plan(None, "$6$fake", None);
        assert_eq!(p.root_password_hash, "*");
        assert!(p.accounts[0].is_administrator());
    }

    #[test]
    fn no_plaintext_password_ever_reaches_a_plan() {
        let m = ready();
        let p = m.plan(None, "$6$fake", None);
        assert!(!p.accounts.iter().any(|a| a.password_hash.contains("hunter2")));
        assert!(!install::render(&install::compile(&p, &m.inventory).unwrap()).contains("hunter2"));
    }

    #[test]
    fn a_machine_with_no_disks_says_so_rather_than_offering_nothing() {
        let mut m = InstallerModel::new(DiskInventory::new(vec![]));
        assert!(m.status(Spoke::Disk).contains("No disk"), "{}", m.status(Spoke::Disk));
        m.inventory_error = "disk discovery needs FreeBSD's geom(8)".into();
        assert_eq!(m.status(Spoke::Disk), "disk discovery needs FreeBSD's geom(8)");
    }

    #[test]
    fn the_keyboard_spoke_says_the_layouts_name_not_its_file() {
        let mut m = ready();
        assert_eq!(m.status(Spoke::Keyboard), "U.S. (default)");
        m.enter(Spoke::Keyboard);
        m.selection = 6;
        m.choose_selection();
        assert_eq!(m.keymap, "us.dvorak.kbd", "the plan keeps the file");
        assert_eq!(m.status(Spoke::Keyboard), "Dvorak");
        assert_eq!(keymap_names().len(), keymap_files().len());
        assert_eq!(keymap_names()[1], "British");
    }
}
