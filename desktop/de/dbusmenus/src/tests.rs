//! GtkMenusTests.swift: GTK's menus as our vocabulary, with no bus. The
//! fixture is the `org.gtk.Menus.Start` reply a stock GtkApplication sent in
//! PHASE10 §4.1.

use crate::gtkmenus::*;
use crate::*;
use dbus::Value;
use menu_model::{Command, Enablement, GtkMenuAddress, Key, KeyEquivalent, MenuItem, Modifiers};
use std::collections::{BTreeSet, HashMap};

fn s(v: &str) -> Value {
    Value::String(v.into())
}

fn item(kv: Vec<(&str, Value)>) -> Value {
    Value::Array("{sv}".into(), kv.into_iter().map(|(k, v)| Value::DictEntry(Box::new(s(k)), Box::new(Value::Variant(Box::new(v))))).collect())
}

fn link(g: u32, m: u32) -> Value {
    Value::Struct(vec![Value::UInt32(g), Value::UInt32(m)])
}

fn group(g: u32, m: u32, items: Vec<Value>) -> Value {
    Value::Struct(vec![Value::UInt32(g), Value::UInt32(m), Value::Array("a{sv}".into(), items)])
}

fn reply(groups: Vec<Value>) -> Vec<GtkMenuGroup> {
    groups_from_start_reply(&[Value::Array("(uuaa{sv})".into(), groups)])
}

fn action(a: &str, label: &str) -> Value {
    item(vec![("action", s(a)), ("label", s(label))])
}

/// What gtkmenu.c's GtkApplication exported, verbatim in shape.
fn spike() -> Vec<GtkMenuGroup> {
    reply(vec![
        group(0, 0, vec![item(vec![("label", s("File")), (":submenu", link(1, 0))]), item(vec![("label", s("Edit")), (":submenu", link(2, 0))])]),
        group(1, 0, vec![action("app.new", "New"), action("app.open", "Open…"), action("app.quit", "Quit")]),
        group(2, 0, vec![action("app.copy", "Copy"), action("app.paste", "Paste")]),
    ])
}

#[test]
fn the_spikes_menus_become_our_model() {
    let groups = spike();
    assert_eq!(groups.len(), 3);
    assert!(missing_groups(&groups).is_empty(), "every link is satisfied");
    let m = model("MenuSpike", &groups, &[]);
    let titles: Vec<&str> = m.menus.iter().map(|m| m.title.as_str()).collect();
    assert_eq!(titles, ["MenuSpike", "File", "Edit"], "the application menu first, as Jaguar's is");
    let verbs: Vec<&str> = m.commands().iter().map(|c| c.verb.as_str()).collect();
    assert_eq!(verbs, ["app.new", "app.open", "app.quit", "app.copy", "app.paste"]);
    assert_eq!(m.command("app.open").map(|c| c.title.as_str()), Some("Open…"));
    assert_eq!(m.command("app.quit").and_then(|c| c.key), None, "set_accels_for_action is not in the model (§4.1): no key is invented");
}

#[test]
fn only_group_0_is_known_at_first_so_the_rest_are_asked_for() {
    let only0 = reply(vec![group(0, 0, vec![item(vec![("label", s("File")), (":submenu", link(1, 0))]), item(vec![("label", s("Edit")), (":submenu", link(2, 0))])])]);
    assert_eq!(missing_groups(&only0), BTreeSet::from([1, 2]));
}

#[test]
fn sections_are_inline_with_separators_between() {
    let groups = reply(vec![
        group(0, 0, vec![item(vec![("label", s("_File")), (":submenu", link(0, 1))])]),
        group(0, 1, vec![item(vec![(":section", link(0, 2))]), item(vec![(":section", link(0, 3))])]),
        group(0, 2, vec![item(vec![("action", s("app.new")), ("label", s("_New")), ("accel", s("<Primary>n"))])]),
        group(0, 3, vec![action("app.quit", "_Quit")]),
    ]);
    let file = &model("A", &groups, &[]).menus[1];
    assert_eq!(file.title, "File", "the mnemonic underscore is not a letter");
    assert_eq!(file.items.len(), 3);
    assert_eq!(file.items[1], MenuItem::Separator);
    assert_eq!(file.commands()[0].key, Some(KeyEquivalent::cmd('n', Modifiers::NONE)), "an accel in the model is shown");
}

#[test]
fn a_model_that_links_to_itself_ends() {
    let groups = reply(vec![group(0, 0, vec![item(vec![("label", s("Loop")), (":submenu", link(0, 0))])])]);
    // Must return.
    model("A", &groups, &[]);
}

#[test]
fn titles_and_accelerators() {
    assert_eq!(title("_Open"), "Open");
    assert_eq!(title("Save __As"), "Save _As");
    assert_eq!(accel("<Primary>q"), Some(KeyEquivalent::cmd('q', Modifiers::NONE)));
    assert_eq!(accel("<Primary><Shift>n"), Some(KeyEquivalent::cmd('n', Modifiers::SHIFT)));
    assert_eq!(accel("<Control><Alt>Delete"), Some(KeyEquivalent::new(Key::ForwardDelete, Modifiers::CONTROL | Modifiers::OPTION)));
    assert_eq!(accel("<Hyper>x"), None, "a modifier we cannot draw is no key at all");
    assert_eq!(accel("<Primary>F12"), None);
}

#[test]
fn enablement_comes_from_describe_all_with_its_prefix() {
    let entry = |name: &str, on: bool| Value::DictEntry(Box::new(s(name)), Box::new(Value::Struct(vec![Value::Bool(on), Value::Signature(String::new()), Value::Array("v".into(), vec![])])));
    let acts = actions_from_describe_all(&[Value::Array("{s(bgav)}".into(), vec![entry("paste", false), entry("open", true)])], "app.");
    assert_eq!(acts, HashMap::from([("app.paste".to_owned(), false), ("app.open".to_owned(), true)]));
    assert_eq!(enablement(&Command::new("app.open", "Open", ""), &acts), Enablement::Enabled);
    assert_eq!(enablement(&Command::new("app.paste", "Paste", ""), &acts), Enablement::Disabled("the application has disabled it".into()));
    assert_eq!(enablement(&Command::new("win.close", "Close", ""), &acts), Enablement::Disabled("the application has no action win.close".into()));
}

#[test]
fn a_parameterised_item_is_drawn_and_not_bridged() {
    let groups = reply(vec![
        group(0, 0, vec![item(vec![("label", s("View")), (":submenu", link(1, 0))])]),
        group(1, 0, vec![item(vec![("action", s("win.zoom")), ("label", s("Big")), ("target", s("big"))])]),
    ]);
    let m = model("A", &groups, &[]);
    let c = m.commands()[0];
    assert_eq!(c.title, "Big");
    assert_eq!(enablement(c, &HashMap::from([("win.zoom".to_owned(), true)])), Enablement::Disabled("a parameterised action, which the bridge does not carry yet".into()));
}

#[test]
fn the_address_round_trips_and_knows_when_there_is_nothing_to_read() {
    let a = GtkMenuAddress {
        application_id: "org.abyss.MenuSpike".into(),
        bus_name: ":1.0".into(),
        application_path: "/org/abyss/MenuSpike".into(),
        menubar_path: "/org/abyss/MenuSpike/menus/menubar".into(),
        app_menu_path: String::new(),
        window_path: "/org/abyss/MenuSpike/window/1".into(),
    };
    assert_eq!(GtkMenuAddress::from_encoded(&a.encoded()), Some(a.clone()));
    assert!(a.has_menus());
    let none = GtkMenuAddress { menubar_path: String::new(), ..a.clone() };
    assert!(!none.has_menus(), "a window with no menubar and no app menu has nothing to show");
    assert_eq!(GtkMenuAddress::from_encoded("just one line"), None);
    assert_eq!(app_name(&a), "MenuSpike");
}
