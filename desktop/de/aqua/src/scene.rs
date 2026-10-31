//! Scenes (Scene.swift): what a window draws, and one frame of it rendered
//! offscreen, for headless checks and the goldens.

use aquadraw::canvas::Canvas;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::{Rect, Runner};
use aquadraw::text::Style;
use aquadraw::theme::Theme;
use abyss_sys::{self as ffi, Context, Pattern, Surface};

/// What AquaDemo shows (AQUA_SCENE).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SceneKind {
    Window,
    Widgets,
    Scroll,
    Tabs,
    Sheet,
    /// The desktop: a layer-shell BACKGROUND surface live, full-bleed in a
    /// PNG.
    Wallpaper,
    /// The menu bar: a TOP layer surface live; over the wallpaper in a PNG.
    MenuBar,
    /// The Dock: a BOTTOM layer surface live; over the wallpaper in a PNG.
    Dock,
    /// The Finder: its own application, many windows.
    Finder,
    /// System Preferences.
    Prefs,
    /// The guided installer: its own window live.
    Installer,
    /// Terminal: its own windows live, sized to 80×24.
    Terminal,
    /// TextEdit: a window per document live.
    TextEdit,
    /// Grab's panel: with the pictures it takes, live.
    Grab,
    /// Activity Monitor: the process table.
    Activity,
    /// Disk Utility: disks, datasets, snapshots.
    DiskUtility,
    /// The notification centre: an OVERLAY surface only while there are
    /// toasts, and the `notify` service.
    Notify,
    /// "… has unexpectedly quit": started by the keeper, live.
    CrashReport,
    /// The Agent window: its conversation, live with a session.
    Agent,
}

impl SceneKind {
    /// The scene AQUA_SCENE names, its title and its size, as AquaDemo has
    /// them. None for one not ported yet.
    pub fn named(name: Option<&str>) -> Option<(SceneKind, &'static str, i32, i32)> {
        match name {
            Some("widgets") => Some((SceneKind::Widgets, "Aqua Controls", 460, 360)),
            Some("scroll") => Some((SceneKind::Scroll, "Scroll", 360, 420)),
            Some("tabs") => Some((SceneKind::Tabs, "Tab View", 480, 380)),
            Some("sheet") => Some((SceneKind::Sheet, "Sheets", 440, 320)),
            Some("wallpaper") => Some((SceneKind::Wallpaper, "Desktop", 800, 600)),
            Some("menubar") => Some((SceneKind::MenuBar, "Menu Bar", 800, 600)),
            Some("dock") => Some((SceneKind::Dock, "Dock", 800, 600)),
            Some("finder") => Some((SceneKind::Finder, "Finder", 520, 400)),
            Some("sysprefs") => Some((SceneKind::Prefs, "System Preferences", 760, 620)),
            // Wide enough for a disk row to say why it cannot be used.
            Some("installer") => Some((SceneKind::Installer, "Install AbyssBSD", 620, 460)),
            // Live, Terminal sizes its window to 80×24 itself.
            Some("terminal") => Some((SceneKind::Terminal, "Terminal", 500, 340)),
            // Live, the arguments are files to open.
            Some("textedit") => Some((SceneKind::TextEdit, "TextEdit", 520, 380)),
            Some("grab") => Some((SceneKind::Grab, "Grab", 420, 150)),
            Some("activity") => Some((SceneKind::Activity, "Activity Monitor", 620, 360)),
            Some("diskutility") => Some((SceneKind::DiskUtility, "Disk Utility", 700, 440)),
            Some("notify") => Some((SceneKind::Notify, "Notifications", 800, 600)),
            Some("agent") => Some((SceneKind::Agent, "Agent", 560, 460)),
            Some("crashreport") => Some((SceneKind::CrashReport, "", 480, 180)),
            None | Some("window") => Some((SceneKind::Window, "AbyssBSD", 440, 300)),
            _ => None,
        }
    }
}

/// The demo window: chrome, a welcome, a click counter, a live text field
/// and a default button. Returns the button's rect, for hit-testing.
#[allow(clippy::too_many_arguments)]
pub fn paint_aqua_window(c: &mut Canvas, w: f64, h: f64, title: &str, clicks: u64, pressed: bool, typed: &str, focused: bool) -> Rect {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, title, false, true);
    let t = c.theme.tokens.clone();
    c.text_left("Welcome to AbyssBSD", 24.0, 70.0, t.body_text, 16.0, Style::Regular, Role::Interface);
    c.text_left("A Swift 6 desktop, dressed in Aqua.", 24.0, 94.0, t.body_text.with_a(0.7), t.font_size, Style::Regular, Role::Interface);
    c.text_left(&format!("Clicks: {clicks}"), 24.0, 132.0, t.body_text, t.font_size, Style::Regular, Role::Interface);
    // A live text field: real keyboard input lands here.
    c.text_field(Rect::new(24.0, 150.0, w - 48.0, 26.0), typed, focused, "");
    let (bw, bh) = (120.0, 30.0);
    let button = Rect::new(w - bw - 20.0, h - bh - 20.0, bw, bh);
    c.gel_button(button, "Click Me", true, pressed);
    button
}

/// One scene rendered to a PNG: the desktop-grey backdrop, and the scene's
/// window inset on it.
#[allow(clippy::too_many_arguments)]
pub fn render_scene_png(path: &str, kind: SceneKind, width: i32, height: i32, scale: i32, title: &str, clicks: u64, runner: &mut Runner, theme: &Theme) -> bool {
    let cs = Surface::image(ffi::FORMAT_ARGB32, width * scale, height * scale);
    {
        let cr = Context::new(&cs);
        cr.scale(scale as f64, scale as f64);
        let was = runner.text.render_scale;
        runner.text.render_scale = scale; // shape and hint on the device grid
        // The shell's surfaces are full-bleed: no grey desktop, no inset.
        if matches!(kind, SceneKind::Wallpaper | SceneKind::MenuBar | SceneKind::Dock) {
            let mut c = Canvas::new(&cr, runner, theme);
            crate::wallpaper::paint_wallpaper(&mut c, width as f64, height as f64);
            if kind == SceneKind::Wallpaper {
                let top = theme.tokens.desktop_top_inset;
                let bounds = Rect::new(0.0, top, width as f64, height as f64 - top);
                // The desktop's own icons, over a fixed listing.
                crate::desktop_icons::paint_desktop_icons(&mut c, bounds, &crate::desktop_icons::desktop_sample_entries(), Some(1));
            } else if kind == SceneKind::MenuBar {
                paint_menu_bar_scene(&mut c, width as f64);
            } else {
                paint_dock_scene(&mut c, width as f64, height as f64);
            }
            runner.text.render_scale = was;
            drop(cr);
            cs.flush();
            return cs.write_png(path);
        }
        let g = Pattern::linear(0.0, 0.0, 0.0, height as f64);
        g.add_color_stop_rgba(0.0, 0.62, 0.66, 0.72, 1.0);
        g.add_color_stop_rgba(1.0, 0.50, 0.54, 0.60, 1.0);
        cr.set_source(&g);
        cr.paint();
        let inset = 16.0;
        cr.save();
        cr.translate(inset, inset);
        let (cw, ch) = (width as f64 - 2.0 * inset, height as f64 - 2.0 * inset);
        let mut c = Canvas::new(&cr, runner, theme);
        match kind {
            SceneKind::Window => {
                paint_aqua_window(&mut c, cw, ch, title, clicks, false, "", false);
            }
            SceneKind::Scroll => {
                crate::scroll::paint_scroll(&mut c, cw, ch, 0.0);
            }
            SceneKind::Tabs => {
                crate::tabs::paint_tabs(&mut c, cw, ch, crate::tabs::TabsState::default());
            }
            // The sheet fully out, for the still.
            SceneKind::Sheet => {
                crate::sheet::paint_sheet_scene(&mut c, cw, ch, 1.0, true, "—");
            }
            SceneKind::Widgets => {
                crate::widgets::paint_widgets(&mut c, cw, ch, &crate::widgets::WidgetState::default(), Some(crate::widgets::WidgetFocus::Ok));
            }
            // AQUA_PREFS_PANE=<id> pictures a pane's page (P14.1).
            SceneKind::Prefs => {
                let mut m = crate::prefs::PrefsModel::default();
                let mut panes = crate::prefs::app::sample_panes();
                if let Ok(p) = std::env::var("AQUA_PREFS_PANE") {
                    // "network-wifi": the Network pane with its radio chosen (P14.5c).
                    if p == "network-wifi" {
                        use crate::prefs::network::{NetworkPane, NetworkPaneState};
                        panes.retain(|x| x.id() != "network");
                        panes.push(NetworkPane::new(NetworkPaneState::sample_wifi()));
                        m.view = crate::prefs::PrefsView::Pane("network".into())
                    } else if p == "accounts-new" {
                        // "accounts-new": the Accounts pane with New User… open (P16.6a).
                        use crate::prefs::accounts::{AccountsPane, AccountsPaneState};
                        panes.retain(|x| x.id() != "accounts");
                        panes.push(AccountsPane::new(AccountsPaneState::sample_new()));
                        m.view = crate::prefs::PrefsView::Pane("accounts".into())
                    } else {
                        m.view = crate::prefs::PrefsView::Pane(p)
                    }
                }
                crate::prefs::paint_system_preferences(&mut c, cw, ch, &m, &panes);
            }
            SceneKind::Finder => {
                crate::finder::paint_finder(&mut c, cw, ch, &finder_scene_state());
            }
            // A fixed document: wrapped lines, a tab, a selection across a
            // line break, and the find bar with its text.
            SceneKind::TextEdit => {
                use text_model::{TextPosition, TextRange};
                let mut view = crate::text_view::TextView::new(crate::textedit::sample_text(), &mut c.runner.text);
                view.edit(|m| m.select(TextRange::new(TextPosition::new(2, 6), TextPosition::new(3, 9))));
                crate::textedit::paint_textedit(&mut c, cw, ch, "Notes.txt — Edited", &mut view, Some("wraps"), false, true);
            }
            // A sample stack: the toast without a live service to post into it.
            SceneKind::Notify => crate::notify::paint_sample(&mut c, cw),
            // A fixed machine: one disk, a pool, a dataset with two snapshots.
            SceneKind::DiskUtility => {
                crate::diskutility::paint_disk_utility(&mut c, cw, ch, &crate::diskutility::sample_view());
            }
            // A fixed table: names, users and numbers that do not change.
            SceneKind::Activity => {
                crate::activity::paint_activity(&mut c, cw, ch, &crate::activity::sample_view(), &crate::activity::sample_user);
            }
            SceneKind::Agent => crate::agent_app::paint_sample(&mut c, cw, ch),
            SceneKind::CrashReport => {
                let n = crate::crash_report::CrashNotice::new(1, "galculator", "SIGSEGV", true);
                use crate::crash_report::CrashChoice::{Ask, Close};
                crate::crash_report::paint_crash_report(&mut c, cw, ch, &n, None, &[Close, Ask]);
            }
            SceneKind::Grab => {
                crate::grab::paint_grab_panel(&mut c, cw, ch, "Choose what to capture.");
            }
            // A fixed transcript through the real screen model.
            SceneKind::Terminal => {
                crate::terminal_app::paint_terminal(&mut c, cw, ch, "sh — 70×20", &crate::terminal_app::sample_screen(), true, true, 0, None);
            }
            // A fixed synthetic machine; AQUA_INSTALLER_PAGE picks the screen.
            SceneKind::Installer => {
                let (m, focus) = crate::installer::sample_at(std::env::var("AQUA_INSTALLER_PAGE").ok().as_deref());
                crate::installer::paint_installer(&mut c, cw, ch, &m, focus, false);
            }
            SceneKind::Wallpaper | SceneKind::MenuBar | SceneKind::Dock => {}
        }
        cr.restore();
        runner.text.render_scale = was;
    }
    cs.flush();
    cs.write_png(path)
}

/// A fixed home folder, the same on any machine. AQUA_FINDER_PATH=
/// applications pictures /Applications (the desktop's own, wearing the
/// theme's icons, Utilities, and a port's bundle with no icon);
/// AQUA_FINDER_VIEW=list the list; AQUA_FINDER_STATE "rename" (item 2's name
/// edited, part selected, Back enabled) or "back" (Back held, the rename
/// down to its caret).
fn finder_scene_state() -> crate::finder::FinderState {
    use crate::finder::{FinderEdit, FinderState};
    use crate::finder_model::{finder_sample_entries, finder_sort, FinderEntry, FinderItemKind, FinderView};
    let env = |k: &str| std::env::var(k).ok();
    let apps = env("AQUA_FINDER_PATH").as_deref() == Some("applications");
    let entries = if apps {
        let mut v: Vec<FinderEntry> = app_bundles::BUILTIN_APPS.iter().filter(|b| b.folder == Some("")).map(|b| FinderEntry { icon_path: Some(format!("{}{}", crate::app_icon::THEME_PREFIX, b.theme_icon())), ..FinderEntry::new(&format!("{}.app", b.name), FinderItemKind::Application) }).collect();
        v.push(FinderEntry::new("Utilities", FinderItemKind::Folder));
        v.push(FinderEntry::new("Galculator.app", FinderItemKind::Application));
        finder_sort(v)
    } else {
        finder_sample_entries()
    };
    let mut s = FinderState::new(if apps { "/Applications" } else { "/Users/abyss" }, entries);
    s.selection = Some(2);
    s.free_bytes = 39_600_000_000;
    if env("AQUA_FINDER_VIEW").as_deref() == Some("list") {
        s.view = FinderView::List
    }
    let name = s.entries[2].name.clone();
    match env("AQUA_FINDER_STATE").as_deref() {
        Some("rename") => {
            s.can_go_back = true;
            s.edit = Some(FinderEdit { index: 2, text: name, selected_prefix: 4 })
        }
        Some("back") => {
            s.can_go_back = true;
            s.back_pressed = true;
            s.edit = Some(FinderEdit { index: 2, text: format!("{name} copy"), selected_prefix: 0 })
        }
        _ => {}
    }
    s
}

/// AQUA_AGENTS=STATE:N pictures N agent sessions in STATE (P18.13b): the
/// Dock tile's badge, and the menu bar's Agent item.
pub fn pictured_agents() -> Vec<crate::agent_presence::AgentPresence> {
    use crate::agent_presence::{AgentPresence, AgentState};
    let Some((st, n)) = std::env::var("AQUA_AGENTS").ok().and_then(|e| e.split_once(':').and_then(|(s, n)| Some((AgentState::from_name(s)?, n.parse::<i32>().ok()?)))) else { return vec![] };
    (0..n).map(|i| AgentPresence::new(1000 + i, st, "")).collect()
}

/// The menu bar as the headless render has it: the Finder's menus, Monday
/// 9:41, the machine's status read as the live bar reads it (so an item
/// that would show live shows here too), and AQUA_MENUBAR_OPEN=i picturing
/// title i open (0 is the system menu's mark).
fn paint_menu_bar_scene(c: &mut Canvas, w: f64) {
    use crate::menubar::{format_menu_clock, menus_for, paint_menu_bar, BarState};
    let pictured = pictured_agents();
    let agent = crate::agent_presence::menu_bar_agent_label(&pictured);
    let clock = format_menu_clock(9, 41, 1);
    let s = BarState {
        clock: &clock,
        show_clock: true,
        open_index: std::env::var("AQUA_MENUBAR_OPEN").ok().and_then(|v| v.parse().ok()),
        status: crate::menubar_status::MenuBarStatus::read(),
        agent: agent.as_deref(),
        agent_waiting: pictured.iter().any(|a| a.state == crate::agent_presence::AgentState::Waiting),
        ..BarState::default()
    };
    let h = c.theme.tokens.menu_bar_height;
    paint_menu_bar(c, w, h, &menus_for(&crate::finder_commands::finder_menu_bar()), &s);
}

/// The stock Dock as the headless render has it, at the output's bottom:
/// the pointer near a tile to show the curve; AQUA_DOCK_RUNNING marks every
/// other application running (never the Trash); AQUA_AGENTS adds the Agent
/// tile and its badge.
fn paint_dock_scene(c: &mut Canvas, w: f64, h: f64) {
    use crate::dock::{default_pinned, dock_surface_height, paint_dock, DockItem};
    let pictured = pictured_agents();
    let dock_h = dock_surface_height(&c.theme.tokens, 48.0);
    let mut items = default_pinned(pool_config::Agents::on(None));
    if !pictured.is_empty()
        && let Some(b) = crate::dock::builtin_running("org.abyssbsd.agent")
    {
        let at = items.len().min(3);
        items.insert(at, DockItem { command: None, environment: vec![], ..b })
    }
    items.push(DockItem::trash(false));
    let running = std::env::var_os("AQUA_DOCK_RUNNING").is_some();
    let flags: Vec<bool> = items.iter().enumerate().map(|(i, it)| running && i % 2 == 0 && !it.is_trash).collect();
    c.cr.save();
    c.cr.translate(0.0, h - dock_h);
    paint_dock(c, w, dock_h, &items, &flags, Some(w * 0.42), 48.0, true, crate::agent_presence::AgentBadge::of(&pictured));
    c.cr.restore();
}

/// An open menu (Scene.swift's renderMenuPNG): the Finder's File menu with
/// New Folder hovered, or, with `marks`, the parts File never shows: a
/// checked row, and a submenu's ▸ plain, disabled and highlighted.
pub fn render_menu_png(path: &str, scale: i32, marks: bool, runner: &mut Runner, theme: &Theme) -> bool {
    use crate::commands::{aqua_menu_items, aqua_menu_rows, AquaMenuItem};
    use crate::finder_commands::{finder_menu_bar, static_enablement};
    use crate::menu::AquaMenu;
    let t = theme.tokens.clone();
    let rows = if marks {
        vec![AquaMenuItem::new("as Icons"), AquaMenuItem::new("as List"), AquaMenuItem::separator(), AquaMenuItem::new("Arrange By").submenu(), AquaMenuItem::new("Label").disabled().submenu(), AquaMenuItem::new("Show View Options").key("⌘J").submenu()]
    } else {
        let bar = finder_menu_bar();
        let Some(file) = bar.menus.iter().find(|m| m.title == "File") else { return false };
        aqua_menu_items(file, &static_enablement)
    };
    let hover = if marks { rows.len() - 1 } else { 1 };
    let mut menu = AquaMenu::new(rows, if marks { Some(0) } else { None });
    let was = runner.text.render_scale;
    runner.text.render_scale = scale;
    let w = menu.preferred_width(runner, &t).max(150.0) as i32;
    let h = menu.preferred_height(&t).ceil() as i32;
    let (ry, rh) = aqua_menu_rows(&menu.items, &t)[hover];
    menu.pointer_moved(ry + rh / 2.0, &t);
    let cs = Surface::image(ffi::FORMAT_ARGB32, w * scale, h * scale);
    {
        let cr = Context::new(&cs);
        cr.scale(scale as f64, scale as f64);
        // A transparent ground, so the rounded corners read.
        cr.set_operator(0); // CLEAR
        cr.paint();
        cr.set_operator(ffi::OPERATOR_OVER);
        let mut c = Canvas::new(&cr, runner, theme);
        menu.render(&mut c, w as f64, h as f64);
    }
    runner.text.render_scale = was;
    cs.flush();
    cs.write_png(path)
}

/// Every icon in the theme, or in a list file, at 16, 32 and 64 points
/// (Scene.swift's renderIconSheetPNG): `icon.*` and `dock.icon.*`, sorted,
/// twenty to a column.
pub fn render_icon_sheet_png(path: &str, list_file: Option<&str>, scale: i32, runner: &mut Runner, theme: &Theme) -> bool {
    use aquadraw::drawlist::{DrawListFile, DrawState};
    use aquadraw::runner::DrawContext;
    let own;
    let lists = match list_file {
        None => &theme.lists,
        Some(f) => {
            let Ok(text) = std::fs::read_to_string(f) else { return false };
            match DrawListFile::parse(&text) {
                Ok(l) => {
                    own = l;
                    &own
                }
                Err(e) => {
                    eprintln!("AquaDemo: {f}: {e}");
                    return false;
                }
            }
        }
    };
    let mut names: Vec<&String> = lists.lists.keys().filter(|k| (k.starts_with("icon.") || k.starts_with("dock.icon.")) && !k.ends_with(".small")).collect();
    names.sort();
    if names.is_empty() {
        return false;
    }
    let per_column = 20;
    let columns = names.len().div_ceil(per_column);
    let (row_h, col_w) = (72.0, 140.0);
    let (w, h) = ((col_w * columns as f64) as i32 + 8, (row_h * names.len().min(per_column) as f64) as i32 + 8);
    let cs = Surface::image(ffi::FORMAT_ARGB32, w * scale, h * scale);
    let was = runner.text.render_scale;
    runner.text.render_scale = scale;
    {
        let cr = Context::new(&cs);
        cr.scale(scale as f64, scale as f64);
        let bg = theme.tokens.content_background;
        cr.set_source_rgba(bg.r, bg.g, bg.b, bg.a);
        cr.paint();
        let small_below = theme.tokens.icon_small_below;
        for (i, n) in names.iter().enumerate() {
            let (x0, y0) = (4.0 + col_w * (i / per_column) as f64, 4.0 + row_h * (i % per_column) as f64);
            let mut x = x0;
            for size in [16.0, 32.0, 64.0] {
                let r = Rect::new(x, y0 + (64.0 - size) / 2.0, size, size);
                if list_file.is_none() {
                    Canvas::new(&cr, runner, theme).icon(n, r);
                } else {
                    let small = format!("{n}.small");
                    let name = if r.w < small_below && lists.get(&small).is_some() { small.as_str() } else { n.as_str() };
                    if let Some(l) = lists.get(name) {
                        cr.new_path();
                        runner.run(l, &cr, &DrawContext::new(r, DrawState::NORMAL, ""));
                    }
                }
                x += size + 6.0;
            }
        }
    }
    runner.text.render_scale = was;
    cs.flush();
    cs.write_png(path)
}

/// R0's draw-list sheet, from `list_file`, with the loaded theme's roles.
pub fn render_drawlist_png(path: &str, list_file: &str, scale: i32, runner: &mut Runner) -> bool {
    let Ok(text) = std::fs::read_to_string(list_file) else { return false };
    let file = match aquadraw::drawlist::DrawListFile::parse(&text) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("AquaDemo: {list_file}: {e}");
            return false;
        }
    };
    let was = runner.text.render_scale;
    runner.text.render_scale = scale;
    let cs = Surface::image(ffi::FORMAT_ARGB32, aquadraw::scene::WIDTH * scale, aquadraw::scene::HEIGHT * scale);
    {
        let cr = Context::new(&cs);
        aquadraw::scene::drawlist(&cr, scale, &file, runner);
    }
    runner.text.render_scale = was;
    cs.flush();
    cs.write_png(path)
}
