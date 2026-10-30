//! GTK applications' menus, served as MenuWire (Bridge.swift, PHASE10
//! P10.6).
//!
//! The bar speaks one protocol. When the frontmost window is a GTK
//! application's (focus kind `gtk`), the bar sends its ordinary MenuWire
//! requests to **one** service, `menus-dbus`, with the address as `target`;
//! this answers them by asking the application, `org.gtk.Menus` and
//! `org.gtk.Actions`, over ADE's bridge.
//!
//! **A process of its own** (`abyss-dbus --menus`): the portal blocks while
//! a file dialog is open, and a menu bar must never wait on an Open panel.
//!
//! Nothing is cached: every `describe` reads the menus again and every
//! `validate` asks what is enabled. **What changes is pushed (P10.9)**: GTK
//! sends `org.gtk.Menus.Changed` only to a watcher holding a `Start`, so the
//! bridge holds one on every group while anyone watches. A signal marks the
//! application dirty; after a short quiet the menus are read again, and the
//! bars told `changed` only if the model differs, which filters the noise.

use crate::gtkmenus::{self, GtkMenuGroup};
use current_ipc::{Msg, Server};
use dbus::{Connection, Error, Message, MessageType, Value};
use menu_model::{Command, CommandResult, Enablement, GtkMenuAddress, MenuBarModel};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

pub const SERVICE_NAME: &str = "menus-dbus";

/// A jail class's menu bridge (PHASE18): applications in a jail publish
/// their menus on the jail's own bridge, which the session's cannot reach,
/// so each class has one, named for the class the bar is told with focus.
pub fn service_name_for_jail_class(class: &str) -> String {
    format!("{SERVICE_NAME}-{class}")
}

/// How long a burst of signals must be quiet before the menus are read.
const QUIET: Duration = Duration::from_millis(100);
const CALL_MS: u64 = 1000;

/// Bars watching one application's menus (P10.9).
struct Watch {
    address: GtkMenuAddress,
    subscribers: Vec<UnixStream>,
    /// The match rules asked for, to remove word for word.
    rules: Vec<String>,
    /// What the bars were last shown: `changed` is said only when it differs.
    model: Option<MenuBarModel>,
    /// A signal arrived; read again once things are quiet.
    dirty_since: Option<Instant>,
    /// The groups held with Start, by object path, to End when done.
    held: BTreeMap<String, Vec<u32>>,
}

pub struct GtkMenuBridge {
    conn: Connection,
    server: Server,
    pub served: usize,
    /// Watched applications, by target.
    watches: HashMap<String, Watch>,
    /// `changed` pushed, and re-reads that found nothing new: for the log a
    /// test reads (the second is how an echo loop would show).
    pub changes_pushed: usize,
    pub quiet_rereads: usize,
    /// Where the bridge says what it did.
    pub log: Box<dyn FnMut(&str)>,
}

/// The application's name, as the bar draws it bold: the last component of
/// its id (`org.gnome.TextEditor` → `TextEditor`).
pub fn app_name(a: &GtkMenuAddress) -> String {
    a.application_id.rsplit('.').next().unwrap_or(&a.application_id).to_owned()
}

fn menu_paths(a: &GtkMenuAddress) -> impl Iterator<Item = &String> {
    [&a.menubar_path, &a.app_menu_path].into_iter().filter(|p| !p.is_empty())
}

fn groups_value(gs: &[u32]) -> Value {
    Value::Array("u".into(), gs.iter().map(|g| Value::UInt32(*g)).collect())
}

fn end(conn: &mut Connection, a: &GtkMenuAddress, path: &str, gs: &[u32]) {
    if !gs.is_empty() {
        let _ = conn.call(Message::method_call(&a.bus_name, path, "org.gtk.Menus", "End", vec![groups_value(gs)]), CALL_MS);
    }
}

/// Every group of the menu at `path`, following links until none is
/// missing. With `keep`, the Start is held (a watch) and not ended here.
fn groups(conn: &mut Connection, a: &GtkMenuAddress, path: &str, keep: bool) -> Result<Vec<GtkMenuGroup>, Error> {
    if path.is_empty() {
        return Ok(vec![]);
    }
    let mut have = vec![];
    let mut want: BTreeSet<u32> = [0].into();
    let mut asked: BTreeSet<u32> = BTreeSet::new();
    while !want.is_empty() && asked.len() < 64 {
        asked.extend(&want);
        let ids: Vec<u32> = want.iter().copied().collect();
        let reply = conn.call(Message::method_call(&a.bus_name, path, "org.gtk.Menus", "Start", vec![groups_value(&ids)]), CALL_MS)?;
        have.extend(gtkmenus::groups_from_start_reply(&reply.body));
        want = gtkmenus::missing_groups(&have).difference(&asked).copied().collect();
    }
    // Let go, unless a watch holds it: else GTK signals nobody.
    if !keep {
        end(conn, a, path, &asked.into_iter().collect::<Vec<_>>());
    }
    Ok(have)
}

fn read(conn: &mut Connection, a: &GtkMenuAddress) -> Result<MenuBarModel, Error> {
    let menubar = groups(conn, a, &a.menubar_path, false)?;
    let app_menu = groups(conn, a, &a.app_menu_path, false)?;
    Ok(gtkmenus::model(&app_name(a), &menubar, &app_menu))
}

fn actions(conn: &mut Connection, a: &GtkMenuAddress) -> Result<HashMap<String, bool>, Error> {
    let mut out = HashMap::new();
    for (path, prefix) in [(&a.application_path, "app."), (&a.window_path, "win.")] {
        if path.is_empty() {
            continue;
        }
        let reply = conn.call(Message::method_call(&a.bus_name, path, "org.gtk.Actions", "DescribeAll", vec![]), CALL_MS)?;
        out.extend(gtkmenus::actions_from_describe_all(&reply.body, prefix));
    }
    Ok(out)
}

fn activate(conn: &mut Connection, verb: &str, a: &GtkMenuAddress) -> Result<CommandResult, Error> {
    let acts = actions(conn, a)?;
    if let Enablement::Disabled(why) = gtkmenus::enablement(&Command::new(verb, verb, ""), &acts) {
        return Ok(CommandResult::Refused(why));
    }
    let (path, name) = if let Some(n) = verb.strip_prefix("app.") {
        (&a.application_path, n)
    } else if let Some(n) = verb.strip_prefix("win.") {
        (&a.window_path, n)
    } else {
        return Ok(CommandResult::Refused(format!("{verb} is not an app. or win. action")));
    };
    let body = vec![Value::String(name.into()), Value::Array("v".into(), vec![]), Value::Array("{sv}".into(), vec![])];
    conn.call(Message::method_call(&a.bus_name, path, "org.gtk.Actions", "Activate", body), CALL_MS)?;
    Ok(CommandResult::Ok(None))
}

/// GTK sends Changed only to a watcher holding a Start: hold one on every
/// group there is now, and let go of those held before.
fn hold(conn: &mut Connection, w: &mut Watch) -> Result<(), Error> {
    let before = std::mem::take(&mut w.held);
    for path in menu_paths(&w.address) {
        let gs = groups(conn, &w.address, path, true)?.iter().map(|g| g.group).collect();
        w.held.insert(path.clone(), gs);
    }
    for (path, gs) in before {
        end(conn, &w.address, &path, &gs);
    }
    Ok(())
}

impl GtkMenuBridge {
    pub fn new(conn: Connection, service: &str) -> Result<GtkMenuBridge, current_ipc::Error> {
        let server = Server::new(service)?;
        server.set_nonblocking(true)?;
        Ok(GtkMenuBridge { conn, server, served: 0, watches: HashMap::new(), changes_pushed: 0, quiet_rereads: 0, log: Box::new(|_| {}) })
    }

    /// Wait up to `timeout_ms` for either side and answer what arrived.
    pub fn step(&mut self, timeout_ms: i32) -> Result<(), Error> {
        use abyss_sys::proc::{poll, poll_fd};
        let subs: Vec<i32> = self.watches.values().flat_map(|w| w.subscribers.iter().map(AsRawFd::as_raw_fd)).collect();
        let mut fds = vec![poll_fd(self.server.fd(), libc::POLLIN), poll_fd(self.conn.as_raw_fd(), libc::POLLIN)];
        fds.extend(subs.iter().map(|&s| poll_fd(s, libc::POLLIN)));
        // A dirty application is read within the quiet time, whatever else;
        // and what a call left queued is answered now.
        let wait = if self.conn.has_queued() {
            0
        } else if self.watches.values().any(|w| w.dirty_since.is_some()) {
            timeout_ms.min(50)
        } else {
            timeout_ms
        };
        if poll(&mut fds, wait).unwrap_or(0) > 0 || self.conn.has_queued() {
            if fds[1].revents != 0 || self.conn.has_queued() {
                for r in self.conn.receive(0)? {
                    match r.message.kind {
                        MessageType::Signal => self.signal(&r.message),
                        MessageType::MethodCall => {
                            let _ = self.conn.unknown_method(&r.message);
                        }
                        _ => {}
                    }
                }
            }
            if fds[0].revents != 0 {
                self.serve_one();
            }
            // A subscriber is only ever readable when its bar has gone (it
            // sends nothing after subscribing).
            for (i, s) in subs.iter().enumerate() {
                if fds[i + 2].revents != 0 {
                    self.unsubscribe(*s);
                }
            }
        }
        self.reread_quiet();
        Ok(())
    }

    fn serve_one(&mut self) {
        let Ok(c) = self.server.accept() else { return };
        // A menu request carries no descriptors; any that came close with it.
        let Ok(request) = current_ipc::receive(&c) else { return };
        self.served += 1;
        if request.string("method") == Some("subscribe") {
            return self.subscribe(&request, c);
        }
        let reply = self.handle(&request);
        let _ = current_ipc::send(&reply, &c);
    }

    // MARK: watching (P10.9)

    fn subscribe(&mut self, request: &Msg, c: UnixStream) {
        let Some((t, a)) = request.string("target").and_then(|t| Some((t.to_owned(), GtkMenuAddress::from_encoded(t)?))) else {
            let _ = current_ipc::send(&menu_wire::error_reply("subscribe needs a target: the address the compositor reported"), &c);
            return;
        };
        if !self.watches.contains_key(&t) {
            let mut w = Watch { address: a, subscribers: vec![], rules: vec![], model: None, dirty_since: None, held: BTreeMap::new() };
            if let Err(e) = self.watch(&mut w) {
                let _ = current_ipc::send(&menu_wire::error_reply(&format!("cannot watch it: {e}")), &c);
                return;
            }
            self.watches.insert(t.clone(), w);
        }
        let mut ok = Msg::new();
        ok.set_bool("ok", true);
        if current_ipc::send(&ok, &c).is_err() {
            return;
        }
        let w = self.watches.get_mut(&t).unwrap();
        w.subscribers.push(c);
        let msg = format!("watching {} for {} bar(s)", w.address.application_id, w.subscribers.len());
        (self.log)(&msg);
    }

    /// Start listening: the match rules, GTK's held groups, and the model as
    /// it is now, which `changed` is measured against.
    fn watch(&mut self, w: &mut Watch) -> Result<(), Error> {
        for path in menu_paths(&w.address).cloned().collect::<Vec<_>>() {
            let rule = format!("type='signal',sender='{}',path='{path}',interface='org.gtk.Menus',member='Changed'", w.address.bus_name);
            self.conn.add_match(&rule)?;
            w.rules.push(rule);
        }
        w.model = Some(read(&mut self.conn, &w.address)?);
        hold(&mut self.conn, w)
    }

    fn unsubscribe(&mut self, fd: i32) {
        let Some(t) = self.watches.iter().find(|(_, w)| w.subscribers.iter().any(|s| s.as_raw_fd() == fd)).map(|(t, _)| t.clone()) else { return };
        let w = self.watches.get_mut(&t).unwrap();
        w.subscribers.retain(|s| s.as_raw_fd() != fd);
        if !w.subscribers.is_empty() {
            return;
        }
        let w = self.watches.remove(&t).unwrap();
        for r in &w.rules {
            let _ = self.conn.remove_match(r);
        }
        for (path, gs) in &w.held {
            end(&mut self.conn, &w.address, path, gs);
        }
        (self.log)(&format!("no bar watches {} now", w.address.application_id));
    }

    /// A signal: which watched application does it concern?
    fn signal(&mut self, m: &Message) {
        let (Some(sender), Some(path)) = (&m.sender, &m.path) else { return };
        for w in self.watches.values_mut() {
            let a = &w.address;
            if a.bus_name == *sender && (*path == a.menubar_path || *path == a.app_menu_path) && m.member.as_deref() == Some("Changed") && w.dirty_since.is_none() {
                w.dirty_since = Some(Instant::now());
            }
        }
    }

    /// Read every application quiet long enough since its last signal, and
    /// tell its bars if the menus are different.
    fn reread_quiet(&mut self) {
        let due: Vec<String> = self.watches.iter().filter(|(_, w)| w.dirty_since.is_some_and(|t| t.elapsed() >= QUIET)).map(|(t, _)| t.clone()).collect();
        for t in due {
            let mut w = self.watches.remove(&t).unwrap();
            w.dirty_since = None;
            let fresh = read(&mut self.conn, &w.address).ok();
            if fresh.is_some() {
                let _ = hold(&mut self.conn, &mut w);
            }
            let name = w.address.application_id.clone();
            match fresh {
                Some(m) if Some(&m) != w.model.as_ref() => {
                    w.model = Some(m);
                    let mut msg = Msg::new();
                    msg.set_string("method", "changed");
                    w.subscribers.retain(|s| current_ipc::send(&msg, s).is_ok());
                    self.changes_pushed += 1;
                    let line = format!("{name}'s menus changed; told {} bar(s) ({} changes, {} quiet re-reads)", w.subscribers.len(), self.changes_pushed, self.quiet_rereads);
                    (self.log)(&line);
                }
                _ => {
                    self.quiet_rereads += 1;
                    let line = format!("{name} signalled, and its menus are the same ({} quiet re-reads)", self.quiet_rereads);
                    (self.log)(&line);
                }
            }
            self.watches.insert(t, w);
        }
    }

    /// One MenuWire request about the application at `target`. Whatever
    /// goes wrong (it went away, it answered nonsense), the bar gets a clean
    /// error, never a hang.
    pub fn handle(&mut self, request: &Msg) -> Msg {
        let Some(a) = request.string("target").and_then(GtkMenuAddress::from_encoded) else {
            return menu_wire::error_reply("menus-dbus needs a target: the address the compositor reported");
        };
        let conn = &mut self.conn;
        let r = match request.string("method") {
            Some("describe") => read(conn, &a).and_then(|m| Ok((m, actions(conn, &a)?))).map(|(m, acts)| menu_wire::describe_reply(&m, &|c| gtkmenus::enablement(c, &acts))),
            Some("validate") => read(conn, &a).and_then(|m| Ok((m, actions(conn, &a)?))).map(|(m, acts)| menu_wire::validate_reply(&m, &|c| gtkmenus::enablement(c, &acts))),
            Some("activate") => match request.string("verb") {
                None => return menu_wire::error_reply("activate needs a verb"),
                Some(verb) => activate(conn, verb, &a).map(|r| menu_wire::result_reply(&r)),
            },
            other => return menu_wire::error_reply(&format!("unknown method {}", other.unwrap_or("(none)"))),
        };
        r.unwrap_or_else(|e| menu_wire::error_reply(&format!("{}: {e}", a.application_id)))
    }
}
