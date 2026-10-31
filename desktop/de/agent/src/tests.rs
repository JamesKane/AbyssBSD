//! The loop's bounds, and its tools (Tests/ModelTests/AgentTests.swift).

use crate::tools::{self, READ_LIMIT};
use crate::{obj, s, AgentLoop, Answer, ModelCall, Stop, Tool};
use model::session::{ModelSession, StubBackend};
use model::{Json, Request};
use std::cell::RefCell;
use std::os::unix::fs::PermissionsExt;
use std::rc::Rc;

fn completion(content: Option<&str>, calls: &[(&str, &str)], tokens: i64) -> Json {
    let mut msg = vec![("role", s("assistant")), ("content", content.map_or(Json::Null, s))];
    if !calls.is_empty() {
        let list = calls
            .iter()
            .enumerate()
            .map(|(i, (name, args))| obj(vec![("id", s(&format!("c{i}"))), ("type", s("function")), ("function", obj(vec![("name", s(name)), ("arguments", s(args))]))]))
            .collect();
        msg.push(("tool_calls", Json::Array(list)));
    }
    obj(vec![
        ("choices", Json::Array(vec![obj(vec![("index", Json::Number(0.0)), ("message", obj(msg))])])),
        ("usage", obj(vec![("total_tokens", Json::Number(tokens as f64))])),
    ])
}

fn says(text: &str) -> Json {
    completion(Some(text), &[], 50)
}

fn calls(calls: &[(&str, &str)]) -> Json {
    completion(None, calls, 50)
}

fn echo() -> Tool {
    Tool::new("echo", "say it back", obj(vec![("type", s("object"))]), |a| format!("echoed {}", a.get("say").and_then(Json::as_str).unwrap_or("")))
}

/// A model that plays `replies` in order and records what it was asked.
fn script(replies: Vec<(u16, Json)>) -> (ModelCall, Rc<RefCell<Vec<Json>>>) {
    let asked = Rc::new(RefCell::new(vec![]));
    let a = asked.clone();
    let mut replies = std::collections::VecDeque::from(replies);
    (
        Box::new(move |req: &Json| {
            a.borrow_mut().push(req.clone());
            replies.pop_front().ok_or_else(|| "the script ran out".to_owned())
        }),
        asked,
    )
}

fn messages(j: &Json) -> Vec<Json> {
    j.get("messages").and_then(Json::as_array).unwrap_or(&[]).to_vec()
}

fn roles(m: &[Json]) -> Vec<String> {
    m.iter().map(|x| x.get("role").and_then(Json::as_str).unwrap_or("?").to_owned()).collect()
}

#[test]
fn a_tool_call_is_run_and_its_result_answers_the_call() {
    let (model, asked) = script(vec![(200, calls(&[("echo", r#"{"say":"hi"}"#)])), (200, says("done"))]);
    let a = AgentLoop::new("sys", vec![echo()], model).ask("go");
    assert_eq!(a, Answer { text: "done".into(), stop: Stop::Answered, calls: vec![r#"echo({"say":"hi"})"#.into()], steps: 2 });
    let second = messages(&asked.borrow()[1]);
    assert_eq!(roles(&second), ["system", "user", "assistant", "tool"]);
    let id = second[2].get("tool_calls").and_then(|t| t.at(0)).and_then(|c| c.get("id")).and_then(Json::as_str);
    assert_eq!(id, Some("c0"), "the assistant's calls go back as they came");
    assert_eq!(second[3].get("tool_call_id").and_then(Json::as_str), Some("c0"), "the result answers that call");
    assert_eq!(second[3].get("content").and_then(Json::as_str), Some("echoed hi"));
}

/// The person sees each call as it starts: in order, before the answer.
#[test]
fn each_call_is_told_as_it_starts() {
    let (model, asked) = script(vec![(200, calls(&[("echo", r#"{"say":"a"}"#), ("echo", r#"{"say":"b"}"#)])), (200, says("done"))]);
    let told = Rc::new(RefCell::new(vec![]));
    let mut l = AgentLoop::new("sys", vec![echo()], model);
    let (t, a2) = (told.clone(), asked.clone());
    l.on_call = Box::new(move |c| t.borrow_mut().push((c.to_owned(), a2.borrow().len())));
    let a = l.ask("go");
    let told = told.borrow();
    assert_eq!(told.iter().map(|x| x.0.as_str()).collect::<Vec<_>>(), [r#"echo({"say":"a"})"#, r#"echo({"say":"b"})"#]);
    assert_eq!(told.iter().map(|x| x.0.clone()).collect::<Vec<_>>(), a.calls);
    assert_eq!(told.iter().map(|x| x.1).collect::<Vec<_>>(), [1, 1], "told before the model was asked again");
}

#[test]
fn the_request_offers_the_tools_with_thinking_off() {
    let (model, asked) = script(vec![(200, says("ok"))]);
    AgentLoop::new("sys", vec![echo()], model).ask("q");
    let r = &asked.borrow()[0];
    let name = r.get("tools").and_then(|t| t.at(0)).and_then(|t| t.get("function")).and_then(|f| f.get("name")).and_then(Json::as_str);
    assert_eq!(name, Some("echo"));
    assert_eq!(r.get("chat_template_kwargs").and_then(|k| k.get("enable_thinking")).and_then(Json::as_bool), Some(false));
    assert_eq!(r.get("stream"), None, "abyss-model refuses streaming");
}

fn budget_refusal(message: &str) -> Json {
    obj(vec![("error", obj(vec![("type", s("budget")), ("message", s(message))]))])
}

/// The budget ends the question with abyss-model's own words, and the loop
/// does not try again.
#[test]
fn a_budget_refusal_ends_the_question() {
    let why = "the session's budget of 500 tokens is spent (600 used)";
    let (model, asked) = script(vec![(200, calls(&[("echo", "{}")])), (429, budget_refusal(why)), (200, says("never"))]);
    let a = AgentLoop::new("sys", vec![echo()], model).ask("go");
    assert_eq!((a.stop, a.text.as_str()), (Stop::Budget, why));
    assert_eq!(asked.borrow().len(), 2, "no call after the refusal");
}

#[test]
fn the_step_limit_stops_a_model_that_never_answers() {
    let (model, asked) = script(vec![(200, calls(&[("echo", "{}")])); 10]);
    let mut l = AgentLoop::new("sys", vec![echo()], model);
    l.max_steps = 3;
    let a = l.ask("go");
    assert_eq!((a.stop, a.steps, a.text.as_str()), (Stop::Steps, 3, "stopped after 3 steps without an answer"));
    assert_eq!(asked.borrow().len(), 3);
}

#[test]
fn a_bad_call_is_the_models_to_see_not_a_crash() {
    let (model, asked) = script(vec![(200, calls(&[("rm_rf", "{}"), ("echo", "not json")])), (200, says("sorry"))]);
    assert_eq!(AgentLoop::new("sys", vec![echo()], model).ask("go").stop, Stop::Answered);
    let results: Vec<String> = messages(&asked.borrow()[1])
        .iter()
        .filter(|m| m.get("role").and_then(Json::as_str) == Some("tool"))
        .map(|m| m.get("content").and_then(Json::as_str).unwrap_or("").to_owned())
        .collect();
    assert_eq!(results, ["error: there is no tool named rm_rf", "error: the arguments are not JSON: not json"]);
}

#[test]
fn an_unreachable_model_or_an_odd_reply_fails() {
    assert_eq!(AgentLoop::new("s", vec![], script(vec![]).0).ask("q").stop, Stop::Failed);
    assert_eq!(AgentLoop::new("s", vec![], script(vec![(200, obj(vec![]))]).0).ask("q").stop, Stop::Failed);
    assert_eq!(AgentLoop::new("s", vec![], script(vec![(502, Json::Null)]).0).ask("q").text, "abyss-model said 502");
}

/// After the budget stopped a question and the person allowed more, the
/// loop carries on from where it was: the question is not asked again.
#[test]
fn resume_carries_on_without_asking_again() {
    let (model, asked) = script(vec![(200, calls(&[("echo", "{}")])), (429, budget_refusal("spent")), (200, says("done"))]);
    let mut l = AgentLoop::new("sys", vec![echo()], model);
    assert_eq!(l.ask("go").stop, Stop::Budget);
    let a = l.resume();
    assert_eq!((a.stop, a.text.as_str()), (Stop::Answered, "done"));
    let last = messages(asked.borrow().last().unwrap());
    assert_eq!(roles(&last), ["system", "user", "assistant", "tool"], "one question, its call and result: no second user turn");
}

#[test]
fn the_conversation_persists_across_questions() {
    let (model, asked) = script(vec![(200, says("one")), (200, says("two"))]);
    let mut l = AgentLoop::new("sys", vec![], model);
    l.ask("first");
    l.ask("second");
    let contents: Vec<String> = messages(&asked.borrow()[1]).iter().filter_map(|m| m.get("content").and_then(Json::as_str).map(str::to_owned)).collect();
    assert_eq!(contents, ["sys", "first", "one", "second"]);
}

/// End to end through abyss-model's session, budget and all.
#[test]
fn the_loop_against_a_model_session() {
    let stub = StubBackend::new(vec![completion(None, &[("echo", "{}")], 60), completion(Some("done"), &[], 60)]);
    let session = Rc::new(RefCell::new(ModelSession::new("a", 100, stub, std::fs::OpenOptions::new().write(true).open("/dev/null").unwrap())));
    let model: ModelCall = Box::new(move |req: &Json| {
        let r = session.borrow_mut().handle(&Request { method: "POST".into(), path: "/v1/chat/completions".into(), headers: vec![], body: req.text().into_bytes() });
        Ok((r.status, Json::parse(&r.body).map_err(|e| e.to_string())?))
    });
    let mut l = AgentLoop::new("sys", vec![echo()], model);
    assert_eq!(l.ask("go").stop, Stop::Answered, "60 + 60: the second reply crosses 100 and is delivered");
    let a = l.ask("again");
    assert_eq!((a.stop, a.text.as_str()), (Stop::Budget, "the session's budget of 100 tokens is spent (120 used)"), "and the next call is refused");
}

// MARK: tools

fn scratch(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("abyss-agent-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn run(t: &Tool, args: Json) -> String {
    (t.run)(&args)
}

/// lldb on one crash: the model picks the command, never the target.
#[test]
fn the_lldb_tools_target_is_fixed() {
    let dir = scratch("lldb");
    let fake = dir.join("lldb");
    std::fs::write(&fake, "#!/bin/sh\nfor a in \"$@\"; do printf '[%s]' \"$a\"; done\n").unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let t = tools::lldb("/run/granted/1/crasher.core", "/run/granted/2/crasher", &fake.to_string_lossy());
    let fixed = "[--batch][--no-lldbinit][-c][/run/granted/1/crasher.core][/run/granted/2/crasher][-o]";
    assert_eq!(run(&t, obj(vec![("command", s("bt"))])), format!("{fixed}[bt]"));
    assert_eq!(run(&t, obj(vec![("command", s("bt; -c /etc/other.core"))])), format!("{fixed}[bt; -c /etc/other.core]"), "the command is one argument: it cannot name another core");
    assert_eq!(
        run(&t, obj(vec![("command", s("bt")), ("core", s("/etc/other.core")), ("binary", s("/bin/sh"))])),
        format!("{fixed}[bt]"),
        "a model that names another core or binary is not heard"
    );
    assert_eq!(run(&t, obj(vec![])), "error: lldb needs a command");
    let none = tools::lldb("c", "b", &dir.join("none").to_string_lossy());
    assert!(run(&none, obj(vec![("command", s("bt"))])).starts_with("error:"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_reading_tools() {
    let dir = scratch("read");
    std::fs::create_dir(dir.join("sub")).unwrap();
    std::fs::write(dir.join("a.txt"), "hello\n").unwrap();
    std::fs::write(dir.join("big.txt"), "x".repeat(READ_LIMIT + 10)).unwrap();
    let d = dir.to_string_lossy().into_owned();
    let (list, read) = (tools::list_directory(), tools::read_file());
    assert_eq!(run(&list, obj(vec![("path", s(&d))])), "a.txt\nbig.txt\nsub/");
    assert_eq!(run(&read, obj(vec![("path", s(&format!("{d}/a.txt")))])), "hello\n");
    let big = run(&read, obj(vec![("path", s(&format!("{d}/big.txt")))]));
    assert!(big.ends_with(&format!("\n(more from offset {READ_LIMIT})")), "a long file is cut, and says where it goes on");
    assert_eq!(run(&read, obj(vec![("path", s(&format!("{d}/big.txt"))), ("offset", Json::Number(READ_LIMIT as f64))])), "x".repeat(10));
    assert_eq!(run(&read, obj(vec![("path", s(&format!("{d}/none")))])), format!("error: {d}/none: No such file or directory"));
    assert_eq!(run(&list, obj(vec![])), "error: list_directory needs a path");
    let _ = std::fs::remove_dir_all(&dir);
}
