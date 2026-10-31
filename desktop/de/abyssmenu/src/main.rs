//! abyssmenu: ask an application what it can do, and have it do it
//! (PHASE10.md P10.2), ported from main.swift beside it.
//!
//!     abyssmenu list                              # applications publishing menus
//!     abyssmenu describe finder                   # the vocabulary: verbs, keys, arguments
//!     abyssmenu validate finder                   # what can run now, and why not
//!     abyssmenu run finder file.new-folder        # invoke one verb; prints its result
//!     abyssmenu run finder go.to-folder path=/tmp # ... with typed arguments
//!
//! The first consumer of an application's vocabulary is deliberately this
//! one, which cannot draw a menu: if a verb is only usable from the menu
//! bar, the surface is a drawing routine and not a vocabulary (PLAN.md,
//! Phase 10). Phase 18's agent reads the same thing.
//!
//! Output is line-oriented for a script. `run` exits 0 on `ok`, 1 on
//! `refused` (the reason on stderr), 2 when the application could not be
//! reached.

use menu_model::{CommandResult, Enablement, Menu, MenuItem};
use menu_wire::client;
use std::collections::{BTreeMap, HashMap};
use std::process::exit;

const USAGE: &str = "usage: abyssmenu list\n       abyssmenu describe APP\n       abyssmenu validate APP\n       abyssmenu run APP VERB [NAME=VALUE ...]";

fn fail(why: impl std::fmt::Display, code: i32) -> ! {
    eprintln!("abyssmenu: {why}");
    exit(code)
}

fn usage() -> ! {
    eprintln!("{USAGE}");
    exit(2)
}

fn state(e: Option<&Enablement>) -> String {
    match e {
        Some(Enablement::Enabled) => "enabled".into(),
        Some(Enablement::Disabled(why)) => format!("disabled ({why})"),
        None => "unknown".into(),
    }
}

fn show(menu: &Menu, depth: usize, enablement: &HashMap<String, Enablement>) {
    let pad = "  ".repeat(depth);
    println!("{pad}menu {}", menu.title);
    for item in &menu.items {
        match item {
            MenuItem::Separator => {}
            MenuItem::Submenu(m) => show(m, depth + 1, enablement),
            MenuItem::Command(c) => {
                let key = c.key.as_ref().map_or(String::new(), |k| format!("\t{}", k.display()));
                println!("{pad}  {}\t{}{key}\t{}", c.verb, c.title, state(enablement.get(&c.verb)));
                println!("{pad}    {}", c.summary);
                for a in &c.arguments {
                    println!("{pad}    arg {}: {} — {}", a.name, a.ty.as_str(), a.summary);
                }
            }
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let service = |i: usize| match args.get(i) {
        None => usage(),
        Some(name) => client::resolve(name).unwrap_or_else(|e| fail(e, 2)),
    };
    match args.first().map(String::as_str) {
        Some("list") => {
            for s in client::services() {
                let app = client::describe(&s, None).map_or_else(|_| "?".to_owned(), |d| d.0.app_name);
                println!("{app}\t{s}");
            }
        }
        Some("describe") => {
            let s = service(1);
            let (model, enablement) = client::describe(&s, None).unwrap_or_else(|e| fail(format!("{s}: {e}"), 2));
            println!("app {}", model.app_name);
            for m in &model.menus {
                show(m, 0, &enablement);
            }
        }
        Some("validate") => {
            let s = service(1);
            let v = client::validate(&s, None).unwrap_or_else(|e| fail(format!("{s}: {e}"), 2));
            let mut verbs: Vec<&String> = v.keys().collect();
            verbs.sort();
            for verb in verbs {
                println!("{verb}\t{}", state(v.get(verb)));
            }
        }
        Some("run") => {
            let s = service(1);
            let Some(verb) = args.get(2) else { usage() };
            let mut arguments = BTreeMap::new();
            for a in &args[3..] {
                let Some((k, v)) = a.split_once('=') else { fail(format!("argument {a} is not NAME=VALUE"), 2) };
                arguments.insert(k.to_owned(), v.to_owned());
            }
            match client::activate(&s, verb, &arguments, None).unwrap_or_else(|e| fail(format!("{s}: {e}"), 2)) {
                CommandResult::Ok(Some(value)) => println!("ok {value}"),
                CommandResult::Ok(None) => println!("ok"),
                CommandResult::Refused(why) => {
                    println!("refused");
                    fail(why, 1)
                }
            }
        }
        Some("-h" | "--help") => println!("{USAGE}"),
        _ => usage(),
    }
}
