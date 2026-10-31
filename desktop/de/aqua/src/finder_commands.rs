//! The Finder's commands, defined once (FinderCommands.swift, PHASE10
//! P10.1): the key handler asks which verb a key runs and the menu bar
//! draws them, so ⌘D and File ▸ Duplicate are one command reached two ways.
//!
//! **`FinderVerb` is exhaustive on purpose**: the window's `perform` matches
//! it with no wildcard, so a new command here does not compile until the
//! window decides what it does. A verb the Finder cannot do yet is drawn
//! disabled, never left out: an item that does nothing must look it.

use menu_model::{Argument, ArgumentType, Command, Enablement, Key, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};

macro_rules! verbs {
    ($($v:ident = $s:literal),* $(,)?) => {
        /// Every command the Finder's menus carry.
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum FinderVerb { $($v),* }
        impl FinderVerb {
            pub const ALL: &'static [FinderVerb] = &[$(FinderVerb::$v),*];
            pub fn raw(self) -> &'static str {
                match self { $(FinderVerb::$v => $s),* }
            }
            pub fn from_raw(s: &str) -> Option<FinderVerb> {
                match s { $($s => Some(FinderVerb::$v),)* _ => None }
            }
        }
    };
}

verbs! {
    About = "finder.about", Preferences = "finder.preferences", EmptyTrash = "finder.empty-trash",
    Hide = "finder.hide", HideOthers = "finder.hide-others", ShowAll = "finder.show-all",
    NewWindow = "file.new-window", NewFolder = "file.new-folder", Open = "file.open",
    CloseWindow = "file.close-window", GetInfo = "file.get-info", Duplicate = "file.duplicate",
    MakeAlias = "file.make-alias", MoveToTrash = "file.move-to-trash", SaveHere = "file.save-here",
    Find = "file.find",
    Undo = "edit.undo", Redo = "edit.redo", Cut = "edit.cut", Copy = "edit.copy", Paste = "edit.paste",
    SelectAll = "edit.select-all",
    AsIcons = "view.as-icons", AsList = "view.as-list", AsColumns = "view.as-columns",
    ToggleToolbar = "view.toggle-toolbar",
    Back = "go.back", EnclosingFolder = "go.enclosing-folder", GoToFolder = "go.to-folder",
    Computer = "go.computer", Home = "go.home", Applications = "go.applications",
    Minimize = "window.minimize", Zoom = "window.zoom",
    Help = "help.finder",
}

impl FinderVerb {
    /// Whether the Finder can do this at all yet: false is drawn disabled.
    pub fn is_implemented(self) -> bool {
        use FinderVerb::*;
        match self {
            // SelectAll: the Finder selects one item at a time.
            About | Preferences | Hide | HideOthers | ShowAll | GetInfo | MakeAlias | Find | SelectAll | AsColumns | Help => false,
            EmptyTrash | NewWindow | NewFolder | Open | CloseWindow | Duplicate | MoveToTrash | SaveHere | Undo | Redo | Cut | Copy | Paste | AsIcons | AsList | ToggleToolbar | Back | EnclosingFolder | GoToFolder | Computer | Home | Applications | Minimize | Zoom => true,
        }
    }
}

fn cmd(c: char) -> KeyEquivalent {
    KeyEquivalent::cmd(c, Modifiers::NONE)
}
fn cmd_with(c: char, m: Modifiers) -> KeyEquivalent {
    KeyEquivalent::cmd(c, m)
}
fn cmd_key(k: Key, m: Modifiers) -> KeyEquivalent {
    KeyEquivalent::cmd_key(k, m)
}

/// The Finder's menus, as Jaguar laid them out.
pub fn finder_menu_bar() -> MenuBarModel {
    use FinderVerb::*;
    // The verbs that remove one of the person's files: an agent's first in a
    // session asks the person first (P18.11).
    let writing = |v: FinderVerb| matches!(v, MoveToTrash | EmptyTrash);
    let c = |v: FinderVerb, title: &str, key: Option<KeyEquivalent>, also: Vec<KeyEquivalent>, args: Vec<Argument>, summary: &str| {
        let mut cm = Command::new(v.raw(), title, summary).with_alternates(also).with_arguments(args);
        if let Some(k) = key {
            cm = cm.with_key(k)
        }
        if writing(v) {
            cm = cm.writing()
        }
        MenuItem::Command(cm)
    };
    let k = |v, t, key, s| c(v, t, Some(key), vec![], vec![], s);
    let n = |v, t, s| c(v, t, None, vec![], vec![], s);
    let sep = || MenuItem::Separator;
    MenuBarModel::new(
        "Finder",
        vec![
            Menu::new(
                "Finder",
                vec![
                    n(About, "About Finder", "Show the Finder's version."),
                    sep(),
                    n(Preferences, "Preferences…", "Change how the Finder behaves."),
                    sep(),
                    k(EmptyTrash, "Empty Trash…", cmd_key(Key::Backspace, Modifiers::SHIFT), "Permanently delete everything in the Trash."),
                    sep(),
                    k(Hide, "Hide Finder", cmd('h'), "Hide the Finder's windows."),
                    k(HideOthers, "Hide Others", cmd_with('h', Modifiers::OPTION), "Hide every other application's windows."),
                    n(ShowAll, "Show All", "Show every hidden window."),
                ],
            ),
            Menu::new(
                "File",
                vec![
                    k(NewWindow, "New Finder Window", cmd('n'), "Open a new window on your home folder."),
                    k(NewFolder, "New Folder", cmd_with('n', Modifiers::SHIFT), "Make an untitled folder here and name it."),
                    c(Open, "Open", Some(cmd('o')), vec![cmd_key(Key::Down, Modifiers::NONE)], vec![], "Open the selected item."),
                    k(CloseWindow, "Close Window", cmd('w'), "Close this window."),
                    sep(),
                    k(GetInfo, "Get Info", cmd('i'), "Show the selected item's details."),
                    k(Duplicate, "Duplicate", cmd('d'), "Copy the selected item beside itself."),
                    k(MakeAlias, "Make Alias", cmd('l'), "Make an alias of the selected item."),
                    sep(),
                    c(MoveToTrash, "Move to Trash", Some(cmd_key(Key::Backspace, Modifiers::NONE)), vec![cmd_key(Key::ForwardDelete, Modifiers::NONE)], vec![], "Move the selected item to the Trash."),
                    k(SaveHere, "Save Here", cmd('s'), "In a save dialog, save into the folder on screen."),
                    sep(),
                    k(Find, "Find…", cmd('f'), "Search for files."),
                ],
            ),
            Menu::new(
                "Edit",
                vec![
                    k(Undo, "Undo", cmd('z'), "Undo the last change."),
                    k(Redo, "Redo", cmd_with('z', Modifiers::SHIFT), "Redo the change just undone."),
                    sep(),
                    k(Cut, "Cut", cmd('x'), "Put the selected item on the clipboard, to be moved by Paste."),
                    k(Copy, "Copy", cmd('c'), "Put the selected item on the clipboard."),
                    k(Paste, "Paste", cmd('v'), "Copy or move the clipboard's item here."),
                    k(SelectAll, "Select All", cmd('a'), "Select every item here."),
                ],
            ),
            Menu::new(
                "View",
                vec![
                    k(AsIcons, "as Icons", cmd('1'), "Show items as icons."),
                    k(AsList, "as List", cmd('2'), "Show items as a list."),
                    k(AsColumns, "as Columns", cmd('3'), "Show items in columns."),
                    sep(),
                    k(ToggleToolbar, "Hide Toolbar", cmd('b'), "Show or hide the toolbar, switching between browsing and spatial windows."),
                ],
            ),
            Menu::new(
                "Go",
                vec![
                    k(Back, "Back", cmd('['), "Go to the previous folder."),
                    k(EnclosingFolder, "Enclosing Folder", cmd_key(Key::Up, Modifiers::NONE), "Go to the folder that contains this one."),
                    c(GoToFolder, "Go to Folder…", Some(cmd_with('g', Modifiers::SHIFT)), vec![], vec![Argument::new("path", ArgumentType::Path, "The folder to go to.")], "Go to the folder at a path."),
                    sep(),
                    k(Computer, "Computer", cmd_with('c', Modifiers::SHIFT), "Go to the top of the disk."),
                    k(Home, "Home", cmd_with('h', Modifiers::SHIFT), "Go to your home folder."),
                    k(Applications, "Applications", cmd_with('a', Modifiers::SHIFT), "Go to the Applications folder."),
                ],
            ),
            Menu::new(
                "Window",
                vec![
                    // The window asks; the compositor does it (P9.4).
                    k(Minimize, "Minimize Window", cmd('m'), "Put this window in the Dock."),
                    n(Zoom, "Zoom Window", "Grow this window to fill the screen, or back."),
                ],
            ),
            // Jaguar shows ⌘? here; not bound, ? being a shifted key.
            Menu::new("Help", vec![n(Help, "Mac Help", "Open help.")]),
        ],
    )
}

/// The Finder's contextual menus (P10.8): commands from the bar, by verb.
pub mod context {
    use super::*;
    /// Right-clicking an item; None is a separator.
    pub const ITEM: [Option<FinderVerb>; 8] = [Some(FinderVerb::Open), Some(FinderVerb::GetInfo), None, Some(FinderVerb::Duplicate), Some(FinderVerb::MakeAlias), Some(FinderVerb::MoveToTrash), None, Some(FinderVerb::Copy)];
    /// Right-clicking the folder's background.
    pub const BACKGROUND: [Option<FinderVerb>; 6] = [Some(FinderVerb::NewFolder), None, Some(FinderVerb::Paste), None, Some(FinderVerb::AsIcons), Some(FinderVerb::AsList)];

    /// A verb the model lacks is a bug, left out rather than drawn from
    /// nothing.
    pub fn menu(verbs: &[Option<FinderVerb>], model: &MenuBarModel) -> Menu {
        Menu::new("", verbs.iter().filter_map(|v| match v {
            None => Some(MenuItem::Separator),
            Some(v) => model.command(v.raw()).cloned().map(MenuItem::Command),
        }).collect())
    }
}

/// What the bar offers with no application to ask (MenuBar.swift): the
/// Finder's implemented verbs, nothing else yet.
pub fn static_enablement(c: &Command) -> Enablement {
    match FinderVerb::from_raw(&c.verb) {
        Some(v) if v.is_implemented() => Enablement::Enabled,
        Some(_) => Enablement::Disabled("the Finder cannot do this yet".into()),
        None => Enablement::Disabled("not available yet".into()),
    }
}
