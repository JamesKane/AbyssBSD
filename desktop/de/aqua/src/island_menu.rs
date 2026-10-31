//! The menu bar's island item (IslandMenu.swift, P13.4): where you are, and
//! every island's windows. Once a window can be somewhere you are not,
//! something on screen must always know where it is; this menu is that,
//! for every window at once. Pure: the bar asks the compositor for the list
//! as the menu opens, and builds it here.

use crate::agent_presence::AgentPresence;
use menu_model::{Command, Key, KeyEquivalent, Menu, MenuItem, Modifiers};
use surface::menubar_focus::{IslandWindow, ShoalInfo};

/// What a chosen row asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IslandAction {
    SwitchTo(u32),
    Window(u32),
    /// A shoal command (P13.6) for the compositor.
    Shoal(String, u32),
}

/// A row per island of `display`, the one shown ticked, its windows
/// indented under it; then this island's shoals and what the front window
/// can do. Choosing a window goes to it, wherever it is.
pub fn island_menu(display: &str, active: u32, count: u32, names: &[String], windows: &[IslandWindow], shoals: &[ShoalInfo], agents: &[AgentPresence]) -> Menu {
    let mut items = Vec::new();
    for n in 1..=count.max(1) {
        let name = names.get(n as usize - 1).filter(|s| !s.is_empty()).cloned().unwrap_or_else(|| n.to_string());
        let shown = if name == n.to_string() { format!("Island {n}") } else { name };
        let title = format!("{}{shown}", if n == active { "✓ " } else { "    " });
        let mut c = Command::new(&format!("island.switch.{n}"), &title, &format!("Show island {n} on this display."));
        if n <= 9 {
            c = c.with_key(KeyEquivalent::new(Key::Character(char::from_digit(n, 10).unwrap()), Modifiers::CONTROL))
        }
        items.push(MenuItem::Command(c));
        for w in windows.iter().filter(|w| w.display == display && w.island == n) {
            let mut label = if w.title.is_empty() { w.app_id.clone() } else { w.title.clone() };
            // An agent session's window says its state (P18.13b), matched by
            // the process that owns it.
            if w.pid > 0
                && let Some(a) = agents.iter().find(|a| a.pid == w.pid)
            {
                label = format!("{label} — {}", a.state.words())
            }
            items.push(MenuItem::Command(Command::new(&format!("island.window.{}", w.id), &format!("        {label}"), "Go to this window.")));
        }
    }
    let here: Vec<&ShoalInfo> = shoals.iter().filter(|s| s.display == display && s.island == active).collect();
    items.push(MenuItem::Separator);
    for s in &here {
        items.push(MenuItem::Command(Command::new(&format!("shoal.recall.{}", s.index), &format!("Recall {} ({})", s.name, s.open), "Bring this shoal's windows to the front together.")));
    }
    items.push(MenuItem::Command(Command::new("shoal.new.0", "New Shoal from Front Window", "Make a shoal of the front window.")));
    if !here.is_empty() {
        let adds = here.iter().map(|s| MenuItem::Command(Command::new(&format!("shoal.add.{}", s.index), &s.name, "Add the front window to this shoal."))).collect();
        items.push(MenuItem::Submenu(Menu::new("Add Front Window To", adds)));
    }
    items.push(MenuItem::Command(Command::new("shoal.remove.0", "Remove Front Window from Its Shoal", "Take the front window out of its shoal.")));
    items.push(MenuItem::Command(Command::new("shoal.strip.0", "Show or Hide the Strip", "The shoals of this island, down the left edge.")));
    Menu::new("Islands", items)
}

pub fn island_action(verb: &str) -> Option<IslandAction> {
    if let Some(n) = verb.strip_prefix("island.switch.") {
        return n.parse().ok().map(IslandAction::SwitchTo);
    }
    if let Some(id) = verb.strip_prefix("island.window.") {
        return id.parse().ok().map(IslandAction::Window);
    }
    // shoal.VERB.ARG
    let p: Vec<&str> = verb.split('.').collect();
    match p.as_slice() {
        ["shoal", v @ ("recall" | "new" | "add" | "remove" | "strip"), a] => a.parse().ok().map(|a| IslandAction::Shoal(v.to_string(), a)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_presence::AgentState;

    fn w(id: u32, island: u32, title: &str, display: &str) -> IslandWindow {
        IslandWindow { id, display: display.into(), island, app_id: format!("org.x.{id}"), title: title.into(), pid: 0 }
    }

    fn rows(m: &Menu) -> Vec<(String, String)> {
        m.items.iter().filter_map(|i| if let MenuItem::Command(c) = i { Some((c.verb.clone(), c.title.clone())) } else { None }).collect()
    }

    #[test]
    fn every_island_has_a_row_and_its_windows_under_it() {
        let m = island_menu("DP-1", 2, 3, &["1".into(), "Mail".into(), "3".into()], &[w(7, 1, "Notes", "DP-1"), w(9, 2, "Inbox", "DP-1"), w(4, 1, "", "DP-1"), w(5, 2, "Elsewhere", "HDMI-A-1")], &[], &[]);
        let r = rows(&m);
        assert_eq!(r.iter().take(6).map(|x| x.0.as_str()).collect::<Vec<_>>(), ["island.switch.1", "island.window.7", "island.window.4", "island.switch.2", "island.window.9", "island.switch.3"]);
        assert_eq!(r[0].1, "    Island 1");
        assert_eq!(r[3].1, "✓ Mail", "the island shown is ticked, by its name");
        assert!(r[2].1.ends_with("org.x.4"), "a window with no title is called by its application");
    }

    #[test]
    fn the_shoals_section_is_this_islands() {
        let shoals = [ShoalInfo { display: "DP-1".into(), island: 2, index: 0, name: "Writing".into(), open: 3 }, ShoalInfo { display: "DP-1".into(), island: 1, index: 1, name: "Elsewhere".into(), open: 1 }];
        let m = island_menu("DP-1", 2, 2, &[], &[], &shoals, &[]);
        let all = m.commands();
        let verbs: Vec<&str> = all.iter().map(|c| c.verb.as_str()).collect();
        assert!(verbs.contains(&"shoal.recall.0"));
        assert!(!verbs.contains(&"shoal.recall.1"), "another island's shoal is not this island's");
        assert_eq!(all.iter().find(|c| c.verb == "shoal.recall.0").unwrap().title, "Recall Writing (3)");
        assert!(["shoal.add.0", "shoal.new.0", "shoal.remove.0"].iter().all(|v| verbs.contains(v)));
        assert_eq!(island_action("shoal.recall.4"), Some(IslandAction::Shoal("recall".into(), 4)));
        assert_eq!(island_action("shoal.sink.1"), None);
    }

    #[test]
    fn a_chosen_row_says_what_it_asks_for() {
        assert_eq!(island_action("island.switch.3"), Some(IslandAction::SwitchTo(3)));
        assert_eq!(island_action("island.window.42"), Some(IslandAction::Window(42)));
        assert_eq!(island_action("island.switch.x"), None);
        assert_eq!(island_action("system.force-quit"), None);
    }

    #[test]
    fn the_island_menu_says_which_window_waits() {
        let mut ws = vec![w(1, 1, "Agent", "D"), w(2, 1, "Agent", "D"), w(3, 1, "Calculator", "D")];
        for (w, pid) in ws.iter_mut().zip([50, 51, 52]) {
            w.pid = pid
        }
        let agents = [AgentPresence::new(51, AgentState::Waiting, ""), AgentPresence::new(50, AgentState::Idle, "")];
        let m = island_menu("D", 1, 1, &[], &ws, &[], &agents);
        let r: Vec<String> = rows(&m).into_iter().filter(|x| x.0.starts_with("island.window.")).map(|x| x.1.trim().to_string()).collect();
        assert_eq!(r, ["Agent — Idle", "Agent — Waiting for you", "Calculator"]);
        let unknown = island_menu("D", 1, 1, &[], &[w(1, 1, "A", "D")], &[], &[AgentPresence::new(0, AgentState::Waiting, "")]);
        assert_eq!(rows(&unknown).iter().rfind(|x| x.0.starts_with("island.window.")).unwrap().1.trim(), "A", "a window whose pid is not known is never matched");
    }
}
