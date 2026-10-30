//! The cross-language fixtures (RUST.md §3.3): abyss/tests/wire/vocab,
//! written by Swift (Tests/ModelTests/VocabularyFixtureTests.swift, the
//! specification). Every script runs here against the same fake
//! applications, and the agent is told, and the transcript gets, what
//! Swift's did, byte for byte.

use current_ipc::{Msg, Value};
use menu_model::{Argument, ArgumentType, Command, CommandResult, Enablement, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use model::Json;
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::error::Error;
use std::fs;
use std::path::PathBuf;
use std::rc::Rc;
use vocabulary::{Described, MenuCaller, VocabularyBridge};

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../abyss/tests/wire/vocab")
}

#[derive(Default)]
struct Apps {
    dead: RefCell<HashSet<String>>,
}

fn model(service: &str) -> Option<MenuBarModel> {
    let cmd = MenuItem::Command;
    let textedit = MenuBarModel::new(
        "TextEdit",
        vec![
            Menu::new(
                "File",
                vec![
                    cmd(Command::new("file.save", "Save", "Save the document.").with_key(KeyEquivalent::cmd('s', Modifiers(0))).writing()),
                    cmd(Command::new("file.open", "Open…", "Open a file.").with_arguments(vec![Argument::new("path", ArgumentType::Path, "The file.")])),
                    MenuItem::Separator,
                    cmd(Command::new("file.close", "Close", "Close the document.")),
                ],
            ),
            Menu::new(
                "Edit",
                vec![cmd(Command::new("edit.find", "Find…", "Find text.").with_arguments(vec![
                    Argument::new("text", ArgumentType::String, "What to find."),
                    Argument::new("case", ArgumentType::Bool, "Match case."),
                ]))],
            ),
        ],
    );
    match service {
        "menus.textedit.42" | "menus.textedit.43" => Some(textedit),
        "menus.grab.7" => Some(MenuBarModel::new("Grab", vec![Menu::new("Capture", vec![cmd(Command::new("capture.screen", "Screen", "Capture the screen."))])])),
        "menus.preview.9" => Some(MenuBarModel::new(
            "Preview",
            vec![
                Menu::new("Go", vec![cmd(Command::new("go.page", "Go to Page…", "Show a page.").with_arguments(vec![Argument::new("page", ArgumentType::Integer, "The page.")]))]),
                Menu::new("File", vec![cmd(Command::new("file.export", "Export…", "Write a copy.").with_arguments(vec![Argument::new("path", ArgumentType::Path, "Where.")]).writing())]),
            ],
        )),
        _ => None,
    }
}

impl MenuCaller for Apps {
    fn describe(&self, service: &str) -> Result<Described, Box<dyn Error>> {
        if self.dead.borrow().contains(service) {
            return Err("gone".into());
        }
        let m = model(service).ok_or("gone")?;
        let en = |why: &str| Enablement::Disabled(why.into());
        Ok((m, HashMap::from([("file.open".to_owned(), en("a document is open")), ("go.page".to_owned(), en("no document"))])))
    }

    fn activate(&self, service: &str, verb: &str, arguments: &BTreeMap<String, String>) -> Result<CommandResult, Box<dyn Error>> {
        if self.dead.borrow().contains(service) {
            return Err("gone".into());
        }
        Ok(match verb {
            "file.save" | "file.close" => CommandResult::Ok(None),
            "capture.screen" => CommandResult::Ok(Some("/home/a/Screen.png".into())),
            "file.export" => CommandResult::Ok(Some(format!("wrote {}", arguments.get("path").map_or("nothing", String::as_str)))),
            _ => CommandResult::Refused("not now".into()),
        })
    }
}

fn q(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => out.push_str(&format!("\\u{{{:x}}}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// A command's words, quoted ones (with \n, \" and \\) apart.
fn words(line: &str) -> Vec<String> {
    let mut out = vec![];
    let mut chars = line.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c == ' ' {
            chars.next();
            continue;
        }
        let mut w = String::new();
        if c == '"' {
            chars.next();
            while let Some(c) = chars.next() {
                match c {
                    '"' => break,
                    '\\' => {
                        let e = chars.next().unwrap();
                        w.push(if e == 'n' { '\n' } else { e });
                    }
                    c => w.push(c),
                }
            }
        } else {
            while let Some(&c) = chars.peek().filter(|&&c| c != ' ') {
                w.push(c);
                chars.next();
            }
        }
        out.push(w);
    }
    out
}

fn reply(m: &Msg) -> String {
    let mut out = String::from("reply");
    for (name, v) in m.fields() {
        out += &match v {
            Value::String(s) => format!(" {name}={}", q(s)),
            Value::Bool(b) => format!(" {name}={}", u8::from(*b)),
            Value::UInt64(n) => format!(" {name}={n}"),
            _ => format!(" {name}=?"),
        };
    }
    out + "\n"
}

fn run(script: &str) -> String {
    let mut out = String::new();
    let logged = Rc::new(RefCell::new(String::new()));
    let l = logged.clone();
    let mut b = VocabularyBridge::new(Apps::default(), Box::new(move |kind, fields| *l.borrow_mut() += &format!("log {kind} {}\n", Json::Object(fields).text())));
    for line in script.split('\n').filter(|l| !l.is_empty()) {
        out += &format!("> {line}\n");
        let w = words(line);
        match w[0].as_str() {
            "give" => match b.give(&w[1]) {
                Ok(name) => out += &format!("given {}\n", q(&name)),
                Err(e) => out += &format!("not given: {e}\n"),
            },
            "take" => out += &format!("taken {}\n", u8::from(b.take(&w[1]))),
            "permit" => b.permit(&w[1], w[2] == "yes"),
            "kill" => {
                b.menus().dead.borrow_mut().insert(w[1].clone());
            }
            "request" => {
                let mut m = Msg::new();
                m.set_string("method", &w[1]);
                for (i, k) in ["app", "verb", "arguments"].iter().enumerate() {
                    if let Some(v) = w.get(i + 2) {
                        m.set_string(k, v);
                    }
                }
                out += &reply(&b.handle(&m));
            }
            _ => out += "no command\n",
        }
        out += &logged.borrow();
        logged.borrow_mut().clear();
    }
    out
}

#[test]
fn the_fixtures_are_what_rust_says_and_logs() {
    let mut cases: Vec<String> = fs::read_dir(dir())
        .expect("abyss/tests/wire/vocab: run the Swift test with ABYSS_WIRE_UPDATE=1")
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter_map(|f| f.strip_suffix(".in").map(str::to_owned))
        .collect();
    cases.sort();
    assert!(cases.len() >= 5, "only {} scripts", cases.len());
    let mut wrong = vec![];
    for case in &cases {
        let script = fs::read_to_string(dir().join(format!("{case}.in"))).unwrap();
        let swift = fs::read_to_string(dir().join(format!("{case}.txt"))).unwrap();
        let got = run(&script);
        if got != swift {
            wrong.push(format!("{case}\n--- swift\n{swift}--- rust\n{got}"));
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    eprintln!("{} scripts", cases.len());
}
