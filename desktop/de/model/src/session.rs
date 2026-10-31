//! What `abyss-model` does with one agent session's requests (Session.swift,
//! PHASE18 P18.7).
//!
//! Everything between an agent and a model passes here, so this is where
//! the rules are that the agent cannot argue with:
//!
//!   - **the budget**: tokens per session, counted from what the backend
//!     says each reply used. A request once the budget is spent is refused
//!     (HTTP 429, the reason in the body) and nothing is sent anywhere. The
//!     stop is at the next call, never mid-reply;
//!   - **the transcript**: every request, reply and refusal, one JSON line
//!     each, appended to a file outside the jail and never rewritten;
//!   - **one wire format**: OpenAI-compatible chat completions in and out,
//!     whatever the backend. Streaming is not offered yet, and is refused in
//!     words rather than half-served.

use crate::http::{self, Call, Endpoint, Failure, Request, Response};
use crate::json::Json;
use std::fs::{DirBuilder, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::time::{SystemTime, UNIX_EPOCH};

/// Where a session's completions come from.
pub trait Backend {
    fn name(&self) -> String;
    fn complete(&mut self, request: &Json) -> Result<Json, Failure>;
}

/// Canned replies, in order and then round again: for every test (P18.7),
/// each a chat-completion object, tool calls and usage included.
pub struct StubBackend {
    replies: Vec<Json>,
    next: usize,
    /// How many requests reached it: what a refusal must leave unchanged.
    pub calls: usize,
    /// A pause before each reply: a test's model that takes its time.
    pub delay_ms: u64,
}

impl StubBackend {
    pub fn new(replies: Vec<Json>) -> StubBackend {
        StubBackend { replies, next: 0, calls: 0, delay_ms: 0 }
    }
}

impl Backend for StubBackend {
    fn name(&self) -> String {
        "stub".into()
    }

    fn complete(&mut self, _: &Json) -> Result<Json, Failure> {
        self.calls += 1;
        if self.delay_ms > 0 {
            std::thread::sleep(std::time::Duration::from_millis(self.delay_ms));
        }
        if self.replies.is_empty() {
            return Err(Failure("the stub has no replies".into()));
        }
        let r = self.replies[self.next].clone();
        self.next = (self.next + 1) % self.replies.len();
        Ok(r)
    }
}

/// A server speaking the same wire: llama.cpp's `llama-server`.
pub struct HttpBackend {
    pub name: String,
    endpoint: Endpoint,
    path: String,
}

impl HttpBackend {
    pub fn unix(socket: &str, name: &str) -> HttpBackend {
        HttpBackend { name: name.into(), endpoint: Endpoint::Unix(socket.into()), path: "/v1/chat/completions".into() }
    }

    /// `http://HOST:PORT[/path]`: loopback TCP, never TLS (remote providers
    /// are a later pass).
    pub fn url(url: &str) -> Option<HttpBackend> {
        let rest = url.strip_prefix("http://")?;
        let (hostport, path) = match rest.find('/') {
            Some(i) => (&rest[..i], rest[i..].to_owned()),
            None => (rest, "/v1/chat/completions".to_owned()),
        };
        let (host, port) = hostport.split_once(':')?;
        let port: u16 = port.parse().ok()?;
        Some(HttpBackend { name: format!("http://{host}:{port}{path}"), endpoint: Endpoint::Tcp { host: host.into(), port }, path })
    }
}

impl Backend for HttpBackend {
    fn name(&self) -> String {
        self.name.clone()
    }

    fn complete(&mut self, request: &Json) -> Result<Json, Failure> {
        let r = http::call(&self.endpoint, &Call { json: Some(request), ..Call::new("POST", &self.path) })?;
        if r.status != 200 {
            let said = String::from_utf8_lossy(&r.body[..r.body.len().min(300)]).into_owned();
            return Err(Failure(format!("the backend said {}: {said}", r.status)));
        }
        Json::parse(&r.body).map_err(|e| Failure(e.to_string()))
    }
}

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

fn n(x: i64) -> Json {
    Json::Number(x as f64)
}

fn s(x: &str) -> Json {
    Json::String(x.into())
}

/// One transcript line: when, which session, what kind, and the rest.
/// What abyss-model, abyss-vocab and abyss-fetch all write.
pub fn transcript_line(t: f64, session: &str, head: Vec<(String, Json)>, fields: Vec<(String, Json)>) -> String {
    let mut o = vec![("t".to_owned(), Json::Number((t * 1000.0).round() / 1000.0)), ("session".to_owned(), s(session))];
    o.extend(head);
    o.extend(fields);
    Json::Object(o).text() + "\n"
}

pub struct ModelSession<B: Backend> {
    pub id: String,
    budget: i64,
    used: i64,
    pub refusals: u64,
    pub backend: B,
    transcript: File,
    clock: Box<dyn Fn() -> f64>,
}

impl<B: Backend> ModelSession<B> {
    /// `transcript`: an open, append-only file ([`open_transcript`]).
    pub fn new(id: &str, budget: i64, backend: B, transcript: File) -> ModelSession<B> {
        ModelSession { id: id.into(), budget, used: 0, refusals: 0, backend, transcript, clock: Box::new(now) }
    }

    pub fn with_clock(mut self, clock: impl Fn() -> f64 + 'static) -> ModelSession<B> {
        self.clock = Box::new(clock);
        self
    }

    pub fn budget(&self) -> i64 {
        self.budget
    }

    pub fn used(&self) -> i64 {
        self.used
    }

    /// The person allowed more (P18.11): the budget grows by `tokens`, said
    /// in the transcript, and the next call goes through.
    pub fn raise(&mut self, tokens: i64) {
        if tokens <= 0 {
            return;
        }
        self.budget = self.budget.saturating_add(tokens);
        self.log("raised", vec![("by".into(), n(tokens)), ("used".into(), n(self.used))]);
    }

    /// Answer one HTTP request.
    pub fn handle(&mut self, req: &Request) -> Response {
        match (req.method.as_str(), req.path.as_str()) {
            ("GET", "/v1/models") => {
                let model = Json::Object(vec![("id".into(), s(&self.backend.name())), ("object".into(), s("model"))]);
                Response::json(200, "OK", &Json::Object(vec![("object".into(), s("list")), ("data".into(), Json::Array(vec![model]))]))
            }
            ("POST", "/v1/chat/completions") => self.complete(&req.body),
            _ => refuse(404, "Not Found", "not_found", "abyss-model answers POST /v1/chat/completions and GET /v1/models"),
        }
    }

    fn complete(&mut self, body: &[u8]) -> Response {
        let request = match Json::parse(body) {
            Ok(r) => r,
            Err(e) => return refuse(400, "Bad Request", "invalid_request", &format!("the body is not JSON: {e}")),
        };
        if request.get("messages").and_then(Json::as_array).is_none() {
            return refuse(400, "Bad Request", "invalid_request", "a chat completion needs messages");
        }
        if request.get("stream").and_then(Json::as_bool) == Some(true) {
            return refuse(400, "Bad Request", "invalid_request", "streaming is not offered yet: ask with stream false");
        }
        // **The budget, before anything leaves.** Spent means spent: the
        // next call is refused with its reason, and the transcript says so.
        if self.used >= self.budget {
            self.refusals += 1;
            let why = format!("the session's budget of {} tokens is spent ({} used)", self.budget, self.used);
            self.log("refused", vec![("reason".into(), s("budget")), ("message".into(), s(&why)), ("request".into(), request)]);
            return refuse(429, "Too Many Requests", "budget", &why);
        }
        self.log("request", vec![("request".into(), request.clone())]);
        let reply = match self.backend.complete(&request) {
            Ok(r) => r,
            Err(e) => {
                self.log("failed", vec![("message".into(), s(&e.0))]);
                return refuse(502, "Bad Gateway", "backend", &format!("the model did not answer: {e}"));
            }
        };
        let usage = |k: &str| reply.get("usage").and_then(|u| u.get(k)).and_then(Json::as_int);
        let tokens = usage("total_tokens").unwrap_or_else(|| usage("prompt_tokens").unwrap_or(0) + usage("completion_tokens").unwrap_or(0)).max(0);
        self.used = self.used.saturating_add(tokens);
        self.log("reply", vec![("reply".into(), reply.clone()), ("tokens".into(), n(tokens)), ("used".into(), n(self.used))]);
        Response::json(200, "OK", &reply)
    }

    fn log(&mut self, kind: &str, fields: Vec<(String, Json)>) {
        let line = transcript_line((self.clock)(), &self.id, vec![("kind".into(), s(kind)), ("budget".into(), n(self.budget))], fields);
        let _ = self.transcript.write_all(line.as_bytes());
    }
}

fn refuse(status: u16, reason: &str, kind: &str, message: &str) -> Response {
    let e = Json::Object(vec![("type".into(), s(kind)), ("message".into(), s(message))]);
    Response::json(status, reason, &Json::Object(vec![("error".into(), e)]))
}

/// Open `dir/transcript.jsonl` for appending only (O_APPEND, so no write
/// lands anywhere but the end), making the directory (0700) and the file
/// (0600) if need be.
pub fn open_transcript(dir: &str) -> Result<File, Failure> {
    DirBuilder::new().recursive(true).mode(0o700).create(dir).map_err(|e| Failure(format!("mkdir {dir}: {e}")))?;
    OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .open(format!("{dir}/transcript.jsonl"))
        .map_err(|e| Failure(format!("open the transcript: {e}")))
}

// MARK: which model, for this machine (PHASE18 §6b.1)

/// The VRAM the GPU driver reported at boot ("amdgpu: 12272M of VRAM memory
/// ready" on the 12700KF's RX 6750 XT), the largest if several.
pub fn vram_from_boot_messages(text: &str) -> Option<i64> {
    text.lines()
        .filter(|l| l.contains("of VRAM memory ready"))
        .filter_map(|l| l.split(' ').find_map(|w| w.strip_suffix('M').and_then(|n| n.parse::<i64>().ok())))
        .max()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tier {
    Cpu,
    Gpu8,
    Gpu12,
    Gpu24,
}

impl Tier {
    /// By VRAM first: a model that has to spill out of VRAM runs at a
    /// fraction of the speed, so RAM decides only when there is no GPU.
    pub fn choose(vram_mib: Option<i64>) -> Tier {
        match vram_mib {
            Some(v) if v >= 22 * 1024 => Tier::Gpu24,
            Some(v) if v >= 11 * 1024 => Tier::Gpu12,
            Some(v) if v >= 6 * 1024 => Tier::Gpu8,
            _ => Tier::Cpu,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Tier::Cpu => "cpu",
            Tier::Gpu8 => "gpu8",
            Tier::Gpu12 => "gpu12",
            Tier::Gpu24 => "gpu24",
        }
    }

    /// The default model, quantisation and context (§6b.1), as measured on
    /// the 12700KF's 6750 XT (2026-10-02). The context leaves the desktop
    /// room: Granite 8B Q4 took 6.1 GB at 8K, 7.7 GB at 16K; Q8 at 16K left
    /// 775 MiB, which is why the 12 GB tier is Q4 and not Q8.
    pub fn proposed(self) -> (&'static str, &'static str, u32) {
        match self {
            Tier::Cpu => ("MiniCPM5-2B", "Q4_K_M", 8192),
            Tier::Gpu8 => ("Granite-4.2-8B", "Q4_K_M", 8192),
            Tier::Gpu12 => ("Granite-4.2-8B", "Q4_K_M", 16384),
            Tier::Gpu24 => ("Granite-4.2-30B", "Q4_K_M", 16384),
        }
    }
}
