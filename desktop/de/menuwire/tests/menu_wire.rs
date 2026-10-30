//! MenuWireTests.swift, ported. Services bind in a per-test scratch
//! directory, so tests running in parallel never share a socket or touch
//! the environment.

use current_ipc::{connect_path, receive, send, Msg};
use menu_model::{
    Argument, ArgumentType, Command, CommandResult, Enablement, Key, KeyEquivalent, Menu, MenuBarModel, MenuItem,
    Modifiers,
};
use menu_wire::fixtures::{key_name, key_named};
use menu_wire::{client, Error, MenuProvider, MenuService};
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

const NONE: Modifiers = Modifiers::NONE;

/// A provider with one of everything the wire has to carry.
struct FakeApp {
    performed: Vec<(String, BTreeMap<String, String>)>,
    paste_enabled: bool,
    model: MenuBarModel,
}

impl FakeApp {
    fn new() -> FakeApp {
        let cmd = MenuItem::Command;
        let model = MenuBarModel::new(
            "Fake",
            vec![
                Menu::new("Fake", vec![cmd(Command::new("app.about", "About Fake", "Say what this is."))]),
                Menu::new(
                    "File",
                    vec![
                        cmd(Command::new("file.open", "Open", "Open it.")
                            .with_key(KeyEquivalent::cmd('o', NONE))
                            .with_alternates(vec![KeyEquivalent::cmd_key(Key::Down, NONE)])),
                        MenuItem::Separator,
                        MenuItem::Submenu(Menu::new(
                            "Recent",
                            vec![MenuItem::Submenu(Menu::new(
                                "Older",
                                vec![cmd(Command::new("file.oldest", "Oldest", "Three deep.")
                                    .with_key(KeyEquivalent::cmd('9', Modifiers::SHIFT | Modifiers::OPTION)))],
                            ))],
                        )),
                        cmd(Command::new("file.go", "Go…", "Go somewhere.").with_arguments(vec![
                            Argument::new("path", ArgumentType::Path, "Where."),
                            Argument::new("times", ArgumentType::Integer, "How often."),
                        ])),
                    ],
                ),
                Menu::new(
                    "Edit",
                    vec![cmd(Command::new("edit.paste", "Paste", "Paste.").with_key(KeyEquivalent::cmd('v', NONE)))],
                ),
                Menu::new("Empty", vec![]),
            ],
        );
        FakeApp { performed: Vec::new(), paste_enabled: false, model }
    }
}

impl MenuProvider for FakeApp {
    fn menu_model(&self) -> MenuBarModel {
        self.model.clone()
    }

    fn menu_validate(&self, c: &Command) -> Enablement {
        if c.verb == "edit.paste" && !self.paste_enabled {
            Enablement::Disabled("the clipboard is empty".into())
        } else {
            Enablement::Enabled
        }
    }

    fn menu_perform(&mut self, c: &Command, arguments: &BTreeMap<String, String>) -> CommandResult {
        self.performed.push((c.verb.clone(), arguments.clone()));
        CommandResult::Ok(if c.verb == "file.go" { arguments.get("path").cloned() } else { None })
    }
}

fn round_trip(m: &Msg) -> Msg {
    Msg::unpack(&m.pack(), vec![]).unwrap()
}

fn args(kv: &[(&str, &str)]) -> BTreeMap<String, String> {
    kv.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

/// `writes` (P18.11) travels, and an application that never says it reads
/// as writing nothing.
#[test]
fn writes_round_trips() {
    let model = MenuBarModel::new(
        "W",
        vec![Menu::new(
            "File",
            vec![
                MenuItem::Command(Command::new("file.save", "Save", "Save.").writing()),
                MenuItem::Command(Command::new("file.close", "Close", "Close.")),
            ],
        )],
    );
    let (back, _) = menu_wire::decode_describe(&round_trip(&menu_wire::describe_reply(&model, &|_| Enablement::Enabled))).unwrap();
    assert_eq!(back.commands().iter().map(|c| c.writes).collect::<Vec<_>>(), [true, false]);
    assert_eq!(back, model);
}

#[test]
fn describe_round_trips_the_whole_tree() {
    let app = FakeApp::new();
    let reply = round_trip(&menu_wire::describe_reply(&app.model, &|c| app.menu_validate(c)));
    let (model, enablement) = menu_wire::decode_describe(&reply).unwrap();
    assert_eq!(model, app.model, "menus, separators, a submenu three deep, an empty menu, keys, arguments");
    assert_eq!(
        enablement.get("edit.paste"),
        Some(&Enablement::Disabled("the clipboard is empty".into())),
        "enablement travels with the reason, for a reader that sees no grey"
    );
    assert_eq!(enablement.get("file.oldest"), Some(&Enablement::Enabled));
}

#[test]
fn validate_carries_every_command() {
    let mut app = FakeApp::new();
    app.paste_enabled = true;
    let v = menu_wire::decode_validate(&round_trip(&menu_wire::validate_reply(&app.model, &|c| app.menu_validate(c)))).unwrap();
    let verbs: HashSet<&str> = app.model.commands().iter().map(|c| c.verb.as_str()).collect();
    assert_eq!(v.keys().map(String::as_str).collect::<HashSet<_>>(), verbs);
    assert_eq!(v.get("edit.paste"), Some(&Enablement::Enabled));
}

#[test]
fn every_key_name_round_trips() {
    let keys = [
        Key::Character('a'),
        Key::Character('['),
        Key::Character('é'),
        Key::Backspace,
        Key::ForwardDelete,
        Key::Up,
        Key::Down,
        Key::Left,
        Key::Right,
        Key::Enter,
        Key::Escape,
        Key::Tab,
    ];
    for k in keys {
        assert_eq!(key_named(&key_name(k)), Some(k), "{k:?}");
    }
    assert_eq!(key_named("char:ab"), None);
    assert_eq!(key_named("char:"), None);
    assert_eq!(key_named("hyper"), None);
}

#[test]
fn arguments_are_checked_against_their_declared_types() {
    let app = FakeApp::new();
    let go = app.model.command("file.go").unwrap();
    assert_eq!(MenuService::check(go, &args(&[("path", "/tmp"), ("times", "2")])), None);
    assert_eq!(
        MenuService::check(go, &args(&[("path", "/tmp")])).as_deref(),
        Some("file.go needs times (integer): How often.")
    );
    assert_eq!(
        MenuService::check(go, &args(&[("path", "tmp"), ("times", "2")])).as_deref(),
        Some("path must be an absolute path, not tmp")
    );
    assert_eq!(
        MenuService::check(go, &args(&[("path", "/tmp"), ("times", "two")])).as_deref(),
        Some("times must be an integer, not two")
    );
    assert_eq!(
        MenuService::check(go, &args(&[("path", "/tmp"), ("times", "2"), ("tims", "3")])).as_deref(),
        Some("file.go takes no argument tims"),
        "a misspelt name fails rather than being ignored"
    );
    let flag = Command::new("v.flag", "Flag", ".").with_arguments(vec![Argument::new("on", ArgumentType::Bool, "Whether.")]);
    assert_eq!(MenuService::check(&flag, &args(&[("on", "true")])), None);
    assert_eq!(MenuService::check(&flag, &args(&[("on", "yes")])).as_deref(), Some("on must be true or false, not yes"));
}

#[test]
fn activate_is_refused_with_a_reason_and_never_reaches_the_app() {
    let mut app = FakeApp::new();
    let run = |app: &mut FakeApp, verb: &str, a: &[(&str, &str)]| {
        let request = round_trip(&menu_wire::activate_request(verb, &args(a)));
        menu_wire::decode_result(&round_trip(&MenuService::handle(&request, app))).unwrap()
    };
    assert_eq!(run(&mut app, "edit.paste", &[]), CommandResult::Refused("the clipboard is empty".into()));
    assert_eq!(run(&mut app, "file.nope", &[]), CommandResult::Refused("Fake has no verb file.nope".into()));
    assert_eq!(
        run(&mut app, "file.go", &[("path", "/tmp")]),
        CommandResult::Refused("file.go needs times (integer): How often.".into())
    );
    assert!(app.performed.is_empty(), "a refused command never reaches perform");

    assert_eq!(
        run(&mut app, "file.go", &[("path", "/tmp"), ("times", "1")]),
        CommandResult::Ok(Some("/tmp".into())),
        "a result comes back, not nothing"
    );
    assert_eq!(app.performed, [("file.go".to_owned(), args(&[("path", "/tmp"), ("times", "1")]))]);
}

#[test]
fn an_argument_that_is_not_text_is_refused() {
    let mut app = FakeApp::new();
    let mut a = Msg::new();
    a.set_u64("times", 2);
    let mut m = Msg::new();
    m.set_string("method", "activate");
    m.set_string("verb", "file.go");
    m.set_bytes("arguments", &a.pack());
    let r = menu_wire::decode_result(&MenuService::handle(&m, &mut app)).unwrap();
    assert_eq!(r, CommandResult::Refused("malformed: argument times is not text".into()));
}

#[test]
fn an_unknown_method_is_an_error_not_a_result() {
    let mut app = FakeApp::new();
    let mut m = Msg::new();
    m.set_string("method", "dance");
    let reply = MenuService::handle(&m, &mut app);
    assert_eq!(reply.bool("ok"), Some(false));
    assert_eq!(menu_wire::decode_result(&reply), Err(Error::Service("unknown method dance".into())));
    let mut none = Msg::new();
    none.set_string("verb", "file.open");
    assert_eq!(MenuService::handle(&none, &mut app).string("error"), Some("unknown method (none)"));
}

#[test]
fn service_names_are_slugged() {
    assert_eq!(menu_wire::service_name("Fake", 77), "menus.fake.77");
    assert_eq!(menu_wire::service_name("Text Edit", 1), "menus.text-edit.1");
    assert_eq!(menu_wire::service_name("Café/2", 3), "menus.café-2.3");
}

// MARK: a real socket

#[test]
fn describe_activate_and_subscribe_over_a_real_socket() {
    let dir = Scratch::new();
    let mut app = FakeApp::new();
    let name = menu_wire::service_name("Fake", 77);
    let mut service = MenuService::bind(&name, &dir.sock(&name)).unwrap();

    // One thread, taking turns: the connection waits in the backlog until
    // the service is told its fd is readable, as the run loop would.
    let exchange = |service: &mut MenuService, app: &mut FakeApp, request: &Msg| {
        let c = connect_path(&dir.sock(&name)).unwrap();
        send(request, &c).unwrap();
        service.service_readable(app);
        receive(&c).unwrap()
    };
    let mut describe = Msg::new();
    describe.set_string("method", "describe");
    let (model, _) = menu_wire::decode_describe(&exchange(&mut service, &mut app, &describe)).unwrap();
    assert_eq!(model.app_name, "Fake");
    let open = menu_wire::activate_request("file.open", &BTreeMap::new());
    assert_eq!(menu_wire::decode_result(&exchange(&mut service, &mut app, &open)).unwrap(), CommandResult::Ok(None));

    // Subscribe, then change: the push arrives on the held connection.
    let sub = connect_path(&dir.sock(&name)).unwrap();
    let mut s = Msg::new();
    s.set_string("method", "subscribe");
    send(&s, &sub).unwrap();
    service.service_readable(&mut app);
    assert_eq!(receive(&sub).unwrap().bool("ok"), Some(true));
    assert_eq!(service.subscriber_count(), 1);
    service.changed();
    assert_eq!(receive(&sub).unwrap().string("method"), Some("changed"));

    // A subscriber that has gone is dropped the next time there is news.
    drop(sub);
    service.changed();
    service.changed(); // the first send may still land in the socket buffer
    assert_eq!(service.subscriber_count(), 0);
}

#[test]
fn resolve_finds_an_application_by_name() {
    let dir = Scratch::new();
    let d = dir.0.to_str().unwrap();
    assert_eq!(client::resolve_in(d, "fake"), Err(Error::NoSuchApplication("fake".into())));
    let one_name = menu_wire::service_name("Fake", 1);
    let one = MenuService::bind(&one_name, &dir.sock(&one_name)).unwrap();
    assert_eq!(client::resolve_in(d, "fake").as_deref(), Ok("menus.fake.1"));
    assert_eq!(client::resolve_in(d, "menus.fake.1").as_deref(), Ok("menus.fake.1"));

    // A socket left by a crash is not an application: it does not make the
    // name ambiguous. (Bound and never listened on: a connect is refused.)
    drop(UnixListener::bind(dir.sock(&menu_wire::service_name("Fake", 2))).unwrap());
    assert_eq!(client::resolve_in(d, "fake").as_deref(), Ok("menus.fake.1"));
    assert_eq!(client::services_in(d), ["menus.fake.1"]);

    let three_name = menu_wire::service_name("Fake", 3);
    let three = MenuService::bind(&three_name, &dir.sock(&three_name)).unwrap();
    assert_eq!(
        client::resolve_in(d, "fake"),
        Err(Error::Ambiguous("fake".into(), vec!["menus.fake.1".into(), "menus.fake.3".into()]))
    );
    drop((one, three));
}

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Scratch {
        static N: AtomicU32 = AtomicU32::new(0);
        let p = std::env::temp_dir().join(format!("abyss-menu-{}-{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir(&p).unwrap();
        Scratch(p)
    }
    fn sock(&self, service: &str) -> String {
        format!("{}/{service}.sock", self.0.display())
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
