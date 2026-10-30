//! DBusBridgeTests.swift: every decision the bridge makes, and above all the
//! ones that make it a bridge and not a bus (PRODUCT §5.6).

use crate::*;
use dbus::{Message, MessageType, Value, DRIVER};
use std::collections::BTreeSet;

const PORTAL: usize = 1;
const MENUS: usize = 2;
const ZENITY: usize = 3;
const GIMP: usize = 4;

struct T {
    r: Router,
    serial: u32,
}

fn s(v: &str) -> Value {
    Value::String(v.into())
}

impl T {
    fn new() -> T {
        let mut t = T { r: Router::new("0123456789abcdef0123456789abcdef"), serial: 100 };
        t.r.attach(PORTAL, PeerKind::Service, 1001, 10);
        t.r.attach(MENUS, PeerKind::Service, 1001, 11);
        t.r.attach(ZENITY, PeerKind::Application, 1001, 20);
        t.r.attach(GIMP, PeerKind::Application, 1001, 21);
        for id in [PORTAL, MENUS, ZENITY, GIMP] {
            t.hello(id);
        }
        t.driver(PORTAL, "RequestName", vec![s("org.freedesktop.portal.Desktop"), Value::UInt32(0)]);
        t
    }

    fn call(&mut self, dest: &str, member: &str, body: Vec<Value>, iface: &str) -> Message {
        self.serial += 1;
        Message { serial: self.serial, ..Message::method_call(dest, "/o", iface, member, body) }
    }

    fn route_call(&mut self, from: usize, dest: &str, member: &str, iface: &str) -> Vec<Action> {
        let m = self.call(dest, member, vec![], iface);
        self.r.route(from, m)
    }

    fn driver_on(&mut self, from: usize, member: &str, body: Vec<Value>, iface: &str) -> Vec<Action> {
        let m = self.call(DRIVER, member, body, iface);
        self.r.route(from, m)
    }

    fn driver(&mut self, from: usize, member: &str, body: Vec<Value>) -> Vec<Action> {
        self.driver_on(from, member, body, DRIVER)
    }

    fn hello(&mut self, id: usize) -> Vec<Action> {
        self.driver(id, "Hello", vec![])
    }

    fn unique(&self, id: usize) -> String {
        self.r.peers[&id].unique.clone()
    }

    fn add_match(&mut self, id: usize, rule: &str) {
        let a = self.driver(id, "AddMatch", vec![s(rule)]);
        assert_eq!(reply(&a, id).map(|m| m.kind), Some(MessageType::MethodReturn), "{rule}");
    }
}

fn delivered(a: &[Action]) -> Vec<(usize, &Message)> {
    a.iter()
        .filter_map(|x| match x {
            Action::Deliver(to, m) => Some((*to, m)),
            _ => None,
        })
        .collect()
}

fn to(a: &[Action]) -> Vec<usize> {
    delivered(a).into_iter().map(|(t, _)| t).collect()
}

fn reply(a: &[Action], id: usize) -> Option<&Message> {
    delivered(a).into_iter().find(|(t, m)| *t == id && matches!(m.kind, MessageType::MethodReturn | MessageType::Error)).map(|(_, m)| m)
}

fn error_name(a: &[Action], id: usize) -> Option<String> {
    reply(a, id).and_then(|m| m.error_name.clone())
}

fn body(a: &[Action], id: usize) -> Vec<Value> {
    reply(a, id).map(|m| m.body.clone()).unwrap_or_default()
}

// MARK: connecting

#[test]
fn hello_gives_a_unique_name_and_nothing_comes_before_it() {
    let mut t = T { r: Router::new("x"), serial: 0 };
    t.r.attach(9, PeerKind::Application, 1, 1);
    let early = t.route_call(9, "org.freedesktop.portal.Desktop", "OpenFile", "org.example.I");
    assert_eq!(early, vec![Action::Close(9, "a message before Hello".into())]);
    let a = t.hello(9);
    let me = t.unique(9);
    assert_eq!(delivered(&a)[0].1.body, vec![s(&me)]);
    assert!(delivered(&a).iter().any(|(_, m)| m.member.as_deref() == Some("NameAcquired") && m.destination.as_deref() == Some(me.as_str())));
    let again = t.hello(9);
    assert_eq!(reply(&again, 9).map(|m| m.kind), Some(MessageType::Error), "Hello twice");
}

// MARK: applications reach ADE's services

#[test]
fn an_applications_call_reaches_the_service_with_its_true_sender() {
    let mut t = T::new();
    let mut m = t.call("org.freedesktop.portal.Desktop", "OpenFile", vec![], "org.freedesktop.portal.FileChooser");
    m.sender = Some(":1.999".into()); // forged
    let a = t.r.route(ZENITY, m);
    let d = delivered(&a);
    assert_eq!(d.len(), 1);
    assert_eq!(d[0].0, PORTAL);
    assert_eq!(d[0].1.sender, Some(t.unique(ZENITY)), "the bridge says who sent it, not the message");
}

#[test]
fn the_services_reply_reaches_the_application() {
    let mut t = T::new();
    let a = t.route_call(ZENITY, "org.freedesktop.portal.Desktop", "OpenFile", "org.example.I");
    let fwd = delivered(&a)[0].1.clone();
    let back = Message::method_return(&fwd, vec![Value::ObjectPath("/r".into())]);
    assert_eq!(to(&t.r.route(PORTAL, back)), vec![ZENITY]);
}

#[test]
fn a_service_may_call_an_application_by_its_unique_name_or_the_name_it_asked_for() {
    let mut t = T::new();
    t.driver(ZENITY, "RequestName", vec![s("org.gnome.Zenity"), Value::UInt32(0)]);
    let z = t.unique(ZENITY);
    assert_eq!(to(&t.route_call(MENUS, &z, "Describe", "org.gtk.Menus")), vec![ZENITY]);
    assert_eq!(to(&t.route_call(MENUS, "org.gnome.Zenity", "Describe", "org.gtk.Menus")), vec![ZENITY]);
}

// MARK: and never each other (the bridge, not a bus)

#[test]
fn an_application_cannot_call_another_application() {
    let mut t = T::new();
    t.driver(GIMP, "RequestName", vec![s("org.gimp.GIMP"), Value::UInt32(0)]);
    let g = t.unique(GIMP);
    let by_unique = t.route_call(ZENITY, &g, "Activate", "org.example.I");
    assert_eq!(error_name(&by_unique, ZENITY).as_deref(), Some("org.freedesktop.DBus.Error.AccessDenied"));
    assert!(!to(&by_unique).contains(&GIMP));
    let by_name = t.route_call(ZENITY, "org.gimp.GIMP", "Activate", "org.example.I");
    assert_eq!(error_name(&by_name, ZENITY).as_deref(), Some("org.freedesktop.DBus.Error.ServiceUnknown"), "an application's name is not anyone else's to call");
}

#[test]
fn an_applications_signals_reach_only_services_that_asked() {
    let mut t = T::new();
    t.add_match(MENUS, "type='signal',interface='org.gtk.Menus'");
    // Another application, asking for everything.
    t.add_match(GIMP, "type='signal'");
    let sig = Message::signal("/m", "org.gtk.Menus", "Changed", None, vec![]);
    assert_eq!(to(&t.r.route(ZENITY, sig)), vec![MENUS]);
    let g = t.unique(GIMP);
    let poke = Message::signal("/m", "org.x", "Poke", Some(&g), vec![]);
    assert!(to(&t.r.route(ZENITY, poke)).is_empty(), "a signal addressed to another application goes nowhere");
}

fn setting_changed() -> Message {
    Message::signal("/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "SettingChanged", None, vec![s("org.freedesktop.appearance")])
}

#[test]
fn a_services_broadcast_reaches_applications_that_asked() {
    let mut t = T::new();
    t.add_match(ZENITY, "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'");
    assert_eq!(to(&t.r.route(PORTAL, setting_changed())), vec![ZENITY]);
}

/// A rule may name the sender by its well-known name, as GLib's `gdbus
/// monitor --dest` and every portal client's subscription do.
#[test]
fn a_rule_may_name_the_sender_by_its_well_known_name() {
    let mut t = T::new();
    t.add_match(ZENITY, "type='signal',sender='org.freedesktop.portal.Desktop',interface='org.freedesktop.portal.Settings'");
    assert_eq!(to(&t.r.route(PORTAL, setting_changed())), vec![ZENITY]);
    assert!(to(&t.r.route(MENUS, setting_changed())).is_empty(), "another service is not that name");
}

#[test]
fn nobody_watches_anybody() {
    let mut t = T::new();
    t.add_match(GIMP, "eavesdrop='true',type='method_call'");
    let a = t.route_call(ZENITY, "org.freedesktop.portal.Desktop", "OpenFile", "org.example.I");
    assert!(!to(&a).contains(&GIMP), "an eavesdrop rule is accepted and grants nothing");
    let m = t.driver_on(GIMP, "BecomeMonitor", vec![Value::Array("s".into(), vec![]), Value::UInt32(0)], "org.freedesktop.DBus.Monitoring");
    assert_eq!(error_name(&m, GIMP).as_deref(), Some("org.freedesktop.DBus.Error.AccessDenied"));
}

#[test]
fn nothing_is_started_by_name() {
    let mut t = T::new();
    let a = t.driver(ZENITY, "StartServiceByName", vec![s("org.gnome.Nautilus"), Value::UInt32(0)]);
    assert_eq!(error_name(&a, ZENITY).as_deref(), Some("org.freedesktop.DBus.Error.ServiceUnknown"));
    let b = t.driver(ZENITY, "UpdateActivationEnvironment", vec![Value::Array("{ss}".into(), vec![])]);
    assert_eq!(error_name(&b, ZENITY).as_deref(), Some("org.freedesktop.DBus.Error.AccessDenied"));
}

#[test]
fn a_reply_between_applications_goes_nowhere() {
    let mut t = T::new();
    let g = t.unique(GIMP);
    let mut c = t.call(&g, "X", vec![], "org.example.I");
    c.sender = Some(g);
    let fake = Message::method_return(&c, vec![]);
    assert!(to(&t.r.route(ZENITY, fake)).is_empty());
}

// MARK: names

#[test]
fn every_copy_of_an_application_thinks_it_is_the_only_one() {
    let mut t = T::new();
    let a = t.driver(ZENITY, "RequestName", vec![s("org.gnome.Zenity"), Value::UInt32(4)]);
    assert_eq!(body(&a, ZENITY), vec![Value::UInt32(1)]);
    let b = t.driver(GIMP, "RequestName", vec![s("org.gnome.Zenity"), Value::UInt32(4)]);
    assert_eq!(body(&b, GIMP), vec![Value::UInt32(1)], "no single-instance handover between applications (PRODUCT §5.6's price)");
    let (z, g) = (t.unique(ZENITY), t.unique(GIMP));
    assert_eq!(body(&t.driver(ZENITY, "GetNameOwner", vec![s("org.gnome.Zenity")]), ZENITY), vec![s(&z)]);
    assert_eq!(body(&t.driver(GIMP, "GetNameOwner", vec![s("org.gnome.Zenity")]), GIMP), vec![s(&g)]);
}

#[test]
fn one_service_per_name() {
    let mut t = T::new();
    let a = t.driver(MENUS, "RequestName", vec![s("org.freedesktop.portal.Desktop"), Value::UInt32(0)]);
    assert_eq!(body(&a, MENUS), vec![Value::UInt32(3)]);
}

#[test]
fn an_application_sees_ades_names_and_its_own_only() {
    let mut t = T::new();
    t.driver(GIMP, "RequestName", vec![s("org.gimp.GIMP"), Value::UInt32(0)]);
    let a = t.driver(ZENITY, "ListNames", vec![]);
    let Some(Value::Array(_, items)) = body(&a, ZENITY).first().cloned() else { panic!("ListNames: {a:?}") };
    let names: Vec<String> = items.into_iter().filter_map(|v| if let Value::String(s) = v { Some(s) } else { None }).collect();
    assert!(names.contains(&"org.freedesktop.portal.Desktop".into()));
    assert!(names.contains(&t.unique(ZENITY)));
    assert!(!names.contains(&t.unique(GIMP)));
    assert!(!names.contains(&"org.gimp.GIMP".into()));
    assert_eq!(body(&t.driver(ZENITY, "NameHasOwner", vec![s("org.gimp.GIMP")]), ZENITY), vec![Value::Bool(false)]);
    assert_eq!(body(&t.driver(MENUS, "NameHasOwner", vec![s("org.gimp.GIMP")]), MENUS), vec![Value::Bool(true)], "a service may know");
}

#[test]
fn an_application_may_ask_about_itself_and_a_service_about_anyone() {
    let mut t = T::new();
    let (z, g) = (t.unique(ZENITY), t.unique(GIMP));
    assert_eq!(body(&t.driver(ZENITY, "GetConnectionUnixUser", vec![s(&z)]), ZENITY), vec![Value::UInt32(1001)]);
    let other = t.driver(ZENITY, "GetConnectionUnixUser", vec![s(&g)]);
    assert_eq!(reply(&other, ZENITY).map(|m| m.kind), Some(MessageType::Error));
    assert_eq!(body(&t.driver(MENUS, "GetConnectionUnixProcessID", vec![s(&g)]), MENUS), vec![Value::UInt32(21)]);
}

#[test]
fn owner_changes_of_applications_are_for_services_only() {
    let mut t = T::new();
    t.add_match(MENUS, "type='signal',member='NameOwnerChanged'");
    t.add_match(GIMP, "type='signal',member='NameOwnerChanged'");
    let a: BTreeSet<usize> = to(&t.r.detach(ZENITY)).into_iter().collect();
    assert_eq!(a, [MENUS].into(), "an application's coming and going is not news to other applications");
    let b: BTreeSet<usize> = to(&t.r.detach(PORTAL)).into_iter().collect();
    assert_eq!(b, [MENUS, GIMP].into(), "a service's is");
    let c = t.driver(MENUS, "RequestName", vec![s("org.freedesktop.portal.Desktop"), Value::UInt32(0)]);
    assert_eq!(body(&c, MENUS), vec![Value::UInt32(1)], "a name goes with its owner");
}

// MARK: match rules

#[test]
fn match_rules_parse_and_match() {
    let none = BTreeSet::new();
    assert!(MatchRule::parse("type='signal',interface='org.gtk.Menus',path_namespace='/org/gtk',arg0='a''b'").is_some());
    assert!(MatchRule::parse("type").is_none(), "a key with no value");
    let r1 = MatchRule::parse("type='signal',interface='org.gtk.Menus',path_namespace='/org/gtk',arg0='x'").unwrap();
    let mut sig = Message::signal("/org/gtk/menus/0", "org.gtk.Menus", "Changed", None, vec![s("x")]);
    assert!(r1.matches(&sig, &none));
    sig.path = Some("/org/gtkx".into());
    assert!(!r1.matches(&sig, &none), "path_namespace is by component");
    sig.path = Some("/org/gtk".into());
    sig.body = vec![s("y")];
    assert!(!r1.matches(&sig, &none));
    assert!(!MatchRule::parse("type='method_call'").unwrap().matches(&sig, &none));
}

/// The spec's escape for a quote inside a value: close, `\'`, reopen.
#[test]
fn a_quote_inside_a_value_is_the_specs_escape() {
    let r = MatchRule::parse(r"arg0='it'\''s'").unwrap();
    assert_eq!(r.fields["arg0"], "it's");
}

/// A call that expects no reply gets none, even when it is refused.
#[test]
fn a_call_that_expects_no_reply_gets_none() {
    let mut t = T::new();
    let g = t.unique(GIMP);
    let mut m = t.call(&g, "Activate", vec![], "org.example.I");
    m.flags = dbus::Flags::NO_REPLY_EXPECTED;
    assert!(t.r.route(ZENITY, m).is_empty());
}
