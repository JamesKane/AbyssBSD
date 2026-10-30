//! MenuModel in Rust (RUST.md R2): what an application can do, as a value,
//! ported from Command.swift beside it (PHASE10.md P10.1).
//!
//! A `Command` is one definition with two routes: the key handler looks its
//! key equivalent up here, and the menu is drawn from here, so the two can
//! never disagree about what ⌘D means. It is also the *vocabulary*: a stable
//! verb, a sentence of description and typed arguments are what a script or
//! an agent reads (PRODUCT.md §5.5).
//!
//! Dependency-free, so the menu wire and a command-line client link it
//! without linking an application. Enablement is not in the model: whether
//! a command can run *now* is a question only the running application can
//! answer ([`Enablement`]).

use std::collections::{HashMap, HashSet};
use std::ops::BitOr;

/// The modifiers held with a key: a set of [`Modifiers::COMMAND`],
/// [`SHIFT`](Modifiers::SHIFT), [`OPTION`](Modifiers::OPTION) and
/// [`CONTROL`](Modifiers::CONTROL), the bits the wire carries.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Modifiers(pub u8);

impl Modifiers {
    pub const NONE: Modifiers = Modifiers(0);
    pub const COMMAND: Modifiers = Modifiers(1 << 0);
    pub const SHIFT: Modifiers = Modifiers(1 << 1);
    pub const OPTION: Modifiers = Modifiers(1 << 2);
    pub const CONTROL: Modifiers = Modifiers(1 << 3);

    pub fn contains(self, other: Modifiers) -> bool {
        self.0 & other.0 == other.0
    }
}

impl BitOr for Modifiers {
    type Output = Modifiers;
    fn bitor(self, rhs: Modifiers) -> Modifiers {
        Modifiers(self.0 | rhs.0)
    }
}

/// The key of a key equivalent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Key {
    Character(char),
    /// ⌫, the key the Mac calls Delete.
    Backspace,
    /// ⌦
    ForwardDelete,
    Up,
    Down,
    Left,
    Right,
    Enter,
    Escape,
    Tab,
}

/// A key equivalent: the key and the modifiers that must be held with it.
///
/// Matching is **exact** on modifiers, the rule the compositor's keybind
/// table already uses (PHASE9 P9.5): ⌘D and ⇧⌘D are different keystrokes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct KeyEquivalent {
    key: Key,
    modifiers: Modifiers,
}

impl KeyEquivalent {
    /// A character is stored lowercased (Shift is a modifier, not a
    /// different letter), so ⇧⌘N is `Character('n')` with SHIFT. A letter
    /// whose lowercase is more than one character (İ) is kept as it is
    /// (Swift: lowercased as a Character, RUST.md §1, Swift's quirks).
    pub fn new(key: Key, modifiers: Modifiers) -> KeyEquivalent {
        let key = match key {
            Key::Character(c) => {
                let mut lower = c.to_lowercase();
                match (lower.next(), lower.next()) {
                    (Some(l), None) => Key::Character(l),
                    _ => key,
                }
            }
            k => k,
        };
        KeyEquivalent { key, modifiers }
    }

    /// ⌘ plus a character, the common case: `cmd('d', NONE)`,
    /// `cmd('n', SHIFT)`.
    pub fn cmd(c: char, extra: Modifiers) -> KeyEquivalent {
        KeyEquivalent::new(Key::Character(c), extra | Modifiers::COMMAND)
    }

    /// ⌘ plus a named key: `cmd_key(Key::Backspace, NONE)`.
    pub fn cmd_key(k: Key, extra: Modifiers) -> KeyEquivalent {
        KeyEquivalent::new(k, extra | Modifiers::COMMAND)
    }

    pub fn key(&self) -> Key {
        self.key
    }

    pub fn modifiers(&self) -> Modifiers {
        self.modifiers
    }

    /// How a menu shows it, in the order the Mac draws modifiers (⌃⌥⇧⌘),
    /// then the key: `⇧⌘N`, `⌘⌫`, `⌘↑`.
    pub fn display(&self) -> String {
        let mut s = String::new();
        for (m, glyph) in [
            (Modifiers::CONTROL, '⌃'),
            (Modifiers::OPTION, '⌥'),
            (Modifiers::SHIFT, '⇧'),
            (Modifiers::COMMAND, '⌘'),
        ] {
            if self.modifiers.contains(m) {
                s.push(glyph);
            }
        }
        match self.key {
            Key::Character(c) => s.extend(c.to_uppercase()),
            Key::Backspace => s.push('⌫'),
            Key::ForwardDelete => s.push('⌦'),
            Key::Up => s.push('↑'),
            Key::Down => s.push('↓'),
            Key::Left => s.push('←'),
            Key::Right => s.push('→'),
            Key::Enter => s.push('↩'),
            Key::Escape => s.push('⎋'),
            Key::Tab => s.push('⇥'),
        }
        s
    }
}

/// The type of one argument a verb takes. Small on purpose: this is what a
/// script has to be able to supply, not a type system.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ArgumentType {
    String,
    Path,
    Integer,
    Bool,
}

impl ArgumentType {
    pub const ALL: [ArgumentType; 4] = [ArgumentType::String, ArgumentType::Path, ArgumentType::Integer, ArgumentType::Bool];

    /// The name the wire carries.
    pub fn as_str(self) -> &'static str {
        match self {
            ArgumentType::String => "string",
            ArgumentType::Path => "path",
            ArgumentType::Integer => "integer",
            ArgumentType::Bool => "bool",
        }
    }

    pub fn from_name(s: &str) -> Option<ArgumentType> {
        ArgumentType::ALL.into_iter().find(|t| t.as_str() == s)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Argument {
    pub name: String,
    pub ty: ArgumentType,
    pub summary: String,
}

impl Argument {
    pub fn new(name: &str, ty: ArgumentType, summary: &str) -> Argument {
        Argument { name: name.to_owned(), ty, summary: summary.to_owned() }
    }
}

/// One thing an application can do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Command {
    /// Stable, never localised, what a script says: `file.duplicate`.
    pub verb: String,
    /// What a person reads: `Duplicate`.
    pub title: String,
    /// Shown in the menu, and answered by the key handler.
    pub key: Option<KeyEquivalent>,
    /// Also answered, never shown: ⌘↓ opens as well as ⌘O.
    pub alternate_keys: Vec<KeyEquivalent>,
    pub arguments: Vec<Argument>,
    /// One sentence: what it does. For a reader that cannot see the menu.
    pub summary: String,
    /// It writes or removes one of the person's files (Save, Save As…, Move
    /// to Trash). An agent's first such command in a session asks the person
    /// before it runs (PHASE18 P18.11, requester 1).
    pub writes: bool,
}

impl Command {
    pub fn new(verb: &str, title: &str, summary: &str) -> Command {
        Command {
            verb: verb.to_owned(),
            title: title.to_owned(),
            key: None,
            alternate_keys: Vec::new(),
            arguments: Vec::new(),
            summary: summary.to_owned(),
            writes: false,
        }
    }

    pub fn with_key(mut self, k: KeyEquivalent) -> Command {
        self.key = Some(k);
        self
    }

    pub fn with_alternates(mut self, keys: Vec<KeyEquivalent>) -> Command {
        self.alternate_keys = keys;
        self
    }

    pub fn with_arguments(mut self, arguments: Vec<Argument>) -> Command {
        self.arguments = arguments;
        self
    }

    pub fn writing(mut self) -> Command {
        self.writes = true;
        self
    }

    /// Every key that runs this command, the shown one first.
    pub fn all_keys(&self) -> impl Iterator<Item = &KeyEquivalent> {
        self.key.iter().chain(&self.alternate_keys)
    }

    /// The same command under another title: Undo becomes "Undo Move to
    /// Trash" and back. Everything else is unchanged, `writes` included
    /// (Swift's drops it: BACKLOG §5).
    pub fn retitled(&self, title: &str) -> Command {
        Command { title: title.to_owned(), ..self.clone() }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MenuItem {
    Command(Command),
    Separator,
    Submenu(Menu),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Menu {
    pub title: String,
    pub items: Vec<MenuItem>,
}

impl Menu {
    pub fn new(title: &str, items: Vec<MenuItem>) -> Menu {
        Menu { title: title.to_owned(), items }
    }

    /// Every command in this menu and its submenus, in menu order.
    pub fn commands(&self) -> Vec<&Command> {
        let mut out = Vec::new();
        self.collect(&mut out);
        out
    }

    fn collect<'a>(&'a self, out: &mut Vec<&'a Command>) {
        for item in &self.items {
            match item {
                MenuItem::Command(c) => out.push(c),
                MenuItem::Separator => {}
                MenuItem::Submenu(m) => m.collect(out),
            }
        }
    }

    pub fn retitled(&self, titles: &HashMap<String, String>) -> Menu {
        let items = self
            .items
            .iter()
            .map(|item| match item {
                MenuItem::Command(c) => MenuItem::Command(match titles.get(&c.verb) {
                    Some(t) => c.retitled(t),
                    None => c.clone(),
                }),
                MenuItem::Separator => MenuItem::Separator,
                MenuItem::Submenu(m) => MenuItem::Submenu(m.retitled(titles)),
            })
            .collect();
        Menu { title: self.title.clone(), items }
    }
}

/// An application's menus: what goes to the right of the system menu, the
/// first being the bold application menu.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MenuBarModel {
    pub app_name: String,
    pub menus: Vec<Menu>,
}

impl MenuBarModel {
    pub fn new(app_name: &str, menus: Vec<Menu>) -> MenuBarModel {
        MenuBarModel { app_name: app_name.to_owned(), menus }
    }

    pub fn commands(&self) -> Vec<&Command> {
        let mut out = Vec::new();
        for m in &self.menus {
            m.collect(&mut out);
        }
        out
    }

    pub fn command(&self, verb: &str) -> Option<&Command> {
        self.commands().into_iter().find(|c| c.verb == verb)
    }

    /// The verb a key runs, if any. **This is the whole key handler**: an
    /// application that asks this instead of switching on keysyms has one
    /// definition of each command, and its menu is that definition drawn.
    pub fn verb_for(&self, press: &KeyEquivalent) -> Option<&str> {
        self.commands().into_iter().find(|c| c.all_keys().any(|k| k == press)).map(|c| c.verb.as_str())
    }

    /// Keys claimed by more than one command: each would silently run only
    /// the first. Empty in a well-formed model; a test asserts it.
    pub fn conflicting_keys(&self) -> Vec<KeyEquivalent> {
        let mut seen = HashSet::new();
        self.commands().into_iter().flat_map(|c| c.all_keys()).filter(|k| !seen.insert(**k)).copied().collect()
    }

    /// Verbs that appear more than once. A verb names one thing.
    pub fn duplicate_verbs(&self) -> Vec<&str> {
        let mut seen = HashSet::new();
        self.commands().into_iter().map(|c| c.verb.as_str()).filter(|v| !seen.insert(*v)).collect()
    }

    /// The model with some commands' titles replaced, by verb. How a title
    /// that depends on state (Undo's) reaches the bar without a second
    /// definition.
    pub fn retitled(&self, titles: &HashMap<String, String>) -> MenuBarModel {
        if titles.is_empty() {
            return self.clone();
        }
        MenuBarModel { app_name: self.app_name.clone(), menus: self.menus.iter().map(|m| m.retitled(titles)).collect() }
    }
}

/// Whether a command can run now, and if not, why: the reason is for a
/// script, which cannot see a greyed-out item.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Enablement {
    Enabled,
    Disabled(String),
}

impl Enablement {
    pub fn is_enabled(&self) -> bool {
        *self == Enablement::Enabled
    }
}

/// What running a command produced. Not `()`: a script needs to know
/// whether it worked and what it made (PHASE10 P10.2).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandResult {
    Ok(Option<String>),
    Refused(String),
}

/// Where a GTK application's menus are, as `gtk_surface1.set_dbus_properties`
/// told the compositor (PHASE10.md P10.6): carried to the bar as the address
/// of a `gtk`-kind focus, and from the bar to the bridge that reads them.
///
/// One encoding for the three parties that handle it (undertow, the menu
/// bar, `abyss-dbus --menus`): fields in a fixed order, one per line. None
/// of them can contain a newline: they are a D-Bus name, object paths and an
/// application id.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GtkMenuAddress {
    pub application_id: String,
    pub bus_name: String,
    pub application_path: String,
    pub menubar_path: String,
    pub app_menu_path: String,
    pub window_path: String,
}

impl GtkMenuAddress {
    pub fn encoded(&self) -> String {
        [
            &self.application_id,
            &self.bus_name,
            &self.application_path,
            &self.menubar_path,
            &self.app_menu_path,
            &self.window_path,
        ]
        .map(String::as_str)
        .join("\n")
    }

    /// Six lines, the bus name not empty. Lines end at `\n` alone (Swift
    /// reads a CRLF as one Character, so never splits there).
    pub fn from_encoded(s: &str) -> Option<GtkMenuAddress> {
        let f: Vec<&str> = s.split('\n').collect();
        let [application_id, bus_name, application_path, menubar_path, app_menu_path, window_path] = f[..] else {
            return None;
        };
        if bus_name.is_empty() {
            return None;
        }
        Some(GtkMenuAddress {
            application_id: application_id.to_owned(),
            bus_name: bus_name.to_owned(),
            application_path: application_path.to_owned(),
            menubar_path: menubar_path.to_owned(),
            app_menu_path: app_menu_path.to_owned(),
            window_path: window_path.to_owned(),
        })
    }

    /// Whether there is anything to read: a bus to ask and a menu to ask for.
    pub fn has_menus(&self) -> bool {
        !self.bus_name.is_empty() && !(self.menubar_path.is_empty() && self.app_menu_path.is_empty())
    }
}

#[cfg(test)]
mod tests;
