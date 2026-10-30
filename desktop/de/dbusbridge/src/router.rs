//! What ADE's D-Bus bridge does with a message (Router.swift, BACKLOG D.1,
//! PRODUCT §5.6).
//!
//! **A bridge, not a bus.** Two kinds of peer, and messages go between
//! kinds, never within one:
//!
//!   - **applications** connect at `DBUS_SESSION_BUS_ADDRESS` (or a jail's);
//!   - **ADE's services** (the portal, the menu bridge) connect on a private
//!     socket in the session's runtime directory, and only they may own
//!     names that anyone else can call.
//!
//! An application reaches ADE's services and nothing else: a call addressed
//! to another application is refused, its broadcast signals go only to
//! services that asked, and it never sees another application's traffic (no
//! eavesdropping, no `BecomeMonitor`, nothing started by name). A name an
//! application asks for is granted as far as it can tell, and only ADE's
//! services can call it by that name: two copies of an application each
//! think they are the only one, which is the price PRODUCT §5.6 states.
//!
//! Pure: no sockets. The endpoint reads and writes; this decides.

use dbus::{Flags, Message, MessageType, Value, DRIVER, DRIVER_PATH};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PeerKind {
    Application,
    Service,
}

impl std::fmt::Display for PeerKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            PeerKind::Application => "application",
            PeerKind::Service => "service",
        })
    }
}

/// A match rule, `type='signal',interface='x',arg0='y'`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MatchRule {
    pub fields: BTreeMap<String, String>,
}

impl MatchRule {
    /// Values quoted with `'` and the spec's `'\''` escape. None for a rule
    /// that does not parse.
    pub fn parse(text: &str) -> Option<MatchRule> {
        let chars: Vec<char> = text.chars().collect();
        let mut out = BTreeMap::new();
        let mut i = 0;
        let skip = |i: &mut usize| {
            while *i < chars.len() && (chars[*i] == ',' || chars[*i] == ' ') {
                *i += 1;
            }
        };
        skip(&mut i);
        while i < chars.len() {
            let mut key = String::new();
            while i < chars.len() && chars[i] != '=' {
                key.push(chars[i]);
                i += 1;
            }
            if i >= chars.len() || key.is_empty() {
                return None;
            }
            i += 1;
            let mut value = String::new();
            while i < chars.len() && chars[i] != ',' {
                if chars[i] == '\'' {
                    i += 1;
                    while i < chars.len() && chars[i] != '\'' {
                        value.push(chars[i]);
                        i += 1;
                    }
                    if i >= chars.len() {
                        return None;
                    }
                    i += 1;
                } else if chars[i] == '\\' && chars.get(i + 1) == Some(&'\'') {
                    value.push('\'');
                    i += 2;
                } else {
                    value.push(chars[i]);
                    i += 1;
                }
            }
            out.insert(key.trim_matches(' ').to_owned(), value);
            skip(&mut i);
        }
        Some(MatchRule { fields: out })
    }

    /// `sender_names`: every name the sending connection answers to (its
    /// unique name and the well-known names it owns), because a rule may
    /// name either, as on any bus.
    pub fn matches(&self, m: &Message, sender_names: &BTreeSet<String>) -> bool {
        let is = |field: &Option<String>, v: &str| field.as_deref() == Some(v);
        self.fields.iter().all(|(k, v)| match k.as_str() {
            "type" => {
                let t = match m.kind {
                    MessageType::MethodCall => "method_call",
                    MessageType::MethodReturn => "method_return",
                    MessageType::Error => "error",
                    MessageType::Signal => "signal",
                };
                t == v
            }
            "sender" => is(&m.sender, v) || sender_names.contains(v),
            "interface" => is(&m.interface, v),
            "member" => is(&m.member, v),
            "path" => is(&m.path, v),
            "path_namespace" => m.path.as_deref().is_some_and(|p| p == v || v == "/" || p.starts_with(&format!("{v}/"))),
            "destination" => is(&m.destination, v),
            // Asked for, never granted.
            "eavesdrop" => true,
            _ => match k.strip_prefix("arg").map(str::parse::<usize>) {
                Some(Ok(n)) if n < 64 => matches!(m.body.get(n), Some(Value::String(s)) if s == v),
                // argNpath: nothing ADE serves needs it.
                Some(_) if k.ends_with("path") => true,
                _ => false,
            },
        })
    }
}

/// One connection, as the bridge knows it.
#[derive(Clone, Debug, PartialEq)]
pub struct Peer {
    pub kind: PeerKind,
    pub unique: String,
    pub uid: u32,
    pub pid: i32,
    pub greeted: bool,
    /// Names it asked for. A service's are everyone's to call; an
    /// application's are for ADE's services only.
    pub names: Vec<String>,
    pub rules: Vec<MatchRule>,
}

/// What to do: deliver to a connection, or close one.
#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    Deliver(usize, Message),
    Close(usize, String),
}

pub struct Router {
    /// By connection id, so every fan-out is in the order peers came.
    pub peers: BTreeMap<usize, Peer>,
    next_unique: u64,
    serial: u32,
    /// The bridge's id (`GetId`): 32 hex digits, per bridge.
    pub guid: String,
}

const ERR: &str = "org.freedesktop.DBus.Error.";

impl Router {
    pub fn new(guid: &str) -> Router {
        Router { peers: BTreeMap::new(), next_unique: 1, serial: 1, guid: guid.into() }
    }

    // MARK: connections

    pub fn attach(&mut self, id: usize, kind: PeerKind, uid: u32, pid: i32) {
        let unique = format!(":1.{}", self.next_unique);
        self.next_unique += 1;
        self.peers.insert(id, Peer { kind, unique, uid, pid, greeted: false, names: vec![], rules: vec![] });
    }

    /// A connection went: its names go with it, and those who asked hear.
    pub fn detach(&mut self, id: usize) -> Vec<Action> {
        let Some(p) = self.peers.remove(&id) else { return vec![] };
        let mut out = vec![];
        for n in p.names.iter().chain(p.greeted.then_some(&p.unique)) {
            out.extend(self.owner_changed(n, &p.unique, "", p.kind));
        }
        out
    }

    /// Who owns `name`, as a peer of kind `asker` may know it.
    fn owner(&self, name: &str, asker: PeerKind) -> Option<usize> {
        if name.starts_with(':') {
            return self.peers.iter().find(|(_, p)| p.unique == name && p.greeted).map(|(k, _)| *k);
        }
        // A service's name is anyone's; an application's, only a service's.
        if let Some((k, _)) = self.peers.iter().find(|(_, p)| p.kind == PeerKind::Service && p.names.iter().any(|n| n == name)) {
            return Some(*k);
        }
        if asker == PeerKind::Service {
            // The newest copy, if an application is running twice.
            return self.peers.iter().rev().find(|(_, p)| p.kind == PeerKind::Application && p.names.iter().any(|n| n == name)).map(|(k, _)| *k);
        }
        None
    }

    fn kind_of(&self, id: usize) -> Option<PeerKind> {
        self.peers.get(&id).map(|p| p.kind)
    }

    // MARK: a message arrives

    pub fn route(&mut self, from: usize, incoming: Message) -> Vec<Action> {
        let Some(me) = self.peers.get(&from) else { return vec![] };
        let kind = me.kind;
        // The sender is who the bridge says, never who the message says.
        let m = Message { sender: Some(me.unique.clone()), ..incoming };
        if !me.greeted && !(m.kind == MessageType::MethodCall && m.destination.as_deref() == Some(DRIVER) && m.member.as_deref() == Some("Hello")) {
            return vec![Action::Close(from, "a message before Hello".into())];
        }
        if m.destination.as_deref() == Some(DRIVER) {
            return self.driver(from, m);
        }
        let quiet = m.flags.contains(Flags::NO_REPLY_EXPECTED);
        let app_to_app = |target: Option<PeerKind>| kind == PeerKind::Application && target == Some(PeerKind::Application);
        match m.kind {
            MessageType::MethodCall => {
                let to = m.destination.as_deref().and_then(|d| self.owner(d, kind));
                let Some(to) = to else {
                    if quiet {
                        return vec![];
                    }
                    let text = format!("{} is not here: the bridge connects applications to the desktop, not to each other", m.destination.as_deref().unwrap_or("(no destination)"));
                    return vec![Action::Deliver(from, self.error(&m, "ServiceUnknown", &text))];
                };
                if app_to_app(self.kind_of(to)) {
                    if quiet {
                        return vec![];
                    }
                    return vec![Action::Deliver(from, self.error(&m, "AccessDenied", "an application cannot call another application through ADE's bridge (PRODUCT §5.6)"))];
                }
                vec![Action::Deliver(to, m)]
            }
            MessageType::MethodReturn | MessageType::Error => match m.destination.as_deref().and_then(|d| self.owner(d, PeerKind::Service)) {
                Some(to) if !app_to_app(self.kind_of(to)) => vec![Action::Deliver(to, m)],
                _ => vec![],
            },
            MessageType::Signal => match m.destination.as_deref() {
                Some(d) => match self.owner(d, kind) {
                    Some(to) if !app_to_app(self.kind_of(to)) => vec![Action::Deliver(to, m)],
                    _ => vec![],
                },
                None => self.broadcast(&m, kind, from),
            },
        }
    }

    /// A broadcast signal: to every connection whose rules match, but an
    /// application's reaches services only.
    fn broadcast(&self, m: &Message, kind: PeerKind, except: usize) -> Vec<Action> {
        // The sender's well-known names count, but an application's only as
        // far as services may know them.
        let names: BTreeSet<String> = self.peers.get(&except).map(|p| std::iter::once(p.unique.clone()).chain(p.names.iter().cloned()).collect()).unwrap_or_default();
        let none = BTreeSet::new();
        self.peers
            .iter()
            .filter(|&(&k, p)| {
                let may = kind == PeerKind::Service || p.kind == PeerKind::Service;
                k != except && p.greeted && may && p.rules.iter().any(|r| r.matches(m, if may { &names } else { &none }))
            })
            .map(|(&k, _)| Action::Deliver(k, m.clone()))
            .collect()
    }

    // MARK: org.freedesktop.DBus, as the bridge answers it

    fn driver(&mut self, id: usize, m: Message) -> Vec<Action> {
        if m.kind != MessageType::MethodCall {
            return vec![];
        }
        let quiet = m.flags.contains(Flags::NO_REPLY_EXPECTED);
        let arg = |i: usize| match m.body.get(i) {
            Some(Value::String(s)) => Some(s.clone()),
            _ => None,
        };
        let interface = m.interface.clone().unwrap_or_else(|| DRIVER.into());
        let member = m.member.clone().unwrap_or_default();
        let mut me = self.peers[&id].clone();

        // What goes back to the caller first, then anything else.
        let answer: Result<Vec<Value>, (&str, String)>;
        let mut after: Vec<Action> = vec![];
        match (interface.as_str(), member.as_str()) {
            (DRIVER, "Hello") => {
                if me.greeted {
                    answer = Err(("Failed", "Hello twice".into()));
                } else {
                    me.greeted = true;
                    self.peers.insert(id, me.clone());
                    answer = Ok(vec![Value::String(me.unique.clone())]);
                    after.push(Action::Deliver(id, self.signal("NameAcquired", Some(&me.unique), vec![Value::String(me.unique.clone())])));
                    after.extend(self.owner_changed(&me.unique, "", &me.unique, me.kind));
                }
            }
            (DRIVER, "RequestName") => match arg(0).filter(|n| !n.starts_with(':') && !n.is_empty() && n != DRIVER) {
                None => answer = Err(("InvalidArgs", "not a name that can be owned".into())),
                // Already the owner.
                Some(n) if me.names.contains(&n) => answer = Ok(vec![Value::UInt32(4)]),
                // Exists: one service per name.
                Some(n) if me.kind == PeerKind::Service && self.owner(&n, PeerKind::Service).and_then(|o| self.kind_of(o)) == Some(PeerKind::Service) => {
                    answer = Ok(vec![Value::UInt32(3)])
                }
                Some(n) => {
                    me.names.push(n.clone());
                    self.peers.insert(id, me.clone());
                    answer = Ok(vec![Value::UInt32(1)]);
                    after.push(Action::Deliver(id, self.signal("NameAcquired", Some(&me.unique), vec![Value::String(n.clone())])));
                    after.extend(self.owner_changed(&n, "", &me.unique, me.kind));
                }
            },
            (DRIVER, "ReleaseName") => match arg(0) {
                None => answer = Err(("InvalidArgs", "no name".into())),
                Some(n) => match me.names.iter().position(|x| *x == n) {
                    // Not the owner.
                    None => answer = Ok(vec![Value::UInt32(3)]),
                    Some(i) => {
                        me.names.remove(i);
                        self.peers.insert(id, me.clone());
                        answer = Ok(vec![Value::UInt32(1)]);
                        after.push(Action::Deliver(id, self.signal("NameLost", Some(&me.unique), vec![Value::String(n.clone())])));
                        after.extend(self.owner_changed(&n, &me.unique, "", me.kind));
                    }
                },
            },
            (DRIVER, "GetNameOwner") => match arg(0) {
                None => answer = Err(("InvalidArgs", "no name".into())),
                Some(n) if n == DRIVER => answer = Ok(vec![Value::String(DRIVER.into())]),
                Some(n) if me.names.contains(&n) => answer = Ok(vec![Value::String(me.unique.clone())]),
                Some(n) => {
                    let p = self.owner(&n, me.kind).map(|o| &self.peers[&o]);
                    answer = match p {
                        Some(p) if !(me.kind == PeerKind::Application && p.kind == PeerKind::Application && p.unique != me.unique) => Ok(vec![Value::String(p.unique.clone())]),
                        _ => Err(("NameHasNoOwner", format!("{n} has no owner here"))),
                    };
                }
            },
            (DRIVER, "NameHasOwner") => match arg(0) {
                None => answer = Err(("InvalidArgs", "no name".into())),
                Some(n) => {
                    let mine = n == DRIVER || me.names.contains(&n) || n == me.unique;
                    let visible = self.owner(&n, me.kind).map(|o| self.peers[&o].kind).is_some_and(|k| !(me.kind == PeerKind::Application && k == PeerKind::Application));
                    answer = Ok(vec![Value::Bool(mine || visible)]);
                }
            },
            (DRIVER, "ListNames") => {
                let mut names = vec![DRIVER.to_owned(), me.unique.clone()];
                names.extend(me.names.iter().cloned());
                for p in self.peers.values().filter(|p| p.unique != me.unique && p.greeted) {
                    if p.kind == PeerKind::Service || me.kind == PeerKind::Service {
                        names.push(p.unique.clone());
                        names.extend(p.names.iter().cloned());
                    }
                }
                answer = Ok(vec![Value::Array("s".into(), names.into_iter().map(Value::String).collect())]);
            }
            (DRIVER, "ListActivatableNames") => answer = Ok(vec![Value::Array("s".into(), vec![Value::String(DRIVER.into())])]),
            (DRIVER, "StartServiceByName") => answer = Err(("ServiceUnknown", "the bridge starts nothing by name".into())),
            (DRIVER, "UpdateActivationEnvironment") => answer = Err(("AccessDenied", "the bridge starts nothing, so has no environment".into())),
            (DRIVER, "AddMatch") => match arg(0).and_then(|t| MatchRule::parse(&t)) {
                None => answer = Err(("MatchRuleInvalid", "cannot read that rule".into())),
                Some(rule) => {
                    me.rules.push(rule);
                    self.peers.insert(id, me.clone());
                    answer = Ok(vec![]);
                }
            },
            (DRIVER, "RemoveMatch") => match arg(0).and_then(|t| MatchRule::parse(&t)).and_then(|r| me.rules.iter().position(|x| *x == r)) {
                None => answer = Err(("MatchRuleNotFound", "no such rule".into())),
                Some(i) => {
                    me.rules.remove(i);
                    self.peers.insert(id, me.clone());
                    answer = Ok(vec![]);
                }
            },
            (DRIVER, "GetId") => answer = Ok(vec![Value::String(self.guid.clone())]),
            (DRIVER, "GetConnectionUnixUser" | "GetConnectionUnixProcessID" | "GetConnectionCredentials") => {
                // About yourself, or (for a service) about anyone.
                let o = arg(0).and_then(|n| self.owner(&n, me.kind).or((me.names.contains(&n) || n == me.unique).then_some(id)));
                answer = match o.filter(|&o| o == id || me.kind == PeerKind::Service).and_then(|o| self.peers.get(&o)) {
                    None => Err(("NameHasNoOwner", format!("{} has no owner you may ask about", arg(0).unwrap_or_else(|| "?".into())))),
                    Some(p) => Ok(match member.as_str() {
                        "GetConnectionUnixUser" => vec![Value::UInt32(p.uid)],
                        "GetConnectionUnixProcessID" => vec![Value::UInt32(p.pid as u32)],
                        _ => vec![Value::Array(
                            "{sv}".into(),
                            vec![
                                Value::DictEntry(Box::new(Value::String("UnixUserID".into())), Box::new(Value::Variant(Box::new(Value::UInt32(p.uid))))),
                                Value::DictEntry(Box::new(Value::String("ProcessID".into())), Box::new(Value::Variant(Box::new(Value::UInt32(p.pid as u32))))),
                            ],
                        )],
                    }),
                };
            }
            ("org.freedesktop.DBus.Monitoring", "BecomeMonitor") => answer = Err(("AccessDenied", "nobody watches anybody through ADE's bridge (PRODUCT §5.6)".into())),
            ("org.freedesktop.DBus.Peer", "Ping") => answer = Ok(vec![]),
            ("org.freedesktop.DBus.Peer", "GetMachineId") => answer = Ok(vec![Value::String(self.guid.clone())]),
            ("org.freedesktop.DBus.Introspectable", "Introspect") => answer = Ok(vec![Value::String(INTROSPECTION.into())]),
            ("org.freedesktop.DBus.Properties", "GetAll") => answer = Ok(vec![Value::Array("{sv}".into(), vec![])]),
            ("org.freedesktop.DBus.Properties", "Get") => answer = Err(("UnknownProperty", "the bridge publishes no properties".into())),
            _ => answer = Err(("UnknownMethod", format!("the bridge does not answer {interface}.{member}"))),
        }
        let mut out = vec![];
        if !quiet {
            let reply = match answer {
                Ok(body) => self.reply(&m, body),
                Err((name, text)) => self.error(&m, name, &text),
            };
            out.push(Action::Deliver(id, reply));
        }
        out.extend(after);
        out
    }

    /// NameOwnerChanged: a service's names are news to everyone who asked;
    /// an application's, to ADE's services only.
    fn owner_changed(&mut self, name: &str, old: &str, new: &str, kind: PeerKind) -> Vec<Action> {
        let s = self.signal("NameOwnerChanged", None, vec![Value::String(name.into()), Value::String(old.into()), Value::String(new.into())]);
        let none = BTreeSet::new();
        self.peers
            .iter()
            .filter(|(_, p)| p.greeted && (kind == PeerKind::Service || p.kind == PeerKind::Service) && p.rules.iter().any(|r| r.matches(&s, &none)))
            .map(|(&k, _)| Action::Deliver(k, s.clone()))
            .collect()
    }

    // MARK: the driver's own messages

    fn next_serial(&mut self) -> u32 {
        let s = self.serial;
        self.serial = self.serial.wrapping_add(1).max(1);
        s
    }

    fn reply(&mut self, call: &Message, body: Vec<Value>) -> Message {
        Message { sender: Some(DRIVER.into()), serial: self.next_serial(), ..Message::method_return(call, body) }
    }

    fn error(&mut self, call: &Message, name: &str, text: &str) -> Message {
        Message { sender: Some(DRIVER.into()), serial: self.next_serial(), ..Message::error(call, &format!("{ERR}{name}"), text) }
    }

    fn signal(&mut self, member: &str, destination: Option<&str>, body: Vec<Value>) -> Message {
        Message { sender: Some(DRIVER.into()), serial: self.next_serial(), ..Message::signal(DRIVER_PATH, DRIVER, member, destination, body) }
    }
}

const INTROSPECTION: &str = r#"<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.DBus">
    <method name="Hello"><arg direction="out" type="s"/></method>
    <method name="RequestName"><arg direction="in" type="s"/><arg direction="in" type="u"/><arg direction="out" type="u"/></method>
    <method name="ReleaseName"><arg direction="in" type="s"/><arg direction="out" type="u"/></method>
    <method name="GetNameOwner"><arg direction="in" type="s"/><arg direction="out" type="s"/></method>
    <method name="NameHasOwner"><arg direction="in" type="s"/><arg direction="out" type="b"/></method>
    <method name="ListNames"><arg direction="out" type="as"/></method>
    <method name="AddMatch"><arg direction="in" type="s"/></method>
    <method name="RemoveMatch"><arg direction="in" type="s"/></method>
    <method name="GetId"><arg direction="out" type="s"/></method>
    <signal name="NameOwnerChanged"><arg type="s"/><arg type="s"/><arg type="s"/></signal>
    <signal name="NameLost"><arg type="s"/></signal>
    <signal name="NameAcquired"><arg type="s"/></signal>
  </interface>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect"><arg direction="out" type="s"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
    <method name="GetMachineId"><arg direction="out" type="s"/></method>
  </interface>
</node>"#;
