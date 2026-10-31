//! The keybind table (KeyBindings.swift, PHASE9.md P9.5).
//!
//! The compositor is the only thing that hears a key before the focused
//! application, so shortcuts that belong to the *desktop* are decided here
//! or not at all. **The match is a pure function** (§2.9): the corner cases
//! (a bound key with an extra modifier held; a bound key an application may
//! keep) are miserable to drive through a live compositor.

use crate::geometry::EbbScope;
use pool_config::Config;

/// The modifiers a binding can name: wlroots' own mask bits. Caps Lock and
/// Num Lock are absent: they are *states*, and a table that saw them would
/// stop every shortcut the moment somebody left Caps Lock on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct KeyModifiers(pub u32);

impl KeyModifiers {
    pub const SHIFT: KeyModifiers = KeyModifiers(1);
    pub const CTRL: KeyModifiers = KeyModifiers(4);
    pub const ALT: KeyModifiers = KeyModifiers(8);
    /// The Logo/Super key, which on this desktop is **Command**.
    pub const CMD: KeyModifiers = KeyModifiers(64);
    /// The bits a binding may name, so lock states never enter a comparison.
    pub const MEANINGFUL: KeyModifiers = KeyModifiers(1 | 4 | 8 | 64);

    pub fn normalized(self) -> KeyModifiers {
        KeyModifiers(self.0 & KeyModifiers::MEANINGFUL.0)
    }
}

impl std::ops::BitOr for KeyModifiers {
    type Output = KeyModifiers;
    fn bitor(self, o: KeyModifiers) -> KeyModifiers {
        KeyModifiers(self.0 | o.0)
    }
}

/// Ctrl-Alt-F*n*: the virtual terminal it asks for. Not a binding in the
/// table, because it is not the desktop's to rebind: it is how a person
/// leaves for a text console, and on the live medium the only way to a
/// command line. xkb's `pc` symbols already turn it into
/// `XF86Switch_VT_n`, so this is a range check on the translated symbol.
pub fn vt_switch(syms: &[u32]) -> Option<u32> {
    const FIRST: u32 = 0x1008_FE01; // XKB_KEY_XF86Switch_VT_1
    const LAST: u32 = 0x1008_FE0C; // XKB_KEY_XF86Switch_VT_12
    syms.iter().find(|&&s| (FIRST..=LAST).contains(&s)).map(|s| s - FIRST + 1)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyAction {
    NextWindow,
    PreviousWindow,
    CloseWindow,
    /// Close every window of the focused application: Cmd-Q on a Mac, not
    /// the same thing as closing a window.
    QuitApplication,
    /// Run a command, detached. **Every hardware key is one of these**:
    /// volume and brightness go out through `ventsctl`, so the compositor
    /// needs no dependency on the hardware bridges.
    Run(Vec<String>),
    /// Islands (P13.1): show island N; step one way or the other, wrapping;
    /// send the focused window to island N, going with it or not.
    Island(i64),
    IslandStep(i64),
    MoveToIsland { island: i64, follow: bool },
    /// Ebb (P13.5): open in a scope.
    Ebb(EbbScope),
    /// Shoals (P13.6): make one of the focused window, add it to the
    /// current one, take it out, recall this island's Nth, show the strip.
    ShoalNew,
    ShoalAdd,
    ShoalRemove,
    ShoalRecall(i64),
    ShoalStrip,
    /// The Agent window (P18.13): only while agents are on.
    Agent,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyBinding {
    pub sym: u32,
    pub modifiers: KeyModifiers,
    pub action: KeyAction,
}

impl KeyBinding {
    pub fn new(sym: u32, modifiers: KeyModifiers, action: KeyAction) -> KeyBinding {
        KeyBinding { sym, modifiers: modifiers.normalized(), action }
    }
}

/// The table, and the rule that reads it.
#[derive(Clone, Debug, Default)]
pub struct KeyBindings {
    pub bindings: Vec<KeyBinding>,
    /// app_id to the bindings that application keeps for itself (§6.2); an
    /// empty list keeps everything.
    pub passthrough: Vec<(String, Vec<KeyBinding>)>,
}

impl KeyBindings {
    /// The action for a keystroke, or None to let the client have it.
    /// **Modifiers must match exactly** (lock states masked off): Cmd-Q and
    /// Cmd-Shift-Q are different keystrokes.
    pub fn matching(&self, sym: u32, modifiers: KeyModifiers, focused_app_id: Option<&str>) -> Option<&KeyAction> {
        let mods = modifiers.normalized();
        let hit = self.bindings.iter().find(|b| b.sym == sym && b.modifiers == mods)?;
        // **§6.2: an application may keep a combination.** A terminal that
        // cannot receive Cmd-Q cannot run a program that wants it, and `*`
        // lets one application (a VM window) opt out of the whole table.
        if let Some(app) = focused_app_id
            && let Some((_, kept)) = self.passthrough.iter().find(|(a, _)| a == app)
            && (kept.is_empty() || kept.iter().any(|k| k.sym == hit.sym && k.modifiers == hit.modifiers))
        {
            return None;
        }
        Some(&hit.action)
    }
}

// MARK: reading the table

/// `"Cmd+Shift+3"` as modifiers and a keysym. Case-insensitive on the
/// modifier names and forgiving about spaces, a file a person edits. The
/// key name goes to xkb untouched first (keysym names are case-sensitive)
/// and only then capitalised, so `tab` works and `A` keeps its meaning.
pub fn parse_spec(spec: &str, keysym: &dyn Fn(&str) -> Option<u32>) -> Option<(KeyModifiers, u32)> {
    let (mut mods, mut name) = (KeyModifiers::default(), None);
    for part in spec.split('+') {
        let part = part.trim_matches([' ', '\t']);
        if part.is_empty() {
            return None;
        }
        match part.to_lowercase().as_str() {
            "cmd" | "command" | "super" | "logo" | "meta" => mods = mods | KeyModifiers::CMD,
            "shift" => mods = mods | KeyModifiers::SHIFT,
            "ctrl" | "control" => mods = mods | KeyModifiers::CTRL,
            "alt" | "option" | "opt" => mods = mods | KeyModifiers::ALT,
            // Two key names in one spec is a typo, not a chord.
            _ if name.is_some() => return None,
            _ => name = Some(part),
        }
    }
    let key = name?;
    if let Some(s) = keysym(key).filter(|s| *s != 0) {
        return Some((mods, s));
    }
    let mut chars = key.chars();
    let capitalised: String = chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default();
    keysym(&capitalised).filter(|s| *s != 0).map(|s| (mods, s))
}

/// An action as `keys.ini` names it, or None for one this cannot run.
pub fn parse_action(action: &str) -> Option<KeyAction> {
    let a = action.trim_matches([' ', '\t']);
    let lower = a.to_lowercase();
    Some(match lower.as_str() {
        "next-window" => KeyAction::NextWindow,
        "previous-window" => KeyAction::PreviousWindow,
        "close-window" => KeyAction::CloseWindow,
        "quit-app" => KeyAction::QuitApplication,
        "shoal new" => KeyAction::ShoalNew,
        "shoal add" => KeyAction::ShoalAdd,
        "shoal remove" => KeyAction::ShoalRemove,
        "shoal strip" => KeyAction::ShoalStrip,
        "ebb island" => KeyAction::Ebb(EbbScope::Island),
        "ebb archipelago" => KeyAction::Ebb(EbbScope::Archipelago),
        "ebb app" => KeyAction::Ebb(EbbScope::App),
        "island next" => KeyAction::IslandStep(1),
        "island previous" => KeyAction::IslandStep(-1),
        "agent" => KeyAction::Agent,
        _ => {
            // `island N`, `shoal recall N`, `move-to-island N [follow]`.
            let w: Vec<&str> = lower.split(' ').filter(|w| !w.is_empty()).collect();
            let digit = |s: &str| s.parse::<i64>().ok().filter(|n| (1..=9).contains(n));
            match w.as_slice() {
                ["island", n] => return digit(n).map(KeyAction::Island),
                ["shoal", "recall", n] => return digit(n).map(KeyAction::ShoalRecall),
                ["move-to-island", n] => return digit(n).map(|island| KeyAction::MoveToIsland { island, follow: false }),
                ["move-to-island", n, "follow"] => return digit(n).map(|island| KeyAction::MoveToIsland { island, follow: true }),
                ["move-to-island", ..] => return None,
                _ => {}
            }
            // `run: cmd arg arg`. Deliberately not a shell: no quoting, no
            // globbing, no `rm -rf $HOME` from a stray semicolon in a file
            // the desktop reads at every keystroke.
            if !lower.starts_with("run:") {
                return None;
            }
            let words: Vec<String> = a[4..].split(' ').filter(|w| !w.is_empty()).map(str::to_owned).collect();
            if words.is_empty() {
                return None;
            }
            KeyAction::Run(words)
        }
    })
}

/// The whole table out of a Config: `[keys]` is `spec = action`;
/// `[passthrough]` is `app_id = spec spec …`, `*` (or nothing that parses)
/// meaning the application keeps everything.
pub fn table(config: &Config, keysym: &dyn Fn(&str) -> Option<u32>) -> KeyBindings {
    let bindings = config
        .pairs("keys")
        .iter()
        .filter_map(|(spec, action)| {
            let (mods, sym) = parse_spec(spec, keysym)?;
            Some(KeyBinding::new(sym, mods, parse_action(action)?))
        })
        .collect();
    let passthrough = config
        .pairs("passthrough")
        .iter()
        .map(|(app, specs)| {
            let words: Vec<&str> = specs.split(' ').filter(|w| !w.is_empty()).collect();
            let kept = if words.contains(&"*") {
                vec![]
            } else {
                words.iter().filter_map(|s| parse_spec(s, keysym)).map(|(m, s)| KeyBinding::new(s, m, KeyAction::CloseWindow)).collect()
            };
            ((*app).to_owned(), kept)
        })
        .collect();
    KeyBindings { bindings, passthrough }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stub keysym table, so the parse is tested without xkb.
    fn sym(name: &str) -> Option<u32> {
        match name {
            "Tab" => Some(0xff09),
            "q" | "Q" => Some(0x71),
            "w" => Some(0x77),
            "3" => Some(0x33),
            "XF86AudioRaiseVolume" => Some(0x1008ff13),
            _ => None,
        }
    }

    const CMD: KeyModifiers = KeyModifiers::CMD;

    #[test]
    fn spec_parsing_takes_modifiers_in_any_order_and_case() {
        assert_eq!(parse_spec("Cmd+Shift+Tab", &sym), Some((CMD | KeyModifiers::SHIFT, 0xff09)));
        assert_eq!(parse_spec(" shift + CMD + tab ", &sym), Some((CMD | KeyModifiers::SHIFT, 0xff09)), "case and spaces do not matter");
        assert_eq!(parse_spec("Super+q", &sym).map(|p| p.0), Some(CMD));
        assert_eq!(parse_spec("Cmd+NoSuchKey", &sym), None);
        assert_eq!(parse_spec("Cmd+q+w", &sym), None);
        assert_eq!(parse_spec("Cmd+", &sym), None);
    }

    #[test]
    fn action_parsing_refuses_what_it_cannot_run() {
        assert_eq!(parse_action("next-window"), Some(KeyAction::NextWindow));
        assert_eq!(parse_action("quit-app"), Some(KeyAction::QuitApplication));
        assert_eq!(parse_action("run: abyssgrab screen"), Some(KeyAction::Run(vec!["abyssgrab".into(), "screen".into()])));
        assert_eq!(parse_action("rm -rf /"), None);
        assert_eq!(parse_action("run:"), None);
    }

    /// Islands' actions (P13.1): a number in range, or nothing.
    #[test]
    fn island_actions_parse_and_refuse() {
        assert_eq!(parse_action("island 3"), Some(KeyAction::Island(3)));
        assert_eq!(parse_action("Island Next"), Some(KeyAction::IslandStep(1)));
        assert_eq!(parse_action("island previous"), Some(KeyAction::IslandStep(-1)));
        assert_eq!(parse_action("move-to-island 2"), Some(KeyAction::MoveToIsland { island: 2, follow: false }));
        assert_eq!(parse_action("move-to-island 2 follow"), Some(KeyAction::MoveToIsland { island: 2, follow: true }));
        for bad in ["island 0", "island 10", "island", "move-to-island 2 later"] {
            assert_eq!(parse_action(bad), None, "{bad}");
        }
        let d = pool_config::DesktopKeys::defaults();
        let get = |k: &str| d.iter().find(|(s, _)| s == k).map(|(_, a)| a.as_str());
        assert_eq!(get("Ctrl+2"), Some("island 2"));
        assert_eq!(get("Ctrl+Right"), Some("island next"));
        assert_eq!(get("Ctrl+Alt+3"), Some("move-to-island 3"));
        assert_eq!(get("Ctrl+Alt+Shift+3"), Some("move-to-island 3 follow"));
    }

    #[test]
    fn modifiers_must_match_exactly() {
        let t = KeyBindings { bindings: vec![KeyBinding::new(0x71, CMD, KeyAction::QuitApplication)], passthrough: vec![] };
        assert_eq!(t.matching(0x71, CMD, None), Some(&KeyAction::QuitApplication));
        assert_eq!(t.matching(0x71, CMD | KeyModifiers::SHIFT, None), None, "Cmd-Shift-Q reaches the application");
        assert_eq!(t.matching(0x71, KeyModifiers::default(), None), None);
        assert_eq!(t.matching(0x71, KeyModifiers(64 | 2), None), Some(&KeyAction::QuitApplication), "Caps Lock is a state");
    }

    #[test]
    fn an_application_may_keep_a_combination() {
        let q = KeyBinding::new(0x71, CMD, KeyAction::QuitApplication);
        let w = KeyBinding::new(0x77, CMD, KeyAction::CloseWindow);
        let t = KeyBindings { bindings: vec![q.clone(), w], passthrough: vec![("org.abyssbsd.terminal".into(), vec![q])] };
        assert_eq!(t.matching(0x71, CMD, Some("org.abyssbsd.terminal")), None, "the terminal keeps Cmd-Q");
        assert_eq!(t.matching(0x77, CMD, Some("org.abyssbsd.terminal")), Some(&KeyAction::CloseWindow), "but not Cmd-W");
        assert_eq!(t.matching(0x71, CMD, Some("org.abyssbsd.finder")), Some(&KeyAction::QuitApplication));
        assert_eq!(t.matching(0x71, CMD, None), Some(&KeyAction::QuitApplication));
    }

    #[test]
    fn an_application_may_keep_everything() {
        let t = KeyBindings { bindings: vec![KeyBinding::new(0x71, CMD, KeyAction::QuitApplication)], passthrough: vec![("org.abyssbsd.vm".into(), vec![])] };
        assert_eq!(t.matching(0x71, CMD, Some("org.abyssbsd.vm")), None);
        assert_eq!(t.matching(0x71, CMD, Some("other")), Some(&KeyAction::QuitApplication));
    }

    #[test]
    fn the_table_reads_a_config_and_skips_what_it_cannot_understand() {
        let mut c = Config::new();
        c.set("keys", "Cmd+Tab", "next-window");
        c.set("keys", "Cmd+q", "quit-app");
        c.set("keys", "Cmd+NoSuchKey", "next-window");
        c.set("keys", "Cmd+w", "explode");
        c.set("passthrough", "org.abyssbsd.terminal", "Cmd+q");
        let t = table(&c, &sym);
        assert_eq!(t.bindings.len(), 2);
        assert_eq!(t.matching(0xff09, CMD, None), Some(&KeyAction::NextWindow));
        assert_eq!(t.matching(0x71, CMD, Some("org.abyssbsd.terminal")), None);
    }

    /// A default that does not parse is a shortcut that silently does not
    /// exist.
    #[test]
    fn the_built_in_defaults_all_parse() {
        for (spec, action) in pool_config::DesktopKeys::defaults() {
            assert!(parse_action(&action).is_some(), "{action}");
            assert!(!spec.split('+').any(str::is_empty), "{spec}");
        }
    }

    /// The Agent chord (P18.13) is an action of its own.
    #[test]
    fn the_agent_chord_parses() {
        assert_eq!(parse_action("agent"), Some(KeyAction::Agent));
        assert_ne!(parse_action("agent"), Some(KeyAction::Run(vec!["agent".into()])));
    }

    #[test]
    fn ctrl_alt_fn_is_a_vt_and_nothing_else_is() {
        assert_eq!(vt_switch(&[0x1008_FE01]), Some(1));
        assert_eq!(vt_switch(&[0x1008_FE0C]), Some(12));
        assert_eq!(vt_switch(&[0xffbf]), None, "F2 alone is the application's");
        assert_eq!(vt_switch(&[]), None);
    }
}
