//! The Agents pane (AgentsPane.swift, P18.11b): what agents did, and what
//! was given. The sessions' transcripts (~/Library/Logs/Agents/SESSION/),
//! newest first, the selected one said in sentences, the last lines that
//! fit; below, the files given to confined applications this session, each
//! with Revoke: the keeper takes it back. Read from disk when the pane
//! opens; the grants are the keeper's to say, asked over CurrentIPC.

use super::{at, log, Pane, PrefsHost};
use aquadraw::canvas::Canvas;
use aquadraw::color::Color;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use current_ipc::Msg;
use model::transcript::{self, Summary};
use pool_config::Agents;
use std::cell::RefCell;
use std::rc::Rc;
use surface::keyboard::{KeyEvent, KeySym};

/// A file given to a confined application.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GrantRow {
    pub jail: String,
    pub n: u64,
    pub writable: bool,
    pub path: String,
}

impl GrantRow {
    /// From the keeper's `grants`: "JAIL<TAB>N<TAB>ro|rw<TAB>inside<TAB>source".
    pub fn parse(line: &str) -> Option<GrantRow> {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 5 {
            return None;
        }
        Some(GrantRow { jail: f[0].into(), n: f[1].parse().ok()?, writable: f[2] == "rw", path: f[4].into() })
    }

    /// "app — /home/ada/notes.txt (read-write)": the jail's class, not its name.
    pub fn line(&self) -> String {
        let class = self.jail.split('-').skip(2).collect::<Vec<_>>().join("-");
        format!("{} — {} ({})", if class.is_empty() { &self.jail } else { &class }, self.path, if self.writable { "read-write" } else { "read-only" })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentsPaneState {
    pub sessions: Vec<Summary>,
    pub selected: Option<usize>,
    pub digest: Vec<String>,
    pub grants: Vec<GrantRow>,
    pub note: String,
    /// Whether agents are on: `agents.ini` exists.
    pub on: bool,
}

impl Default for AgentsPaneState {
    fn default() -> AgentsPaneState {
        AgentsPaneState { sessions: vec![], selected: None, digest: vec![], grants: vec![], note: String::new(), on: true }
    }
}

impl AgentsPaneState {
    pub fn sample() -> AgentsPaneState {
        let s = |id: &str, class: &str, started: &str, tokens, given: &[&str]| Summary { id: id.into(), class: class.into(), started: started.into(), questions: 1, tokens, given: given.iter().map(|g| g.to_string()).collect() };
        AgentsPaneState {
            sessions: vec![s("20261002-173010-agent-1-1", "agent", "2026-10-02 17:30", 4469, &["TextEdit"]), s("20261002-162929-debug-1-1", "debug", "2026-10-02 16:29", 3120, &[])],
            selected: Some(0),
            digest: [
                "17:30:12  You gave the agent TextEdit",
                "17:30:15  You asked: Please save the document I have open in TextEdit.",
                "17:30:17    The agent called activate({\"app\":\"TextEdit\",\"verb\":\"file.save\"})",
                "17:30:17  The agent asked to write with TextEdit (Save)",
                "17:30:27  You allowed TextEdit to write for the agent",
                "17:30:27    TextEdit ran file.save: ok",
                "17:30:28  The agent answered: The document has been saved.",
            ]
            .map(String::from)
            .to_vec(),
            grants: vec![GrantRow { jail: "abyss-1001-app".into(), n: 1, writable: true, path: "/home/ada/Documents/notes.txt".into() }],
            ..AgentsPaneState::default()
        }
    }
}

/// Where transcripts are: $HOME/Library/Logs/Agents.
pub fn logs() -> String {
    format!("{}/Library/Logs/Agents", std::env::var("HOME").unwrap_or_else(|_| "/".into()))
}

fn transcript_of(dir: &str, id: &str) -> Option<String> {
    std::fs::read(format!("{dir}/{id}/transcript.jsonl")).ok().map(|b| String::from_utf8_lossy(&b).into_owned())
}

/// The sessions on disk, newest first.
pub fn sessions(dir: &str) -> Vec<Summary> {
    let mut ids: Vec<String> = std::fs::read_dir(dir).map(|d| d.flatten().filter_map(|e| e.file_name().into_string().ok()).filter(|n| !n.starts_with('.')).collect()).unwrap_or_default();
    ids.sort_by(|a, b| b.cmp(a));
    ids.into_iter().filter_map(|id| transcript_of(dir, &id).map(|t| transcript::summary(&id, &transcript::lines(&t)))).collect()
}

pub fn digest(dir: &str, id: &str) -> Vec<String> {
    transcript::digest(&transcript::lines(&transcript_of(dir, id).unwrap_or_default()))
}

/// The keeper's grants; None when the session's jails are not running.
pub fn grants() -> Option<Vec<GrantRow>> {
    let mut m = Msg::new();
    m.set_string("method", "grants");
    let r = current_ipc::call("jails", &m).ok().filter(|r| r.bool("ok") == Some(true))?;
    // JailWire's list encoding (NUL-separated), without linking jaild.
    Some(r.bytes("grants").unwrap_or_default().split(|b| *b == 0).filter(|s| !s.is_empty()).filter_map(|s| GrantRow::parse(&String::from_utf8_lossy(s))).collect())
}

/// Take a grant back; None on success, else why not.
pub fn revoke(g: &GrantRow) -> Option<String> {
    let mut m = Msg::new();
    m.set_string("method", "revoke");
    m.set_string("jail", &g.jail);
    m.set_u64("grant", g.n);
    match current_ipc::call("jails", &m) {
        Err(_) => Some("the session's jails are not running".into()),
        Ok(r) if r.bool("ok") == Some(true) => None,
        Ok(r) => Some(r.string("error").unwrap_or("refused").into()),
    }
}

pub const MAX_SESSIONS: usize = 10;
pub const MAX_GRANTS: usize = 4;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AgentsLayout {
    pub sessions: Rect,
    pub session_rows: Vec<Rect>,
    pub digest: Rect,
    pub grants: Rect,
    pub grant_rows: Vec<Rect>,
    pub revoke: Vec<Rect>,
    pub note_y: f64,
    /// "Let agents run on this computer".
    pub on_off: Rect,
}

pub fn agents_layout(body: Rect, s: &AgentsPaneState) -> AgentsLayout {
    let (left, w) = (body.x + 30.0, body.w - 60.0);
    let sessions = Rect::new(left, body.y + 74.0, 250.0, MAX_SESSIONS as f64 * 22.0);
    let grants = Rect::new(left, sessions.y + sessions.h + 40.0, w, MAX_GRANTS as f64 * 26.0);
    let grant_rows: Vec<Rect> = (0..s.grants.len().min(MAX_GRANTS)).map(|i| Rect::new(left, grants.y + i as f64 * 26.0, w, 26.0)).collect();
    AgentsLayout {
        on_off: Rect::new(left, body.y + 14.0, w, 22.0),
        session_rows: (0..s.sessions.len().min(MAX_SESSIONS)).map(|i| Rect::new(left, sessions.y + i as f64 * 22.0, 250.0, 22.0)).collect(),
        digest: Rect::new(left + 262.0, sessions.y, w - 262.0, sessions.h),
        revoke: grant_rows.iter().map(|r| Rect::new(r.x + r.w - 92.0, r.y + 2.0, 84.0, 22.0)).collect(),
        grant_rows,
        note_y: grants.y + grants.h + 24.0,
        sessions,
        grants,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgentsHit {
    Session(usize),
    Revoke(usize),
    OnOff,
}

pub fn agents_hit(l: &AgentsLayout, x: f64, y: f64) -> Option<AgentsHit> {
    if l.on_off.contains(x, y) {
        return Some(AgentsHit::OnOff);
    }
    if let Some(i) = l.revoke.iter().position(|r| r.contains(x, y)) {
        return Some(AgentsHit::Revoke(i));
    }
    l.session_rows.iter().position(|r| r.contains(x, y)).map(AgentsHit::Session)
}

/// The digest as paragraphs to wrap: an agent's answer may hold line
/// breaks, each a paragraph of its own.
pub fn digest_paragraphs(digest: &[String]) -> Vec<String> {
    digest.iter().flat_map(|d| d.split('\n').filter(|s| !s.is_empty()).map(String::from)).collect()
}

pub fn paint_agents(c: &mut Canvas, l: &AgentsLayout, s: &AgentsPaneState) {
    let t = c.theme.tokens.clone();
    let text = |c: &mut Canvas, s: &str, x: f64, y: f64, k, size, style| c.text_left(s, x, y, k, size, style, Role::Interface);
    let white = Color::new(1.0, 1.0, 1.0, 1.0);
    let boxed = |c: &mut Canvas, r: Rect| {
        c.set_color(white);
        c.cr.rectangle(r.x, r.y, r.w, r.h);
        c.cr.fill();
        c.set_color(Color::new(0.6, 0.6, 0.6, 1.0));
        c.cr.set_line_width(1.0);
        c.cr.rectangle(r.x + 0.5, r.y + 0.5, r.w - 1.0, r.h - 1.0);
        c.cr.stroke()
    };
    c.checkbox(Rect::new(l.on_off.x, l.on_off.y + 3.0, 16.0, 16.0), s.on);
    text(c, "Let agents run on this computer", l.on_off.x + 24.0, l.on_off.y + 15.0, t.body_text, 13.0, Style::Regular);
    let says = if s.on { "An agent runs only when you ask, confined, and only with what you give it." } else { "Off: no Agent window, menu item, chord or Ask the Agent, and no agent runs." };
    text(c, says, l.on_off.x + 24.0, l.on_off.y + 32.0, t.secondary_text, 11.0, Style::Regular);
    text(c, "What agents did, session by session:", l.sessions.x, l.sessions.y - 12.0, t.body_text, 13.0, Style::Regular);
    boxed(c, l.sessions);
    if s.sessions.is_empty() {
        text(c, "No agent has run yet.", l.sessions.x + 10.0, l.sessions.y + 16.0, t.secondary_text, 12.0, Style::Regular)
    }
    for (i, (ts, r)) in s.sessions.iter().zip(&l.session_rows).enumerate() {
        let on = Some(i) == s.selected;
        if on {
            c.set_color(Color::new(0.22, 0.46, 0.84, 1.0));
            c.cr.rectangle(r.x + 1.0, r.y, r.w - 2.0, r.h);
            c.cr.fill()
        }
        text(c, &format!("{} · {}", ts.started, ts.class), r.x + 8.0, r.y + 15.0, if on { white } else { t.body_text }, 12.0, Style::Regular)
    }
    boxed(c, l.digest);
    c.cr.save();
    c.cr.rectangle(l.digest.x, l.digest.y, l.digest.w, l.digest.h);
    c.cr.clip();
    // The last lines that fit: a session reads to its end.
    let mut lines = vec![];
    if let Some(ts) = s.selected.and_then(|i| s.sessions.get(i)) {
        lines.push(ts.line());
        lines.push(String::new())
    }
    for d in digest_paragraphs(&s.digest) {
        lines.extend(c.wrap_words(&d, l.digest.w - 16.0, 11.0, Style::Regular))
    }
    let fit = ((l.digest.h - 10.0) / 15.0) as usize;
    if lines.len() > fit {
        lines.drain(2..lines.len() - (fit - 2));
    }
    for (k, line) in lines.iter().enumerate() {
        text(c, line, l.digest.x + 8.0, l.digest.y + 16.0 + k as f64 * 15.0, t.body_text, 11.0, if k == 0 { Style::Bold } else { Style::Regular })
    }
    c.cr.restore();

    text(c, "Files given to confined applications:", l.grants.x, l.grants.y - 12.0, t.body_text, 13.0, Style::Regular);
    boxed(c, l.grants);
    if s.grants.is_empty() {
        text(c, "None: nothing confined holds one of your files.", l.grants.x + 10.0, l.grants.y + 17.0, t.secondary_text, 12.0, Style::Regular)
    }
    for ((g, r), b) in s.grants.iter().zip(&l.grant_rows).zip(&l.revoke) {
        text(c, &g.line(), r.x + 8.0, r.y + 17.0, t.body_text, 12.0, Style::Regular);
        c.gel_button(*b, "Revoke", false, false)
    }
    if !s.note.is_empty() {
        text(c, &s.note, l.grants.x, l.note_y, t.body_text, 12.0, Style::Regular)
    }
}

fn glog(s: &str) {
    log(&format!("agents: {s}"))
}

#[derive(Default)]
pub struct AgentsPane {
    state: RefCell<AgentsPaneState>,
    layout: RefCell<Option<AgentsLayout>>,
    dumped: RefCell<Option<AgentsLayout>>,
}

impl AgentsPane {
    pub fn new(state: AgentsPaneState) -> AgentsPane {
        AgentsPane { state: RefCell::new(state), ..AgentsPane::default() }
    }

    /// The sessions on disk, the selected one's digest, the keeper's grants.
    fn load(&self, h: &Rc<PrefsHost>) {
        let dir = logs();
        let (keep, note) = { let s = self.state.borrow(); (s.selected.and_then(|i| s.sessions.get(i)).map(|t| t.id.clone()), s.note.clone()) };
        let mut s = AgentsPaneState { on: Agents::on(None), sessions: sessions(&dir), ..AgentsPaneState::default() };
        s.selected = keep.and_then(|k| s.sessions.iter().position(|t| t.id == k)).or((!s.sessions.is_empty()).then_some(0));
        if let Some(t) = s.selected.map(|i| &s.sessions[i]) {
            s.digest = digest(&dir, &t.id)
        }
        match grants() {
            Some(g) => s.grants = g,
            None => s.note = "The session's jails are not running.".into(),
        }
        if !note.is_empty() {
            s.note = note
        }
        let gs: Vec<String> = s.grants.iter().map(|g| format!("{}.{}", g.jail, g.n)).collect();
        glog(&format!("{}; {} session(s); grants: {}", if s.on { "on" } else { "off" }, s.sessions.len(), gs.join(" ")));
        *self.state.borrow_mut() = s;
        *self.dumped.borrow_mut() = None;
        h.redraw()
    }

    fn select(&self, h: &Rc<PrefsHost>, i: usize) {
        let mut s = self.state.borrow_mut();
        let Some(id) = s.sessions.get(i).map(|t| t.id.clone()) else { return };
        s.selected = Some(i);
        s.digest = digest(&logs(), &id);
        // Each line without its time.
        let said: Vec<&str> = s.digest.iter().map(|d| d.split_once(' ').map_or("", |(_, r)| r.trim_start_matches(' '))).collect();
        glog(&format!("showing {id}: {}", said.join(" | ")));
        drop(s);
        h.redraw()
    }
}

impl Pane for AgentsPane {
    fn id(&self) -> &'static str {
        "agents"
    }
    fn shown(&self, h: &Rc<PrefsHost>) {
        self.load(h)
    }
    fn paint(&self, c: &mut Canvas, body: Rect) {
        let s = self.state.borrow().clone();
        let l = agents_layout(body, &s);
        paint_agents(c, &l, &s);
        *self.layout.borrow_mut() = Some(l)
    }
    /// Each session by ID, each grant's Revoke by its number and jail.
    fn dump(&self) -> Vec<String> {
        let Some(l) = self.layout.borrow().clone() else { return vec![] };
        if self.dumped.borrow().as_ref() == Some(&l) {
            return vec![];
        }
        let s = self.state.borrow();
        let mut line = "agents layout".to_string();
        for (t, r) in s.sessions.iter().zip(&l.session_rows) {
            line += &format!(" session.{}={}", t.id, at(r))
        }
        for (g, r) in s.grants.iter().zip(&l.revoke) {
            line += &format!(" revoke.{}.{}={}", g.jail, g.n, at(r))
        }
        line += &format!(" onoff={}", at(&l.on_off));
        *self.dumped.borrow_mut() = Some(l);
        vec![line]
    }
    fn press(&self, h: &Rc<PrefsHost>, x: f64, y: f64) -> bool {
        let Some(hit) = self.layout.borrow().as_ref().and_then(|l| agents_hit(l, x, y)) else { return false };
        match hit {
            AgentsHit::OnOff => {
                // Off is one file, absent: on writes agents.ini, off removes it.
                let on = !self.state.borrow().on;
                let note = match Agents::set(on, None) {
                    Some(why) => format!("Not changed: {why}"),
                    None if Agents::on(None) => "Agents are on.".into(),
                    None => "Agents are off.".into(),
                };
                glog(&note);
                self.state.borrow_mut().note = note;
                // Agent.app is the person's, in ~/Applications while agents
                // are on: appgen, beside this binary, adds or removes it now
                // (its default sources, as at login).
                if let (Some(me), Ok(home)) = (crate::launcher::self_executable(), std::env::var("HOME")) {
                    let appgen = std::path::Path::new(&me).with_file_name("abyss-appgen");
                    if crate::launcher::is_executable_file(&appgen.to_string_lossy()) {
                        crate::launcher::launch_detached(&[appgen.to_string_lossy().into_owned(), "--to".into(), format!("{home}/Applications")], &[]);
                    }
                }
                self.load(h)
            }
            AgentsHit::Session(i) => self.select(h, i),
            AgentsHit::Revoke(i) => {
                let Some(g) = self.state.borrow().grants.get(i).cloned() else { return true };
                let note = match revoke(&g) {
                    Some(why) => format!("Not revoked: {why}"),
                    None => format!("Revoked: {} is no longer in {}.", g.path, g.jail),
                };
                glog(&note);
                self.state.borrow_mut().note = note;
                self.load(h)
            }
        }
        true
    }
    fn key(&self, h: &Rc<PrefsHost>, e: &KeyEvent) {
        let (sel, n) = { let s = self.state.borrow(); (s.selected, s.sessions.len()) };
        match e.keysym {
            KeySym::DOWN if n > 0 => self.select(h, sel.map_or(0, |i| (i + 1).min(n - 1))),
            KeySym::UP if n > 0 => self.select(h, sel.map_or(0, |i| i.saturating_sub(1))),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_grant_reads_from_the_keeper_and_says_its_class() {
        let g = GrantRow::parse("abyss-1001-app\t3\trw\t/mnt/x\t/home/ada/notes.txt").unwrap();
        assert_eq!(g.line(), "app — /home/ada/notes.txt (read-write)");
        assert_eq!(GrantRow::parse("abyss\tx\tro\ta\tb"), None);
        assert_eq!(digest_paragraphs(&["a\nb".into(), "c".into()]), ["a", "b", "c"]);
        let s = AgentsPaneState::sample();
        let l = agents_layout(Rect::new(0.0, 80.0, 760.0, 540.0), &s);
        let r = l.session_rows[1];
        assert_eq!(agents_hit(&l, r.x + 5.0, r.y + 5.0), Some(AgentsHit::Session(1)));
        assert_eq!(agents_hit(&l, l.revoke[0].x + 5.0, l.revoke[0].y + 5.0), Some(AgentsHit::Revoke(0)));
    }

    #[test]
    fn a_grant_from_the_keeper() {
        assert_eq!(GrantRow::parse("abyss-1001-app\t3\trw\t/run/granted/3/notes.txt\t/home/ada/notes.txt"), Some(GrantRow { jail: "abyss-1001-app".into(), n: 3, writable: true, path: "/home/ada/notes.txt".into() }));
        assert_eq!(GrantRow::parse("abyss-1001-app-net\t1\tro\t/run/granted/1/a b.pdf\t/home/ada/a b.pdf").unwrap().line(), "app-net — /home/ada/a b.pdf (read-only)", "a hyphenated class, and a path with a space");
        assert_eq!(GrantRow::parse("abyss-1001-app\tnot-a-number\tro\tx\ty"), None);
        assert_eq!(GrantRow::parse("too\tfew"), None);
    }

    #[test]
    fn rows_and_revokes_are_where_they_are_drawn() {
        let s = AgentsPaneState::sample();
        let l = agents_layout(Rect::new(0.0, 100.0, 760.0, 500.0), &s);
        assert_eq!((l.session_rows.len(), l.revoke.len()), (2, 1));
        let mid = |r: Rect| (r.x + 5.0, r.y + 5.0);
        let (x, y) = mid(l.session_rows[1]);
        assert_eq!(agents_hit(&l, x, y), Some(AgentsHit::Session(1)));
        let (x, y) = mid(l.revoke[0]);
        assert_eq!(agents_hit(&l, x, y), Some(AgentsHit::Revoke(0)));
        let (x, y) = mid(l.digest);
        assert_eq!(agents_hit(&l, x, y), None, "the digest is read, not pressed");
        let (x, y) = mid(l.on_off);
        assert_eq!(agents_hit(&l, x, y), Some(AgentsHit::OnOff));
        assert!(l.on_off.y + l.on_off.h < l.sessions.y - 20.0, "the switch sits above the sessions' heading");
        assert!(l.sessions.x + l.sessions.w < l.digest.x, "the list and the digest do not overlap");
        assert!(l.digest.y + l.digest.h < l.grants.y);
    }

    #[test]
    fn an_answers_line_breaks_are_paragraphs() {
        assert_eq!(digest_paragraphs(&["17:33:08  The agent answered: Let me check.\nThen save.".into(), "next".into()]), ["17:33:08  The agent answered: Let me check.", "Then save.", "next"]);
        assert_eq!(digest_paragraphs(&["a\n\nb".into()]), ["a", "b"], "no empty paragraph");
    }

    #[test]
    fn at_most_what_fits() {
        let sessions = (0..20).map(|i| Summary { id: i.to_string(), class: "agent".into(), started: String::new(), questions: 0, tokens: 0, given: vec![] }).collect();
        let grants = (0..9).map(|n| GrantRow { jail: "j".into(), n, writable: false, path: "/p".into() }).collect();
        let s = AgentsPaneState { sessions, grants, ..AgentsPaneState::default() };
        let l = agents_layout(Rect::new(0.0, 100.0, 760.0, 500.0), &s);
        assert_eq!((l.session_rows.len(), l.revoke.len()), (MAX_SESSIONS, MAX_GRANTS));
    }
}
