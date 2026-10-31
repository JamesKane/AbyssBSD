//! Reading an agent session's log back, for a person (Transcript.swift,
//! PHASE18 P18.11b).
//!
//! abyss-model, abyss-vocab and abyss-fetch append JSON lines to
//! ~/Library/Logs/Agents/SESSION/transcript.jsonl: every request and reply,
//! refusal and raise, give and take, requester and answer. That is the
//! record; this is how the Preferences pane says it in sentences. Pure,
//! given the lines.

use crate::json::Json;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Summary {
    /// The session's ID (its directory's name): `YYYYMMDD-HHMMSS-CLASS-PID-N`.
    pub id: String,
    pub class: String,
    /// "2026-10-02 17:30", from the ID.
    pub started: String,
    pub questions: usize,
    pub tokens: i64,
    pub given: Vec<String>,
}

impl Summary {
    /// One line for a list: when, which class, how much, what it drove.
    pub fn line(&self) -> String {
        let mut s = format!("{} · {} · {} question{} · {} tokens", self.started, self.class, self.questions, if self.questions == 1 { "" } else { "s" }, self.tokens);
        if !self.given.is_empty() {
            s += &format!(" · {}", self.given.join(", "));
        }
        s
    }
}

/// The lines of a transcript file; a line that is not JSON is skipped,
/// never fatal (a write cut short by a crash).
pub fn lines(text: &str) -> Vec<Json> {
    text.split('\n').filter(|l| !l.is_empty()).filter_map(|l| Json::parse(l.as_bytes()).ok()).collect()
}

/// `20261002-173010-agent-23133-1` is ("agent", "2026-10-02 17:30").
pub fn parse_id(id: &str) -> (String, String) {
    let parts: Vec<&str> = id.split('-').filter(|p| !p.is_empty()).collect();
    let digits = |p: &str, n: usize| p.len() == n && p.bytes().all(|b| b.is_ascii_digit());
    if parts.len() < 3 || !digits(parts[0], 8) || !digits(parts[1], 6) {
        return ("?".into(), id.into());
    }
    let (d, t) = (parts[0], parts[1]);
    let started = format!("{}-{}-{} {}:{}", &d[0..4], &d[4..6], &d[6..8], &t[0..2], &t[2..4]);
    // The class is everything between the time and the trailing pid-n.
    let class = if parts.len() >= 5 { parts[2..parts.len() - 2].join("-") } else { parts[2].to_owned() };
    (class, started)
}

fn str_of<'a>(l: &'a Json, k: &str) -> Option<&'a str> {
    l.get(k).and_then(Json::as_str)
}

fn user_turns(l: &Json) -> Vec<&Json> {
    let msgs = l.get("request").and_then(|r| r.get("messages")).and_then(Json::as_array).unwrap_or(&[]);
    msgs.iter().filter(|m| str_of(m, "role") == Some("user")).collect()
}

pub fn summary(id: &str, lines: &[Json]) -> Summary {
    let (class, started) = parse_id(id);
    let (mut tokens, mut questions, mut users) = (0, 0, 0);
    let mut given: Vec<String> = vec![];
    for l in lines {
        match (str_of(l, "kind"), str_of(l, "event")) {
            (Some("reply"), _) => tokens = l.get("used").and_then(Json::as_int).unwrap_or(tokens),
            // A request carries the whole conversation: what is new is the
            // user's turns since the last.
            (Some("request"), _) => {
                let n = user_turns(l).len();
                if n > users {
                    questions += n - users;
                    users = n;
                }
            }
            (Some("vocabulary"), Some("given")) => {
                if let Some(a) = str_of(l, "app")
                    && !given.iter().any(|g| g == a)
                {
                    given.push(a.into());
                }
            }
            (Some("vocabulary"), Some("taken")) => given.retain(|g| Some(g.as_str()) != str_of(l, "app")),
            _ => {}
        }
    }
    Summary { id: id.into(), class, started, questions, tokens, given }
}

/// `t` as local HH:MM:SS, and two spaces.
fn clock(l: &Json) -> String {
    l.get("t").and_then(Json::as_f64).map_or(String::new(), |t| format!("{}  ", abyss_sys::platform::local_time_of_day(t as i64)))
}

/// The session in sentences, one an event, in order.
pub fn digest(lines: &[Json]) -> Vec<String> {
    let mut out = vec![];
    let mut users = 0;
    for l in lines {
        let at = clock(l);
        let f = |k: &str| str_of(l, k).unwrap_or("").to_owned();
        let int = |k: &str| l.get(k).and_then(Json::as_int).unwrap_or(0);
        match (str_of(l, "kind"), str_of(l, "event")) {
            (Some("request"), _) => {
                let turns = user_turns(l);
                for m in turns.iter().skip(users) {
                    out.push(format!("{at}You asked: {}", str_of(m, "content").unwrap_or("")));
                }
                users = users.max(turns.len());
            }
            (Some("reply"), _) => {
                let msg = l.get("reply").and_then(|r| r.get("choices")).and_then(|c| c.at(0)).and_then(|c| c.get("message"));
                for c in msg.and_then(|m| m.get("tool_calls")).and_then(Json::as_array).unwrap_or(&[]) {
                    let func = c.get("function");
                    let name = func.and_then(|x| str_of(x, "name")).unwrap_or("?");
                    out.push(format!("{at}  The agent called {name}({})", func.and_then(|x| str_of(x, "arguments")).unwrap_or("")));
                }
                if let Some(text) = msg.and_then(|m| str_of(m, "content")).filter(|t| !t.is_empty()) {
                    out.push(format!("{at}The agent answered: {text}"));
                }
            }
            (Some("refused"), _) => out.push(format!("{at}Stopped: {}", str_of(l, "message").unwrap_or("refused"))),
            (Some("raised"), _) => out.push(format!("{at}You allowed {} more tokens", int("by"))),
            (Some("failed"), _) => out.push(format!("{at}The model did not answer: {}", f("message"))),
            (Some("fetch"), Some(e)) => {
                let host = f("host");
                let said = match e {
                    "asked" => format!("The agent asked to reach {host} ({})", f("url")),
                    "permitted" => format!("You allowed the agent to reach {host}"),
                    "denied" => format!("You did not allow the agent to reach {host}"),
                    "fetched" => format!("  Fetched {} ({}, {} bytes)", f("url"), int("status"), int("bytes")),
                    "redirected" => format!("  Redirected to {}", f("to")),
                    "refused" => format!("Refused {}: {}", f("url"), f("reason")),
                    _ => continue,
                };
                out.push(at + &said);
            }
            (Some("vocabulary"), Some(e)) => {
                let app = str_of(l, "app").unwrap_or("?");
                let said = match e {
                    "given" => format!("You gave the agent {app}"),
                    "taken" => format!("You took {app} back"),
                    "asked" => format!("The agent asked to write with {app} ({})", str_of(l, "title").or(str_of(l, "verb")).unwrap_or("")),
                    "permitted" => format!("You allowed {app} to write for the agent"),
                    "denied" => format!("You did not allow {app} to write"),
                    "refused" => format!("Refused: {app} was not given to the agent"),
                    "activate" => {
                        let result = str_of(l, "result").map(str::to_owned).or_else(|| l.get("failed").map(|_| "failed".into())).unwrap_or_else(|| "?".into());
                        let shown = if result == "refused" { format!("refused ({})", f("why")) } else { result };
                        format!("  {app} ran {}: {shown}", str_of(l, "verb").unwrap_or("?"))
                    }
                    _ => continue,
                };
                out.push(at + &said);
            }
            _ => {}
        }
    }
    out
}
