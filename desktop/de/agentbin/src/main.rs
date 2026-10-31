//! abyss-agent: an agent session, inside its jail (PHASE18 P18.8), ported
//! from main.swift beside it.
//!
//!   abyss-agent serve --model SOCKET --listen SOCKET [--class CLASS]
//!                     [--core CORE --binary BINARY --crash WHAT] [--vocab SOCKET]
//!                     [--fetch SOCKET]
//!       the loop, answering questions on the socket at --listen (inside the
//!       jail's runtime directory). Its only way to a model is abyss-model
//!       at --model, and its tools read only what the jail holds. `bye` ends
//!       the session. With --core and --binary (a `debug` session, P18.9) it
//!       also has lldb on that core; with --vocab (P18.10) it can drive the
//!       applications it was given; with --fetch (P18.12b), read web pages.
//!   abyss-agent ask --listen SOCKET TEXT...
//!       ask the agent at SOCKET: one `call=` line per tool as it is called,
//!       then its answer, then `stop=` and `steps=`. Exits 0 when it
//!       answered, 3 when the budget stopped it, 4 when the step limit did,
//!       1 otherwise.
//!   abyss-agent continue --listen SOCKET
//!       carry on from where the last question stopped; prints as ask does.
//!   abyss-agent tool NAME JSON [--vocab SOCKET] [--fetch SOCKET]
//!       run one tool, as the agent would, with no model: what an agent in
//!       this jail can reach, asked directly (the gate, P18.14). A question
//!       for the person is answered no.
//!   abyss-agent bye --listen SOCKET

use agent::tools::{self, AskPerson};
use agent::{model_over_socket, AgentLoop, PersonQuestion};
use current_ipc::{Msg, Server};
use jails::JailLayout;
use model::Json;
use std::cell::RefCell;
use std::os::unix::net::UnixStream;
use std::process::exit;
use std::rc::Rc;

fn die(why: impl std::fmt::Display) -> ! {
    eprintln!("abyss-agent: {why}");
    exit(1)
}

/// The connection of the question being answered: where a requester goes.
type Asking = Rc<RefCell<Option<UnixStream>>>;

/// Ask the window on the question's own connection, and wait for its
/// answer there (P18.11, P18.12b). The window tells the bridge first; this
/// only says whether to try again.
fn ask_the_person(asking: Asking) -> AskPerson {
    Rc::new(move |q: &PersonQuestion| {
        let a = asking.borrow();
        let Some(c) = a.as_ref() else { return false };
        let mut e = Msg::new();
        e.set_string("event", "permission");
        e.set_string("kind", q.kind.as_str());
        for (k, v) in [("app", &q.app), ("verb", &q.verb), ("title", &q.title), ("host", &q.host), ("url", &q.url)] {
            e.set_string(k, v);
        }
        if current_ipc::send(&e, c).is_err() {
            return false;
        }
        // **A person takes as long as they take** (HANDOFF §2.131).
        let _ = c.set_read_timeout(None);
        current_ipc::receive(c).is_ok_and(|r| r.string("method") == Some("answer") && r.bool("allow") == Some(true))
    })
}

fn serve(listen: &str, opt: &dyn Fn(&str) -> Option<String>) -> ! {
    let Some(model_socket) = opt("--model") else { die("serve needs --model SOCKET") };
    let cls = opt("--class").unwrap_or_else(|| "agent".into());
    let mut server = Server::bind(listen, 0o600).unwrap_or_else(|e| die(format!("cannot listen at {listen}: {e}")));
    // Where its home is, said outright: told only "your own home", Granite
    // tried /home/agent, /abyss and / before /home/abyss.
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home".into());
    let mut system = format!(
        "You are an agent on the AbyssBSD desktop, working for the person who asked. You run confined, in a jail of class {cls}: you see the system read-only, your own home ({home}), and only the files the person granted you (under {}). Use the tools to look before you answer. Answer plainly and briefly.",
        JailLayout::GRANTED
    );
    let asking: Asking = Rc::new(RefCell::new(None));
    let mut tools = tools::reading();
    // A debug session (P18.9): one crash, its core and binary granted in.
    if let (Some(core), Some(binary)) = (opt("--core"), opt("--binary")) {
        tools.push(tools::lldb(&core, &binary, "/usr/bin/lldb"));
        let crash = opt("--crash").unwrap_or_else(|| "it was killed by a signal".into());
        system += &format!(
            " A program crashed: {crash}. Its core is {core} and its binary {binary}; the lldb tool runs one command on them. Find where and why it crashed — start with \"bt\" — and say so in a short report: the signal, the frame that faulted with its file and line if known, and the likely cause."
        );
    }
    if let Some(vocab) = opt("--vocab") {
        tools.extend(tools::vocabulary(&vocab, ask_the_person(asking.clone())));
        system += " You can drive the applications the person gave you, by their menus: list them with apps, read one's commands with describe_app, and run a command with activate. Use only verbs describe_app lists, and say what you did.";
    }
    if let Some(fetch) = opt("--fetch") {
        tools.push(tools::fetch(&fetch, ask_the_person(asking.clone())));
        system += " You can read web pages with fetch; the person is asked before each new host, and may say no.";
    }
    let mut l = AgentLoop::new(&system, tools, model_over_socket(&model_socket));
    println!("ready (class {cls}, model at {model_socket})");
    loop {
        let Ok(c) = server.accept() else { continue };
        let Ok(req) = current_ipc::receive(&c) else { continue };
        let mut reply = Msg::new();
        match req.string("method").unwrap_or("") {
            method @ ("ask" | "continue") => {
                // Each tool call as it starts, as an event on the same
                // connection before the reply.
                let events = c.try_clone().ok();
                l.on_call = Box::new(move |call| {
                    if let Some(e) = &events {
                        let mut m = Msg::new();
                        m.set_string("event", "call");
                        m.set_string("call", call);
                        let _ = current_ipc::send(&m, e);
                    }
                });
                *asking.borrow_mut() = c.try_clone().ok();
                // `continue` (P18.11): on, from where the budget stopped it.
                let a = if method == "continue" { l.resume() } else { l.ask(req.string("text").unwrap_or("")) };
                l.on_call = Box::new(|_| {});
                *asking.borrow_mut() = None;
                reply.set_bool("ok", true);
                reply.set_string("text", &a.text);
                reply.set_string("stop", a.stop.as_str());
                reply.set_u64("steps", a.steps as u64);
                reply.set_bytes("calls", a.calls.join("\n").as_bytes());
                println!("asked: {} after {} step(s), {} tool call(s)", a.stop.as_str(), a.steps, a.calls.len());
            }
            "bye" => {
                reply.set_bool("ok", true);
                let _ = current_ipc::send(&reply, &c);
                server.shutdown_and_unlink();
                println!("bye");
                exit(0)
            }
            _ => {
                reply.set_bool("ok", false);
                reply.set_string("error", "unknown method");
            }
        }
        let _ = current_ipc::send(&reply, &c);
    }
}

/// `ask`, `continue` or `bye`, as a client.
fn client(verb: &str, listen: &str, args: &[String]) -> ! {
    let mut m = Msg::new();
    m.set_string("method", verb);
    if verb == "ask" {
        // Everything after the options is the question.
        let mut words = vec![];
        let mut it = args.iter().skip(1);
        while let Some(a) = it.next() {
            if a == "--listen" {
                it.next();
            } else {
                words.push(a.as_str());
            }
        }
        m.set_string("text", &words.join(" "));
    }
    let r = (|| -> Result<Msg, String> {
        let fd = current_ipc::connect_path(listen).map_err(|e| e.to_string())?;
        // The agent takes as long as its model does.
        let _ = fd.set_read_timeout(None);
        current_ipc::send(&m, &fd).map_err(|e| e.to_string())?;
        // Events first (a tool call as it starts), then the reply. A
        // requester has no person here to ask: it is said, and answered
        // no; a script is not the person.
        loop {
            let r = current_ipc::receive(&fd).map_err(|e| e.to_string())?;
            match r.string("event") {
                Some("permission") => {
                    if r.string("kind") == Some("host") {
                        println!("permission=host {}", r.string("host").unwrap_or(""));
                    } else {
                        println!("permission={} {}", r.string("app").unwrap_or(""), r.string("verb").unwrap_or(""));
                    }
                    let mut no = Msg::new();
                    no.set_string("method", "answer");
                    no.set_bool("allow", false);
                    current_ipc::send(&no, &fd).map_err(|e| e.to_string())?;
                }
                Some("call") => println!("call={}", r.string("call").unwrap_or("")),
                _ => return Ok(r),
            }
        }
    })()
    .unwrap_or_else(|e| die(format!("no agent at {listen}: {e}")));
    if r.bool("ok") != Some(true) {
        die(r.string("error").unwrap_or("refused"))
    }
    if verb == "bye" {
        println!("bye");
        exit(0)
    }
    println!("{}", r.string("text").unwrap_or(""));
    let stop = r.string("stop").unwrap_or("failed");
    println!("stop={stop}");
    println!("steps={}", r.u64("steps").unwrap_or(0));
    exit(match stop {
        "answered" => 0,
        "budget" => 3,
        "steps" => 4,
        _ => 1,
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let opt = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    // One tool, no model (P18.14): the same tools, run once.
    if args.first().map(String::as_str) == Some("tool") {
        let input = args.get(2).and_then(|a| Json::parse(a.as_bytes()).ok());
        let Some(input) = input else { die("usage: abyss-agent tool NAME JSON [--vocab SOCKET] [--fetch SOCKET]") };
        let no: AskPerson = Rc::new(|_| false);
        let mut tools = tools::reading();
        if let Some(v) = opt("--vocab") {
            tools.extend(tools::vocabulary(&v, no.clone()));
        }
        if let Some(f) = opt("--fetch") {
            tools.push(tools::fetch(&f, no));
        }
        let Some(tool) = tools.iter().find(|t| t.name == args[1]) else {
            let names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
            die(format!("no tool {}; this agent has: {}", args[1], names.join(" ")))
        };
        println!("{}", (tool.run)(&input));
        exit(0)
    }
    let Some(listen) = opt("--listen") else {
        eprintln!("usage: abyss-agent serve --model SOCKET --listen SOCKET [--class C] | ask --listen SOCKET TEXT... | bye --listen SOCKET");
        exit(2)
    };
    match args.first().map(String::as_str) {
        Some("serve") => serve(&listen, &opt),
        Some(v @ ("ask" | "bye" | "continue")) => client(v, &listen, &args),
        other => die(format!("unknown command {}", other.unwrap_or(""))),
    }
}
