//! VocabularyTests.swift, ported: only what was given, as the
//! application's own menus say it, and every step in the transcript.

use super::*;
use menu_model::{Argument, ArgumentType, Command, KeyEquivalent, Menu, MenuItem, Modifiers};
use std::cell::RefCell;
use std::rc::Rc;

/// One activation: the service, the verb, its arguments.
type Activation = (String, String, BTreeMap<String, String>);

#[derive(Default)]
pub(crate) struct FakeMenus {
    pub activated: RefCell<Vec<Activation>>,
}

pub(crate) fn fake_model(service: &str) -> Option<MenuBarModel> {
    let cmd = |c: Command| MenuItem::Command(c);
    match service {
        "menus.textedit.42" => Some(MenuBarModel::new(
            "TextEdit",
            vec![Menu::new(
                "File",
                vec![
                    cmd(Command::new("file.save", "Save", "Save the document.").with_key(KeyEquivalent::cmd('s', Modifiers(0))).writing()),
                    cmd(Command::new("file.open", "Open…", "Open a file.").with_arguments(vec![Argument::new("path", ArgumentType::Path, "The file.")])),
                    cmd(Command::new("file.close", "Close", "Close the document.")),
                ],
            )],
        )),
        "menus.grab.7" => Some(MenuBarModel::new("Grab", vec![Menu::new("Capture", vec![cmd(Command::new("capture.screen", "Screen", "Capture the screen."))])])),
        _ => None,
    }
}

impl MenuCaller for FakeMenus {
    fn describe(&self, service: &str) -> Result<Described, Box<dyn Error>> {
        let m = fake_model(service).ok_or("gone")?;
        Ok((m, HashMap::from([("file.open".to_owned(), Enablement::Disabled("a document is open".into()))])))
    }

    fn activate(&self, service: &str, verb: &str, arguments: &BTreeMap<String, String>) -> Result<CommandResult, Box<dyn Error>> {
        self.activated.borrow_mut().push((service.into(), verb.into(), arguments.clone()));
        Ok(if verb == "file.save" || verb == "file.close" { CommandResult::Ok(None) } else { CommandResult::Refused("not now".into()) })
    }
}

fn msg(method: &str, app: &str, verb: &str, arguments: &str) -> Msg {
    let mut m = Msg::new();
    m.set_string("method", method);
    for (k, v) in [("app", app), ("verb", verb), ("arguments", arguments)] {
        if !v.is_empty() {
            m.set_string(k, v);
        }
    }
    m
}

/// A bridge whose transcript lines are `kind app`, kept.
fn bridge() -> (VocabularyBridge<FakeMenus>, Rc<RefCell<Vec<String>>>) {
    let logged = Rc::new(RefCell::new(vec![]));
    let l = logged.clone();
    let b = VocabularyBridge::new(
        FakeMenus::default(),
        Box::new(move |kind, f| {
            let app = f.iter().find(|(k, _)| k == "app").and_then(|(_, v)| v.as_str()).unwrap_or("").to_owned();
            l.borrow_mut().push(format!("{kind} {app}"));
        }),
    );
    (b, logged)
}

fn kinds(l: &Rc<RefCell<Vec<String>>>) -> Vec<String> {
    l.borrow().iter().map(|s| s.split(' ').next().unwrap().to_owned()).collect()
}

#[test]
fn only_what_was_given_is_reachable() {
    let (mut b, logged) = bridge();
    assert_eq!(b.handle(&msg("apps", "", "", "")).string("apps"), Some(""), "nothing until something is given");
    assert_eq!(b.give("menus.textedit.42").unwrap(), "TextEdit");
    assert_eq!(b.handle(&msg("apps", "", "", "")).string("apps"), Some("TextEdit"));
    let grab = b.handle(&msg("describe", "Grab", "", ""));
    assert_eq!(grab.bool("ok"), Some(false));
    assert_eq!(grab.string("error"), Some("Grab was not given to this session"));
    assert_eq!(b.handle(&msg("activate", "Grab", "capture.screen", "")).bool("ok"), Some(false));
    assert!(b.menus().activated.borrow().is_empty(), "a refusal is never forwarded");
    assert_eq!(*logged.borrow(), ["given TextEdit", "refused Grab", "refused Grab"]);
    assert_eq!(b.handle(&msg("describe", "", "", "")).string("error"), Some("that application was not given to this session"));
}

/// Requester 1 (P18.11): a verb that writes is not run until the person
/// allowed that application, on the keeper's side; one that does not, is.
#[test]
fn a_write_waits_for_the_person() {
    let (mut b, logged) = bridge();
    b.give("menus.textedit.42").unwrap();
    let first = b.handle(&msg("activate", "TextEdit", "file.save", ""));
    assert_eq!((first.bool("ok"), first.bool("permission"), first.string("title")), (Some(false), Some(true), Some("Save")));
    assert!(b.menus().activated.borrow().is_empty(), "not run before the person answers");
    assert_eq!(b.handle(&msg("activate", "TextEdit", "file.close", "")).string("text"), Some("ok"), "a verb that writes nothing is not asked about");
    b.permit("TextEdit", false);
    assert_eq!(b.handle(&msg("activate", "TextEdit", "file.save", "")).bool("permission"), Some(true), "Don't Allow: asked again, never run");
    b.permit("TextEdit", true);
    assert_eq!(b.handle(&msg("activate", "TextEdit", "file.save", "")).string("text"), Some("ok"));
    assert_eq!(b.menus().activated.borrow().iter().map(|a| a.1.as_str()).collect::<Vec<_>>(), ["file.close", "file.save"]);
    assert_eq!(kinds(&logged), ["given", "asked", "activate", "denied", "asked", "permitted", "activate"]);
}

#[test]
fn activate_goes_to_the_application_with_its_arguments() {
    let (mut b, _) = bridge();
    b.give("menus.textedit.42").unwrap();
    b.permit("TextEdit", true);
    assert_eq!(b.handle(&msg("activate", "textedit", "file.save", "")).string("text"), Some("ok"), "names are matched without case");
    assert_eq!(b.handle(&msg("activate", "TextEdit", "file.open", "path=/home/a.txt\nx=1=2\nnot an argument")).string("text"), Some("refused: not now"));
    let a = b.menus().activated.borrow();
    assert_eq!(a.iter().map(|x| x.0.as_str()).collect::<Vec<_>>(), ["menus.textedit.42", "menus.textedit.42"]);
    assert_eq!(a[1].2, BTreeMap::from([("path".to_owned(), "/home/a.txt".to_owned()), ("x".to_owned(), "1=2".to_owned())]));
}

#[test]
fn the_description_is_the_applications_own() {
    let (mut b, _) = bridge();
    b.give("menus.textedit.42").unwrap();
    assert_eq!(
        b.handle(&msg("describe", "TextEdit", "", "")).string("text"),
        Some(
            "TextEdit:\n  file.save — \"Save\" in File [enabled]. Save the document.\n  file.open — \"Open…\" in File; arguments: path (path): The file. [disabled: a document is open]. Open a file.\n  file.close — \"Close\" in File [enabled]. Close the document."
        )
    );
}

/// The agent's side answers apps, describe and activate, never give.
#[test]
fn the_agent_cannot_give_itself_anything() {
    let (mut b, _) = bridge();
    let mut m = msg("give", "", "", "");
    m.set_string("service", "menus.grab.7");
    let r = b.handle(&m);
    assert_eq!(r.bool("ok"), Some(false));
    assert_eq!(r.string("error"), Some("the vocabulary bridge answers apps, describe and activate"));
    assert!(b.given().is_empty());
}

/// Taken back (P18.11): refused from then on, as never given.
#[test]
fn a_taken_application_is_refused_again() {
    let (mut b, logged) = bridge();
    b.give("menus.textedit.42").unwrap();
    b.permit("TextEdit", true);
    assert!(b.take("textedit"));
    assert!(!b.take("textedit"), "nothing to take twice");
    assert_eq!(b.handle(&msg("activate", "TextEdit", "file.save", "")).string("error"), Some("TextEdit was not given to this session"));
    assert!(b.menus().activated.borrow().is_empty());
    assert_eq!(kinds(&logged), ["given", "permitted", "taken", "refused"]);
}

#[test]
fn a_give_is_one_running_copy() {
    let (mut b, _) = bridge();
    assert!(b.give("menus.textedit.999").is_err(), "an application that does not answer is not given");
    b.give("menus.textedit.42").unwrap();
    b.give("menus.textedit.42").unwrap();
    assert_eq!(b.given(), ["TextEdit"], "giving again does not duplicate");
}

/// An application that will not say what a verb does does not have it run
/// unasked: Swift's `try?` runs it.
#[test]
fn a_write_is_not_run_when_the_application_will_not_say_what_it_does() {
    struct Mute(RefCell<bool>, FakeMenus);
    impl MenuCaller for Mute {
        fn describe(&self, service: &str) -> Result<Described, Box<dyn Error>> {
            if *self.0.borrow() { Err("busy".into()) } else { self.1.describe(service) }
        }
        fn activate(&self, service: &str, verb: &str, a: &BTreeMap<String, String>) -> Result<CommandResult, Box<dyn Error>> {
            self.1.activate(service, verb, a)
        }
    }
    let mut b = VocabularyBridge::new(Mute(RefCell::new(false), FakeMenus::default()), Box::new(|_, _| {}));
    b.give("menus.textedit.42").unwrap();
    *b.menus().0.borrow_mut() = true;
    let r = b.handle(&msg("activate", "TextEdit", "file.save", ""));
    assert_eq!(r.string("error"), Some("TextEdit did not answer: busy"));
    assert!(b.menus().1.activated.borrow().is_empty(), "not run unasked");
    b.permit("TextEdit", true);
    assert_eq!(b.handle(&msg("activate", "TextEdit", "file.save", "")).string("text"), Some("ok"), "allowed: no need to ask");
}
