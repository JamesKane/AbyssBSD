//! Model's tests (Tests/ModelTests): the wire's HTTP, the session's budget
//! and transcript, the tier a machine gets, reading a transcript back, and
//! URLs as the fetch bridge takes them. JSON's are R2's, in tests/.

use crate::http::{self, Request, Response, WebUrl};
use crate::json::Json;
use crate::session::{self, HttpBackend, ModelSession, StubBackend, Tier};
use crate::transcript;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

fn s(x: &str) -> Json {
    Json::String(x.into())
}

fn obj(kv: Vec<(&str, Json)>) -> Json {
    Json::Object(kv.into_iter().map(|(k, v)| (k.to_owned(), v)).collect())
}

// MARK: HTTP

#[test]
fn a_request_is_read_when_all_of_it_has_arrived() {
    let body = r#"{"messages":[]}"#;
    let raw = format!("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n\r\n{body}", body.len()).into_bytes();
    assert_eq!(http::request(&raw[..20]).unwrap(), None, "a head not yet complete");
    assert_eq!(http::request(&raw[..raw.len() - 3]).unwrap(), None, "a body not yet complete");
    let r = http::request(&raw).unwrap().unwrap();
    assert_eq!((r.method.as_str(), r.path.as_str()), ("POST", "/v1/chat/completions"));
    assert_eq!(r.header("content-length"), Some(body.len().to_string().as_str()));
    assert_eq!(r.body, body.as_bytes());
}

#[test]
fn requests_it_will_not_take() {
    assert!(http::request(b"GARBAGE\r\n\r\n").is_err());
    assert!(http::request(b"POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n").is_err());
    assert!(http::request(b"POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n").is_err());
    assert!(http::request(b"POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n").is_err(), "a negative length is no length");
}

#[test]
fn a_response_round_trips() {
    let r = Response::json(429, "Too Many Requests", &obj(vec![("e", Json::Number(1.0))]));
    let back = http::response(&r.bytes()).unwrap();
    assert_eq!(back.status, 429);
    assert_eq!(back.body, br#"{"e":1}"#);
}

#[test]
fn a_backend_url() {
    assert_eq!(HttpBackend::url("http://127.0.0.1:8080").unwrap().name, "http://127.0.0.1:8080/v1/chat/completions");
    assert_eq!(HttpBackend::url("http://h:9/x/y").unwrap().name, "http://h:9/x/y");
    assert!(HttpBackend::url("https://api.example.com").is_none(), "remote providers are a later pass");
    assert!(HttpBackend::url("http://nohost").is_none());
}

/// End to end over a real unix socket: a client call, a server reading the
/// request and answering it.
#[test]
fn a_call_over_a_unix_socket() {
    let dir = std::env::temp_dir().join(format!("abyss-http-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("s.sock").to_string_lossy().into_owned();
    let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
    let server = std::thread::spawn(move || {
        let (mut c, _) = listener.accept().unwrap();
        let req = http::read_request(&mut c).unwrap().unwrap();
        http::send(&Response::json(200, "OK", &obj(vec![("echo", s(&req.path))])), &mut c).unwrap();
    });
    let r = http::call(&http::Endpoint::Unix(path), &http::Call::new("GET", "/health")).unwrap();
    server.join().unwrap();
    assert_eq!(r.status, 200);
    assert_eq!(Json::parse(&r.body).unwrap().get("echo").and_then(Json::as_str), Some("/health"));
    let _ = std::fs::remove_dir_all(&dir);
}

// MARK: the session

fn reply(text: &str, tokens: i64, tool: Option<&str>) -> Json {
    let mut msg = vec![("role", s("assistant")), ("content", s(text))];
    if let Some(t) = tool {
        let f = obj(vec![("name", s(t)), ("arguments", s("{}"))]);
        msg.push(("tool_calls", Json::Array(vec![obj(vec![("id", s("c1")), ("type", s("function")), ("function", f)])])));
    }
    let usage = obj(vec![
        ("prompt_tokens", Json::Number((tokens - 10) as f64)),
        ("completion_tokens", Json::Number(10.0)),
        ("total_tokens", Json::Number(tokens as f64)),
    ]);
    obj(vec![
        ("id", s("r")),
        ("object", s("chat.completion")),
        ("choices", Json::Array(vec![obj(vec![("index", Json::Number(0.0)), ("message", obj(msg))])])),
        ("usage", usage),
    ])
}

fn post<B: session::Backend>(m: &mut ModelSession<B>, body: &str) -> Response {
    m.handle(&Request { method: "POST".into(), path: "/v1/chat/completions".into(), headers: vec![], body: body.as_bytes().to_vec() })
}

/// An unlinked scratch file to write the transcript to, and a way to read
/// it back.
fn transcript() -> (File, impl Fn() -> Vec<Json>) {
    let path = std::env::temp_dir().join(format!("abyss-model-test-{}-{:?}", std::process::id(), std::thread::current().id()));
    let f = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&path).unwrap();
    let _ = std::fs::remove_file(&path);
    let reader = f.try_clone().unwrap();
    (f, move || {
        let mut r = &reader;
        r.seek(SeekFrom::Start(0)).unwrap();
        let mut text = String::new();
        r.read_to_string(&mut text).unwrap();
        transcript::lines(&text)
    })
}

fn kinds(l: &[Json]) -> Vec<&str> {
    l.iter().map(|x| x.get("kind").and_then(Json::as_str).unwrap_or("?")).collect()
}

#[test]
fn replies_pass_through_and_tokens_are_counted() {
    let (f, lines) = transcript();
    let stub = StubBackend::new(vec![reply("calling", 120, Some("menu.activate")), reply("done", 80, None)]);
    let mut m = ModelSession::new("s1", 1000, stub, f).with_clock(|| 1000.0);
    let r1 = post(&mut m, r#"{"messages":[{"role":"user","content":"save it"}]}"#);
    assert_eq!(r1.status, 200);
    let j = Json::parse(&r1.body).unwrap();
    let name = j.get("choices").and_then(|c| c.at(0)).and_then(|c| c.get("message")).and_then(|m| m.get("tool_calls")).and_then(|t| t.at(0));
    let name = name.and_then(|t| t.get("function")).and_then(|f| f.get("name")).and_then(Json::as_str);
    assert_eq!(name, Some("menu.activate"), "tool calls pass through unchanged");
    post(&mut m, r#"{"messages":[{"role":"user","content":"and?"}]}"#);
    assert_eq!(m.used(), 200);
    let l = lines();
    assert_eq!(kinds(&l), ["request", "reply", "request", "reply"]);
    assert_eq!(l[1].get("used").and_then(Json::as_int), Some(120));
    assert_eq!(l[3].get("used").and_then(Json::as_int), Some(200));
    let asked = l[0].get("request").and_then(|r| r.get("messages")).and_then(|m| m.at(0)).and_then(|m| m.get("content")).and_then(Json::as_str);
    assert_eq!(asked, Some("save it"), "the transcript keeps what was asked");
    assert!(l.iter().all(|x| x.get("session").and_then(Json::as_str) == Some("s1")));
    assert_eq!(l[0].get("t").and_then(Json::as_f64), Some(1000.0));
}

/// The stop is at the next call: a reply that crosses the budget is
/// delivered (it was already paid for), and the call after it is refused,
/// with the reason, and sent nowhere.
#[test]
fn the_budget_stops_the_next_call_with_its_reason() {
    let (f, lines) = transcript();
    let mut m = ModelSession::new("s2", 500, StubBackend::new(vec![reply("a", 300, None)]), f);
    assert_eq!(post(&mut m, r#"{"messages":[]}"#).status, 200);
    assert_eq!(post(&mut m, r#"{"messages":[]}"#).status, 200, "300 used of 500: still allowed");
    assert_eq!(m.used(), 600);
    let r = post(&mut m, r#"{"messages":[]}"#);
    assert_eq!(r.status, 429);
    let e = Json::parse(&r.body).unwrap();
    let e = e.get("error").unwrap();
    assert_eq!(e.get("type").and_then(Json::as_str), Some("budget"));
    assert_eq!(e.get("message").and_then(Json::as_str), Some("the session's budget of 500 tokens is spent (600 used)"));
    assert_eq!(m.backend.calls, 2, "the refused call reached no backend");
    let l = lines();
    assert_eq!(l.last().and_then(|x| x.get("reason")).and_then(Json::as_str), Some("budget"));
}

/// The person allowed more (P18.11): the next call goes through, and the
/// transcript says so.
#[test]
fn a_raise_lets_the_next_call_through() {
    let (f, lines) = transcript();
    let mut m = ModelSession::new("r", 100, StubBackend::new(vec![reply("a", 150, None)]), f);
    assert_eq!(post(&mut m, r#"{"messages":[]}"#).status, 200);
    assert_eq!(post(&mut m, r#"{"messages":[]}"#).status, 429);
    m.raise(100);
    assert_eq!(m.budget(), 200);
    assert_eq!(post(&mut m, r#"{"messages":[]}"#).status, 200, "150 used of 200");
    assert_eq!(kinds(&lines()), ["request", "reply", "refused", "raised", "request", "reply"]);
    m.raise(0);
    assert_eq!(m.budget(), 200, "a raise of nothing changes nothing");
}

#[test]
fn what_it_refuses_and_why() {
    let (f, _) = transcript();
    let mut m = ModelSession::new("s3", 10, StubBackend::new(vec![reply("x", 11, None)]), f);
    assert_eq!(post(&mut m, "not json").status, 400);
    assert_eq!(post(&mut m, r#"{"model":"m"}"#).status, 400, "no messages");
    let st = post(&mut m, r#"{"messages":[],"stream":true}"#);
    assert_eq!(st.status, 400);
    let msg = Json::parse(&st.body).unwrap();
    assert_eq!(msg.get("error").and_then(|e| e.get("message")).and_then(Json::as_str), Some("streaming is not offered yet: ask with stream false"));
    let get = |p: &str| Request { method: "GET".into(), path: p.into(), headers: vec![], body: vec![] };
    assert_eq!(m.handle(&get("/etc/passwd")).status, 404);
    assert_eq!(m.handle(&get("/v1/models")).status, 200);
    assert_eq!(m.used(), 0, "refusals cost nothing");
    assert_eq!(m.backend.calls, 0, "and send nothing");
}

#[test]
fn a_backend_that_fails_is_a_502_and_is_logged() {
    let (f, lines) = transcript();
    let mut m = ModelSession::new("s4", 10, StubBackend::new(vec![]), f);
    assert_eq!(post(&mut m, r#"{"messages":[]}"#).status, 502);
    assert_eq!(kinds(&lines()), ["request", "failed"]);
}

// MARK: tiers

#[test]
fn vram_from_the_boot_messages() {
    let the_box = "drmn0: VRAM: 12272M 0x0000008000000000 - 0x00000082FEFFFFFF (12272M used)\n<6>[drm] Detected VRAM RAM=12272M, BAR=256M\n<6>[drm] amdgpu: 12272M of VRAM memory ready\n<6>[drm] amdgpu: 65446M of GTT memory ready.\n";
    assert_eq!(session::vram_from_boot_messages(the_box), Some(12272));
    assert_eq!(session::vram_from_boot_messages("no gpu here\n"), None);
}

#[test]
fn the_tier_is_by_vram() {
    assert_eq!(Tier::choose(Some(12272)), Tier::Gpu12, "the 12700KF's 6750 XT");
    assert_eq!(Tier::choose(None), Tier::Cpu, "RAM alone does not make a GPU tier");
    assert_eq!(Tier::choose(Some(4096)), Tier::Cpu);
    assert_eq!(Tier::choose(Some(8192)), Tier::Gpu8);
    assert_eq!(Tier::choose(Some(24576)), Tier::Gpu24);
    assert_eq!(Tier::Gpu12.proposed(), ("Granite-4.2-8B", "Q4_K_M", 16384), "Q8 left the desktop 775 MiB on 12 GB");
    assert_eq!(Tier::Gpu8.proposed().2, 8192, "8B Q4 at 16K is 7.7 GB: no room on 8 GB");
    assert_eq!(Tier::Cpu.proposed().0, "MiniCPM5-2B");
}

// MARK: reading a transcript back (P18.11b)

const TEXT: &str = r#"
{"t":1790962210.1,"session":"s","kind":"vocabulary","event":"given","app":"TextEdit","service":"menus.textedit.7"}
{"t":1790962211,"session":"s","kind":"request","budget":500,"request":{"messages":[{"role":"system","content":"sys"},{"role":"user","content":"save my note"}]}}
{"t":1790962212,"session":"s","kind":"reply","budget":500,"reply":{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"activate","arguments":"{\"app\":\"TextEdit\",\"verb\":\"file.save\"}"}}]}}]},"tokens":300,"used":300}
{"t":1790962212.5,"session":"s","kind":"vocabulary","event":"asked","app":"TextEdit","verb":"file.save","title":"Save"}
{"t":1790962220,"session":"s","kind":"vocabulary","event":"permitted","app":"TextEdit"}
{"t":1790962220.2,"session":"s","kind":"vocabulary","event":"activate","app":"TextEdit","verb":"file.save","arguments":{},"result":"ok"}
not json: a line cut short by a crash
{"t":1790962221,"session":"s","kind":"request","budget":500,"request":{"messages":[{"role":"system","content":"sys"},{"role":"user","content":"save my note"},{"role":"assistant","content":null},{"role":"tool","content":"ok"}]}}
{"t":1790962222,"session":"s","kind":"reply","budget":500,"reply":{"choices":[{"message":{"role":"assistant","content":"Saved."}}]},"tokens":250,"used":550}
{"t":1790962230,"session":"s","kind":"request","budget":500,"request":{"messages":[{"role":"system","content":"sys"},{"role":"user","content":"save my note"},{"role":"user","content":"and again"}]}}
{"t":1790962230.1,"session":"s","kind":"refused","budget":500,"reason":"budget","message":"the session's budget of 500 tokens is spent (550 used)"}
{"t":1790962240,"session":"s","kind":"raised","budget":500,"by":500,"used":550}
{"t":1790962241,"session":"s","kind":"vocabulary","event":"taken","app":"TextEdit"}
{"t":1790962242,"session":"s","kind":"vocabulary","event":"refused","app":"Grab","reason":"not given"}"#;

#[test]
fn the_digest_says_it_in_sentences() {
    let d: Vec<String> = transcript::digest(&transcript::lines(TEXT)).iter().map(|l| l[10..].to_owned()).collect();
    assert_eq!(
        d,
        [
            "You gave the agent TextEdit",
            "You asked: save my note",
            r#"  The agent called activate({"app":"TextEdit","verb":"file.save"})"#,
            "The agent asked to write with TextEdit (Save)",
            "You allowed TextEdit to write for the agent",
            "  TextEdit ran file.save: ok",
            "The agent answered: Saved.",
            "You asked: and again",
            "Stopped: the session's budget of 500 tokens is spent (550 used)",
            "You allowed 500 more tokens",
            "You took TextEdit back",
            "Refused: Grab was not given to the agent",
        ]
    );
}

#[test]
fn the_clock_is_local_time() {
    let d = transcript::digest(&transcript::lines(TEXT));
    assert!(d.iter().all(|l| l.len() > 10 && l.as_bytes()[2] == b':' && l.as_bytes()[5] == b':'), "every line starts with HH:MM:SS");
}

#[test]
fn the_summary() {
    let s = transcript::summary("20261002-173010-agent-23133-1", &transcript::lines(TEXT));
    assert_eq!((s.class.as_str(), s.started.as_str()), ("agent", "2026-10-02 17:30"));
    assert_eq!(s.questions, 2, "the same question resent with the conversation is one question");
    assert_eq!(s.tokens, 550);
    assert!(s.given.is_empty(), "TextEdit was taken back");
    assert_eq!(s.line(), "2026-10-02 17:30 · agent · 2 questions · 550 tokens");
}

#[test]
fn an_id_with_a_hyphenated_class() {
    assert_eq!(transcript::parse_id("20261002-090000-my-agent-1-2").0, "my-agent");
    assert_eq!(transcript::parse_id("odd").1, "odd");
}

#[test]
fn the_digest_says_fetches() {
    let lines = transcript::lines(concat!(
        r#"{"t":1,"kind":"fetch","event":"asked","host":"example.org","url":"https://example.org/"}"#,
        "\n",
        r#"{"t":2,"kind":"fetch","event":"permitted","host":"example.org"}"#,
        "\n",
        r#"{"t":3,"kind":"fetch","event":"fetched","url":"https://example.org/","status":200,"bytes":513}"#,
    ));
    let d: Vec<String> = transcript::digest(&lines).iter().map(|l| l[10..].to_owned()).collect();
    assert_eq!(
        d,
        ["The agent asked to reach example.org (https://example.org/)", "You allowed the agent to reach example.org", "  Fetched https://example.org/ (200, 513 bytes)"]
    );
}

// MARK: URLs (P18.12a)

#[test]
fn what_a_url_is() {
    let u = WebUrl::parse("https://Example.org/docs/a?b=1#top").unwrap();
    assert!(u.https);
    assert_eq!(u.host, "example.org", "a host compares without case");
    assert_eq!(u.port, 443);
    assert_eq!(u.path, "/docs/a?b=1", "the fragment is the reader's, not the server's");
    assert_eq!(WebUrl::parse("http://h:8080").map(|u| (u.path, u.port)), Some(("/".into(), 8080)));
    assert_eq!(WebUrl::parse("http://h?x=1").unwrap().path, "/?x=1");
    assert_eq!(WebUrl::parse("https://h:443/p").unwrap().text(), "https://h/p");
}

#[test]
fn what_a_url_is_not() {
    for bad in ["ftp://h/", "file:///etc/passwd", "https://", "https://user:pw@h/", "https://h:0/", "https://h:99999/", "https://h_x/", "https://h x/", "example.org", "https://ехаmple.org/"] {
        assert_eq!(WebUrl::parse(bad), None, "{bad}");
    }
    assert_eq!(WebUrl::parse("https://evil.com@good.com/"), None, "userinfo is refused: the host is not what it looks like");
}

#[test]
fn a_redirect_resolves_against_its_page() {
    let u = WebUrl::parse("https://a.org/x").unwrap();
    assert_eq!(u.resolve("/y").unwrap().text(), "https://a.org/y");
    assert_eq!(u.resolve("https://b.org/z").unwrap().host, "b.org");
    assert_eq!(u.resolve("relative"), None, "only absolute paths and URLs");
}
