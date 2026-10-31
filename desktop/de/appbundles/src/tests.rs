//! The `.desktop` to `.app` rules, with no filesystem
//! (Tests/AppBundlesTests). The entries are the ones the 16 guest has.

use super::*;

const GALCULATOR: &str = "[Desktop Entry]\nVersion=1.0\nName=Galculator\nName[fr]=Galculator (fr)\nComment=Perform simple and scientific calculations\nExec=galculator\nIcon=galculator\nTerminal=false\nType=Application\n";

fn strings(xs: &[&str]) -> Vec<String> {
    xs.iter().map(|x| (*x).to_owned()).collect()
}

fn skip(e: &DesktopEntry) -> Option<String> {
    e.skip_reason("AbyssBSD", false)
}

#[test]
fn an_entry_is_read_and_its_localised_keys_are_not_the_default() {
    let e = DesktopEntry::parse(GALCULATOR).unwrap();
    assert_eq!((e.name.as_str(), e.icon.as_str()), ("Galculator", "galculator"));
    assert_eq!(skip(&e), None);
    assert_eq!(e.command(), Some((strings(&["galculator"]), false)));
    assert_eq!(DesktopEntry::parse("Name=nothing\n"), None, "no [Desktop Entry] group, no entry");
}

/// Half the guest's entries are URL handlers, daemons and Xwayland.
#[test]
fn what_is_not_an_application_says_why() {
    let why = |extra: &str| skip(&DesktopEntry::parse(&format!("[Desktop Entry]\nName=X\nExec=x\nType=Application\n{extra}")).unwrap());
    assert_eq!(why("NoDisplay=true\n").as_deref(), Some("NoDisplay (a handler or a service, not an application)"));
    assert_eq!(why("Hidden=true\n").as_deref(), Some("Hidden"));
    assert_eq!(why("OnlyShowIn=XFCE;GNOME;\n").as_deref(), Some("only for XFCE, GNOME"));
    assert_eq!(why("NotShowIn=AbyssBSD;\n").as_deref(), Some("not for AbyssBSD"));
    assert_eq!(why("Terminal=true\n").as_deref(), Some("needs a terminal, and Terminal was not found beside abyss-appgen"));
    let t = DesktopEntry::parse("[Desktop Entry]\nName=X\nExec=x\nType=Application\nTerminal=true\n").unwrap();
    assert_eq!(t.skip_reason("AbyssBSD", true), None);
    assert_eq!(skip(&DesktopEntry::parse("[Desktop Entry]\nName=L\nType=Link\n").unwrap()).as_deref(), Some("a Link, not an application"));
    assert_eq!(skip(&DesktopEntry::parse("[Desktop Entry]\nName=K\nType=Application\nExec=\n").unwrap()).as_deref(), Some("no Exec"));
}

/// The spec's quoting, and its field codes: one file code becomes where the
/// Finder's files go; the rest are dropped; `%%` is a percent sign.
#[test]
fn exec_is_split_as_the_spec_says_and_field_codes_placed() {
    let e = DesktopEntry::parse("[Desktop Entry]\nType=Application\nName=Geo\nExec=geo-uri-handler --query-template \"https://maps/?q=<Q> \\\\\"x\\\\\"\" --pct 100%% %u %F %i\n").unwrap();
    let (argv, files) = e.command().unwrap();
    assert_eq!(argv, strings(&["geo-uri-handler", "--query-template", "https://maps/?q=<Q> \"x\"", "--pct", "100%", FILES_MARKER]));
    assert!(files);
    assert_eq!(DesktopEntry::parse("[Desktop Entry]\nType=Application\nName=Q\nExec=a \"unterminated\n").unwrap().command(), None);
    assert_eq!(DesktopEntry::parse("[Desktop Entry]\nType=Application\nName=F\nExec=%f\n").unwrap().command(), None, "a file code where the program should be");
}

#[test]
fn the_launcher_execs_the_command_with_the_files_where_they_go() {
    let s = launcher(&strings(&["designer6", "--style", "it's", FILES_MARKER]), "/usr/local/share/applications/designer.desktop", None, None);
    assert!(s.starts_with("#!/bin/sh\n"));
    assert!(s.ends_with("exec designer6 --style 'it'\\''s' \"$@\"\n"), "{s}");
    assert_eq!(directory_name("Firefox Web Browser"), "Firefox Web Browser.app");
    // Terminal=true (P15.4): the command runs in a Terminal window.
    assert!(launcher(&strings(&["top", "-s", "2"]), "top.desktop", Some("/usr/local/bin/AquaDemo"), None).ends_with("exec env AQUA_SCENE=terminal /usr/local/bin/AquaDemo -e top -s 2\n"));
    assert_eq!(directory_name("a/b"), "a-b.app");
    assert_eq!(directory_name(".hidden"), "hidden.app");
}

/// A confined application's launcher asks the session to start it in its
/// jail (P18.5), files and all; Terminal is never confined.
#[test]
fn a_confined_launcher_goes_through_the_sessions_jails() {
    assert!(launcher(&strings(&["galculator", FILES_MARKER]), "g.desktop", None, Some("app")).ends_with("exec abyss-jail launch app -- galculator \"$@\"\n"));
    assert!(launcher(&strings(&["top"]), "top.desktop", Some("/bin/T"), Some("app")).ends_with("exec env AQUA_SCENE=terminal /bin/T -e top\n"), "Terminal is the person's own");
    assert!(launcher(&strings(&["x"]), "x.desktop", None, Some("")).ends_with("exec x\n"));
}

#[test]
fn which_applications_are_confined_is_the_persons_choice_over_the_entrys() {
    let mut e = DesktopEntry::parse("[Desktop Entry]\nType=Application\nName=Z\nExec=zenity\nX-Abyss-Jail=app-gl\n").unwrap();
    assert_eq!(e.jail, "app-gl");
    let f = "/usr/local/share/applications/org.gnome.Zenity.desktop";
    let row = |k: &str, v: &str| vec![(k.to_owned(), v.to_owned())];
    assert_eq!(jail_class(&e, f, &[]).as_deref(), Some("app-gl"), "the entry's own ask");
    assert_eq!(jail_class(&e, f, &row("org.gnome.Zenity", "app")).as_deref(), Some("app"));
    assert_eq!(jail_class(&e, f, &row("org.gnome.Zenity", "none")), None, "none keeps it out");
    e.jail.clear();
    assert_eq!(jail_class(&e, f, &row("galculator", "app")), None, "opt-in: not listed, not confined");
    assert_eq!(jail_class(&e, "/x/galculator.desktop", &row("galculator", "app")).as_deref(), Some("app"));
}

/// Which running windows are this application's (P15.2).
#[test]
fn a_running_window_is_matched_to_its_application() {
    let g = DesktopEntry::parse(GALCULATOR).unwrap().app_ids("/usr/local/share/applications/galculator.desktop");
    assert_eq!(g, ["galculator"], "the same name twice is one candidate");
    assert!(matches("galculator", &g));
    let fedora = DesktopEntry::parse("[Desktop Entry]\nType=Application\nName=Firefox\nExec=firefox %u\n").unwrap().app_ids("/usr/share/applications/org.mozilla.firefox.desktop");
    assert_eq!(fedora, ["org.mozilla.firefox", "firefox"]);
    assert!(matches("org.mozilla.firefox", &fedora));
    let ff = DesktopEntry::parse("[Desktop Entry]\nType=Application\nName=Firefox Web Browser\nExec=firefox %U\n").unwrap().app_ids("firefox.desktop");
    assert_eq!(ff, ["firefox"]);
    assert!(matches("firefox-esr", &ff));
    assert!(!matches("firefoxy", &ff));
    assert!(!matches("", &ff));
    let w = DesktopEntry::parse("[Desktop Entry]\nType=Application\nName=W\nStartupWMClass=org.x.W\nExec=env A=1 /opt/bin/wprog\n").unwrap().app_ids("w.desktop");
    assert_eq!(w, ["org.x.W", "w", "wprog"]);
}

/// galculator's icon on the guest: a 48 px PNG and a scalable SVG in
/// hicolor. 48 px is too small for the Dock, so the SVG is rasterised.
#[test]
fn the_icon_is_a_big_enough_png_else_an_svg_else_the_biggest_png() {
    let g = strings(&["/i/hicolor/48x48/apps/galculator.png", "/i/hicolor/scalable/apps/galculator.svg", "/i/Adwaita/symbolic/apps/galculator-symbolic.svg"]);
    assert_eq!(choose_icon(&g), Some(IconChoice::Svg("/i/hicolor/scalable/apps/galculator.svg".into(), 256)));
    let demo = strings(&["/i/hicolor/48x48/apps/gtk3-demo.png", "/i/hicolor/256x256/apps/gtk3-demo.png"]);
    assert_eq!(choose_icon(&demo), Some(IconChoice::Png("/i/hicolor/256x256/apps/gtk3-demo.png".into())));
    assert_eq!(choose_icon(&strings(&["/i/x/32x32/apps/a.png", "/i/x/64x64@2x/apps/a.png"])), Some(IconChoice::Png("/i/x/64x64@2x/apps/a.png".into())), "@2x doubles its size: 128");
    assert_eq!(choose_icon(&strings(&["/i/x/32x32/apps/a.png"])), Some(IconChoice::Png("/i/x/32x32/apps/a.png".into())), "nothing better: the best there is");
    assert_eq!(choose_icon(&strings(&["/i/x/scalable/a-symbolic.svg"])), None);
}

// MARK: the desktop's own (P18.13 loose ends)

#[test]
fn jaguars_layout() {
    let at = |n: &str| BUILTIN_APPS.iter().find(|b| b.name == n).map(|b| b.folder);
    assert_eq!(at("Finder"), Some(None), "the Finder lived in CoreServices: no bundle");
    for n in ["System Preferences", "TextEdit", "Agent"] {
        assert_eq!(at(n), Some(Some("")), "{n}");
    }
    for n in ["Terminal", "Grab", "Activity Monitor", "Disk Utility", "System Profiler"] {
        assert_eq!(at(n), Some(Some("Utilities")), "{n}");
    }
    let mut tokens: Vec<&str> = BUILTIN_APPS.iter().map(|b| b.token).collect();
    tokens.sort();
    tokens.dedup();
    assert_eq!(tokens.len(), BUILTIN_APPS.len(), "one token each");
}

#[test]
fn a_launcher_runs_the_shell_in_its_scene() {
    let t = BUILTIN_APPS.iter().find(|b| b.token == "diskutility").unwrap();
    assert_eq!(t.launcher("/opt/ade bin/AquaDemo").lines().last(), Some("AQUA_SCENE=diskutility exec '/opt/ade bin/AquaDemo' \"$@\""), "the path quoted; the files handed on");
    assert_eq!(t.theme_icon(), "dock.icon.diskutility");
    assert_eq!(t.marker(), "builtin:diskutility");
}
