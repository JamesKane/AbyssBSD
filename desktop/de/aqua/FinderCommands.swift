// FinderCommands — the Finder's commands, defined once (PHASE10.md P10.1).
//
// Before this file the Finder had two definitions of what it could do that did
// not know about each other: a `switch` on keysyms in `FinderWindow.commandKey`,
// and a list of strings in `MenuBar.defaultMenus`. Now there is this model. The
// key handler asks it which verb a key runs and the menu bar draws it, so
// ⌘D and File ▸ Duplicate are one command reached two ways.
//
// **`FinderVerb` is exhaustive on purpose.** `FinderWindow.perform` switches
// over it with no `default:`, so adding a command here is a compile error until
// the window has decided what the command does — the same structural guard
// §2.51 put on the installer's refusals. A verb the Finder cannot do yet says so
// in `isImplemented`, and is drawn disabled rather than left out: the menu is a
// faithful Jaguar Finder, and an item that does nothing must look like it.

/// Every command the Finder's menus carry.
public enum FinderVerb: String, CaseIterable, Sendable {
    // Finder (the application menu)
    case about = "finder.about"
    case preferences = "finder.preferences"
    case emptyTrash = "finder.empty-trash"
    case hide = "finder.hide"
    case hideOthers = "finder.hide-others"
    case showAll = "finder.show-all"
    // File
    case newWindow = "file.new-window"
    case newFolder = "file.new-folder"
    case open = "file.open"
    case closeWindow = "file.close-window"
    case getInfo = "file.get-info"
    case duplicate = "file.duplicate"
    case makeAlias = "file.make-alias"
    case moveToTrash = "file.move-to-trash"
    case saveHere = "file.save-here"
    case find = "file.find"
    // Edit
    case undo = "edit.undo"
    case redo = "edit.redo"
    case cut = "edit.cut"
    case copy = "edit.copy"
    case paste = "edit.paste"
    case selectAll = "edit.select-all"
    // View
    case asIcons = "view.as-icons"
    case asList = "view.as-list"
    case asColumns = "view.as-columns"
    case toggleToolbar = "view.toggle-toolbar"
    // Go
    case back = "go.back"
    case enclosingFolder = "go.enclosing-folder"
    case goToFolder = "go.to-folder"
    case computer = "go.computer"
    case home = "go.home"
    case applications = "go.applications"
    // Window
    case minimize = "window.minimize"
    case zoom = "window.zoom"
    // Help
    case help = "help.finder"

    /// Whether the Finder can do this at all yet. False means the item is drawn,
    /// disabled, with this as the reason — never silently absent.
    public var isImplemented: Bool {
        switch self {
        case .about, .preferences, .hide, .hideOthers, .showAll,
             .getInfo, .makeAlias, .find,
             .selectAll,                // the Finder selects one item at a time
             .asColumns, .help:
            return false
        case .emptyTrash, .newWindow, .newFolder, .open, .closeWindow,
             .duplicate, .moveToTrash, .saveHere,
             .undo, .redo,              // P10.5: per window, see Undo.swift
             .cut, .copy, .paste,
             .asIcons, .asList, .toggleToolbar,
             .back, .enclosingFolder, .goToFolder, .computer, .home, .applications,
             .minimize, .zoom:
            return true
        }
    }
}

/// The Finder's menus, as Jaguar laid them out. Pure, so a test can walk it.
public func finderMenuBar() -> MenuBarModel {
    func c(_ v: FinderVerb, _ title: String, _ key: KeyEquivalent,
           also: [KeyEquivalent] = [], args: [Argument] = [], _ summary: String) -> MenuItem {
        .command(Command(v.rawValue, title, key: key, alternateKeys: also,
                         arguments: args, summary: summary))
    }
    func c(_ v: FinderVerb, _ title: String, _ summary: String) -> MenuItem {
        .command(Command(v.rawValue, title, summary: summary))
    }
    return MenuBarModel(appName: "Finder", menus: [
        Menu("Finder", [
            c(.about, "About Finder", "Show the Finder's version."),
            .separator,
            c(.preferences, "Preferences…", "Change how the Finder behaves."),
            .separator,
            c(.emptyTrash, "Empty Trash…", .cmd(.backspace, .shift),
              "Permanently delete everything in the Trash."),
            .separator,
            c(.hide, "Hide Finder", .cmd("h"), "Hide the Finder's windows."),
            c(.hideOthers, "Hide Others", .cmd("h", .option),
              "Hide every other application's windows."),
            c(.showAll, "Show All", "Show every hidden window."),
        ]),
        Menu("File", [
            c(.newWindow, "New Finder Window", .cmd("n"),
              "Open a new window on your home folder."),
            c(.newFolder, "New Folder", .cmd("n", .shift),
              "Make an untitled folder here and name it."),
            c(.open, "Open", .cmd("o"), also: [.cmd(.down)],
              "Open the selected item."),
            c(.closeWindow, "Close Window", .cmd("w"), "Close this window."),
            .separator,
            c(.getInfo, "Get Info", .cmd("i"), "Show the selected item's details."),
            c(.duplicate, "Duplicate", .cmd("d"),
              "Copy the selected item beside itself."),
            c(.makeAlias, "Make Alias", .cmd("l"),
              "Make an alias of the selected item."),
            .separator,
            c(.moveToTrash, "Move to Trash", .cmd(.backspace),
              also: [.cmd(.forwardDelete)], "Move the selected item to the Trash."),
            c(.saveHere, "Save Here", .cmd("s"),
              "In a save dialog, save into the folder on screen."),
            .separator,
            c(.find, "Find…", .cmd("f"), "Search for files."),
        ]),
        Menu("Edit", [
            c(.undo, "Undo", .cmd("z"), "Undo the last change."),
            c(.redo, "Redo", .cmd("z", .shift), "Redo the change just undone."),
            .separator,
            c(.cut, "Cut", .cmd("x"),
              "Put the selected item on the clipboard, to be moved by Paste."),
            c(.copy, "Copy", .cmd("c"), "Put the selected item on the clipboard."),
            c(.paste, "Paste", .cmd("v"), "Copy or move the clipboard's item here."),
            c(.selectAll, "Select All", .cmd("a"), "Select every item here."),
        ]),
        Menu("View", [
            c(.asIcons, "as Icons", .cmd("1"), "Show items as icons."),
            c(.asList, "as List", .cmd("2"), "Show items as a list."),
            c(.asColumns, "as Columns", .cmd("3"), "Show items in columns."),
            .separator,
            c(.toggleToolbar, "Hide Toolbar", .cmd("b"),
              "Show or hide the toolbar, switching between browsing and spatial windows."),
        ]),
        Menu("Go", [
            c(.back, "Back", .cmd("["), "Go to the previous folder."),
            c(.enclosingFolder, "Enclosing Folder", .cmd(.up),
              "Go to the folder that contains this one."),
            c(.goToFolder, "Go to Folder…", .cmd("g", .shift),
              args: [Argument("path", .path, "The folder to go to.")],
              "Go to the folder at a path."),
            .separator,
            c(.computer, "Computer", .cmd("c", .shift), "Go to the top of the disk."),
            c(.home, "Home", .cmd("h", .shift), "Go to your home folder."),
            c(.applications, "Applications", .cmd("a", .shift),
              "Go to the Applications folder."),
        ]),
        Menu("Window", [
            // The window asks; the compositor does it (PHASE9 P9.4).
            c(.minimize, "Minimize Window", .cmd("m"), "Put this window in the Dock."),
            c(.zoom, "Zoom Window", "Grow this window to fill the screen, or back."),
        ]),
        Menu("Help", [
            // Jaguar shows ⌘? here. Not bound: ? is a shifted key, and
            // `keyEquivalent(keysym:modifiers:)` cannot match shifted
            // punctuation yet (see its comment).
            c(.help, "Mac Help", "Open help."),
        ]),
    ])
}

/// The Finder's contextual menus (P10.8) — commands from `finderMenuBar()`,
/// picked by verb, so they are the same commands the menu bar shows.
public enum FinderContext {
    /// Right-clicking an item.
    public static let item: [FinderVerb?] = [.open, .getInfo, nil, .duplicate, .makeAlias,
                                             .moveToTrash, nil, .copy]
    /// Right-clicking the folder's background.
    public static let background: [FinderVerb?] = [.newFolder, nil, .paste, nil,
                                                   .asIcons, .asList]

    /// `nil` is a separator. A verb the model does not have is a bug, and is
    /// left out rather than drawn from nothing.
    public static func menu(_ verbs: [FinderVerb?], in model: MenuBarModel) -> Menu {
        Menu("", verbs.compactMap { v -> MenuItem? in
            guard let v else { return .separator }
            return model.command(v.rawValue).map { .command($0) }
        })
    }
}
