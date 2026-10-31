//! The agent's own tools (Tools.swift, PHASE18 P18.8): reading what the
//! jail holds, lldb on one crash, the vocabulary and the fetch bridge.
//!
//! Read-only, and bounded by the jail, not by checks here: inside, the
//! jail's filesystem *is* what the agent may see. Checks here would be a
//! second boundary that could disagree with the first.

use crate::{obj, s, Tool};
use current_ipc::Msg;
use model::Json;
use spawn::{ErrorOutput, Options};
use std::io::{Read, Seek, SeekFrom};
use std::rc::Rc;

pub const READ_LIMIT: usize = 16 << 10;
pub const LIST_LIMIT: usize = 200;

fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}

fn params(props: Vec<(&str, Json)>, required: &[&str]) -> Json {
    let mut p = vec![("type", s("object")), ("properties", obj(props))];
    if !required.is_empty() {
        p.push(("required", Json::Array(required.iter().map(|r| s(r)).collect())));
    }
    obj(p)
}

fn typed(t: &str) -> Json {
    obj(vec![("type", s(t))])
}

fn described(t: &str, d: &str) -> Json {
    obj(vec![("type", s(t)), ("description", s(d))])
}

fn arg<'a>(a: &'a Json, k: &str) -> Option<&'a str> {
    a.get(k).and_then(Json::as_str).filter(|v| !v.is_empty())
}

pub fn reading() -> Vec<Tool> {
    vec![list_directory(), read_file()]
}

pub fn list_directory() -> Tool {
    Tool::new("list_directory", "List the entries of a directory. Directories end in /.", params(vec![("path", typed("string"))], &["path"]), |a| {
        let Some(path) = arg(a, "path") else { return "error: list_directory needs a path".into() };
        let entries = match std::fs::read_dir(path) {
            Ok(d) => d,
            Err(e) => return format!("error: {path}: {}", words(&e)),
        };
        let mut names: Vec<String> = entries
            .filter_map(|e| e.ok())
            .map(|e| {
                let name = e.file_name().to_string_lossy().into_owned();
                let dir = e.file_type().is_ok_and(|t| t.is_dir());
                if dir { format!("{name}/") } else { name }
            })
            .collect();
        names.sort();
        if names.is_empty() {
            return "(empty)".into();
        }
        let more = if names.len() > LIST_LIMIT { format!("\n({} more)", names.len() - LIST_LIMIT) } else { String::new() };
        names.truncate(LIST_LIMIT);
        names.join("\n") + &more
    })
}

pub fn read_file() -> Tool {
    let p = params(vec![("path", typed("string")), ("offset", typed("integer"))], &["path"]);
    Tool::new("read_file", "Read a text file, up to 16 KB from an optional byte offset.", p, |a| {
        let Some(path) = arg(a, "path") else { return "error: read_file needs a path".into() };
        let mut f = match std::fs::File::open(path) {
            Ok(f) => f,
            Err(e) => return format!("error: {path}: {}", words(&e)),
        };
        let offset = a.get("offset").and_then(Json::as_int).unwrap_or(0).max(0) as u64;
        if offset > 0 && f.seek(SeekFrom::Start(offset)).is_err() {
            return format!("error: {path}: cannot seek to {offset}");
        }
        let mut buf = Vec::with_capacity(READ_LIMIT + 1);
        if let Err(e) = f.take(READ_LIMIT as u64 + 1).read_to_end(&mut buf) {
            return format!("error: {path}: {}", words(&e));
        }
        let more = if buf.len() > READ_LIMIT { format!("\n(more from offset {})", offset + READ_LIMIT as u64) } else { String::new() };
        buf.truncate(READ_LIMIT);
        String::from_utf8_lossy(&buf).into_owned() + &more
    })
}

/// The `debug` class's tool (P18.9): lldb on one crash, its core and its
/// binary fixed by the session, so the model chooses the command and never
/// the target. `--batch`: it runs the command and exits; the output is cut
/// at READ_LIMIT.
pub fn lldb(core: &str, binary: &str, lldb: &str) -> Tool {
    let (core, binary, lldb) = (core.to_owned(), binary.to_owned(), lldb.to_owned());
    let d = "Run one lldb command on the crashed program's core, e.g. \"bt\", \"frame select 1\", \"frame variable\", \"register read\", \"image list\".";
    Tool::new("lldb", d, params(vec![("command", typed("string"))], &["command"]), move |a| {
        let Some(command) = arg(a, "command") else { return "error: lldb needs a command".into() };
        let r = spawn::run_with(
            &[&lldb, "--batch", "--no-lldbinit", "-c", &core, &binary, "-o", command],
            Options { stderr: ErrorOutput::Merge, limit: READ_LIMIT + 1, ..Options::default() },
        );
        if let Some(why) = &r.failure {
            return format!("error: lldb could not run: {why}");
        }
        let out = if r.stdout.len() > READ_LIMIT { String::from_utf8_lossy(&r.stdout[..READ_LIMIT]).into_owned() + "\n(cut)" } else { r.stdout_text() };
        if r.succeeded() { out } else { format!("lldb exited {}:\n{out}", r.code()) }
    })
}

/// What a tool asks the person, through the window (P18.11, P18.12b).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuestionKind {
    Write,
    Host,
}

impl QuestionKind {
    pub fn as_str(self) -> &'static str {
        match self {
            QuestionKind::Write => "write",
            QuestionKind::Host => "host",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PersonQuestion {
    pub kind: QuestionKind,
    pub app: String,
    pub verb: String,
    pub title: String,
    pub host: String,
    pub url: String,
}

pub type AskPerson = Rc<dyn Fn(&PersonQuestion) -> bool>;

/// One request to a bridge's socket.
fn call(socket: &str, m: &Msg) -> Result<Msg, String> {
    let fd = current_ipc::connect_path(socket).map_err(|e| e.to_string())?;
    current_ipc::send(m, &fd).map_err(|e| e.to_string())?;
    current_ipc::receive(&fd).map_err(|e| e.to_string())
}

fn request(method: &str, kv: &[(&str, &str)]) -> Msg {
    let mut m = Msg::new();
    m.set_string("method", method);
    for (k, v) in kv {
        m.set_string(k, v);
    }
    m
}

/// The vocabulary (P18.10): the applications this session was given,
/// through the bridge at `socket`. What the agent may drive is the
/// bridge's to say, not these tools'. `ask_person` (requester 1): a verb
/// that writes is not run until the person is asked; if they allowed it,
/// the call is made once more, and whether it may write is still the
/// bridge's call.
pub fn vocabulary(socket: &str, ask_person: AskPerson) -> Vec<Tool> {
    let say = |r: Result<Msg, String>| match r {
        Err(e) => format!("error: the vocabulary bridge did not answer: {e}"),
        Ok(r) if r.bool("ok") != Some(true) => format!("error: {}", r.string("error").unwrap_or("refused")),
        Ok(r) => r.string("text").or(r.string("apps")).unwrap_or("ok").to_owned(),
    };
    let app_param = described("string", "The application's name, as apps lists it.");
    let (s1, s2, s3) = (socket.to_owned(), socket.to_owned(), socket.to_owned());
    let activate_params = params(
        vec![
            ("app", app_param.clone()),
            ("verb", described("string", "e.g. file.save")),
            ("arguments", described("object", "The verb's arguments, if it has any.")),
        ],
        &["app", "verb"],
    );
    vec![
        Tool::new("apps", "List the applications you were given to drive.", params(vec![], &[]), move |_| {
            let out = say(call(&s1, &request("apps", &[])));
            if out.is_empty() { "(none: the person has given you no application)".into() } else { out }
        }),
        Tool::new(
            "describe_app",
            "An application's commands (its menus): each verb, what it does, its arguments, and whether it can run now.",
            params(vec![("app", app_param)], &["app"]),
            move |a| say(call(&s2, &request("describe", &[("app", a.get("app").and_then(Json::as_str).unwrap_or(""))]))),
        ),
        Tool::new("activate", "Run one of an application's commands by its verb, as choosing it from the menu would.", activate_params, move |a| {
            let field = |k: &str| a.get(k).and_then(Json::as_str).unwrap_or("").to_owned();
            let mut m = request("activate", &[("app", &field("app")), ("verb", &field("verb"))]);
            if let Some(Json::Object(kv)) = a.get("arguments") {
                let lines: Vec<String> = kv.iter().map(|(k, v)| format!("{k}={}", v.as_str().map_or_else(|| v.text(), str::to_owned))).collect();
                m.set_string("arguments", &lines.join("\n"));
            }
            let first = call(&s3, &m);
            let Ok(r) = &first else { return say(first) };
            if r.bool("permission") != Some(true) {
                return say(first);
            }
            let (app, title) = (r.string("app").unwrap_or("").to_owned(), r.string("title").unwrap_or("").to_owned());
            let q = PersonQuestion { kind: QuestionKind::Write, app: app.clone(), verb: r.string("verb").unwrap_or("").into(), title: title.clone(), host: String::new(), url: String::new() };
            if !ask_person(&q) {
                return format!("refused: the person did not allow {app} to write for you ({title})");
            }
            say(call(&s3, &m))
        }),
    ]
}

/// The fetch tool (P18.12b): a URL through the fetch bridge, the agent's
/// only way to the network. A host the person has not allowed is asked
/// about first, as a write is (requester 3).
pub fn fetch(socket: &str, ask_person: AskPerson) -> Tool {
    let socket = socket.to_owned();
    let say = |r: Result<Msg, String>| match r {
        Err(e) => format!("error: the fetch bridge did not answer: {e}"),
        Ok(r) if r.bool("ok") != Some(true) => format!("error: {}", r.string("error").unwrap_or("refused")),
        Ok(r) => format!("{} (status {}):\n{}", r.string("url").unwrap_or(""), r.u64("status").unwrap_or(0), r.string("text").unwrap_or("")),
    };
    let p = params(vec![("url", described("string", "e.g. https://example.org/page"))], &["url"]);
    Tool::new("fetch", "Fetch a web page (http or https) and read its text. The person is asked before each new host.", p, move |a| {
        let url = a.get("url").and_then(Json::as_str).unwrap_or("").to_owned();
        let m = request("fetch", &[("url", &url)]);
        let first = call(&socket, &m);
        let Ok(r) = &first else { return say(first) };
        if r.bool("permission") != Some(true) {
            return say(first);
        }
        let host = r.string("host").unwrap_or("").to_owned();
        let q = PersonQuestion { kind: QuestionKind::Host, app: String::new(), verb: String::new(), title: String::new(), host: host.clone(), url: r.string("url").unwrap_or(&url).into() };
        if !ask_person(&q) {
            return format!("refused: the person did not allow you to reach {host}");
        }
        say(call(&socket, &m))
    })
}
