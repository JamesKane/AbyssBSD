//! DBusPortalTests.swift: the FileChooser and Settings rules, without a bus.
//! Every literal (a Request path's shape, a results key) is from the
//! interface XML on disk, not from memory. What a real GTK app gets is the
//! live scripts' to say.

use crate::*;
use current_ipc::Msg;
use dbus::Value;
use settings::{APPEARANCE, PALETTE};

fn bytes(s: &str) -> Value {
    Value::Array("y".into(), s.bytes().chain([0]).map(Value::Byte).collect())
}

fn opts(pairs: Vec<(&str, Value)>) -> ChooserOptions {
    ChooserOptions::from(&Value::options(pairs))
}

fn strings(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| s.to_string()).collect()
}

// MARK: the Request object's path

/// The spec's transformation, which the *client* performs too, on its own
/// name, to subscribe before it calls: any divergence is a hang.
#[test]
fn request_path_is_derived_the_way_the_spec_says() {
    assert_eq!(request_path(":1.42", "gtk1").as_deref(), Some("/org/freedesktop/portal/desktop/request/1_42/gtk1"));
    assert_eq!(request_path(":1.0", "t").as_deref(), Some("/org/freedesktop/portal/desktop/request/1_0/t"));
    // Every dot, not just the first.
    assert_eq!(sender_element(":1.2.3").as_deref(), Some("1_2_3"));
}

/// Refused, not sanitised into something the client cannot predict.
#[test]
fn tokens_that_would_break_the_object_path_are_refused() {
    for bad in ["a/b", "a-b", "a b", "", "café"] {
        assert_eq!(request_path(":1.4", bad), None, "{bad:?}");
    }
    assert!(request_path(":1.4", "a_1B").is_some());
}

#[test]
fn a_sender_with_dots_but_no_colon_still_produces_one_element() {
    assert_eq!(sender_element("org.gtk.App").as_deref(), Some("org_gtk_App"));
    assert_eq!(sender_element("org.gtk.App-2"), None);
}

// MARK: file:// URIs

#[test]
fn paths_become_properly_escaped_file_uris() {
    assert_eq!(file_uri("/home/jkane/notes.txt"), "file:///home/jkane/notes.txt");
    assert_eq!(file_uri("/home/jkane/My Documents/a b.txt"), "file:///home/jkane/My%20Documents/a%20b.txt");
    // `?` and `#` would make the rest a query or a fragment.
    assert_eq!(file_uri("/a/b?c#d"), "file:///a/b%3Fc%23d");
    assert_eq!(file_uri("/a/100%.txt"), "file:///a/100%25.txt");
}

#[test]
fn non_ascii_paths_are_encoded_byte_wise() {
    assert_eq!(file_uri("/home/j/Bücher"), "file:///home/j/B%C3%BCcher");
    assert_eq!(file_uri_path(&file_uri("/home/j/Bücher")).as_deref(), Some("/home/j/Bücher"));
    assert_eq!(file_uri_path(&file_uri("/a b/c%d?e")).as_deref(), Some("/a b/c%d?e"));
}

// MARK: the options vardict

#[test]
fn current_folder_is_a_byte_array_and_its_trailing_nul_comes_off() {
    assert_eq!(opts(vec![("current_folder", bytes("/tmp/docs"))]).current_folder.as_deref(), Some("/tmp/docs"));
}

#[test]
fn a_relative_current_folder_is_not_forwarded() {
    assert_eq!(opts(vec![("current_folder", bytes("../../etc"))]).current_folder, None);
    // A string where `ay` belongs is a client bug: ignored, not obeyed.
    assert_eq!(opts(vec![("current_folder", Value::String("/tmp".into()))]).current_folder, None);
}

#[test]
fn options_we_understand_and_options_we_merely_tolerate() {
    let filters = Value::Array(
        "(sa(us))".into(),
        vec![Value::Struct(vec![Value::String("Text".into()), Value::Array("(us)".into(), vec![Value::Struct(vec![Value::UInt32(0), Value::String("*.txt".into())])])])],
    );
    let o = opts(vec![
        ("handle_token", Value::String("gtk7".into())),
        ("multiple", Value::Bool(true)),
        ("modal", Value::Bool(true)),
        ("accept_label", Value::String("_Open".into())),
        ("filters", filters),
    ]);
    assert_eq!(o.handle_token.as_deref(), Some("gtk7"));
    assert!(o.multiple);
    assert!(!o.directory);
    let mut ignored = o.ignored.clone();
    ignored.sort();
    assert_eq!(ignored, strings(&["accept_label", "filters", "modal"]));
}

#[test]
fn an_empty_options_dictionary_is_fine() {
    assert_eq!(opts(vec![]), ChooserOptions::default());
}

// MARK: translating to abyss-portal

/// The confused-deputy rule at the bridge too: no option becomes "the path
/// to open".
#[test]
fn the_bridge_cannot_be_talked_into_naming_a_file() {
    let open = portal_call_message(
        ChooserKind::Open,
        &opts(vec![("current_folder", bytes("/tmp/docs")), ("current_name", Value::String("secret.txt".into())), ("current_file", bytes("/tmp/docs"))]),
    );
    assert_eq!(open.string("method"), Some("file.open"));
    assert_eq!(open.string("dir"), Some("/tmp/docs"));
    // `current_name` is a save suggestion, and `current_file` is never
    // forwarded.
    assert_eq!(open.string("name"), None);
    assert_eq!(open.string("path"), None);
    assert!(!open.has("file"));

    let save = portal_call_message(ChooserKind::Save, &opts(vec![("current_name", Value::String("Untitled.txt".into()))]));
    assert_eq!(save.string("method"), Some("file.save"));
    assert_eq!(save.string("name"), Some("Untitled.txt"));
}

// MARK: the Response

fn reply(ok: bool, key: &str, value: &str) -> Msg {
    let mut m = Msg::new();
    m.set_bool("ok", ok);
    if !key.is_empty() {
        m.set_string(key, value);
    }
    m
}

#[test]
fn cancel_is_not_an_error() {
    assert_eq!(chooser_response(&reply(false, "error", "cancelled")).0, PortalResponse::Cancelled);
    assert_eq!(chooser_response(&reply(false, "error", "the picker exited 3")).0, PortalResponse::Other);
}

#[test]
fn a_success_without_a_path_is_not_a_success() {
    let (code, results) = chooser_response(&reply(true, "path", "/tmp/docs/Chosen file.txt"));
    assert_eq!(code, PortalResponse::Success);
    assert_eq!(results, Value::options(vec![("uris", Value::Array("s".into(), vec![Value::String("file:///tmp/docs/Chosen%20file.txt".into())]))]));
    assert_eq!(chooser_response(&reply(true, "", "")).0, PortalResponse::Other);
    assert_eq!(chooser_response(&reply(true, "path", "docs/x.txt")).0, PortalResponse::Other, "a relative path is not an answer");
}

#[test]
fn results_have_the_signature_the_spec_publishes() {
    let r = chooser_results(&["/a/b.txt"]);
    assert_eq!(r.signature(), "a{sv}");
    let Value::Array(_, entries) = &r else { panic!() };
    let Value::DictEntry(k, v) = &entries[0] else { panic!() };
    assert_eq!(**k, Value::String("uris".into()));
    let Value::Variant(inner) = &**v else { panic!() };
    assert_eq!(inner.signature(), "as");
}

// MARK: introspection walking

#[test]
fn introspection_points_the_way_down_from_the_root() {
    assert_eq!(next_component(OBJECT_PATH, "/").as_deref(), Some("org"));
    assert_eq!(next_component(OBJECT_PATH, "/org").as_deref(), Some("freedesktop"));
    assert_eq!(next_component(OBJECT_PATH, "/org/freedesktop/portal").as_deref(), Some("desktop"));
    assert_eq!(next_component(OBJECT_PATH, OBJECT_PATH), None);
    assert_eq!(next_component(OBJECT_PATH, "/net"), None);
    assert!(service::introspection(Some("/org")).contains("<node name=\"freedesktop\"/>"));
}

// MARK: Settings (P8.3)

#[test]
fn namespace_globbing_is_trailing_only() {
    let m = PortalSettings::matches;
    assert!(m("org.gnome.desktop.interface", &strings(&["org.gnome.*"])));
    assert!(m(APPEARANCE, &strings(&[APPEARANCE])));
    assert!(m("anything", &[]));
    assert!(m("anything", &strings(&["a.b", ""])));
    assert!(!m("org.kde.stuff", &strings(&["org.gnome.*"])));
    assert!(!m("org.gnome", &strings(&["org.gnome.*"])), "the `.` is part of the prefix");
}

#[test]
fn read_all_answers_empty_for_namespaces_we_do_not_publish() {
    let all = PortalSettings::aqua().read_all(&strings(&["org.gnome.*"]));
    assert_eq!(all.signature(), "a{sa{sv}}");
    assert_eq!(all, Value::Array("{sa{sv}}".into(), vec![]));
}

#[test]
fn read_all_carries_the_appearance_namespace() {
    for patterns in [vec![], strings(&[""]), strings(&["org.freedesktop.*"]), strings(&[APPEARANCE])] {
        let Value::Array(_, entries) = PortalSettings::aqua().read_all(&patterns) else { panic!() };
        let Some(Value::DictEntry(ns, keys)) = entries.first() else { panic!("no namespace for {patterns:?}") };
        assert_eq!(**ns, Value::String(APPEARANCE.into()));
        assert_eq!(keys.signature(), "a{sv}");
    }
}

/// The asymmetry is the interface's, not ours: reproducing it is correct.
#[test]
fn read_is_double_wrapped_and_read_one_is_not() {
    let a = PortalSettings::aqua();
    let v = |x| Value::Variant(Box::new(x));
    assert_eq!(a.read_one(APPEARANCE, "color-scheme"), Some(v(Value::UInt32(2))));
    assert_eq!(a.read(APPEARANCE, "color-scheme"), Some(v(v(Value::UInt32(2)))));
}

#[test]
fn an_unknown_setting_is_not_invented() {
    let a = PortalSettings::aqua();
    assert_eq!(a.read_one(APPEARANCE, "no-such-key"), None);
    assert_eq!(a.read_one("org.gnome.desktop.interface", "font-name"), None);
}

#[test]
fn the_desktop_reports_the_preference_it_actually_has() {
    assert_eq!(PortalSettings::aqua().value(APPEARANCE, "color-scheme"), Some(&Value::UInt32(2)));
}

fn accent() -> Vec<f64> {
    let a = PortalSettings::aqua();
    let Some(Value::Struct(parts)) = a.value(APPEARANCE, "accent-color") else { panic!("no accent colour") };
    parts.iter().map(|p| if let Value::Double(c) = p { *c } else { panic!("not a double") }).collect()
}

/// Out of [0,1] means "unset": a component left at 0–255 would silently turn
/// the accent off.
#[test]
fn the_accent_colour_is_three_doubles_in_range() {
    let c = accent();
    assert_eq!(c.len(), 3);
    assert!(c.iter().all(|x| (0.0..=1.0).contains(x)), "{c:?}");
}

/// …and it is the colour the desktop selects things with: change Jaguar's
/// `menu_highlight` and this fails.
#[test]
fn the_accent_colour_matches_the_aqua_theme() {
    let c = aquadraw::tokens::ThemeTokens::jaguar().menu_highlight;
    assert_eq!(accent(), vec![c.r, c.g, c.b], "the Settings accent colour has drifted from Theme.menuHighlight");
}

// MARK: the theme's palette (P11.10)

#[test]
fn settings_are_made_from_a_themes_palette() {
    let text = "[theme]\nname = T\n[appearance]\ncolor-scheme = 1\naccent-color = 1 0.1686 0.8392\ncontrast = 1\n[palette]\nwindow-background = 0.1 0.08 0.2\n";
    let s = PortalSettings::from_palette(text).unwrap();
    let d = |a: f64, b: f64, c: f64| Value::Struct(vec![Value::Double(a), Value::Double(b), Value::Double(c)]);
    assert_eq!(s.value(APPEARANCE, "color-scheme"), Some(&Value::UInt32(1)));
    assert_eq!(s.value(APPEARANCE, "contrast"), Some(&Value::UInt32(1)));
    assert_eq!(s.value(APPEARANCE, "accent-color"), Some(&d(1.0, 0.1686, 0.8392)));
    assert_eq!(s.value(PALETTE, "window-background"), Some(&d(0.1, 0.08, 0.2)));
    assert_eq!(PortalSettings::from_palette("[appearance]\ncolor-scheme = 7\n"), None, "not a palette: Aqua's answer stands");
    assert_eq!(PortalSettings::from_palette("nonsense"), None);
}

// MARK: the theme changes while running (P14.2)

#[test]
fn a_change_of_theme_lists_exactly_the_settings_that_differ() {
    let dark = PortalSettings::from_palette("[appearance]\ncolor-scheme = 1\naccent-color = 1 0.1686 0.8392\n[palette]\nwindow-background = 0.1 0.08 0.2\n").unwrap();
    let changes = PortalSettings::aqua().changes(&dark);
    let keys: Vec<String> = changes.iter().map(|c| format!("{} {}", c.namespace, c.key)).collect();
    assert!(keys.contains(&format!("{APPEARANCE} color-scheme")));
    assert!(keys.contains(&format!("{APPEARANCE} accent-color")));
    assert!(keys.contains(&format!("{PALETTE} window-background")), "a key the new one adds");
    assert!(!keys.contains(&format!("{APPEARANCE} contrast")), "0 before and after");
    assert!(!keys.contains(&format!("{APPEARANCE} reduced-motion")));
    assert_eq!(changes.iter().find(|c| c.key == "color-scheme").map(|c| &c.value), Some(&Value::UInt32(1)));
    assert!(dark.changes(&dark).is_empty(), "the same theme again changes nothing");
}
