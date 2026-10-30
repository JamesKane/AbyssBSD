//! Vocabulary in Rust (RUST.md R2): an agent's way to the applications it
//! was given (PHASE18 P18.10), ported from Bridge.swift beside it.
//!
//! Phase 10 made every application's menus a vocabulary: verbs with titles,
//! arguments and enablement, served by the application itself (menu-wire).
//! An agent drives an application the same way, through this bridge (run by
//! the keeper outside the agent's jail, answering on a socket inside it),
//! and only the applications **this session was given** (§6b.2):
//!
//! - A give is one running application, by its menu service (whose name
//!   carries its pid): a second copy, or the same one relaunched, was not
//!   given. It is the keeper's to make; the agent cannot give itself
//!   anything.
//! - Asking about anything else is refused with a reason, never forwarded.
//! - Every give, activation and refusal is a line in the session's
//!   transcript, beside abyss-model's.
//!
//! `abyss-vocab`, which hosts it, is R3's.

use current_ipc::Msg;
use menu_model::{CommandResult, Enablement, MenuBarModel};
use model::Json;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::error::Error;

pub type Described = (MenuBarModel, HashMap<String, Enablement>);

/// The applications' side, as the bridge sees it: the real one is
/// menu-wire's client.
pub trait MenuCaller {
    fn describe(&self, service: &str) -> Result<Described, Box<dyn Error>>;
    fn activate(&self, service: &str, verb: &str, arguments: &BTreeMap<String, String>) -> Result<CommandResult, Box<dyn Error>>;
}

pub struct LiveMenus;

impl MenuCaller for LiveMenus {
    fn describe(&self, service: &str) -> Result<Described, Box<dyn Error>> {
        Ok(menu_wire::client::describe(service, None)?)
    }

    fn activate(&self, service: &str, verb: &str, arguments: &BTreeMap<String, String>) -> Result<CommandResult, Box<dyn Error>> {
        Ok(menu_wire::client::activate(service, verb, arguments, None)?)
    }
}

/// A transcript line's kind and its fields.
pub type Log = Box<dyn FnMut(&str, Vec<(String, Json)>)>;

pub struct VocabularyBridge<M: MenuCaller> {
    /// Given applications: the name the agent uses (the application's own),
    /// and the service it was given as.
    given: Vec<(String, String)>,
    /// Applications the person allowed to write for the agent this session
    /// (P18.11, requester 1), lowercased. Until then a verb that writes is
    /// not run: the agent is told the person must be asked, and the answer
    /// comes on the keeper's side, never the agent's.
    permitted: HashSet<String>,
    menus: M,
    log: Log,
}

fn s(v: &str) -> Json {
    Json::String(v.to_owned())
}

fn field(k: &str, v: Json) -> (String, Json) {
    (k.to_owned(), v)
}

fn refuse(why: &str) -> Msg {
    let mut m = Msg::new();
    m.set_bool("ok", false);
    m.set_string("error", why);
    m
}

impl<M: MenuCaller> VocabularyBridge<M> {
    pub fn new(menus: M, log: Log) -> VocabularyBridge<M> {
        VocabularyBridge { given: vec![], permitted: HashSet::new(), menus, log }
    }

    /// The given applications' names, in the order given.
    pub fn given(&self) -> Vec<&str> {
        self.given.iter().map(|(n, _)| n.as_str()).collect()
    }

    pub fn menus(&self) -> &M {
        &self.menus
    }

    /// The keeper's: give `service` to this session. Its name is what the
    /// application calls itself.
    pub fn give(&mut self, service: &str) -> Result<String, Box<dyn Error>> {
        let name = self.menus.describe(service)?.0.app_name;
        let lower = name.to_lowercase();
        self.given.retain(|(n, s)| n.to_lowercase() != lower && s != service);
        self.given.push((name.clone(), service.to_owned()));
        (self.log)("given", vec![field("app", s(&name)), field("service", s(service))]);
        Ok(name)
    }

    /// The keeper's: take `app` back (P18.11). From now on it is refused as
    /// anything never given is. Whether it had been given.
    pub fn take(&mut self, app: &str) -> bool {
        let lower = app.to_lowercase();
        let had = self.given.iter().any(|(n, _)| n.to_lowercase() == lower);
        self.given.retain(|(n, _)| n.to_lowercase() != lower);
        if had {
            (self.log)("taken", vec![field("app", s(app))]);
        }
        had
    }

    /// The keeper's: the person's answer to requester 1 for `app`.
    pub fn permit(&mut self, app: &str, allow: bool) {
        if allow {
            self.permitted.insert(app.to_lowercase());
        }
        (self.log)(if allow { "permitted" } else { "denied" }, vec![field("app", s(app))]);
    }

    fn service(&self, app: &str) -> Option<String> {
        let lower = app.to_lowercase();
        self.given.iter().find(|(n, _)| n.to_lowercase() == lower).map(|(_, s)| s.clone())
    }

    fn not_given(&mut self, app: &str) -> Msg {
        (self.log)("refused", vec![field("app", s(app)), field("reason", s("not given"))]);
        refuse(&format!("{} was not given to this session", if app.is_empty() { "that application" } else { app }))
    }

    /// One request from inside the jail.
    pub fn handle(&mut self, req: &Msg) -> Msg {
        let mut r = Msg::new();
        let app = req.string("app").unwrap_or("").to_owned();
        match req.string("method") {
            Some("apps") => {
                r.set_bool("ok", true);
                r.set_string("apps", &self.given().join("\n"));
                r
            }
            Some("describe") => {
                let Some(service) = self.service(&app) else { return self.not_given(&app) };
                match self.menus.describe(&service) {
                    Ok((model, enablement)) => {
                        r.set_bool("ok", true);
                        r.set_string("text", &text(&model, &enablement));
                        r
                    }
                    Err(e) => refuse(&format!("{app} did not answer: {e}")),
                }
            }
            Some("activate") => {
                let Some(service) = self.service(&app) else { return self.not_given(&app) };
                let verb = req.string("verb").unwrap_or("").to_owned();
                let args = arguments(req.string("arguments").unwrap_or(""));
                // Requester 1: a verb that writes the person's file, from an
                // application not yet allowed to write for the agent. **If
                // the application cannot say whether the verb writes, it is
                // not run**: Swift's check is a `try?` that, failing, runs it
                // unasked. Refused in the words, and with the transcript
                // line, a failed activation has.
                let name = self.given.iter().find(|(_, s)| *s == service).map_or(app.clone(), |(n, _)| n.clone());
                let unasked = !self.permitted.contains(&name.to_lowercase());
                let model = if unasked {
                    match self.menus.describe(&service) {
                        Ok((model, _)) => Some(model),
                        Err(e) => {
                            (self.log)("activate", vec![field("app", s(&app)), field("verb", s(&verb)), field("failed", s(&e.to_string()))]);
                            return refuse(&format!("{app} did not answer: {e}"));
                        }
                    }
                } else {
                    None
                };
                if let Some(c) = model.as_ref().and_then(|m| m.command(&verb)).filter(|c| c.writes) {
                    (self.log)("asked", vec![field("app", s(&name)), field("verb", s(&verb)), field("title", s(&c.title))]);
                    let mut m = Msg::new();
                    m.set_bool("ok", false);
                    m.set_bool("permission", true);
                    m.set_string("app", &name);
                    m.set_string("verb", &verb);
                    m.set_string("title", &c.title);
                    m.set_string("error", &format!("the person has not allowed {name} to write for you yet; they are being asked"));
                    return m;
                }
                let result = match self.menus.activate(&service, &verb, &args) {
                    Ok(r) => r,
                    Err(e) => {
                        (self.log)("activate", vec![field("app", s(&app)), field("verb", s(&verb)), field("failed", s(&e.to_string()))]);
                        return refuse(&format!("{app} did not answer: {e}"));
                    }
                };
                let args_json = Json::Object(args.iter().map(|(k, v)| field(k, s(v))).collect());
                let mut fields = vec![field("app", s(&app)), field("verb", s(&verb)), field("arguments", args_json)];
                r.set_bool("ok", true);
                match result {
                    CommandResult::Ok(said) => {
                        fields.push(field("result", s("ok")));
                        r.set_string("text", &said.map_or("ok".to_owned(), |x| format!("ok: {x}")));
                    }
                    CommandResult::Refused(why) => {
                        fields.extend([field("result", s("refused")), field("why", s(&why))]);
                        r.set_string("text", &format!("refused: {why}"));
                    }
                }
                (self.log)("activate", fields);
                r
            }
            _ => refuse("the vocabulary bridge answers apps, describe and activate"),
        }
    }
}

/// `k=v` lines, as the agent's tool sends them; a later key wins.
pub fn arguments(s: &str) -> BTreeMap<String, String> {
    s.split('\n').filter_map(|l| l.split_once('=')).map(|(k, v)| (k.to_owned(), v.to_owned())).collect()
}

/// An application's vocabulary as a model reads it: one line a verb, its
/// title, its arguments, whether it can run now and why not, and what it
/// does.
pub fn text(model: &MenuBarModel, enablement: &HashMap<String, Enablement>) -> String {
    let mut lines = vec![format!("{}:", model.app_name)];
    for menu in &model.menus {
        for c in menu.commands() {
            let mut l = format!("  {} — \"{}\" in {}", c.verb, c.title, menu.title);
            if !c.arguments.is_empty() {
                let a: Vec<String> = c.arguments.iter().map(|a| format!("{} ({}): {}", a.name, a.ty.as_str(), a.summary)).collect();
                l += &format!("; arguments: {}", a.join(", "));
            }
            match enablement.get(&c.verb) {
                Some(Enablement::Disabled(why)) => l += &format!(" [disabled: {why}]"),
                _ => l += " [enabled]",
            }
            l += &format!(". {}", c.summary);
            lines.push(l);
        }
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests;
