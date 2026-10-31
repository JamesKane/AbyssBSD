//! Agent: the chat window (AgentApp.swift, PHASE18 P18.8b).
//!
//! Ours, and **outside** the jail: the agent runs confined (P18.8a), and
//! this window is how the person talks to it. It asks the session's keeper
//! for an agent session in a class (`agent` unless `$ABYSS_AGENT_CLASS`
//! says), then talks to the socket the keeper hands back. It shows what the
//! agent did, not only what it said: each tool call is a line of the
//! conversation. The status line says where the agent runs and why it
//! stopped, in the words of whatever stopped it (abyss-model's budget, the
//! step limit).
//!
//! Nothing here waits: the keeper's answer (a local model may take a while
//! to load) and every reply arrive on a socket the display's poll loop
//! watches. The question's connection has a slot of its own, so a keeper
//! request made while a requester is up cannot lose it.

use crate::agent_presence::{io as presence_io, AgentPresence, AgentState};
use crate::commands::key_equivalent_of;
use crate::text_view::TextView;
use crate::toolkit::Toolkit;
use aquadraw::canvas::Canvas;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeHit, Gadget};
use aquadraw::color::Color;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use current_ipc::Msg;
use menu_model::{Argument, ArgumentType, Command, CommandResult, Enablement, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use menu_wire::{MenuProvider, MenuService};
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::rc::{Rc, Weak};
use surface::{Display, KeyEvent, KeyModifiers, KeySym, RenderTarget, Window, WindowDelegate};
use text_model::{EditKind, Motion};

// MARK: - The vocabulary

pub const VERB_ABOUT: &str = "app.about";
pub const VERB_QUIT: &str = "app.quit";
pub const VERB_ASK: &str = "agent.ask";
pub const VERB_QUESTION: &str = "agent.question";
pub const VERB_CLEAR: &str = "agent.clear";
pub const VERB_GIVE_APP: &str = "agent.give-app";
pub const VERB_GIVE: &str = "agent.give";
pub const VERB_TAKE_APP: &str = "agent.take-app";
pub const VERB_TAKE: &str = "agent.take";
pub const VERB_ALLOW: &str = "agent.allow";
pub const VERB_STOP: &str = "agent.stop";
pub const VERB_MINIMIZE: &str = "window.minimize";

/// The keeper's service (JailKeeper's KeeperWire): named here rather than
/// linked, so the window does not carry the keeper.
const KEEPER: &str = "jails";

pub fn agent_menu_bar() -> MenuBarModel {
    let c = |v: &str, t: &str, k: Option<char>, s: &str, args: Vec<Argument>| {
        let cmd = Command::new(v, t, s).with_arguments(args);
        MenuItem::Command(match k {
            Some(ch) => cmd.with_key(KeyEquivalent::cmd(ch, Modifiers::NONE)),
            None => cmd,
        })
    };
    let arg = |n: &str, s: &str| vec![Argument::new(n, ArgumentType::String, s)];
    MenuBarModel::new(
        "Agent",
        vec![
            Menu::new("Agent", vec![c(VERB_ABOUT, "About Agent", None, "Show Agent's version.", vec![]), MenuItem::Separator, c(VERB_QUIT, "Quit Agent", Some('q'), "End the agent session and close.", vec![])]),
            Menu::new(
                "Conversation",
                vec![
                    c(VERB_ASK, "Ask", None, "Ask the agent what is in the field.", vec![]),
                    // A script asks as a person does: into the field, then
                    // Ask. Its own verb: a declared argument is required.
                    c(VERB_QUESTION, "Ask Question…", None, "Put a question in the field and ask it.", arg("text", "The question.")),
                    c(VERB_CLEAR, "Clear Field", Some('k'), "Empty the question field.", vec![]),
                    MenuItem::Separator,
                    // §6b.2: the agent drives only what it is given, one
                    // running application at a time.
                    c(VERB_GIVE_APP, "Give Application…", None, "Pick a running application for the agent to drive.", vec![]),
                    c(VERB_GIVE, "Give", None, "Give the agent a running application, by name.", arg("app", "The application, as abyssmenu names it.")),
                    c(VERB_TAKE_APP, "Take Back Application…", None, "Pick a given application to take back.", vec![]),
                    c(VERB_TAKE, "Take Back", None, "Take a given application back, by name.", arg("app", "The application, as the agent was given it.")),
                    MenuItem::Separator,
                    // Requesters 1 and 4 (P18.11): the answer to what is asked.
                    c(VERB_ALLOW, "Allow", None, "Allow what the agent is asking: to write with an application, to reach a host, or to use more budget.", vec![]),
                    c(VERB_STOP, "Don't Allow", None, "Refuse what the agent is asking; a spent budget ends the question.", vec![]),
                ],
            ),
            Menu::new("Window", vec![c(VERB_MINIMIZE, "Minimize", Some('m'), "Put the window in the Dock.", vec![])]),
        ],
    )
}

// MARK: - Layout and painting

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AgentLayout {
    pub conversation: Rect,
    pub field: Rect,
    pub ask: Rect,
    pub status_baseline: f64,
}

impl AgentLayout {
    pub fn new(title_bar: f64, w: f64, h: f64) -> AgentLayout {
        let top = title_bar + 10.0;
        AgentLayout {
            conversation: Rect::new(10.0, top, w - 20.0, (h - top - 78.0).max(40.0)),
            status_baseline: h - 50.0,
            field: Rect::new(10.0, h - 38.0, w - 106.0, 26.0),
            ask: Rect::new(w - 86.0, h - 38.0, 76.0, 26.0),
        }
    }
}

pub const PICKER_ROW_HEIGHT: f64 = 24.0;

/// Give Application…'s list, over the conversation: a heading and a row
/// per running application.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentPickerLayout {
    pub panel: Rect,
    pub rows: Vec<Rect>,
}

impl AgentPickerLayout {
    pub fn new(area: Rect, count: usize) -> AgentPickerLayout {
        let h = (area.h - 20.0).min(44.0 + count.max(1) as f64 * PICKER_ROW_HEIGHT);
        AgentPickerLayout {
            panel: Rect::new(area.x + 20.0, area.y + 10.0, area.w - 40.0, h),
            rows: (0..count).map(|i| Rect::new(area.x + 30.0, area.y + 46.0 + i as f64 * PICKER_ROW_HEIGHT, area.w - 60.0, PICKER_ROW_HEIGHT - 2.0)).collect(),
        }
    }

    pub fn hit(&self, x: f64, y: f64) -> Option<usize> {
        self.rows.iter().position(|r| r.contains(x, y))
    }
}

fn panel(c: &mut Canvas, r: Rect) {
    c.set_color(c.theme.tokens.content_background);
    c.cr.rectangle(r.x, r.y, r.w, r.h);
    c.cr.fill();
    c.set_color(Color::new(0.6, 0.6, 0.6, 1.0));
    c.cr.set_line_width(1.0);
    c.cr.rectangle(r.x + 0.5, r.y + 0.5, r.w - 1.0, r.h - 1.0);
    c.cr.stroke()
}

pub fn paint_agent_picker(c: &mut Canvas, area: Rect, names: &[String], title: Option<&str>) -> AgentPickerLayout {
    let l = AgentPickerLayout::new(area, names.len());
    panel(c, l.panel);
    let t = c.theme.tokens.clone();
    let heading = if names.is_empty() { "No other application is running." } else { title.unwrap_or("Give an application to the agent:") };
    c.text_left(heading, l.panel.x + 10.0, l.panel.y + 22.0, t.body_text, t.font_size, Style::Bold, Role::Interface);
    for (name, r) in names.iter().zip(&l.rows) {
        c.set_color(Color::new(1.0, 1.0, 1.0, 1.0));
        c.cr.rectangle(r.x, r.y, r.w, r.h);
        c.cr.fill();
        c.text_left(name, r.x + 10.0, r.y + 16.0, t.body_text, t.font_size, Style::Regular, Role::Interface)
    }
    l
}

/// A requester over the conversation (P18.11): what it asks, why, and two
/// buttons; the one that lets the agent go on is the default.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AgentRequesterLayout {
    pub panel: Rect,
    pub stop: Rect,
    pub allow: Rect,
}

impl AgentRequesterLayout {
    pub fn new(area: Rect) -> AgentRequesterLayout {
        let panel = Rect::new(area.x + 20.0, area.y + 10.0, area.w - 40.0, 120.0);
        let allow = Rect::new(panel.x + panel.w - 112.0, panel.y + panel.h - 34.0, 100.0, 22.0);
        AgentRequesterLayout { panel, stop: Rect::new(allow.x - 92.0, allow.y, 80.0, 22.0), allow }
    }
}

/// What a requester says: its title, its body, and its two buttons.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequesterText {
    pub title: String,
    pub body: String,
    pub no: String,
    pub yes: String,
}

pub fn paint_agent_requester(c: &mut Canvas, area: Rect, r: &RequesterText) -> AgentRequesterLayout {
    let l = AgentRequesterLayout::new(area);
    panel(c, l.panel);
    let body_text = c.theme.tokens.body_text;
    c.text_left(&r.title, l.panel.x + 12.0, l.panel.y + 22.0, body_text, 13.0, Style::Bold, Role::Interface);
    let mut y = l.panel.y + 42.0;
    for line in c.wrap_words(&r.body, l.panel.w - 24.0, 11.0, Style::Regular).into_iter().take(3) {
        c.text_left(&line, l.panel.x + 12.0, y, body_text, 11.0, Style::Regular, Role::Interface);
        y += 15.0
    }
    c.gel_button(l.stop, &r.no, false, false);
    c.gel_button(l.allow, &r.yes, true, false);
    l
}

/// What the window shows besides its conversation.
pub struct AgentScene<'a> {
    pub status: &'a str,
    pub field: &'a str,
    pub caret: bool,
    pub can_ask: bool,
    pub picker: Option<&'a [String]>,
    pub picker_title: Option<&'a str>,
    pub requester: Option<RequesterText>,
}

/// The window, from its state: so the golden image is the live window.
pub fn paint_agent_window(c: &mut Canvas, w: f64, h: f64, conversation: &mut TextView, s: &AgentScene) -> AgentLayout {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, "Agent", false, true);
    let t = c.theme.tokens.clone();
    c.set_color(t.content_background);
    c.cr.rectangle(0.0, t.title_bar_height, w, h - t.title_bar_height);
    c.cr.fill();
    let l = AgentLayout::new(t.title_bar_height, w, h);
    conversation.set_frame(l.conversation);
    conversation.caret_on = false;
    conversation.paint(c, false);
    if let Some(p) = s.picker {
        paint_agent_picker(c, l.conversation, p, s.picker_title);
    }
    if let Some(r) = &s.requester {
        paint_agent_requester(c, l.conversation, r);
    }
    c.text_left(s.status, 12.0, l.status_baseline, t.body_text, t.font_size, Style::Regular, Role::Interface);
    c.text_field(l.field, s.field, s.caret, if s.can_ask { "Ask the agent…" } else { "" });
    c.gel_button(l.ask, "Ask", s.can_ask && !s.field.is_empty(), false);
    l
}

/// A turn of the conversation, in the three pieces the window writes as
/// they happen: the question at once, each tool call as it starts, the
/// answer.
pub fn question_line(q: &str) -> String {
    format!("You: {q}\n")
}
pub fn call_line(c: &str) -> String {
    format!("  › {c}\n")
}
pub fn answer_line(a: &str) -> String {
    format!("Agent: {a}\n\n")
}

/// A whole turn: what the pieces add up to.
pub fn agent_turn(question: &str, calls: &[&str], answer: &str) -> String {
    question_line(question) + &calls.iter().map(|c| call_line(c)).collect::<String>() + &answer_line(answer)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Starting,
    Ready,
    Asking,
    Ended,
}

/// What the window is asking the person (P18.11).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AgentAsk {
    /// Requester 4: the budget is spent; abyss-model's words.
    Budget(String),
    /// Requester 1: the agent's first command this session that writes one
    /// of the person's files, with this application.
    Write { app: String, verb: String, title: String },
    /// Requester 3 (P18.12b): the agent's first fetch from this host.
    Host { host: String, url: String },
}

impl AgentAsk {
    pub fn text(&self, budget: u64) -> RequesterText {
        let rt = |t: String, b: String, no: &str, yes: &str| RequesterText { title: t, body: b, no: no.into(), yes: yes.into() };
        match self {
            AgentAsk::Budget(why) => rt("The agent has used its budget.".into(), budget_question(why, budget), "Stop", "Allow More"),
            AgentAsk::Write { app, verb, title } => rt(
                format!("Allow the agent to write with {app}?"),
                format!("It wants to {} ({verb}) in {app}: the first time it would write one of your files this session. Allow {app} to write for it until the session ends?", title.replace('…', "")),
                "Don't Allow",
                "Allow",
            ),
            AgentAsk::Host { host, url } => rt(
                format!("Allow the agent to reach {host}?"),
                format!("It wants to fetch {url}: the first time it would reach {host} this session. Allow it to fetch from {host} until the session ends?"),
                "Don't Allow",
                "Allow",
            ),
        }
    }
}

/// Requester 4's question: abyss-model's words, as a sentence, and the ask.
pub fn budget_question(why: &str, budget: u64) -> String {
    let mut chars = why.chars();
    let said: String = chars.next().map(|f| f.to_uppercase().chain(chars).collect()).unwrap_or_default();
    format!("{said}. Let it use another {budget} tokens and carry on?")
}

/// What the window says of its session to the rest of the desktop
/// (P18.13b), or None while it has none (starting, or ended). A requester
/// up is waiting, whatever the phase; a question out is working; otherwise
/// idle.
pub fn presence_state(phase: Phase, requester: Option<&AgentAsk>) -> Option<AgentState> {
    match phase {
        Phase::Starting | Phase::Ended => None,
        _ if requester.is_some() => Some(AgentState::Waiting),
        Phase::Asking => Some(AgentState::Working),
        Phase::Ready => Some(AgentState::Idle),
    }
}

/// What a session's presence is about: what the requester asks, else the
/// question.
pub fn presence_about(requester: Option<&AgentAsk>, asked: &str) -> String {
    match requester {
        Some(AgentAsk::Budget(_)) => "Allow more tokens?".into(),
        Some(AgentAsk::Write { app, .. }) => format!("Allow {app} to write?"),
        Some(AgentAsk::Host { host, .. }) => format!("Allow it to reach {host}?"),
        None => asked.into(),
    }
}

/// The golden's window: a fixed conversation, and the field with the next
/// question being typed. `AQUA_AGENT_PICKER=1`: Give Application…'s list
/// open over it; `AQUA_AGENT_REQUESTER=1`: the budget requester; `=write`,
/// the first write's (P18.11).
pub fn paint_sample(c: &mut Canvas, w: f64, h: f64) {
    let text = agent_turn("What do I need to do on Monday?", &[r#"list_directory({"path":"/home/abyss"})"#, r#"read_file({"path":"/home/abyss/notes.txt"})"#], "Call the plumber about the kitchen tap.");
    let mut view = TextView::new(&text, &mut c.runner.text);
    let picker = std::env::var_os("AQUA_AGENT_PICKER").is_some();
    let asking_what = std::env::var("AQUA_AGENT_REQUESTER").ok();
    let asking = asking_what.is_some();
    let write = asking_what.as_deref() == Some("write");
    let ask = if write { AgentAsk::Write { app: "TextEdit".into(), verb: "file.save".into(), title: "Save".into() } } else { AgentAsk::Budget("the session's budget of 200000 tokens is spent (200412 used)".into()) };
    let names: Vec<String> = ["Activity Monitor", "Grab", "TextEdit"].map(String::from).into();
    let status = if write {
        "The agent is asking to write with TextEdit."
    } else if asking {
        "The agent's budget is spent."
    } else {
        "Confined in agent: no network; only what you grant it."
    };
    let scene = AgentScene {
        status,
        field: if picker || asking { "" } else { "And on Tuesday?" },
        caret: !picker && !asking,
        can_ask: !asking,
        picker: picker.then_some(&names[..]),
        picker_title: None,
        requester: asking.then(|| ask.text(200000)),
    };
    paint_agent_window(c, w, h, &mut view, &scene);
}

fn log(s: &str) {
    eprintln!("Agent: {s}")
}

// MARK: - The application

struct State {
    phase: Phase,
    status: String,
    field: String,
    caret_on: bool,
    agent_socket: String,
    asked: String,
    /// What was last said to the desktop, so a redraw does not rewrite it.
    presence: Option<AgentPresence>,
    calls_so_far: u32,
    /// The keeper's session ID (for a give), and whether the session can
    /// be given applications at all: `debug` cannot.
    session_id: String,
    has_vocabulary: bool,
    given: Vec<String>,
    /// Give Application…'s list while it is open: names and their services.
    picking: Option<Vec<(String, String)>>,
    /// Whether the open list is Take Back Application…'s.
    picking_to_take: bool,
    /// The session's budget: what Allow More allows again (P18.11).
    session_budget: u64,
    /// The requester, while it is up (P18.11).
    requester: Option<AgentAsk>,
    logged_requester: bool,
    logged_picker: bool,
    logged: bool,
}

pub struct AgentApp {
    me: Weak<AgentApp>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    window: RefCell<Option<Rc<Window>>>,
    conversation: RefCell<TextView>,
    state: RefCell<State>,
    /// The question's connection, while it is out: the agent's events come
    /// on it, and a requester's answer goes back on it.
    stream: RefCell<Option<Rc<UnixStream>>>,
    pointer: Cell<(f64, f64)>,
    menu_service: RefCell<Option<MenuService>>,
    menu_name: String,
    agent_class: String,
    /// What Quit does once the session is told; by default, the process ends.
    pub on_quit: RefCell<Box<dyn Fn()>>,
}

struct Provider<'a>(&'a AgentApp);

impl MenuProvider for Provider<'_> {
    fn menu_model(&self) -> MenuBarModel {
        agent_menu_bar()
    }
    fn menu_validate(&self, c: &Command) -> Enablement {
        self.0.validate(&c.verb)
    }
    fn menu_perform(&mut self, c: &Command, a: &BTreeMap<String, String>) -> CommandResult {
        if let Enablement::Disabled(why) = self.0.validate(&c.verb) {
            return CommandResult::Refused(why);
        }
        let arg = |n: &str| a.get(n).cloned().unwrap_or_default();
        match c.verb.as_str() {
            VERB_GIVE => self.0.give(&arg("app")),
            VERB_TAKE => self.0.take(&arg("app")),
            VERB_QUESTION => {
                self.0.state.borrow_mut().field = arg("text");
                self.0.redraw();
                return self.0.perform(VERB_ASK);
            }
            v => return self.0.perform(v),
        }
        CommandResult::Ok(None)
    }
}

impl AgentApp {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Option<Rc<AgentApp>> {
        let menu_name = menu_wire::service_name("Agent", std::process::id() as i32);
        let conversation = TextView::new("", &mut toolkit.runner.borrow_mut().text);
        let state = State {
            phase: Phase::Starting,
            status: String::new(),
            field: String::new(),
            caret_on: true,
            agent_socket: String::new(),
            asked: String::new(),
            presence: None,
            calls_so_far: 0,
            session_id: String::new(),
            has_vocabulary: false,
            given: vec![],
            picking: None,
            picking_to_take: false,
            session_budget: 0,
            requester: None,
            logged_requester: false,
            logged_picker: false,
            logged: false,
        };
        let app = Rc::new_cyclic(|me| AgentApp {
            me: me.clone(),
            display: display.clone(),
            toolkit: toolkit.clone(),
            window: RefCell::new(None),
            conversation: RefCell::new(conversation),
            state: RefCell::new(state),
            stream: RefCell::new(None),
            pointer: Cell::new((0.0, 0.0)),
            menu_service: RefCell::new(None),
            menu_name: menu_name.clone(),
            agent_class: std::env::var("ABYSS_AGENT_CLASS").unwrap_or_else(|_| "agent".into()),
            on_quit: RefCell::new(Box::new(|| std::process::exit(0))),
        });
        if let Ok(s) = MenuService::new(&menu_name) {
            let me = app.me.clone();
            display.add_fd(s.fd(), move || {
                if let Some(a) = me.upgrade() {
                    a.serve()
                }
            });
            *app.menu_service.borrow_mut() = Some(s);
        }
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let win = Window::new(display, "Agent", "org.abyssbsd.agent", 560, 460, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&app) as Weak<dyn WindowDelegate>)?;
        if app.menu_service.borrow().is_some() && win.publish_menus(&menu_name) {
            log(&format!("menus on {menu_name}"))
        }
        *app.window.borrow_mut() = Some(win);
        let me = app.me.clone();
        display.add_timer(500, move || {
            let Some(a) = me.upgrade() else { return };
            {
                let mut s = a.state.borrow_mut();
                if s.phase != Phase::Ready {
                    return;
                }
                s.caret_on = !s.caret_on
            }
            a.redraw()
        });
        app.start_session();
        Some(app)
    }

    fn serve(&self) {
        let svc = self.menu_service.borrow_mut().take();
        let Some(mut svc) = svc else { return };
        svc.service_readable(&mut Provider(self));
        *self.menu_service.borrow_mut() = Some(svc)
    }

    fn redraw(&self) {
        if let Some(w) = self.window.borrow().as_ref() {
            w.set_needs_display()
        }
    }

    pub fn phase(&self) -> Phase {
        self.state.borrow().phase
    }

    // MARK: state that the desktop hears of

    fn set_status(&self, s: String) {
        self.state.borrow_mut().status = s;
        self.redraw()
    }

    fn set_phase(&self, p: Phase) {
        self.state.borrow_mut().phase = p;
        self.publish_presence()
    }

    fn set_requester(&self, r: Option<AgentAsk>) {
        {
            let mut s = self.state.borrow_mut();
            s.logged_requester = false;
            s.requester = r;
        }
        self.publish_presence();
        self.redraw()
    }

    /// Say this session's state to the Dock, the menu bar and the island
    /// menu (P18.13b), when it changes; withdraw it when there is none.
    fn publish_presence(&self) {
        let mut s = self.state.borrow_mut();
        let pid = std::process::id() as i32;
        let Some(state) = presence_state(s.phase, s.requester.as_ref()) else {
            if s.presence.take().is_some() {
                presence_io::withdraw(pid);
                log("presence: none")
            }
            return;
        };
        let p = AgentPresence::new(pid, state, &presence_about(s.requester.as_ref(), &s.asked));
        if s.presence.as_ref() == Some(&p) {
            return;
        }
        presence_io::publish(&p);
        log(&format!("presence: {} — {}", state.name(), p.about));
        s.presence = Some(p)
    }

    fn ready_status(&self) -> String {
        if self.agent_class == "debug" {
            return "Confined in debug: one crash, read-only; no network.".into();
        }
        let given = &self.state.borrow().given;
        format!("Confined in {}: no network; {}", self.agent_class, if given.is_empty() { "only what you grant it.".into() } else { format!("given {}.", given.join(", ")) })
    }

    fn append(&self, text: &str) {
        self.conversation.borrow_mut().edit(|m| {
            m.move_caret(Motion::DocumentEnd, false);
            m.insert(text, EditKind::Other("append".into()))
        });
        self.redraw()
    }

    // MARK: talking to the keeper

    /// Send `m` to the keeper on a new connection, and hand the reply to
    /// `then` when it comes. False when it could not be sent.
    fn request(&self, m: &Msg, then: impl FnOnce(&AgentApp, Option<Msg>) + 'static) -> bool {
        let Ok(sock) = current_ipc::connect(KEEPER) else { return false };
        if current_ipc::send(m, &sock).is_err() {
            return false;
        }
        let fd = sock.as_raw_fd();
        let (me, display, slot) = (self.me.clone(), Rc::downgrade(&self.display), RefCell::new(Some((sock, then))));
        self.display.add_fd(fd, move || {
            let Some((sock, then)) = slot.borrow_mut().take() else { return };
            let reply = current_ipc::receive(&sock).ok();
            if let Some(d) = display.upgrade() {
                d.remove_fd(fd)
            }
            drop(sock);
            if let Some(a) = me.upgrade() {
                then(&a, reply)
            }
        });
        true
    }

    fn start_session(&self) {
        // A session already started for it (a crash's debug session): use
        // it, and ask what it was opened to ask.
        if let Ok(given) = std::env::var("ABYSS_AGENT_SOCKET")
            && !given.is_empty()
        {
            self.state.borrow_mut().agent_socket = given.clone();
            self.set_phase(Phase::Ready);
            self.set_status(self.ready_status());
            log(&format!("session (given) at {given}"));
            if let Ok(q) = std::env::var("ABYSS_AGENT_ASK")
                && !q.is_empty()
            {
                self.state.borrow_mut().field = q;
                self.ask()
            }
            return;
        }
        self.set_status(format!("Starting an agent in {}…", self.agent_class));
        let mut m = Msg::new();
        m.set_string("method", "agent");
        m.set_string("class", &self.agent_class);
        let sent = self.request(&m, |a, r| {
            let sock = r.as_ref().filter(|r| r.bool("ok") == Some(true)).and_then(|r| r.string("socket")).map(String::from);
            let (Some(r), Some(sock)) = (r.as_ref(), sock) else {
                a.set_phase(Phase::Ended);
                a.set_status(format!("No agent: {}", keeper_error(r.as_ref())));
                log(&format!("refused: {}", a.state.borrow().status));
                return;
            };
            {
                let mut s = a.state.borrow_mut();
                s.agent_socket = sock.clone();
                s.session_id = r.string("session").unwrap_or("").into();
                s.has_vocabulary = r.bool("vocabulary").unwrap_or(false);
                s.session_budget = r.u64("budget").unwrap_or(0);
            }
            a.set_phase(Phase::Ready);
            a.set_status(a.ready_status());
            log(&format!("session {} at {sock}", r.string("session").unwrap_or("")));
        });
        if !sent {
            self.set_phase(Phase::Ended);
            self.set_status("No agent: the session's jails are not running.".into());
            log(&format!("refused: {}", self.state.borrow().status))
        }
    }

    // MARK: giving applications (P18.10b)

    /// Every other running application that publishes a vocabulary, by its
    /// own name. **Never this window itself**: asked while it is answering
    /// a menu request of its own, it would wait on itself until the timeout.
    fn running_applications(&self) -> Vec<(String, String)> {
        let mut apps: Vec<(String, String)> = menu_wire::client::services()
            .into_iter()
            .filter(|s| *s != self.menu_name)
            .filter_map(|s| menu_wire::client::describe(&s, None).ok().map(|(m, _)| (m.app_name, s)))
            .collect();
        apps.sort_by_key(|a| a.0.to_lowercase());
        apps
    }

    fn open_picker(&self, to_take: bool) {
        let list = if to_take { self.state.borrow().given.iter().map(|g| (g.clone(), String::new())).collect() } else { self.running_applications() };
        let names: Vec<&str> = list.iter().map(|(n, _)| n.as_str()).collect();
        log(&format!("picker{} {}", if to_take { " (take)" } else { "" }, names.join(", ")));
        {
            let mut s = self.state.borrow_mut();
            s.picking_to_take = to_take;
            s.picking = Some(list);
            s.logged_picker = false;
        }
        self.redraw()
    }

    /// Ask the keeper to give `app` (a name or a menu service) to this
    /// session; the answer comes through the poll loop.
    fn give(&self, app: &str) {
        let session = {
            let mut s = self.state.borrow_mut();
            s.picking = None;
            s.session_id.clone()
        };
        let mut m = Msg::new();
        m.set_string("method", "give");
        m.set_string("session", &session);
        m.set_string("app", app);
        let sent = self.request(&m, |a, r| {
            let Some(name) = r.as_ref().filter(|r| r.bool("ok") == Some(true)).and_then(|r| r.string("app")).map(String::from) else {
                a.set_status(format!("Not given: {}", keeper_error(r.as_ref())));
                log(&format!("give refused: {}", a.state.borrow().status));
                return;
            };
            {
                let mut s = a.state.borrow_mut();
                if !s.given.contains(&name) {
                    s.given.push(name.clone())
                }
            }
            a.append(&format!("  (you gave the agent {name})\n"));
            if a.phase() == Phase::Ready {
                a.set_status(a.ready_status())
            }
            log(&format!("gave {name}"))
        });
        if !sent {
            self.state.borrow_mut().status = "Not given: the session's jails are not running.".into()
        }
        self.redraw()
    }

    /// Take `app` back (P18.11): the keeper tells the session's bridge,
    /// which refuses it from now on.
    fn take(&self, app: &str) {
        let session = {
            let mut s = self.state.borrow_mut();
            s.picking = None;
            s.picking_to_take = false;
            s.session_id.clone()
        };
        let mut m = Msg::new();
        m.set_string("method", "take");
        m.set_string("session", &session);
        m.set_string("app", app);
        let app = app.to_string();
        let sent = self.request(&m, move |a, r| {
            if r.as_ref().and_then(|r| r.bool("ok")) != Some(true) {
                a.set_status(format!("Not taken back: {}", keeper_error(r.as_ref())));
                log(&format!("take refused: {}", a.state.borrow().status));
                return;
            }
            a.state.borrow_mut().given.retain(|g| g.to_lowercase() != app.to_lowercase());
            a.append(&format!("  (you took {app} back)\n"));
            if a.phase() == Phase::Ready {
                a.set_status(a.ready_status())
            }
            log(&format!("took {app} back"))
        });
        if !sent {
            self.state.borrow_mut().status = "Not taken back: the session's jails are not running.".into()
        }
        self.redraw()
    }

    // MARK: talking to the agent

    pub fn ask(&self) {
        let q = {
            let mut s = self.state.borrow_mut();
            let q = s.field.trim_matches(' ').to_string();
            if s.phase != Phase::Ready || q.is_empty() {
                return;
            }
            s.field.clear();
            s.asked = q.clone();
            q
        };
        self.publish_presence();
        self.append(&question_line(&q));
        log(&format!("asked: {q}"));
        let mut m = Msg::new();
        m.set_string("method", "ask");
        m.set_string("text", &q);
        self.stream_to_agent(&m)
    }

    /// Carry on from where the budget stopped it (P18.11), once the person
    /// allowed more: the same question, not asked again.
    fn resume(&self) {
        let mut m = Msg::new();
        m.set_string("method", "continue");
        log("continued");
        self.stream_to_agent(&m)
    }

    /// Send `m` to the agent, and take its events (a tool call as it
    /// starts, a permission it waits on) and then its reply through the
    /// poll loop.
    fn stream_to_agent(&self, m: &Msg) {
        let path = self.state.borrow().agent_socket.clone();
        let Some(sock) = current_ipc::connect_path(&path).ok().filter(|s| current_ipc::send(m, s).is_ok()) else {
            self.set_phase(Phase::Ended);
            return self.set_status("The agent is gone.".into());
        };
        self.state.borrow_mut().calls_so_far = 0;
        self.set_phase(Phase::Asking);
        self.set_status("Thinking…".into());
        let sock = Rc::new(sock);
        let fd = sock.as_raw_fd();
        *self.stream.borrow_mut() = Some(sock.clone());
        let me = self.me.clone();
        self.display.add_fd(fd, move || {
            let Some(a) = me.upgrade() else { return };
            let r = current_ipc::receive(&sock).ok();
            match r.as_ref().and_then(|r| r.string("event")) {
                Some("permission") => return a.permission_asked(r.as_ref().unwrap()),
                Some("call") => return a.called(r.as_ref().unwrap().string("call").unwrap_or("")),
                _ => {}
            }
            a.display.remove_fd(fd);
            *a.stream.borrow_mut() = None;
            a.answered(r)
        })
    }

    /// Requesters 1 and 3: the agent waits, on the question's connection,
    /// for the person's answer.
    fn permission_asked(&self, r: &Msg) {
        let s = |n: &str| r.string(n).unwrap_or("").to_string();
        if r.string("kind") == Some("host") {
            let host = s("host");
            log(&format!("requester host: {host}"));
            self.set_requester(Some(AgentAsk::Host { host: host.clone(), url: s("url") }));
            self.set_status(format!("The agent is asking to reach {host}."))
        } else {
            let (app, verb) = (s("app"), s("verb"));
            log(&format!("requester write: {app} {verb}"));
            let title = r.string("title").map(String::from).unwrap_or_else(|| verb.clone());
            self.set_requester(Some(AgentAsk::Write { app: app.clone(), verb, title }));
            self.set_status(format!("The agent is asking to write with {app}."))
        }
    }

    fn called(&self, call: &str) {
        let n = {
            let mut s = self.state.borrow_mut();
            s.calls_so_far += 1;
            s.calls_so_far
        };
        self.append(&call_line(call));
        self.set_status(format!("Thinking… ({n} tool call{} so far)", if n == 1 { "" } else { "s" }));
        log(&format!("call {call}"))
    }

    fn answered(&self, r: Option<Msg>) {
        let Some(r) = r.filter(|r| r.bool("ok") == Some(true)) else {
            self.set_phase(Phase::Ended);
            self.set_status("The agent is gone.".into());
            return log("the agent did not answer");
        };
        let calls = String::from_utf8_lossy(r.bytes("calls").unwrap_or(&[])).split('\n').filter(|l| !l.is_empty()).count();
        let text = r.string("text").unwrap_or("").to_string();
        let stop = r.string("stop").unwrap_or("failed").to_string();
        self.append(&answer_line(if stop == "answered" { &text } else { "(stopped)" }));
        match stop.as_str() {
            "answered" => {
                self.set_phase(Phase::Ready);
                self.set_status(self.ready_status())
            }
            // Requester 4 (P18.11): the person decides, in the window, where
            // they can: a session the keeper started, whose model it can raise.
            "budget" if !self.state.borrow().session_id.is_empty() => {
                log(&format!("requester budget: {text}"));
                self.set_phase(Phase::Asking);
                self.set_requester(Some(AgentAsk::Budget(text)));
                self.set_status("The agent's budget is spent.".into())
            }
            "budget" => {
                self.set_phase(Phase::Ended);
                self.set_status(format!("Stopped: {text}"))
            }
            "steps" => {
                self.set_phase(Phase::Ready);
                self.set_status(format!("Stopped: {text}"))
            }
            _ => {
                self.set_phase(Phase::Ready);
                self.set_status(format!("Failed: {text}"))
            }
        }
        log(&format!("answered: stop={stop} calls={calls} steps={}", r.u64("steps").unwrap_or(0)))
    }

    // MARK: requesters 1 and 3: the first write, the first host (P18.11, P18.12b)

    /// The person's answer to a write or host requester: told to the keeper
    /// (which tells the bridge, outside the jail) first, then to the agent,
    /// waiting on the question's connection, so it may try again.
    fn answer_permission(&self, allow: bool) {
        let asked = self.state.borrow().requester.clone();
        let (method, key, what) = match &asked {
            Some(AgentAsk::Write { app, .. }) => ("permit", "app", app.clone()),
            Some(AgentAsk::Host { host, .. }) => ("permit-host", "host", host.clone()),
            _ => return,
        };
        self.set_requester(None);
        let session = self.state.borrow().session_id.clone();
        let mut m = Msg::new();
        m.set_string("method", method);
        m.set_string("session", &session);
        m.set_string(key, &what);
        m.set_bool("allow", allow);
        let is_write = method == "permit";
        self.set_status(match (allow, is_write) {
            (true, true) => format!("Allowing {what} to write…"),
            (true, false) => format!("Allowing {what}…"),
            (false, _) => "Thinking…".into(),
        });
        let what2 = what.clone();
        let sent = self.request(&m, move |a, r| {
            let told = r.and_then(|r| r.bool("ok")) == Some(true);
            a.tell_agent(allow && told);
            a.set_status("Thinking…".into());
            log(&match (allow && told, is_write) {
                (true, true) => format!("allowed {what2} to write"),
                (false, true) => format!("did not allow {what2} to write"),
                (true, false) => format!("allowed {what2}"),
                (false, false) => format!("did not allow {what2}"),
            })
        });
        if !sent {
            self.tell_agent(false)
        }
        self.redraw()
    }

    /// The answer, to the agent waiting on the question's connection.
    fn tell_agent(&self, allow: bool) {
        if let Some(s) = self.stream.borrow().as_ref() {
            let mut a = Msg::new();
            a.set_string("method", "answer");
            a.set_bool("allow", allow);
            let _ = current_ipc::send(&a, s);
        }
    }

    fn answer_yes(&self) {
        let budget = matches!(self.state.borrow().requester, Some(AgentAsk::Budget(_)));
        if budget { self.allow_more() } else { self.answer_permission(true) }
    }

    fn answer_no(&self) {
        let budget = matches!(self.state.borrow().requester, Some(AgentAsk::Budget(_)));
        if budget { self.stop_asked() } else { self.answer_permission(false) }
    }

    // MARK: requester 4: the budget (P18.11)

    /// Let it use another budget's worth: the keeper raises abyss-model's
    /// budget, and the agent carries on.
    fn allow_more(&self) {
        let (session, budget) = {
            let s = self.state.borrow();
            (s.session_id.clone(), s.session_budget)
        };
        self.set_requester(None);
        let mut m = Msg::new();
        m.set_string("method", "raise");
        m.set_string("session", &session);
        m.set_u64("tokens", budget.max(1));
        self.set_status("Allowing more…".into());
        let sent = self.request(&m, move |a, r| {
            let Some(r) = r.as_ref().filter(|r| r.bool("ok") == Some(true)) else {
                a.set_phase(Phase::Ended);
                a.set_status(format!("Not allowed: {}", keeper_error(r.as_ref())));
                return log(&format!("raise refused: {}", a.state.borrow().status));
            };
            log(&format!("allowed {budget} more (budget {})", r.u64("budget").unwrap_or(0)));
            a.resume()
        });
        if !sent {
            self.set_phase(Phase::Ended);
            self.set_status("Not allowed: the session's jails are not running.".into())
        }
    }

    fn stop_asked(&self) {
        let Some(AgentAsk::Budget(why)) = self.state.borrow().requester.clone() else { return };
        self.set_requester(None);
        self.set_phase(Phase::Ended);
        self.set_status(format!("Stopped: {why}"));
        log("stopped by the person")
    }

    pub fn quit(&self) {
        presence_io::withdraw(std::process::id() as i32);
        let path = self.state.borrow().agent_socket.clone();
        if !path.is_empty()
            && let Ok(s) = current_ipc::connect_path(&path)
        {
            let mut m = Msg::new();
            m.set_string("method", "bye");
            let _ = current_ipc::send(&m, &s);
            let _ = current_ipc::receive(&s);
            log("bye")
        }
        (self.on_quit.borrow())()
    }

    // MARK: the menu

    fn validate(&self, verb: &str) -> Enablement {
        let s = self.state.borrow();
        let off = |why: &str| Enablement::Disabled(why.into());
        match verb {
            VERB_ABOUT => off("Agent has no About box yet"),
            // Enabled whenever the agent can be asked; an empty field is
            // refused when run, with its reason (enablement is checked
            // before the arguments are seen).
            VERB_ASK | VERB_QUESTION => match s.phase {
                Phase::Ready => Enablement::Enabled,
                Phase::Asking => off("the agent is answering"),
                _ => off("there is no agent"),
            },
            VERB_ALLOW | VERB_STOP if s.requester.is_none() => off("nothing is being asked"),
            VERB_TAKE_APP | VERB_TAKE if s.given.is_empty() => off("nothing was given"),
            VERB_GIVE_APP | VERB_GIVE if s.session_id.is_empty() => off(if s.phase == Phase::Starting { "there is no agent yet" } else { "this session cannot be given applications" }),
            VERB_GIVE_APP | VERB_GIVE if !s.has_vocabulary => Enablement::Disabled(format!("{} sessions drive no applications", self.agent_class)),
            _ => Enablement::Enabled,
        }
    }

    fn perform(&self, verb: &str) -> CommandResult {
        match verb {
            VERB_QUIT => self.quit(),
            VERB_ASK => {
                let (phase, empty) = {
                    let s = self.state.borrow();
                    (s.phase, s.field.trim_matches(' ').is_empty())
                };
                if phase != Phase::Ready {
                    return CommandResult::Refused("there is no agent".into());
                }
                if empty {
                    return CommandResult::Refused("the field is empty".into());
                }
                self.ask()
            }
            VERB_CLEAR => {
                self.state.borrow_mut().field.clear();
                self.redraw()
            }
            VERB_GIVE_APP => self.open_picker(false),
            VERB_TAKE_APP => self.open_picker(true),
            VERB_ALLOW => self.answer_yes(),
            VERB_STOP => self.answer_no(),
            VERB_MINIMIZE => {
                if let Some(w) = self.window.borrow().as_ref() {
                    w.minimize();
                }
            }
            _ => return CommandResult::Refused(format!("Agent has no verb {verb}")),
        }
        CommandResult::Ok(None)
    }

    fn close_picker(&self) {
        self.state.borrow_mut().picking = None;
        self.redraw()
    }
}

fn keeper_error(r: Option<&Msg>) -> String {
    r.and_then(|r| r.string("error")).unwrap_or("the session's jails did not answer").to_string()
}

fn mid(r: Rect) -> String {
    format!("{},{}", (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64)
}

impl WindowDelegate for AgentApp {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let mut s = self.state.borrow_mut();
        let names: Option<Vec<String>> = s.picking.as_ref().map(|p| p.iter().map(|(n, _)| n.clone()).collect());
        let scene = AgentScene {
            status: &s.status,
            field: &s.field,
            caret: s.phase == Phase::Ready && s.caret_on && s.picking.is_none(),
            can_ask: s.phase == Phase::Ready,
            picker: names.as_deref(),
            picker_title: s.picking_to_take.then_some("Take an application back:"),
            requester: s.requester.as_ref().map(|r| r.text(s.session_budget)),
        };
        let mut conv = self.conversation.borrow_mut();
        let l = self.toolkit.draw(target, |c, w, h| paint_agent_window(c, w, h, &mut conv, &scene));
        if s.requester.is_some() && !s.logged_requester {
            s.logged_requester = true;
            let r = AgentRequesterLayout::new(l.conversation);
            log(&format!("requester stop={} allow={}", mid(r.stop), mid(r.allow)))
        }
        if let Some(n) = &names
            && !s.logged_picker
        {
            s.logged_picker = true;
            let rows = AgentPickerLayout::new(l.conversation, n.len()).rows;
            let at: Vec<String> = n.iter().zip(rows).map(|(n, r)| format!("{}={}", n.replace(' ', "_"), mid(r))).collect();
            log(&format!("picker rows {}", at.join(" ")))
        }
        if !s.logged {
            s.logged = true;
            log(&format!("layout field={} ask={}", mid(l.field), mid(l.ask)))
        }
    }

    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        self.pointer.set((x, y))
    }

    fn pointer_button(&self, w: &Window, _button: u32, pressed: bool) {
        if !pressed {
            return;
        }
        let (x, y) = self.pointer.get();
        let (sw, sh) = w.size();
        let t = self.toolkit.theme.borrow().tokens.clone();
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(Gadget::Close) => return self.quit(),
            ChromeHit::Gadget(Gadget::Minimize) => {
                w.minimize();
                return;
            }
            ChromeHit::Gadget(Gadget::Depth) => {
                w.lower();
                return;
            }
            ChromeHit::Title => return w.begin_move(),
            _ => {}
        }
        let layout = AgentLayout::new(t.title_bar_height, sw as f64, sh as f64);
        if self.state.borrow().requester.is_some() {
            let r = AgentRequesterLayout::new(layout.conversation);
            if r.allow.contains(x, y) {
                self.answer_yes()
            } else if r.stop.contains(x, y) {
                self.answer_no()
            }
            return;
        }
        let picking = self.state.borrow().picking.clone();
        if let Some(p) = picking {
            match AgentPickerLayout::new(layout.conversation, p.len()).hit(x, y) {
                Some(i) if self.state.borrow().picking_to_take => self.take(&p[i].0),
                Some(i) => self.give(&p[i].1),
                None => self.close_picker(),
            }
            return;
        }
        if layout.ask.contains(x, y) {
            self.ask()
        }
    }

    fn pointer_axis(&self, _w: &Window, axis: u32, value: f64) {
        if axis == 0 {
            self.conversation.borrow_mut().scroll_by(value);
            self.redraw()
        }
    }

    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        if !e.pressed {
            return;
        }
        if e.modifiers.contains(KeyModifiers::COMMAND) {
            if let Some(verb) = key_equivalent_of(e).and_then(|k| agent_menu_bar().verb_for(&k).map(String::from)) {
                self.perform(&verb);
            }
            return;
        }
        if self.state.borrow().requester.is_some() {
            match e.keysym {
                KeySym::ENTER => self.answer_yes(),
                KeySym::ESCAPE => self.answer_no(),
                _ => {}
            }
            return;
        }
        if self.state.borrow().picking.is_some() {
            if e.keysym == KeySym::ESCAPE {
                self.close_picker()
            }
            return;
        }
        if self.phase() != Phase::Ready {
            return;
        }
        if e.keysym == KeySym::ENTER {
            self.ask()
        } else {
            let mut s = self.state.borrow_mut();
            if e.keysym == KeySym::BACKSPACE {
                s.field.pop();
            } else if !e.text.is_empty() && e.text.chars().all(|c| c >= ' ' && c != '\u{7f}') {
                s.field.push_str(&e.text)
            }
        }
        self.state.borrow_mut().caret_on = true;
        self.redraw()
    }

    fn should_close(&self, _w: &Window) {
        self.quit()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_turn_shows_the_tool_calls_before_the_answer() {
        assert_eq!(agent_turn("due monday?", &["list_directory({})", "read_file({})"], "The plumber."), "You: due monday?\n  › list_directory({})\n  › read_file({})\nAgent: The plumber.\n\n");
        assert_eq!(agent_turn("hi", &[], "Hello."), "You: hi\nAgent: Hello.\n\n");
        assert_eq!(question_line("q") + &call_line("c()") + &answer_line("a"), agent_turn("q", &["c()"], "a"));
    }

    #[test]
    fn the_layout_keeps_the_field_and_button_at_the_bottom() {
        for (w, h) in [(560.0, 460.0), (900.0, 700.0), (300.0, 200.0)] {
            let l = AgentLayout::new(22.0, w, h);
            assert_eq!(l.field.y + l.field.h, h - 12.0);
            assert_eq!(l.ask.y, l.field.y);
            assert_eq!(l.ask.x + l.ask.w, w - 10.0);
            assert!(l.field.x + l.field.w < l.ask.x, "the field stops before the button");
            assert!(l.conversation.y + l.conversation.h < l.status_baseline - 10.0, "the conversation is above the status");
            assert!(l.conversation.h >= 40.0)
        }
    }

    #[test]
    fn the_pickers_rows_are_where_they_are_drawn() {
        let area = AgentLayout::new(22.0, 560.0, 460.0).conversation;
        let l = AgentPickerLayout::new(area, 3);
        assert_eq!(l.rows.len(), 3);
        assert_eq!(l.hit(l.rows[2].x + 5.0, l.rows[2].y + 5.0), Some(2));
        assert_eq!(l.hit(l.panel.x + 2.0, l.panel.y + 2.0), None, "the heading is not a row");
        assert!(l.rows.iter().all(|r| r.y + r.h <= l.panel.y + l.panel.h), "every row inside the panel");
        assert!(l.rows.windows(2).all(|p| p[0].y + p[0].h <= p[1].y), "rows do not overlap")
    }

    #[test]
    fn writes_and_hosts_are_asked() {
        let t = AgentAsk::Write { app: "TextEdit".into(), verb: "file.save-as".into(), title: "Save As…".into() }.text(0);
        assert_eq!(t.title, "Allow the agent to write with TextEdit?");
        assert_eq!(t.body, "It wants to Save As (file.save-as) in TextEdit: the first time it would write one of your files this session. Allow TextEdit to write for it until the session ends?");
        assert_eq!(t.no, "Don't Allow");
        assert_eq!(AgentAsk::Budget("spent".into()).text(9).yes, "Allow More");
        let h = AgentAsk::Host { host: "example.org".into(), url: "https://example.org/a".into() }.text(0);
        assert_eq!(h.title, "Allow the agent to reach example.org?");
        assert_eq!(h.body, "It wants to fetch https://example.org/a: the first time it would reach example.org this session. Allow it to fetch from example.org until the session ends?");
    }

    #[test]
    fn the_budget_requester() {
        assert_eq!(budget_question("the session's budget of 500 tokens is spent (600 used)", 500), "The session's budget of 500 tokens is spent (600 used). Let it use another 500 tokens and carry on?");
        let l = AgentRequesterLayout::new(AgentLayout::new(22.0, 560.0, 460.0).conversation);
        assert!(l.stop.x + l.stop.w < l.allow.x, "Stop, then Allow More: the default last");
        assert!(l.allow.x + l.allow.w <= l.panel.x + l.panel.w && l.allow.y + l.allow.h <= l.panel.y + l.panel.h);
    }

    #[test]
    fn the_menus_say_what_they_do() {
        let m = agent_menu_bar();
        let verbs: Vec<String> = m.menus.iter().flat_map(|m| m.items.iter()).filter_map(|i| if let MenuItem::Command(c) = i { Some(c.verb.clone()) } else { None }).collect();
        assert_eq!(verbs, [VERB_ABOUT, VERB_QUIT, VERB_ASK, VERB_QUESTION, VERB_CLEAR, VERB_GIVE_APP, VERB_GIVE, VERB_TAKE_APP, VERB_TAKE, VERB_ALLOW, VERB_STOP, VERB_MINIMIZE]);
        assert_eq!(m.verb_for(&KeyEquivalent::cmd('q', Modifiers::NONE)), Some(VERB_QUIT));
        assert_eq!(m.verb_for(&KeyEquivalent::cmd('k', Modifiers::NONE)), Some(VERB_CLEAR));
    }

    /// The presence follows the phase, and a requester is waiting whatever
    /// the phase (P18.13b).
    #[test]
    fn presence_follows_the_session() {
        let budget = AgentAsk::Budget("x".into());
        assert_eq!(presence_state(Phase::Starting, None), None);
        assert_eq!(presence_state(Phase::Ended, Some(&budget)), None);
        assert_eq!(presence_state(Phase::Ready, None), Some(AgentState::Idle));
        assert_eq!(presence_state(Phase::Asking, None), Some(AgentState::Working));
        assert_eq!(presence_state(Phase::Asking, Some(&budget)), Some(AgentState::Waiting));
        assert_eq!(presence_about(Some(&budget), "q"), "Allow more tokens?");
        assert_eq!(presence_about(None, "q"), "q");
    }

    /// AgentPresenceTests' first test, whole: a host or a write is waiting
    /// too, and the budget's requester comes up after the answer, in Ready.
    #[test]
    fn the_state_follows_the_phase_and_the_requester() {
        let host = AgentAsk::Host { host: "a.org".into(), url: "https://a.org/".into() };
        let budget = AgentAsk::Budget("spent".into());
        let write = AgentAsk::Write { app: "TextEdit".into(), verb: "file.save".into(), title: "Save".into() };
        assert_eq!(presence_state(Phase::Asking, Some(&host)), Some(AgentState::Waiting));
        assert_eq!(presence_state(Phase::Ready, Some(&budget)), Some(AgentState::Waiting), "still waiting");
        assert_eq!(presence_about(Some(&write), "q"), "Allow TextEdit to write?");
        assert_eq!(presence_about(Some(&host), "q"), "Allow it to reach a.org?");
        assert_eq!(presence_about(None, "what is due?"), "what is due?");
    }
}
