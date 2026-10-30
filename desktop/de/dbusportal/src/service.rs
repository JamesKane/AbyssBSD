//! The service (Service.swift): own the name, answer the calls, run the
//! Finder.
//!
//! One file-chooser call, and the ordering is the whole point:
//!
//!   1. `OpenFile` arrives. The Request path is derived from the *caller's*
//!      name and *its* token, and **returned at once**.
//!   2. Only once that reply is written is `abyss-portal` called, which runs
//!      the Finder and blocks until the person decides.
//!   3. Then `Response` goes out on the path from step 1.
//!
//! Steps 2 and 3 are queued, not done while answering: a client that
//! subscribes only when its handle arrives would otherwise be subscribing
//! after the signal went, and hang with no error (PHASE8 §6.1).

use crate::portal::{chooser_response, portal_call_message, request_path, ChooserKind, ChooserOptions, PortalResponse, REQUEST_PREFIX};
use crate::settings::{self, PortalSettings};
use dbus::{Connection, Error, Message, MessageType, Value};
use std::collections::{HashMap, VecDeque};
use std::os::fd::{AsFd, BorrowedFd};

pub const BUS_NAME: &str = "org.freedesktop.portal.Desktop";
pub const OBJECT_PATH: &str = "/org/freedesktop/portal/desktop";
pub const FILE_CHOOSER: &str = "org.freedesktop.portal.FileChooser";
pub const REQUEST: &str = "org.freedesktop.portal.Request";

/// **1, on purpose.** Version 3 added `directory` and `SaveFiles`, which the
/// Finder does not do; claim what is served.
pub const FILE_CHOOSER_VERSION: u32 = 1;

/// Put the chosen file where a jailed caller can open it (PHASE18 P18.4):
/// given the chosen path and the portal's descriptor of it, the path inside
/// the jail, or None if it could not be granted.
pub type Grant = Box<dyn FnMut(&str, BorrowedFd<'_>) -> Option<String>>;

/// Work deferred out of answering a call (see the top).
enum Deferred {
    Choose { kind: ChooserKind, options: ChooserOptions, path: String, title: String, sender: String },
    Respond { path: String, code: PortalResponse },
}

pub struct PortalService {
    conn: Connection,
    /// The CurrentIPC service to translate to: `abyss-portal`, normally.
    pub portal_service: String,
    /// Requests handed out and not yet answered or closed, and whose: the
    /// Response is addressed to that caller, not broadcast.
    live: HashMap<String, String>,
    queue: VecDeque<Deferred>,
    pub journal: Vec<String>,
    /// Completed chooser interactions, for `--once` and the tests.
    pub served: usize,
    /// What a foreign toolkit is told about how this desktop looks.
    pub settings: PortalSettings,
    /// For a jail's bus; None on the session's.
    pub grant: Option<Grant>,
}

fn s(v: &str) -> Value {
    Value::String(v.into())
}

fn err(call: &Message, name: &str, text: &str) -> Message {
    Message::error(call, &format!("org.freedesktop.DBus.Error.{name}"), text)
}

impl PortalService {
    /// `portal_service`: else `$ABYSS_PORTAL_SERVICE`, else `portal`.
    pub fn new(conn: Connection, portal_service: Option<&str>) -> PortalService {
        let service = portal_service.map(str::to_owned).or_else(|| std::env::var("ABYSS_PORTAL_SERVICE").ok().filter(|v| !v.is_empty())).unwrap_or_else(|| "portal".into());
        PortalService { conn, portal_service: service, live: HashMap::new(), queue: VecDeque::new(), journal: vec![], served: 0, settings: PortalSettings::aqua(), grant: None }
    }

    pub fn log(&mut self, msg: String) {
        eprintln!("abyss-dbus: {msg}");
        self.journal.push(msg);
    }

    /// Take the name. Refuses to run as anything but the **primary** owner:
    /// a portal sharing its name with another would answer some calls and
    /// not others, which is worse than not starting.
    pub fn attach(&mut self) -> Result<(), Error> {
        let code = self.conn.request_name(BUS_NAME, 0)?;
        if code != 1 {
            return Err(Error::new(format!("could not own {BUS_NAME}: RequestName returned {code} — is xdg-desktop-portal already on this bus?")));
        }
        let msg = format!("owning {BUS_NAME}, translating to the '{}' service", self.portal_service);
        self.log(msg);
        Ok(())
    }

    // MARK: the run loop

    /// Read and answer, then drain. The order is load-bearing (see the top).
    pub fn step(&mut self, timeout_ms: i32) -> Result<(), Error> {
        for r in self.conn.receive(timeout_ms)? {
            let call = r.message;
            if call.kind != MessageType::MethodCall {
                continue;
            }
            let _ = match self.answer(&call) {
                Some(reply) => self.conn.reply(&call, reply),
                // An unknown method must be answered, or the caller waits.
                None => self.conn.unknown_method(&call),
            };
        }
        while let Some(work) = self.queue.pop_front() {
            match work {
                Deferred::Choose { kind, options, path, title, sender } => self.run_chooser(kind, options, &path, &title, &sender),
                Deferred::Respond { path, code } => self.respond(&path, code, Value::options(vec![])),
            }
        }
        Ok(())
    }

    fn answer(&mut self, call: &Message) -> Option<Message> {
        match (call.interface.as_deref()?, call.member.as_deref()?) {
            (FILE_CHOOSER, "OpenFile") => Some(self.chooser(ChooserKind::Open, call)),
            (FILE_CHOOSER, "SaveFile") => Some(self.chooser(ChooserKind::Save, call)),
            (REQUEST, "Close") => Some(self.close_request(call)),
            (settings::INTERFACE, "ReadAll") => Some(self.settings_read_all(call)),
            (settings::INTERFACE, "Read") => Some(self.settings_read(call, 2)),
            (settings::INTERFACE, "ReadOne") => Some(self.settings_read(call, 1)),
            ("org.freedesktop.DBus.Properties", "Get") => Some(property(call, false)),
            ("org.freedesktop.DBus.Properties", "GetAll") => Some(property(call, true)),
            ("org.freedesktop.DBus.Introspectable", "Introspect") => Some(Message::method_return(call, vec![s(&introspection(call.path.as_deref()))])),
            _ => None,
        }
    }

    // MARK: FileChooser

    fn chooser(&mut self, kind: ChooserKind, call: &Message) -> Message {
        if call.path.as_deref() != Some(OBJECT_PATH) {
            return err(call, "UnknownObject", &format!("no FileChooser at {}", call.path.as_deref().unwrap_or("?")));
        }
        // s parent_window, s title, a{sv} options.
        let (Some(Value::String(title)), Some(opts)) = (call.body.get(1), call.body.get(2)) else {
            return err(call, "InvalidArgs", "expected (s parent_window, s title, a{sv} options)");
        };
        let options = ChooserOptions::from(opts);
        let Some(sender) = call.sender.clone() else {
            return err(call, "Failed", "the bus attached no sender to this call");
        };
        // No token: invent one. The client then has to use the handle it is
        // given, and races us; the spec's remedy is a token, so say so.
        let token = options.handle_token.clone().unwrap_or_else(|| format!("abyss{}", self.served + 1));
        if options.handle_token.is_none() {
            self.log(format!("{sender} sent no handle_token — using '{token}'; a client that subscribes after the call may miss the Response"));
        }
        let Some(path) = request_path(&sender, &token) else {
            return err(call, "InvalidArgs", &format!("handle_token '{token}' is not a valid object path element"));
        };
        self.live.insert(path.clone(), sender.clone());
        if options.directory {
            // Said plainly, rather than open a file picker and pretend.
            self.log(format!("{sender} asked for a directory chooser, which the Finder is not"));
            self.queue.push_back(Deferred::Respond { path: path.clone(), code: PortalResponse::Other });
        } else {
            if options.multiple {
                self.log(format!("{sender} asked to select multiple files; the Finder returns one"));
            }
            if !options.ignored.is_empty() {
                self.log(format!("ignored options: {}", options.ignored.join(", ")));
            }
            self.queue.push_back(Deferred::Choose { kind, options, path: path.clone(), title: title.clone(), sender });
        }
        Message::method_return(call, vec![Value::ObjectPath(path)])
    }

    /// The blocking half: ask `abyss-portal`, wait for the person, answer.
    fn run_chooser(&mut self, kind: ChooserKind, mut options: ChooserOptions, path: &str, title: &str, sender: &str) {
        let what = if kind == ChooserKind::Open { "OpenFile" } else { "SaveFile" };
        self.log(format!("{sender} asked for {what} (\"{title}\") → {path}"));
        // **A jail's folder is not a folder here** (P18.6): it names a place
        // inside the jail, and the caller learns nothing of the person's
        // files by naming one.
        if self.grant.is_some()
            && let Some(f) = options.current_folder.take()
        {
            self.log(format!("ignoring the jailed caller's folder {f}: it names a place inside its jail"));
        }
        let request = portal_call_message(kind, &options);
        let service = self.portal_service.clone();
        let mut reply = match current_ipc::call(&service, &request) {
            Ok(r) => r,
            Err(e) => {
                self.log(format!("cannot reach the '{service}' portal: {e}"));
                return self.respond(path, PortalResponse::Other, Value::options(vec![]));
            }
        };
        // **The descriptor stops here**: the FileChooser Response has no `h`,
        // so the caller opens the path by name (§6.6). **Except in a jail**
        // (P18.4), where the descriptor proves the choice, the file is
        // mounted where the caller can reach it, and that path is answered.
        if let Some(fd) = reply.take_fd("file") {
            let chosen = reply.string("path").map(str::to_owned);
            if let (Some(grant), Some(true), Some(chosen)) = (self.grant.as_mut(), reply.bool("ok"), chosen) {
                match grant(&chosen, fd.as_fd()) {
                    Some(inside) => {
                        reply.set_string("path", &inside);
                        self.log(format!("granted {chosen} to the jail as {inside}"));
                    }
                    None => {
                        reply.set_bool("ok", false);
                        reply.set_string("error", "could not be granted");
                        self.log(format!("could not grant {chosen} to the jail"));
                    }
                }
            }
        }
        reply.close_fds();
        let (code, results) = chooser_response(&reply);
        self.served += 1;
        self.respond(path, code, results);
    }

    /// Change what toolkits are told (the theme changed, P14.2) and **say
    /// so**: `SettingChanged` for every key that differs, broadcast. How
    /// many changed.
    pub fn update(&mut self, new: PortalSettings) -> usize {
        let changed = self.settings.changes(&new);
        self.settings = new;
        for c in &changed {
            let signal = Message::signal(OBJECT_PATH, settings::INTERFACE, "SettingChanged", None, vec![s(&c.namespace), s(&c.key), Value::Variant(Box::new(c.value.clone()))]);
            if let Err(e) = self.conn.send(signal) {
                self.log(format!("could not emit SettingChanged({}, {}): {e}", c.namespace, c.key));
            }
        }
        changed.len()
    }

    /// Emit `Response`, addressed to its caller: unless the caller closed
    /// the Request first, in which case the spec says nothing is emitted.
    fn respond(&mut self, path: &str, code: PortalResponse, results: Value) {
        let Some(sender) = self.live.remove(path) else {
            return self.log(format!("{path} was closed before it finished; no Response emitted"));
        };
        let signal = Message::signal(path, REQUEST, "Response", Some(&sender), vec![Value::UInt32(code as u32), results]);
        match self.conn.send(signal) {
            Ok(_) => self.log(format!("Response({}) on {path}", code as u32)),
            Err(e) => self.log(format!("could not emit Response on {path}: {e}")),
        }
    }

    /// A Request the caller gave up on. While the picker is up this process
    /// is inside `current_ipc::call`, so a Close then is seen only after the
    /// dialog closed; what is guaranteed is that no Response follows it.
    fn close_request(&mut self, call: &Message) -> Message {
        let Some(path) = call.path.clone().filter(|p| self.live.contains_key(p)) else {
            return err(call, "UnknownObject", &format!("no live request at {}", call.path.as_deref().unwrap_or("?")));
        };
        self.live.remove(&path);
        self.log(format!("closed {path} at the client's request"));
        Message::method_return(call, vec![])
    }

    // MARK: Settings

    /// `ReadAll`, which a GTK application calls first: it must succeed even
    /// when nothing it asked for is published. Empty is "no such settings";
    /// an error is "this desktop is broken", warned of on every launch.
    fn settings_read_all(&self, call: &Message) -> Message {
        if call.path.as_deref() != Some(OBJECT_PATH) {
            return err(call, "UnknownObject", &format!("no Settings at {}", call.path.as_deref().unwrap_or("?")));
        }
        let Some(Value::Array(_, items)) = call.body.first().filter(|v| v.signature() == "as") else {
            return err(call, "InvalidArgs", "expected (as namespaces)");
        };
        let patterns: Vec<String> = items.iter().filter_map(|i| if let Value::String(s) = i { Some(s.clone()) } else { None }).collect();
        Message::method_return(call, vec![self.settings.read_all(&patterns)])
    }

    fn settings_read(&self, call: &Message, layers: u8) -> Message {
        if call.path.as_deref() != Some(OBJECT_PATH) {
            return err(call, "UnknownObject", &format!("no Settings at {}", call.path.as_deref().unwrap_or("?")));
        }
        let (Some(Value::String(namespace)), Some(Value::String(key))) = (call.body.first(), call.body.get(1)) else {
            return err(call, "InvalidArgs", "expected (s namespace, s key)");
        };
        let value = if layers == 2 { self.settings.read(namespace, key) } else { self.settings.read_one(namespace, key) };
        match value {
            Some(v) => Message::method_return(call, vec![v]),
            // The spec requires an error, and it is the right answer.
            None => Message::error(call, "org.freedesktop.portal.Error.NotFound", &format!("no setting '{key}' in '{namespace}'")),
        }
    }
}

// MARK: properties and introspection

/// The `version` each interface advertises: read by real clients before
/// anything else, and a missing one reads as 0.
fn version_of(interface: &str) -> Option<u32> {
    match interface {
        FILE_CHOOSER => Some(FILE_CHOOSER_VERSION),
        settings::INTERFACE => Some(settings::VERSION),
        _ => None,
    }
}

fn property(call: &Message, all: bool) -> Message {
    let Some(Value::String(iface)) = call.body.first() else {
        return err(call, "InvalidArgs", "expected an interface name");
    };
    let Some(version) = version_of(iface) else {
        return if all { Message::method_return(call, vec![Value::options(vec![])]) } else { err(call, "UnknownInterface", &format!("no properties on {iface}")) };
    };
    if all {
        return Message::method_return(call, vec![Value::options(vec![("version", Value::UInt32(version))])]);
    }
    match call.body.get(1) {
        Some(Value::String(name)) if name == "version" => Message::method_return(call, vec![Value::Variant(Box::new(Value::UInt32(version)))]),
        _ => err(call, "UnknownProperty", &format!("no such property on {iface}")),
    }
}

const PROPERTIES: &str = concat!(
    r#"<interface name="org.freedesktop.DBus.Properties">"#,
    r#"<method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/>"#,
    r#"<arg type="v" direction="out"/></method>"#,
    r#"<method name="GetAll"><arg type="s" direction="in"/>"#,
    r#"<arg type="a{sv}" direction="out"/></method></interface>"#,
    r#"<interface name="org.freedesktop.DBus.Introspectable">"#,
    r#"<method name="Introspect"><arg type="s" direction="out"/></method></interface>"#,
);

const CHOOSER_METHOD_ARGS: &str = concat!(
    r#"<arg type="s" name="parent_window" direction="in"/>"#,
    r#"<arg type="s" name="title" direction="in"/>"#,
    r#"<arg type="a{sv}" name="options" direction="in"/>"#,
    r#"<arg type="o" name="handle" direction="out"/></method>"#,
);

const SETTINGS_BODY: &str = concat!(
    r#"<method name="ReadAll">"#,
    r#"<arg type="as" name="namespaces" direction="in"/>"#,
    r#"<arg type="a{sa{sv}}" name="value" direction="out"/></method>"#,
    r#"<method name="Read">"#,
    r#"<annotation name="org.freedesktop.DBus.Deprecated" value="true"/>"#,
    r#"<arg type="s" name="namespace" direction="in"/>"#,
    r#"<arg type="s" name="key" direction="in"/>"#,
    r#"<arg type="v" name="value" direction="out"/></method>"#,
    r#"<method name="ReadOne">"#,
    r#"<arg type="s" name="namespace" direction="in"/>"#,
    r#"<arg type="s" name="key" direction="in"/>"#,
    r#"<arg type="v" name="value" direction="out"/></method>"#,
    r#"<property name="version" type="u" access="read"/>"#,
    r#"<signal name="SettingChanged">"#,
    r#"<arg type="s" name="namespace"/><arg type="s" name="key"/>"#,
    r#"<arg type="v" name="value"/></signal>"#,
);

/// Introspection XML: parsed by real clients with a real parser, so
/// well-formed rather than plausible (`gdbus introspect` checks, live).
pub fn introspection(path: Option<&str>) -> String {
    if path == Some(OBJECT_PATH) {
        return format!(
            "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\" \
             \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n<node>{PROPERTIES}\
             <interface name=\"{FILE_CHOOSER}\"><method name=\"OpenFile\">{CHOOSER_METHOD_ARGS}<method name=\"SaveFile\">{CHOOSER_METHOD_ARGS}\
             <property name=\"version\" type=\"u\" access=\"read\"/></interface>\
             <interface name=\"{}\">{SETTINGS_BODY}</interface></node>",
            settings::INTERFACE
        );
    }
    if path.is_some_and(|p| p.starts_with(REQUEST_PREFIX)) {
        return format!(
            "<node>{PROPERTIES}<interface name=\"{REQUEST}\"><method name=\"Close\"/>\
             <signal name=\"Response\"><arg type=\"u\" name=\"response\"/>\
             <arg type=\"a{{sv}}\" name=\"results\"/></signal></interface></node>"
        );
    }
    // Anything else: a bare node naming the one child that leads towards
    // us, so a client walking down from `/` arrives at the portal.
    let child = next_component(OBJECT_PATH, path.unwrap_or("/")).map(|c| format!("<node name=\"{c}\"/>")).unwrap_or_default();
    format!("<node>{PROPERTIES}{child}</node>")
}

/// The next path element from `here` towards `target`, or None if `here`
/// is not an ancestor of it.
pub fn next_component(target: &str, here: &str) -> Option<String> {
    let prefix = if here == "/" { "/".to_owned() } else { format!("{here}/") };
    let rest = target.strip_prefix(&prefix).filter(|r| !r.is_empty())?;
    Some(rest.split('/').next().unwrap_or("").to_owned())
}
