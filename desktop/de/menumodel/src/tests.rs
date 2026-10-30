//! MenuModelTests.swift, and GtkMenusTests' address round trip, ported.

use super::*;

const NONE: Modifiers = Modifiers::NONE;

#[test]
fn display_orders_modifiers_the_mac_way() {
    assert_eq!(KeyEquivalent::cmd('n', Modifiers::SHIFT).display(), "⇧⌘N");
    assert_eq!(KeyEquivalent::cmd_key(Key::Backspace, NONE).display(), "⌘⌫");
    assert_eq!(KeyEquivalent::cmd_key(Key::Escape, Modifiers::OPTION).display(), "⌥⌘⎋");
    let all = Modifiers::CONTROL | Modifiers::OPTION | Modifiers::SHIFT | Modifiers::COMMAND;
    assert_eq!(KeyEquivalent::new(Key::Character('x'), all).display(), "⌃⌥⇧⌘X");
    assert_eq!(KeyEquivalent::cmd_key(Key::Up, NONE).display(), "⌘↑");
}

#[test]
fn characters_are_stored_lowercased() {
    // Shift is a modifier, not a different letter: an uppercase definition
    // and a lowercase press are the same key.
    assert_eq!(
        KeyEquivalent::new(Key::Character('N'), Modifiers::COMMAND | Modifiers::SHIFT),
        KeyEquivalent::cmd('n', Modifiers::SHIFT)
    );
    assert_eq!(KeyEquivalent::cmd('Ü', NONE).key(), Key::Character('ü'));
    // İ lowercases to two characters: kept as it is.
    assert_eq!(KeyEquivalent::cmd('İ', NONE).key(), Key::Character('İ'));
    assert_eq!(KeyEquivalent::cmd('ß', NONE).display(), "⌘SS", "uppercased as a string");
}

fn model() -> MenuBarModel {
    MenuBarModel::new(
        "Test",
        vec![
            Menu::new(
                "File",
                vec![
                    MenuItem::Command(
                        Command::new("file.open", "Open", "Open it.")
                            .with_key(KeyEquivalent::cmd('o', NONE))
                            .with_alternates(vec![KeyEquivalent::cmd_key(Key::Down, NONE)]),
                    ),
                    MenuItem::Separator,
                    MenuItem::Submenu(Menu::new(
                        "Recent",
                        vec![MenuItem::Command(
                            Command::new("file.recent", "Recent", "Again.").with_key(KeyEquivalent::cmd('r', NONE)),
                        )],
                    )),
                ],
            ),
            Menu::new(
                "Edit",
                vec![
                    MenuItem::Command(Command::new("edit.copy", "Copy", "Copy it.").with_key(KeyEquivalent::cmd('c', NONE))),
                    MenuItem::Command(Command::new("edit.noKey", "No Key", "Mouse only.")),
                ],
            ),
        ],
    )
}

#[test]
fn verb_lookup_is_exact_on_modifiers() {
    let m = model();
    assert_eq!(m.verb_for(&KeyEquivalent::cmd('o', NONE)), Some("file.open"));
    assert_eq!(m.verb_for(&KeyEquivalent::cmd_key(Key::Down, NONE)), Some("file.open"), "an alternate key runs it too");
    assert_eq!(m.verb_for(&KeyEquivalent::cmd('o', Modifiers::SHIFT)), None, "⇧⌘O is a different keystroke");
    assert_eq!(m.verb_for(&KeyEquivalent::new(Key::Character('o'), NONE)), None, "a bare O is typing");
    assert_eq!(m.verb_for(&KeyEquivalent::cmd('r', NONE)), Some("file.recent"), "submenus are searched");
}

#[test]
fn commands_flatten_in_menu_order() {
    let m = model();
    let verbs: Vec<&str> = m.commands().iter().map(|c| c.verb.as_str()).collect();
    assert_eq!(verbs, ["file.open", "file.recent", "edit.copy", "edit.noKey"]);
    assert_eq!(m.command("edit.copy").map(|c| c.title.as_str()), Some("Copy"));
    let keys: Vec<KeyEquivalent> = m.command("file.open").unwrap().all_keys().copied().collect();
    assert_eq!(keys, [KeyEquivalent::cmd('o', NONE), KeyEquivalent::cmd_key(Key::Down, NONE)]);
}

#[test]
fn conflicts_and_duplicates_are_found() {
    let m = model();
    assert!(m.conflicting_keys().is_empty());
    assert!(m.duplicate_verbs().is_empty());
    let a = KeyEquivalent::cmd('a', NONE);
    let bad = MenuBarModel::new(
        "Bad",
        vec![Menu::new(
            "M",
            vec![
                MenuItem::Command(Command::new("a", "A", ".").with_key(a)),
                MenuItem::Command(Command::new("b", "B", ".").with_key(a)),
                MenuItem::Command(Command::new("a", "A again", ".")),
            ],
        )],
    );
    assert_eq!(bad.conflicting_keys(), [a]);
    assert_eq!(bad.duplicate_verbs(), ["a"]);
}

#[test]
fn retitling_changes_only_the_title() {
    let m = MenuBarModel::new(
        "T",
        vec![Menu::new(
            "Edit",
            vec![
                MenuItem::Command(Command::new("edit.undo", "Undo", "Undo it.").with_key(KeyEquivalent::cmd('z', NONE)).writing()),
                MenuItem::Submenu(Menu::new("More", vec![MenuItem::Command(Command::new("edit.redo", "Redo", "Again."))])),
            ],
        )],
    );
    let titles = [("edit.undo", "Undo Move to Trash"), ("edit.redo", "Redo Typing")]
        .map(|(v, t)| (v.to_owned(), t.to_owned()))
        .into_iter()
        .collect();
    let r = m.retitled(&titles);
    let undo = r.command("edit.undo").unwrap();
    assert_eq!(undo.title, "Undo Move to Trash");
    assert_eq!(undo, &Command { title: "Undo Move to Trash".into(), ..m.command("edit.undo").unwrap().clone() });
    assert!(undo.writes, "writes survives a retitle");
    assert_eq!(r.command("edit.redo").unwrap().title, "Redo Typing", "submenus are retitled too");
    assert_eq!(m.retitled(&Default::default()), m);
}

#[test]
fn the_address_round_trips_and_knows_when_there_is_nothing_to_read() {
    let a = GtkMenuAddress {
        application_id: "org.abyss.MenuSpike".into(),
        bus_name: ":1.0".into(),
        application_path: "/org/abyss/MenuSpike".into(),
        menubar_path: "/org/abyss/MenuSpike/menus/menubar".into(),
        app_menu_path: "".into(),
        window_path: "/org/abyss/MenuSpike/window/1".into(),
    };
    assert_eq!(GtkMenuAddress::from_encoded(&a.encoded()).as_ref(), Some(&a));
    assert!(a.has_menus());
    let none = GtkMenuAddress { menubar_path: "".into(), ..a.clone() };
    assert!(!none.has_menus(), "a window with no menubar and no app menu has nothing to show");
    assert_eq!(GtkMenuAddress::from_encoded("just one line"), None);
    let no_bus = GtkMenuAddress { bus_name: "".into(), ..a };
    assert_eq!(GtkMenuAddress::from_encoded(&no_bus.encoded()), None, "a bus is required");
}
