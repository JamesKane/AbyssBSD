//! A GTK application's menus, read as our vocabulary (GtkMenus.swift,
//! PHASE10 P10.6).
//!
//! GTK exports a `GMenuModel` as `org.gtk.Menus` and its actions as
//! `org.gtk.Actions`. This turns the first into a `MenuBarModel` and the
//! second into enablement. Pure: groups in, a model out, tested against the
//! reply a real GTK sent in the spike.
//!
//! **What GTK does not give us**, said once so nobody hunts for it:
//!
//!   - **Descriptions.** An item has a label and an action, no sentence:
//!     the summary is the label.
//!   - **Argument types.** A parameterised action carries its target in
//!     the menu, not a type. Such items are drawn and not bridged.
//!   - **Key equivalents set with `set_accels_for_action`**, which is how
//!     most applications set them: they are not in the exported model.

use dbus::Value;
use menu_model::{Command, Enablement, Key, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// One group as `org.gtk.Menus.Start` returns it: (group, menu, items).
#[derive(Clone, Debug, PartialEq)]
pub struct GtkMenuGroup {
    pub group: u32,
    pub menu: u32,
    pub items: Vec<BTreeMap<String, Value>>,
}

/// Marks a verb whose action needs a parameter the menu carries and the
/// bridge does not.
pub const PARAMETERISED: &str = "(…)";

/// A GTK label as a person reads it: `_File` → `File`, `__` → `_`.
pub fn title(label: &str) -> String {
    let mut out = String::new();
    let mut pending = false;
    for c in label.chars() {
        if c == '_' {
            if pending {
                out.push('_');
            }
            pending = !pending;
        } else {
            pending = false;
            out.push(c);
        }
    }
    out
}

/// A GTK accelerator (`<Primary>q`, `<Control><Shift>n`) as a key
/// equivalent, or None for one we cannot spell. `<Primary>` is ⌘: GTK's
/// word for the platform's command key.
pub fn accel(s: &str) -> Option<KeyEquivalent> {
    let mut mods = Modifiers::NONE;
    let mut rest = s;
    while let Some(after) = rest.strip_prefix('<') {
        let close = after.find('>')?;
        mods = mods
            | match after[..close].to_lowercase().as_str() {
                "primary" | "super" | "meta" => Modifiers::COMMAND,
                "control" | "ctrl" => Modifiers::CONTROL,
                "shift" => Modifiers::SHIFT,
                "alt" | "mod1" => Modifiers::OPTION,
                _ => return None,
            };
        rest = &after[close + 1..];
    }
    let key = match rest.to_lowercase().as_str() {
        "backspace" => Key::Backspace,
        "delete" => Key::ForwardDelete,
        "up" => Key::Up,
        "down" => Key::Down,
        "left" => Key::Left,
        "right" => Key::Right,
        "return" => Key::Enter,
        "escape" => Key::Escape,
        "tab" => Key::Tab,
        _ => {
            let mut cs = rest.chars();
            match (cs.next(), cs.next()) {
                (Some(c), None) => Key::Character(c),
                _ => return None,
            }
        }
    };
    Some(KeyEquivalent::new(key, mods))
}

fn string(v: Option<&Value>) -> Option<&str> {
    match v? {
        Value::Variant(inner) => string(Some(inner)),
        Value::String(s) => Some(s),
        _ => None,
    }
}

/// `(group, menu)` from a `:section` or `:submenu` link.
fn link(v: Option<&Value>) -> Option<(u32, u32)> {
    match v? {
        Value::Variant(inner) => link(Some(inner)),
        Value::Struct(f) => match f[..] {
            [Value::UInt32(g), Value::UInt32(m)] => Some((g, m)),
            _ => None,
        },
        _ => None,
    }
}

/// Every group the groups link to and do not contain: what to `Start` next.
pub fn missing_groups(groups: &[GtkMenuGroup]) -> BTreeSet<u32> {
    let have: BTreeSet<u32> = groups.iter().map(|g| g.group).collect();
    groups
        .iter()
        .flat_map(|g| &g.items)
        .flat_map(|item| [":section", ":submenu"].map(|k| link(item.get(k))))
        .flatten()
        .map(|(g, _)| g)
        .filter(|g| !have.contains(g))
        .collect()
}

/// The menu `(group, menu)`, flattened: sections inline with a separator
/// between them, submenus as submenus, items as commands.
fn menu(name: &str, id: (u32, u32), groups: &[GtkMenuGroup], depth: usize) -> Menu {
    // A malformed (or hostile) model that links to itself ends here.
    let Some(g) = groups.iter().find(|g| (g.group, g.menu) == id).filter(|_| depth < 8) else { return Menu::new(name, vec![]) };
    let mut items: Vec<MenuItem> = vec![];
    for item in &g.items {
        if let Some(sec) = link(item.get(":section")) {
            let inner = menu("", sec, groups, depth + 1).items;
            if inner.is_empty() {
                continue;
            }
            if !items.is_empty() && items.last() != Some(&MenuItem::Separator) {
                items.push(MenuItem::Separator);
            }
            items.extend(inner);
            items.push(MenuItem::Separator);
        } else if let Some(sub) = link(item.get(":submenu")) {
            items.push(MenuItem::Submenu(menu(&title(string(item.get("label")).unwrap_or("")), sub, groups, depth + 1)));
        } else if let Some(action) = string(item.get("action")) {
            let label = title(string(item.get("label")).unwrap_or(action));
            // A parameterised item gets a verb no action has: drawn, and
            // refused with a reason, rather than bridged wrong.
            let verb = if item.contains_key("target") { format!("{action}{PARAMETERISED}") } else { action.to_owned() };
            // GTK has no sentence; the label is the most honest summary.
            let mut c = Command::new(&verb, &label, &label);
            if let Some(k) = string(item.get("accel")).and_then(accel) {
                c = c.with_key(k);
            }
            items.push(MenuItem::Command(c));
        }
    }
    while items.first() == Some(&MenuItem::Separator) {
        items.remove(0);
    }
    while items.last() == Some(&MenuItem::Separator) {
        items.pop();
    }
    Menu::new(name, items)
}

/// The application's menus: its app menu (or an empty one, which still
/// names the application) first, as Jaguar's is; then the menubar's
/// top-level submenus.
pub fn model(app_name: &str, menubar: &[GtkMenuGroup], app_menu: &[GtkMenuGroup]) -> MenuBarModel {
    let mut menus = vec![Menu::new(app_name, menu(app_name, (0, 0), app_menu, 0).items)];
    for item in menu("", (0, 0), menubar, 0).items {
        if let MenuItem::Submenu(m) = item {
            menus.push(m);
        }
    }
    MenuBarModel::new(app_name, menus)
}

/// `org.gtk.Menus.Start`'s reply as groups.
pub fn groups_from_start_reply(body: &[Value]) -> Vec<GtkMenuGroup> {
    let Some(Value::Array(_, rows)) = body.first() else { return vec![] };
    rows.iter()
        .filter_map(|row| {
            let Value::Struct(f) = row else { return None };
            let [Value::UInt32(group), Value::UInt32(menu), Value::Array(_, entries)] = &f[..] else { return None };
            let items = entries
                .iter()
                .filter_map(|e| {
                    let Value::Array(_, kvs) = e else { return None };
                    Some(
                        kvs.iter()
                            .filter_map(|kv| match kv {
                                Value::DictEntry(k, v) => match &**k {
                                    Value::String(k) => Some((k.clone(), (**v).clone())),
                                    _ => None,
                                },
                                _ => None,
                            })
                            .collect(),
                    )
                })
                .collect();
            Some(GtkMenuGroup { group: *group, menu: *menu, items })
        })
        .collect()
}

/// `org.gtk.Actions.DescribeAll`'s reply as name → enabled, with the prefix
/// (`app.` or `win.`) the menu's actions are named with.
pub fn actions_from_describe_all(body: &[Value], prefix: &str) -> HashMap<String, bool> {
    let Some(Value::Array(_, rows)) = body.first() else { return HashMap::new() };
    rows.iter()
        .filter_map(|row| match row {
            Value::DictEntry(k, v) => match (&**k, &**v) {
                (Value::String(name), Value::Struct(f)) => match f.first() {
                    Some(Value::Bool(on)) => Some((format!("{prefix}{name}"), *on)),
                    _ => None,
                },
                _ => None,
            },
            _ => None,
        })
        .collect()
}

/// Whether a command can run: the action exists and GTK says it is on.
pub fn enablement(c: &Command, actions: &HashMap<String, bool>) -> Enablement {
    if c.verb.ends_with(PARAMETERISED) {
        return Enablement::Disabled("a parameterised action, which the bridge does not carry yet".into());
    }
    match actions.get(&c.verb) {
        None => Enablement::Disabled(format!("the application has no action {}", c.verb)),
        Some(true) => Enablement::Enabled,
        Some(false) => Enablement::Disabled("the application has disabled it".into()),
    }
}
