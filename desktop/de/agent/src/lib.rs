//! The agent loop in Rust: model, tool, model, until the model answers
//! (Loop.swift, PHASE18 P18.8).
//!
//! It runs **inside** an agent jail, and everything it can do is bounded
//! from outside: the model only through abyss-model's socket (its budget,
//! its transcript), and the tools only within what the jail sees. The loop
//! adds the bounds that are its own:
//!
//!   - a step limit per question, so a model that keeps calling tools
//!     stops with a reason rather than running until the budget does;
//!   - a refusal from abyss-model (the budget, HTTP 429) ends the question
//!     with abyss-model's own words; the loop never retries around it;
//!   - a tool's failure is the model's to see ("error: …"), never a crash.
//!
//! The conversation persists across questions in one session, as a chat
//! does.

pub mod tools;

pub use tools::{PersonQuestion, QuestionKind};

use model::http::{self, Call, Endpoint};
use model::Json;

/// The model, as the loop sees it: a request in, a status and a body out.
pub type ModelCall = Box<dyn FnMut(&Json) -> Result<(u16, Json), String>>;

fn s(x: &str) -> Json {
    Json::String(x.into())
}

fn obj(kv: Vec<(&str, Json)>) -> Json {
    Json::Object(kv.into_iter().map(|(k, v)| (k.to_owned(), v)).collect())
}

pub struct Tool {
    pub name: String,
    pub description: String,
    pub parameters: Json,
    pub run: Box<dyn Fn(&Json) -> String>,
}

impl Tool {
    pub fn new(name: &str, description: &str, parameters: Json, run: impl Fn(&Json) -> String + 'static) -> Tool {
        Tool { name: name.into(), description: description.into(), parameters, run: Box::new(run) }
    }

    fn schema(&self) -> Json {
        let f = obj(vec![("name", s(&self.name)), ("description", s(&self.description)), ("parameters", self.parameters.clone())]);
        obj(vec![("type", s("function")), ("function", f)])
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stop {
    Answered,
    Steps,
    Budget,
    Failed,
}

impl Stop {
    pub fn as_str(self) -> &'static str {
        match self {
            Stop::Answered => "answered",
            Stop::Steps => "steps",
            Stop::Budget => "budget",
            Stop::Failed => "failed",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Answer {
    pub text: String,
    pub stop: Stop,
    /// The tools called, in order, as "name(arguments)".
    pub calls: Vec<String>,
    pub steps: usize,
}

pub struct AgentLoop {
    pub tools: Vec<Tool>,
    pub max_steps: usize,
    messages: Vec<Json>,
    /// Each tool call as it starts, as "name(arguments)": so the person
    /// watches what the agent does while it does it, not after.
    pub on_call: Box<dyn FnMut(&str)>,
    model: ModelCall,
}

impl AgentLoop {
    pub fn new(system: &str, tools: Vec<Tool>, model: ModelCall) -> AgentLoop {
        AgentLoop { tools, max_steps: 12, messages: vec![obj(vec![("role", s("system")), ("content", s(system))])], on_call: Box::new(|_| {}), model }
    }

    pub fn messages(&self) -> &[Json] {
        &self.messages
    }

    fn request(&self) -> Json {
        let mut r = vec![
            ("model", s("default")),
            ("messages", Json::Array(self.messages.clone())),
            ("temperature", Json::Number(0.0)),
            ("max_tokens", Json::Number(1024.0)),
            // Thinking off: a tool call should be quick, and a reasoning
            // model can spend its reply thinking (§6b.1).
            ("chat_template_kwargs", obj(vec![("enable_thinking", Json::Bool(false))])),
        ];
        if !self.tools.is_empty() {
            r.push(("tools", Json::Array(self.tools.iter().map(Tool::schema).collect())));
        }
        obj(r)
    }

    pub fn ask(&mut self, text: &str) -> Answer {
        self.messages.push(obj(vec![("role", s("user")), ("content", s(text))]));
        self.run()
    }

    /// Carry on from where the last question stopped, after the person
    /// allowed more budget (P18.11), without asking it again.
    pub fn resume(&mut self) -> Answer {
        self.run()
    }

    fn run(&mut self) -> Answer {
        let mut calls: Vec<String> = vec![];
        let answer = |text: String, stop, calls: &Vec<String>, steps| Answer { text, stop, calls: calls.clone(), steps };
        for step in 1..=self.max_steps {
            let req = self.request();
            let (status, body) = match (self.model)(&req) {
                Ok(r) => r,
                Err(e) => return answer(format!("the model could not be reached: {e}"), Stop::Failed, &calls, step),
            };
            if status != 200 {
                let err = body.get("error");
                let why = err.and_then(|e| e.get("message")).and_then(Json::as_str).map_or_else(|| format!("abyss-model said {status}"), str::to_owned);
                let stop = if err.and_then(|e| e.get("type")).and_then(Json::as_str) == Some("budget") { Stop::Budget } else { Stop::Failed };
                return answer(why, stop, &calls, step);
            }
            let Some(msg) = body.get("choices").and_then(|c| c.at(0)).and_then(|c| c.get("message")).cloned() else {
                return answer("the model's reply had no message".into(), Stop::Failed, &calls, step);
            };
            let tool_calls = msg.get("tool_calls").and_then(Json::as_array).unwrap_or(&[]).to_vec();
            // The assistant's turn goes into the conversation as it came, so
            // the tool results that follow answer the calls it made.
            let mut turn = vec![("role", s("assistant")), ("content", msg.get("content").cloned().unwrap_or(Json::Null))];
            if !tool_calls.is_empty() {
                turn.push(("tool_calls", Json::Array(tool_calls.clone())));
            }
            self.messages.push(obj(turn));
            if tool_calls.is_empty() {
                return answer(msg.get("content").and_then(Json::as_str).unwrap_or("").into(), Stop::Answered, &calls, step);
            }
            for (i, call) in tool_calls.iter().enumerate() {
                let f = call.get("function");
                let name = f.and_then(|f| f.get("name")).and_then(Json::as_str).unwrap_or("");
                let arg_text = f.and_then(|f| f.get("arguments")).and_then(Json::as_str).unwrap_or("{}");
                let id = call.get("id").and_then(Json::as_str).map_or_else(|| format!("call{step}-{i}"), str::to_owned);
                calls.push(format!("{name}({arg_text})"));
                (self.on_call)(calls.last().expect("just pushed"));
                let result = match self.tools.iter().find(|t| t.name == name) {
                    None => format!("error: there is no tool named {name}"),
                    Some(t) => match Json::parse(arg_text.as_bytes()) {
                        Ok(args) => (t.run)(&args),
                        Err(_) => format!("error: the arguments are not JSON: {arg_text}"),
                    },
                };
                self.messages.push(obj(vec![("role", s("tool")), ("tool_call_id", s(&id)), ("content", s(&result))]));
            }
        }
        answer(format!("stopped after {} steps without an answer", self.max_steps), Stop::Steps, &calls, self.max_steps)
    }
}

/// abyss-model over its unix socket: the only way out of the jail to a
/// model.
pub fn model_over_socket(path: &str) -> ModelCall {
    let to = Endpoint::Unix(path.into());
    Box::new(move |request| {
        let r = http::call(&to, &Call { json: Some(request), ..Call::new("POST", "/v1/chat/completions") }).map_err(|e| e.0)?;
        Ok((r.status, Json::parse(&r.body).unwrap_or(Json::Null)))
    })
}

#[cfg(test)]
mod tests;
