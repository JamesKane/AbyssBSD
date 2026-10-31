//! The Accounts pane (AccountsPane.swift, P16.6a): the people who can log
//! in, each Admin or Standard; New User… and Delete User; and who, if
//! anyone, is logged in automatically at boot. Every change goes through the
//! settings helper as an `accounts` plan.
//!
//! - **New User…** asks for a name, a short name, the password twice, and
//!   whether they may administer this computer. The password is hashed
//!   here (SHA-512 crypt) and only the hash goes to the helper.
//! - **Delete User** asks first, and keeps the home folder unless told.
//! - **Log in automatically as …** replaces the login window at boot.
//!
//! Read, not remembered: the password file, the group file, rc.conf.

use super::settings_client::{self as client, Apply};
use super::{at, log, Pane, PrefsHost};
use aquadraw::canvas::Canvas;
use aquadraw::color::Color;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use login::accounts as login_accounts;
use settings::{AccountAction, SettingsPlan};
use std::cell::RefCell;
use std::rc::{Rc, Weak};
use surface::keyboard::{KeyEvent, KeyModifiers, KeySym};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AccountRow {
    pub name: String,
    pub full_name: String,
    pub admin: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UserField {
    FullName,
    ShortName,
    Password,
    Verify,
}

impl UserField {
    pub const ALL: [UserField; 4] = [UserField::FullName, UserField::ShortName, UserField::Password, UserField::Verify];
}

/// New User…'s sheet.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct NewUserForm {
    pub full_name: String,
    pub short_name: String,
    pub password: String,
    pub verify: String,
    pub admin: bool,
    pub focus: usize,
    pub problem: String,
}

impl NewUserForm {
    pub fn get(&self, f: UserField) -> &str {
        match f {
            UserField::FullName => &self.full_name,
            UserField::ShortName => &self.short_name,
            UserField::Password => &self.password,
            UserField::Verify => &self.verify,
        }
    }
    fn field_mut(&mut self, f: UserField) -> &mut String {
        match f {
            UserField::FullName => &mut self.full_name,
            UserField::ShortName => &mut self.short_name,
            UserField::Password => &mut self.password,
            UserField::Verify => &mut self.verify,
        }
    }
    pub fn focused(&self) -> UserField {
        UserField::ALL[self.focus]
    }

    /// Edit the focused field. The short name follows the full name until it
    /// is typed itself, as the Mac's does.
    fn edit(&mut self, f: impl FnOnce(&mut String)) {
        let followed = self.short_name == suggest(&self.full_name);
        let which = self.focused();
        f(self.field_mut(which));
        if which == UserField::FullName && followed {
            self.short_name = suggest(&self.full_name)
        }
    }

    pub fn type_text(&mut self, text: &str) {
        if text.is_empty() || !text.chars().all(|c| c as u32 >= 0x20 && c as u32 != 0x7f) {
            return;
        }
        self.edit(|s| *s += text);
        self.problem.clear()
    }
    pub fn backspace(&mut self) {
        self.edit(|s| {
            s.pop();
        })
    }
    pub fn tab(&mut self, delta: i64) {
        self.focus = ((self.focus as i64 + delta).rem_euclid(4)) as usize
    }

    /// Why it cannot be created yet, in the sheet's words.
    pub fn why_not(&self) -> Option<&'static str> {
        if self.short_name.is_empty() {
            Some("Type a short name.")
        } else if self.password.is_empty() {
            Some("Type a password.")
        } else if self.password != self.verify {
            Some("The passwords do not match.")
        } else {
            None
        }
    }

    /// Forget what was typed.
    pub fn clear(&mut self) {
        self.password.clear();
        self.verify.clear()
    }
}

/// "Ada Lovelace" → "ada": the first word, lower-cased, letters and digits.
pub fn suggest(full: &str) -> String {
    full.split(' ').find(|w| !w.is_empty()).unwrap_or("").to_lowercase().chars().filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit()).take(16).collect()
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AccountsPaneState {
    pub accounts: Vec<AccountRow>,
    pub selected: Option<usize>,
    pub auto_login: Option<String>,
    pub form: Option<NewUserForm>,
    pub confirming_delete: bool,
    pub remove_home: bool,
    pub note: String,
    pub busy: bool,
}

impl AccountsPaneState {
    pub fn selected_account(&self) -> Option<&AccountRow> {
        self.selected.and_then(|i| self.accounts.get(i))
    }

    /// The accounts from a passwd file, administrators from group's wheel,
    /// the automatic login from rc.conf.
    pub fn read(passwd: &str, group: &str, rc_conf: &str) -> AccountsPaneState {
        let admins = login_accounts::members("wheel", group);
        let accounts: Vec<AccountRow> = login_accounts::parse(passwd).into_iter().map(|a| AccountRow { admin: admins.contains(&a.name), name: a.name, full_name: a.full_name }).collect();
        AccountsPaneState { selected: (!accounts.is_empty()).then_some(0), accounts, auto_login: login_accounts::auto_login(rc_conf), ..AccountsPaneState::default() }
    }

    pub fn sample() -> AccountsPaneState {
        let row = |n: &str, f: &str, admin| AccountRow { name: n.into(), full_name: f.into(), admin };
        AccountsPaneState { accounts: vec![row("ada", "Ada Lovelace", true), row("grace", "Grace Hopper", false)], selected: Some(0), ..AccountsPaneState::default() }
    }

    /// The sample with New User… open and filled in.
    pub fn sample_new() -> AccountsPaneState {
        let mut f = NewUserForm::default();
        f.type_text("Alan Turing");
        f.tab(1);
        f.tab(1);
        f.type_text("enigma");
        f.tab(1);
        f.type_text("enigma");
        f.admin = true;
        AccountsPaneState { form: Some(f), ..AccountsPaneState::sample() }
    }

    fn sheet_open(&self) -> bool {
        self.form.is_some() || self.confirming_delete
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AccountsLayout {
    pub list: Rect,
    pub rows: Vec<Rect>,
    pub new_user: Rect,
    pub delete_user: Rect,
    pub auto_login: Rect,
    /// The sheet, when one is open.
    pub sheet: Rect,
    pub fields: Vec<Rect>,
    pub admin_box: Rect,
    pub cancel: Rect,
    pub confirm: Rect,
}

pub fn accounts_layout(body: Rect, s: &AccountsPaneState) -> AccountsLayout {
    let (left, w) = (body.x + 40.0, body.w - 80.0);
    let list = Rect::new(left, body.y + 40.0, w, 6.0 * 40.0);
    let mut l = AccountsLayout {
        list,
        rows: (0..s.accounts.len().min(6)).map(|i| Rect::new(left, list.y + i as f64 * 40.0, w, 40.0)).collect(),
        new_user: Rect::new(left, list.y + list.h + 12.0, 120.0, 22.0),
        delete_user: Rect::new(left + 132.0, list.y + list.h + 12.0, 120.0, 22.0),
        auto_login: Rect::new(left, list.y + list.h + 52.0, w, 22.0),
        ..AccountsLayout::default()
    };
    let h = if s.form.is_some() { 250.0 } else if s.confirming_delete { 150.0 } else { return l };
    let sh = Rect::new(body.x + (body.w - 420.0) / 2.0, body.y, 420.0, h);
    l.sheet = sh;
    if s.form.is_some() {
        l.fields = (0..4).map(|i| Rect::new(sh.x + 150.0, sh.y + 22.0 + i as f64 * 34.0, 240.0, 22.0)).collect();
        l.admin_box = Rect::new(sh.x + 150.0, sh.y + 160.0, 240.0, 22.0)
    } else {
        l.admin_box = Rect::new(sh.x + 24.0, sh.y + 70.0, 300.0, 22.0)
    }
    l.cancel = Rect::new(sh.x + sh.w - 240.0, sh.y + sh.h - 36.0, 100.0, 22.0);
    l.confirm = Rect::new(sh.x + sh.w - 128.0, sh.y + sh.h - 36.0, 108.0, 22.0);
    l
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccountsHit {
    Row(usize),
    NewUser,
    DeleteUser,
    AutoLogin,
    Field(usize),
    AdminBox,
    Cancel,
    Confirm,
}

pub fn accounts_hit(l: &AccountsLayout, s: &AccountsPaneState, x: f64, y: f64) -> Option<AccountsHit> {
    if s.sheet_open() {
        // A sheet is modal: only it answers.
        if let Some(i) = l.fields.iter().position(|r| r.contains(x, y)) {
            return Some(AccountsHit::Field(i));
        }
        return [(l.admin_box, AccountsHit::AdminBox), (l.cancel, AccountsHit::Cancel), (l.confirm, AccountsHit::Confirm)].into_iter().find(|(r, _)| r.contains(x, y)).map(|(_, h)| h);
    }
    if let Some(i) = l.rows.iter().position(|r| r.contains(x, y)) {
        return Some(AccountsHit::Row(i));
    }
    [(l.new_user, AccountsHit::NewUser), (l.delete_user, AccountsHit::DeleteUser), (l.auto_login, AccountsHit::AutoLogin)].into_iter().find(|(r, _)| r.contains(x, y)).map(|(_, h)| h)
}

fn paint_sheet_background(c: &mut Canvas, r: Rect) {
    let t = c.theme.tokens.clone();
    c.set_color(Color::new(0.0, 0.0, 0.0, 0.25));
    c.cr.rectangle(r.x + 3.0, r.y + 3.0, r.w, r.h);
    c.cr.fill();
    c.set_color(t.content_background);
    c.cr.rectangle(r.x, r.y, r.w, r.h);
    c.cr.fill();
    c.pinstripe(r, Color::new(1.0, 1.0, 1.0, 0.4));
    c.set_color(Color::new(0.55, 0.55, 0.55, 1.0));
    c.cr.set_line_width(1.0);
    c.cr.rectangle(r.x + 0.5, r.y + 0.5, r.w - 1.0, r.h - 1.0);
    c.cr.stroke()
}

pub fn paint_accounts(c: &mut Canvas, l: &AccountsLayout, s: &AccountsPaneState) {
    let t = c.theme.tokens.clone();
    let text = |c: &mut Canvas, s: &str, x: f64, y: f64, k, size, style| c.text_left(s, x, y, k, size, style, Role::Interface);
    let white = Color::new(1.0, 1.0, 1.0, 1.0);
    text(c, "The people who can log in to this computer:", l.list.x, l.list.y - 12.0, t.body_text, 13.0, Style::Regular);
    c.set_color(white);
    c.cr.rectangle(l.list.x, l.list.y, l.list.w, l.list.h);
    c.cr.fill();
    c.set_color(Color::new(0.6, 0.6, 0.6, 1.0));
    c.cr.set_line_width(1.0);
    c.cr.rectangle(l.list.x + 0.5, l.list.y + 0.5, l.list.w - 1.0, l.list.h - 1.0);
    c.cr.stroke();
    for (i, (a, r)) in s.accounts.iter().zip(&l.rows).enumerate() {
        let on = Some(i) == s.selected;
        if on {
            c.set_color(Color::new(0.22, 0.46, 0.84, 1.0));
            c.cr.rectangle(r.x + 1.0, r.y, r.w - 2.0, r.h);
            c.cr.fill()
        }
        let ink = if on { white } else { t.body_text };
        c.icon("icon.myAccount", Rect::new(r.x + 8.0, r.y + 6.0, 28.0, 28.0));
        text(c, &a.full_name, r.x + 46.0, r.y + 18.0, ink, 13.0, Style::Bold);
        let auto = if s.auto_login.as_ref() == Some(&a.name) { " — logs in automatically" } else { "" };
        text(c, &format!("{}{auto}", a.name), r.x + 46.0, r.y + 33.0, if on { ink } else { t.secondary_text }, 11.0, Style::Regular);
        let kind = if a.admin { "Admin" } else { "Standard" };
        let kw = c.text_width(kind, 12.0, Style::Regular, Role::Interface);
        text(c, kind, r.x + r.w - kw - 12.0, r.y + 25.0, ink, 12.0, Style::Regular)
    }
    c.gel_button(l.new_user, "New User…", false, false);
    c.gel_button(l.delete_user, "Delete User", false, false);
    let who = s.selected_account();
    c.checkbox(Rect::new(l.auto_login.x, l.auto_login.y + 3.0, 16.0, 16.0), who.is_some_and(|w| s.auto_login.as_ref() == Some(&w.name)));
    text(c, &format!("Log in automatically as {}", who.map_or("the selected user", |w| &w.full_name)), l.auto_login.x + 24.0, l.auto_login.y + 15.0, t.body_text, 13.0, Style::Regular);
    if !s.note.is_empty() {
        text(c, &s.note, l.list.x, l.auto_login.y + 48.0, t.body_text, 12.0, Style::Regular)
    }

    if let Some(f) = &s.form {
        paint_sheet_background(c, l.sheet);
        for ((field, label), r) in UserField::ALL.iter().zip(["Name:", "Short Name:", "Password:", "Verify:"]).zip(&l.fields) {
            let w = c.text_width(label, 13.0, Style::Regular, Role::Interface);
            text(c, label, r.x - 12.0 - w, r.y + 16.0, t.body_text, 13.0, Style::Regular);
            let v = f.get(*field);
            let shown = if matches!(field, UserField::Password | UserField::Verify) { "•".repeat(v.chars().count()) } else { v.to_string() };
            c.text_field(*r, &shown, f.focused() == *field, "")
        }
        c.checkbox(Rect::new(l.admin_box.x, l.admin_box.y + 3.0, 16.0, 16.0), f.admin);
        text(c, "Allow user to administer this computer", l.admin_box.x + 24.0, l.admin_box.y + 15.0, t.body_text, 12.0, Style::Regular);
        if !f.problem.is_empty() {
            text(c, &f.problem, l.sheet.x + 24.0, l.cancel.y + 16.0, Color::new(0.65, 0.05, 0.05, 1.0), 11.0, Style::Regular)
        }
        c.gel_button(l.cancel, "Cancel", false, false);
        c.gel_button(l.confirm, "Create User", true, false)
    } else if s.confirming_delete
        && let Some(who) = who
    {
        paint_sheet_background(c, l.sheet);
        text(c, &format!("Delete the account {} ({})?", who.full_name, who.name), l.sheet.x + 24.0, l.sheet.y + 40.0, t.body_text, 13.0, Style::Bold);
        c.checkbox(Rect::new(l.admin_box.x, l.admin_box.y + 3.0, 16.0, 16.0), s.remove_home);
        text(c, "Delete the home folder too", l.admin_box.x + 24.0, l.admin_box.y + 15.0, t.body_text, 12.0, Style::Regular);
        c.gel_button(l.cancel, "Cancel", false, false);
        c.gel_button(l.confirm, "Delete", true, false)
    }
}

fn alog(s: &str) {
    log(&format!("accounts: {s}"))
}

pub struct AccountsPane {
    me: Weak<AccountsPane>,
    state: RefCell<AccountsPaneState>,
    layout: RefCell<Option<AccountsLayout>>,
    applying: RefCell<Option<Rc<Apply>>>,
    dumped: RefCell<Option<AccountsLayout>>,
}

impl AccountsPane {
    pub fn new(state: AccountsPaneState) -> Rc<AccountsPane> {
        Rc::new_cyclic(|me| AccountsPane { me: me.clone(), state: RefCell::new(state), layout: RefCell::new(None), applying: RefCell::new(None), dumped: RefCell::new(None) })
    }

    /// The password file, the group file and rc.conf: under
    /// `$ABYSS_ACCOUNTS_ROOT` and `$ABYSS_RC_CONF` for a test's scratch.
    fn load(&self, h: &Rc<PrefsHost>) {
        let root = std::env::var("ABYSS_ACCOUNTS_ROOT").unwrap_or_default();
        let rc = std::env::var("ABYSS_RC_CONF").unwrap_or_else(|_| "/etc/rc.conf".into());
        let text = |p: &str| std::fs::read(p).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
        let mut fresh = AccountsPaneState::read(&text(&format!("{root}/etc/passwd")), &text(&format!("{root}/etc/group")), &text(&rc));
        {
            let old = self.state.borrow();
            if let Some(i) = old.selected_account().and_then(|k| fresh.accounts.iter().position(|a| a.name == k.name)) {
                fresh.selected = Some(i)
            }
            fresh.note = old.note.clone();
        }
        let who: Vec<String> = fresh.accounts.iter().map(|a| format!("{}{}", a.name, if a.admin { "(admin)" } else { "" })).collect();
        alog(&format!("{}; automatic login: {}", who.join(" "), fresh.auto_login.as_deref().unwrap_or("none")));
        *self.state.borrow_mut() = fresh;
        h.redraw()
    }

    fn press_hit(&self, h: &Rc<PrefsHost>, hit: AccountsHit) {
        if self.state.borrow().busy {
            return;
        }
        let mut s = self.state.borrow_mut();
        match hit {
            AccountsHit::Row(i) => s.selected = Some(i),
            AccountsHit::NewUser => {
                s.form = Some(NewUserForm::default());
                s.note.clear();
                alog("new user sheet")
            }
            AccountsHit::DeleteUser => {
                let Some(who) = s.selected_account().map(|a| a.name.clone()) else { return };
                s.confirming_delete = true;
                s.remove_home = false;
                alog(&format!("delete sheet for {who}"))
            }
            AccountsHit::AutoLogin => {
                let Some(who) = s.selected_account().map(|a| a.name.clone()) else { return };
                let on = s.auto_login.as_ref() != Some(&who);
                drop(s);
                return self.apply(h, AccountAction::AutoLogin(on.then(|| who.clone())), &if on { format!("automatic login as {who}") } else { "no automatic login".into() });
            }
            AccountsHit::Field(i) => {
                if let Some(f) = s.form.as_mut() {
                    f.focus = i
                }
            }
            AccountsHit::AdminBox => match s.form.as_mut() {
                Some(f) => f.admin = !f.admin,
                None => s.remove_home = !s.remove_home,
            },
            AccountsHit::Cancel => {
                s.form = None;
                s.confirming_delete = false;
                alog("cancelled")
            }
            AccountsHit::Confirm => {
                drop(s);
                return self.confirm(h);
            }
        }
        drop(s);
        h.redraw()
    }

    fn confirm(&self, h: &Rc<PrefsHost>) {
        let mut s = self.state.borrow_mut();
        if let Some(mut f) = s.form.clone() {
            if let Some(why) = f.why_not() {
                f.problem = why.into();
                s.form = Some(f);
                drop(s);
                return h.redraw();
            }
            // A failure must not become an account with no password: `*` is
            // what `pw` writes for "nothing will ever match".
            let hash = abyss_sys::platform::crypt_sha512(&f.password).unwrap_or_else(|| "*".into());
            f.clear();
            s.form = None;
            drop(s);
            let what = format!("create {}{}", f.short_name, if f.admin { ", an administrator" } else { "" });
            self.apply(h, AccountAction::Add { name: f.short_name, full_name: f.full_name, password_hash: hash, admin: f.admin }, &what)
        } else if s.confirming_delete
            && let Some(who) = s.selected_account().map(|a| a.name.clone())
        {
            s.confirming_delete = false;
            let remove_home = s.remove_home;
            drop(s);
            self.apply(h, AccountAction::Delete { name: who.clone(), remove_home }, &format!("delete {who}{}", if remove_home { " and its home folder" } else { "" }))
        } else {
            drop(s);
            h.redraw()
        }
    }

    fn apply(&self, h: &Rc<PrefsHost>, action: AccountAction, what: &str) {
        if self.applying.borrow().is_some() {
            return;
        }
        alog(&format!("apply {what}"));
        let req = client::apply_request(&SettingsPlan::Accounts(action));
        let a = h.display.as_ref().and_then(|d| {
            let (me, host) = (self.me.clone(), h.clone());
            Apply::begin(d, &req, |line| if line.starts_with('[') { alog(line) }, move |ok, said| {
                let Some(p) = me.upgrade() else { return };
                *p.applying.borrow_mut() = None;
                {
                    let mut s = p.state.borrow_mut();
                    s.busy = false;
                    s.note = if ok { "Done.".into() } else { said.strip_prefix("Not applied: ").map_or(said.clone(), |e| format!("Not changed: {e}")) };
                    alog(&format!("{} — {}", if ok { "applied" } else { "not applied" }, s.note))
                }
                p.load(&host)
            })
        });
        let mut s = self.state.borrow_mut();
        match a {
            Some(a) => {
                *self.applying.borrow_mut() = Some(a);
                s.busy = true
            }
            None => {
                s.note = "Not changed: the settings helper is not running on this machine".into();
                alog(&s.note)
            }
        }
        drop(s);
        h.redraw()
    }
}

impl Pane for AccountsPane {
    fn id(&self) -> &'static str {
        "accounts"
    }
    fn shown(&self, h: &Rc<PrefsHost>) {
        self.load(h)
    }
    fn paint(&self, c: &mut Canvas, body: Rect) {
        let s = self.state.borrow().clone();
        let l = accounts_layout(body, &s);
        paint_accounts(c, &l, &s);
        *self.layout.borrow_mut() = Some(l)
    }
    /// Each row by account name, the buttons, and the sheet's fields and
    /// buttons when one is open.
    fn dump(&self) -> Vec<String> {
        let Some(l) = self.layout.borrow().clone() else { return vec![] };
        if self.dumped.borrow().as_ref() == Some(&l) {
            return vec![];
        }
        let mut line = "accounts layout".to_string();
        for (a, r) in self.state.borrow().accounts.iter().zip(&l.rows) {
            line += &format!(" row.{}={}", a.name, at(r))
        }
        line += &format!(" new={} delete={} auto={}", at(&l.new_user), at(&l.delete_user), at(&l.auto_login));
        for (i, r) in l.fields.iter().enumerate() {
            line += &format!(" field{i}={}", at(r))
        }
        if l.sheet.w > 0.0 {
            line += &format!(" admin={} cancel={} confirm={}", at(&l.admin_box), at(&l.cancel), at(&l.confirm))
        }
        *self.dumped.borrow_mut() = Some(l);
        vec![line]
    }
    fn press(&self, h: &Rc<PrefsHost>, x: f64, y: f64) -> bool {
        let Some(l) = self.layout.borrow().clone() else { return false };
        let open = self.state.borrow().sheet_open();
        let Some(hit) = accounts_hit(&l, &self.state.borrow(), x, y) else { return open };
        self.press_hit(h, hit);
        true
    }
    fn key(&self, h: &Rc<PrefsHost>, e: &KeyEvent) {
        let (form, deleting) = { let s = self.state.borrow(); (s.form.is_some(), s.confirming_delete) };
        if form {
            match e.keysym {
                KeySym::ESCAPE => return self.press_hit(h, AccountsHit::Cancel),
                // Return, and the keypad's Enter.
                KeySym::ENTER | 0xff8d => return self.confirm(h),
                _ => {}
            }
            if let Some(f) = self.state.borrow_mut().form.as_mut() {
                match e.keysym {
                    KeySym::TAB => f.tab(if e.modifiers.contains(KeyModifiers::SHIFT) { -1 } else { 1 }),
                    KeySym::BACK_TAB => f.tab(-1),
                    KeySym::BACKSPACE => f.backspace(),
                    _ => f.type_text(&e.text),
                }
            }
        } else if deleting {
            match e.keysym {
                KeySym::ESCAPE => return self.press_hit(h, AccountsHit::Cancel),
                KeySym::ENTER => return self.confirm(h),
                _ => return,
            }
        } else {
            let mut s = self.state.borrow_mut();
            let n = s.accounts.len();
            match e.keysym {
                KeySym::DOWN if n > 0 => s.selected = Some(s.selected.map_or(0, |i| (i + 1).min(n - 1))),
                KeySym::UP if n > 0 => s.selected = Some(s.selected.map_or(0, |i| i.saturating_sub(1))),
                _ => return,
            }
        }
        h.redraw()
    }
    fn keeps_escape(&self) -> bool {
        self.state.borrow().sheet_open()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_short_name_follows_the_full_name_until_typed_itself() {
        let mut f = NewUserForm::default();
        f.type_text("Ada Lovelace");
        assert_eq!(f.short_name, "ada");
        f.tab(1);
        f.backspace();
        f.type_text("x");
        f.tab(-1);
        f.type_text("!");
        assert_eq!(f.short_name, "adx", "typed itself, it no longer follows");
        assert_eq!(suggest("  Grace B. Hopper"), "grace");
        assert_eq!(f.why_not(), Some("Type a password."));
        f.password = "a".into();
        assert_eq!(f.why_not(), Some("The passwords do not match."));
    }

    #[test]
    fn read_from_the_files_and_a_sheet_answers_alone() {
        let s = AccountsPaneState::read("root:*:0:0:Charlie &:/root:/bin/sh\nada:*:1001:1001:Ada Lovelace:/home/ada:/bin/sh\ngrace:*:1002:1002:Grace Hopper:/home/grace:/bin/sh\n", "wheel:*:0:root,ada\n", "autologin_enable=\"YES\"\nautologin_user=\"grace\"\n");
        let names: Vec<(&str, bool)> = s.accounts.iter().map(|a| (a.name.as_str(), a.admin)).collect();
        assert!(names.contains(&("ada", true)) && names.contains(&("grace", false)), "{names:?}");
        let s = AccountsPaneState::sample_new();
        assert_eq!((s.form.as_ref().unwrap().short_name.as_str(), s.form.as_ref().unwrap().focused()), ("alan", UserField::Verify));
        let l = accounts_layout(Rect::new(0.0, 80.0, 760.0, 540.0), &s);
        let r = l.rows[1];
        assert_eq!(accounts_hit(&l, &s, r.x + 5.0, r.y + 30.0), None, "the list is under a modal sheet");
        assert_eq!(accounts_hit(&l, &s, l.confirm.x + 5.0, l.confirm.y + 5.0), Some(AccountsHit::Confirm));
    }
}
