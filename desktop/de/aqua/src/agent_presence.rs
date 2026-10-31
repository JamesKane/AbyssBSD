//! Agent presence (AgentPresence.swift, P18.13b): a session waiting for a
//! yes is visible without hunting for its window.
//!
//! Only the Agent window knows whether its session is working, waiting (a
//! requester in front of the person) or idle, so it says so as a file,
//! `<runtime dir>/agents/<pid>`: the state, and what it is about. The Dock,
//! the menu bar and the island menu read the directory. A file is written
//! aside and renamed into place, so a watcher sees every change; one whose
//! process is gone is ignored, and removed, when read.

use menu_model::{Command, Menu, MenuItem};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum AgentState {
    // In rank order: waiting outranks working outranks idle.
    Idle,
    Working,
    Waiting,
}

impl AgentState {
    pub fn name(self) -> &'static str {
        match self {
            AgentState::Idle => "idle",
            AgentState::Working => "working",
            AgentState::Waiting => "waiting",
        }
    }
    pub fn from_name(s: &str) -> Option<AgentState> {
        [AgentState::Idle, AgentState::Working, AgentState::Waiting].into_iter().find(|a| a.name() == s)
    }
    /// How the menu bar and the island menu say it.
    pub fn words(self) -> &'static str {
        match self {
            AgentState::Idle => "Idle",
            AgentState::Working => "Working",
            AgentState::Waiting => "Waiting for you",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentPresence {
    pub pid: i32,
    pub state: AgentState,
    /// What it is about: the question, or what the requester asks.
    pub about: String,
}

impl AgentPresence {
    pub fn new(pid: i32, state: AgentState, about: &str) -> AgentPresence {
        AgentPresence { pid, state, about: about.into() }
    }

    /// A presence file's text: one line of what, always.
    pub fn text(&self) -> String {
        format!("{}\n{}\n", self.state.name(), self.about.replace('\n', " "))
    }

    pub fn parse(pid: i32, text: &str) -> Option<AgentPresence> {
        let (state, rest) = text.split_once('\n').unwrap_or((text, ""));
        Some(AgentPresence { pid, state: AgentState::from_name(state)?, about: rest.replace('\n', "") })
    }

    /// Waiting first, then working, then idle; by pid within each.
    pub fn sort(mut all: Vec<AgentPresence>) -> Vec<AgentPresence> {
        all.sort_by(|a, b| b.state.cmp(&a.state).then(a.pid.cmp(&b.pid)));
        all
    }
}

/// What the Dock's Agent tile shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgentBadge {
    None,
    Working,
    Waiting(usize),
}

impl AgentBadge {
    pub fn of(all: &[AgentPresence]) -> AgentBadge {
        let waiting = all.iter().filter(|a| a.state == AgentState::Waiting).count();
        if waiting > 0 {
            AgentBadge::Waiting(waiting)
        } else if all.iter().any(|a| a.state == AgentState::Working) {
            AgentBadge::Working
        } else {
            AgentBadge::None
        }
    }
}

/// The menu bar's Agent item's words, or None with no session open: the
/// most pressing session's state, and how many wait when more than one.
pub fn menu_bar_agent_label(agents: &[AgentPresence]) -> Option<String> {
    let top = AgentPresence::sort(agents.to_vec()).into_iter().next()?;
    Some(match top.state {
        AgentState::Idle => "Agent".into(),
        AgentState::Working => "Agent: Working".into(),
        AgentState::Waiting => match agents.iter().filter(|a| a.state == AgentState::Waiting).count() {
            1 => "Agent: Waiting".into(),
            n => format!("Agent: {n} Waiting"),
        },
    })
}

/// The Agent item's menu: a row per session, the most pressing first, each
/// going to its window; then the Agent window for a new one.
pub fn agent_menu(agents: &[AgentPresence]) -> Menu {
    let mut items: Vec<MenuItem> = AgentPresence::sort(agents.to_vec())
        .into_iter()
        .map(|a| {
            let about = if a.about.is_empty() {
                String::new()
            } else if a.about.chars().count() > 48 {
                format!(": {}…", a.about.chars().take(47).collect::<String>())
            } else {
                format!(": {}", a.about)
            };
            MenuItem::Command(Command::new(&format!("agent.go.{}", a.pid), &format!("{}{about}", a.state.words()), "Go to this session's window."))
        })
        .collect();
    items.push(MenuItem::Separator);
    items.push(MenuItem::Command(Command::new("system.agent", "New Agent Window…", "Open the Agent window.")));
    Menu::new("Agent", items)
}

/// `agent.go.PID` → PID.
pub fn agent_menu_pid(verb: &str) -> Option<i32> {
    verb.strip_prefix("agent.go.")?.parse().ok()
}

/// The files: `<runtime dir>/agents`.
pub mod io {
    use super::AgentPresence;
    use std::fs;
    use std::os::unix::fs::DirBuilderExt;

    /// `<runtime dir>/agents`, made if it is not there.
    pub fn dir() -> Option<String> {
        let d = format!("{}/agents", current_ipc::runtime_dir().ok()?);
        match fs::DirBuilder::new().mode(0o700).create(&d) {
            Ok(()) => Some(d),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Some(d),
            Err(_) => None,
        }
    }

    /// Say this process's state: written aside, renamed into place.
    pub fn publish_in(dir: &str, p: &AgentPresence) {
        let (tmp, path) = (format!("{dir}/.{}.tmp", p.pid), format!("{dir}/{}", p.pid));
        if fs::write(&tmp, p.text()).is_err() || fs::rename(&tmp, &path).is_err() {
            let _ = fs::remove_file(&tmp);
        }
    }

    pub fn publish(p: &AgentPresence) {
        if let Some(d) = dir() {
            publish_in(&d, p)
        }
    }

    /// This process has no session any more.
    pub fn withdraw(pid: i32) {
        if let Some(d) = dir() {
            let _ = fs::remove_file(format!("{d}/{pid}"));
        }
    }

    /// Every live session's presence, sorted. A file whose process is gone
    /// is removed: a window killed outright cannot withdraw its own.
    pub fn read_in(dir: &str) -> Vec<AgentPresence> {
        let Ok(rd) = fs::read_dir(dir) else { return vec![] };
        let mut out = Vec::new();
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            let Some(pid) = name.parse::<i32>().ok().filter(|p| *p > 0) else { continue };
            let path = format!("{dir}/{name}");
            if !alive(pid) {
                let _ = fs::remove_file(&path);
                continue;
            }
            if let Some(p) = fs::read_to_string(&path).ok().and_then(|t| AgentPresence::parse(pid, &t)) {
                out.push(p)
            }
        }
        AgentPresence::sort(out)
    }

    pub fn read() -> Vec<AgentPresence> {
        dir().map_or(vec![], |d| read_in(&d))
    }

    /// kill(pid, 0) says whether it is there (EPERM: there, not ours).
    fn alive(pid: i32) -> bool {
        match abyss_sys::proc::kill_pid(pid, 0) {
            Ok(()) => true,
            Err(e) => e.raw_os_error() != Some(libc::ESRCH),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use AgentState::*;

    fn p(pid: i32, s: AgentState, about: &str) -> AgentPresence {
        AgentPresence::new(pid, s, about)
    }

    #[test]
    fn a_file_says_it_and_reads_back() {
        let a = p(42, Waiting, "Allow it to reach\nexample.org?");
        assert_eq!(a.text(), "waiting\nAllow it to reach example.org?\n", "one line of what, always");
        assert_eq!(AgentPresence::parse(42, &a.text()), Some(p(42, Waiting, "Allow it to reach example.org?")));
        assert_eq!(AgentPresence::parse(1, "sleeping\n"), None);
        assert_eq!(AgentPresence::parse(1, ""), None);
    }

    #[test]
    fn waiting_first_and_the_badge() {
        let all = vec![p(3, Idle, ""), p(1, Working, ""), p(5, Waiting, ""), p(2, Waiting, "")];
        assert_eq!(AgentPresence::sort(all.clone()).iter().map(|a| a.pid).collect::<Vec<_>>(), [2, 5, 1, 3]);
        assert_eq!(AgentBadge::of(&all), AgentBadge::Waiting(2));
        assert_eq!(AgentBadge::of(&[p(1, Working, ""), p(2, Idle, "")]), AgentBadge::Working);
        assert_eq!(AgentBadge::of(&[p(2, Idle, "")]), AgentBadge::None, "idle is the running mark alone");
        assert_eq!(AgentBadge::of(&[]), AgentBadge::None);
    }

    #[test]
    fn the_menu_bar_item() {
        assert_eq!(menu_bar_agent_label(&[]), None);
        assert_eq!(menu_bar_agent_label(&[p(1, Idle, "")]).as_deref(), Some("Agent"));
        assert_eq!(menu_bar_agent_label(&[p(1, Idle, ""), p(2, Working, "")]).as_deref(), Some("Agent: Working"));
        assert_eq!(menu_bar_agent_label(&[p(1, Waiting, ""), p(2, Working, "")]).as_deref(), Some("Agent: Waiting"));
        assert_eq!(menu_bar_agent_label(&[p(1, Waiting, ""), p(2, Waiting, "")]).as_deref(), Some("Agent: 2 Waiting"));
        let m = agent_menu(&[p(7, Idle, "hello"), p(9, Waiting, "Allow it to reach a.org?")]);
        let c = m.commands();
        assert_eq!(c.iter().map(|c| c.verb.as_str()).collect::<Vec<_>>(), ["agent.go.9", "agent.go.7", "system.agent"]);
        assert_eq!(c[0].title, "Waiting for you: Allow it to reach a.org?");
        assert_eq!(agent_menu_pid("agent.go.9"), Some(9));
        assert_eq!(agent_menu_pid("island.window.9"), None);
        let long = agent_menu(&[p(1, Working, &"x".repeat(80))]).commands()[0].title.clone();
        assert_eq!(long.chars().count(), "Working: ".len() + 48, "a long question is cut, with …");
    }

    #[test]
    fn the_directory() {
        let d = std::env::temp_dir().join(format!("abyss-presence-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let d = d.to_str().unwrap();
        let me = std::process::id() as i32;
        io::publish_in(d, &p(me, Working, "q"));
        assert_eq!(io::read_in(d), [p(me, Working, "q")]);
        io::publish_in(d, &p(me, Waiting, "Allow?"));
        assert_eq!(io::read_in(d), [p(me, Waiting, "Allow?")], "replaced, not added");
        io::publish_in(d, &p(999_999, Waiting, ""));
        assert_eq!(io::read_in(d).iter().map(|a| a.pid).collect::<Vec<_>>(), [me]);
        assert!(!std::path::Path::new(&format!("{d}/999999")).exists(), "the dead process's file is removed");
        assert!(!std::path::Path::new(&format!("{d}/.{me}.tmp")).exists(), "nothing left aside");
        let _ = std::fs::remove_dir_all(d);
    }
}
