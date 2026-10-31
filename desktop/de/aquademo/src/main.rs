//! AquaDemo (main.swift beside it): the toolkit's scenes, the ones ported
//! so far. AQUA_SCENE picks one; AQUA_SCALE pins its scale; with
//! AQUA_RENDER_PNG one frame goes there and nothing connects, and without
//! it the scene is a window under WAYLAND_DISPLAY's compositor.

use aqua::scene::{render_scene_png, SceneKind};
use aqua::toolkit::Toolkit;
use aqua::window::AquaWindow;
use std::process::exit;

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn main() {
    let scale: i32 = env("AQUA_SCALE").and_then(|s| s.parse().ok()).unwrap_or(1).max(1);
    // The look is a file (P11.2): loaded before a pixel is painted, and
    // announced, or that it fell back.
    let Some(tk) = Toolkit::new(scale, None) else {
        eprintln!("AquaDemo: no fonts (the toy-text fallback is not ported)");
        exit(1)
    };
    let scene = env("AQUA_SCENE");
    // Render-only scenes for the golden gate: an open menu, the icons, the
    // draw-list sheet.
    if let Some(s @ ("menu" | "icons" | "drawlist")) = scene.as_deref() {
        let Some(out) = env("AQUA_RENDER_PNG") else {
            eprintln!("AquaDemo: the {s} scene is render-only (AQUA_RENDER_PNG)");
            exit(2)
        };
        let (mut runner, theme) = (tk.runner.borrow_mut(), tk.theme.borrow());
        let ok = match s {
            "menu" => aqua::scene::render_menu_png(&out, scale, env("AQUA_MENU_MARKS").is_some(), &mut runner, &theme),
            "icons" => aqua::scene::render_icon_sheet_png(&out, env("AQUA_DRAWLIST").as_deref(), scale, &mut runner, &theme),
            _ => aqua::scene::render_drawlist_png(&out, &env("AQUA_DRAWLIST").unwrap_or_else(|| "abyss/tests/drawlist-sample.dl".into()), scale, &mut runner),
        };
        println!("{}", if ok { format!("AquaDemo: wrote {out}") } else { "AquaDemo: PNG render failed".into() });
        exit(if ok { 0 } else { 1 })
    }
    // The session's own scenes: each a surface of its own, not a window.
    if let Some(s @ ("lock" | "loginwindow" | "setupassistant")) = scene.as_deref() {
        let Some(display) = surface::Display::connect() else {
            println!("AquaDemo: cannot connect to a Wayland compositor (is WAYLAND_DISPLAY set, and does it offer xdg-shell?).");
            exit(1)
        };
        tk.follow_appearance(&display);
        session_scene(s, &display, &tk)
    }
    let Some((kind, title, w, h)) = SceneKind::named(scene.as_deref()) else {
        eprintln!("AquaDemo: the scene {} is not ported to Rust yet", scene.unwrap_or_default());
        exit(2)
    };
    let Some(out) = env("AQUA_RENDER_PNG") else {
        let Some(display) = surface::Display::connect() else {
            println!("AquaDemo: cannot connect to a Wayland compositor (is WAYLAND_DISPLAY set, and does it offer xdg-shell?).");
            exit(1)
        };
        tk.follow_appearance(&display);
        if kind == SceneKind::Wallpaper {
            let Some(_wallpaper) = aqua::wallpaper::Wallpaper::new(&display, &tk) else {
                println!("AquaDemo: failed to create the wallpaper (does the compositor offer wlr-layer-shell?).");
                exit(1)
            };
            println!("AquaDemo: wallpaper (layer-shell BACKGROUND) is up.");
            display.run();
            exit(0)
        }
        if kind == SceneKind::MenuBar {
            let Some(_bar) = aqua::menubar::MenuBar::new(&display, &tk) else {
                println!("AquaDemo: failed to create the menu bar (does the compositor offer wlr-layer-shell?).");
                exit(1)
            };
            println!("AquaDemo: menu bar (layer-shell TOP) is up.");
            display.run();
            exit(0)
        }
        if kind == SceneKind::Finder {
            // The app owns its windows; this reference keeps them.
            let finder = aqua::finder::FinderApp::new(&display, &tk, (w, h), true);
            if !finder.open_initial_window(None) {
                println!("AquaDemo: failed to create the Finder window.");
                exit(1)
            }
            println!("AquaDemo: Finder is up ({}, {} mode).", aqua::finder::start_directory(), if finder.toolbar_visible() { "browser" } else { "spatial" });
            display.run();
            exit(0)
        }
        if kind == SceneKind::Activity {
            let Some(_am) = aqua::activity::ActivityMonitor::new(&display, &tk) else {
                println!("AquaDemo: failed to open Activity Monitor.");
                exit(1)
            };
            eprintln!("AquaDemo: Activity Monitor is up.");
            display.run();
            exit(0)
        }
        if kind == SceneKind::Grab {
            let Some(_grab) = aqua::grab::GrabApp::new(&display, &tk) else {
                println!("AquaDemo: failed to open Grab.");
                exit(1)
            };
            eprintln!("AquaDemo: Grab is up.");
            display.run();
            exit(0)
        }
        if kind == SceneKind::TextEdit {
            // The arguments are files to open; none, an empty document.
            let textedit = aqua::textedit::TextEditApp::new(&display, &tk);
            let files: Vec<String> = std::env::args().skip(1).collect();
            let any = files.iter().filter(|f| textedit.open(Some(f))).count() > 0;
            if !any && !textedit.open(None) {
                println!("AquaDemo: failed to open a TextEdit window.");
                exit(1)
            }
            eprintln!("AquaDemo: TextEdit is up.");
            display.run();
            exit(0)
        }
        if kind == SceneKind::Terminal {
            // `-e PROGRAM ARGS…` runs that instead of the shell, as xterm's
            // does: how a bundle whose entry says Terminal=true opens.
            let args: Vec<String> = std::env::args().collect();
            let command = args.iter().position(|a| a == "-e").map(|i| args[i + 1..].to_vec());
            let terminal = aqua::terminal_app::TerminalApp::new(&display, &tk, command);
            if !terminal.open_window() {
                println!("AquaDemo: failed to open a Terminal window.");
                exit(1)
            }
            eprintln!("AquaDemo: Terminal is up.");
            display.run();
            exit(0)
        }
        if kind == SceneKind::Installer {
            // Ask the machine what it has, once, before the first frame: if
            // the service is not there the hub says so on the disk spoke.
            let (inventory, why) = aqua::installer::disks();
            let n = inventory.disks.len();
            let mut model = aqua::installer::InstallerModel::new(inventory);
            model.inventory_error = why.clone();
            let Some(_app) = aqua::installer::InstallerApp::new(&display, &tk, title, w, h, model) else {
                println!("AquaDemo: failed to create the installer window.");
                exit(1)
            };
            // stderr: unbuffered, for the test waiting on the log.
            eprintln!("AquaDemo: installer is up — {n} disk(s){}", if why.is_empty() { String::new() } else { format!(", and: {why}") });
            display.run();
            exit(0)
        }
        if kind == SceneKind::Prefs {
            let Some(app) = aqua::prefs::app::SystemPreferences::new(&display, &tk, (w, h)) else {
                println!("AquaDemo: could not open System Preferences.");
                exit(1)
            };
            let d = std::rc::Rc::downgrade(&display);
            app.on_quit(move || {
                if let Some(d) = d.upgrade() {
                    d.stop()
                }
            });
            eprintln!("AquaDemo: System Preferences is up ({} panes)", aqua::prefs::all_panes().count());
            display.run();
            exit(0)
        }
        if kind == SceneKind::Dock {
            let Some(_dock) = aqua::dock::Dock::new(&display, &tk) else {
                println!("AquaDemo: failed to create the Dock (does the compositor offer wlr-layer-shell?).");
                exit(1)
            };
            println!("AquaDemo: Dock (layer-shell BOTTOM) is up.");
            display.run();
            exit(0)
        }
        let Some(_window) = AquaWindow::new(&display, &tk, title, kind, w, h) else {
            println!("AquaDemo: failed to create the window.");
            exit(1)
        };
        println!("AquaDemo: window is up. Close it to quit.");
        display.run();
        exit(0)
    };
    // Three clicks, as the golden has them.
    if render_scene_png(&out, kind, w, h, scale, title, 3, &mut tk.runner.borrow_mut(), &tk.theme.borrow()) {
        println!("AquaDemo: wrote {out}");
    } else {
        println!("AquaDemo: PNG render failed");
        exit(1)
    }
}

/// The lock screen, the login window and the Setup Assistant.
fn session_scene(scene: &str, display: &std::rc::Rc<surface::Display>, tk: &std::rc::Rc<Toolkit>) -> ! {
    use std::cell::Cell;
    use std::io::Write;
    use std::rc::Rc;
    match scene {
        // An ext-session-lock client: exits 0 once the authenticator said
        // yes and the session is given back, 1 if the compositor would not
        // lock. The outcome also goes to stdout, one word, unbuffered:
        // anchor reads it from a pipe to tell an unlock from a crash
        // (P16.2c), with no exit status to tell it on FreeBSD.
        "lock" => {
            let outcome = |w: &str| {
                let mut o = std::io::stdout();
                let _ = writeln!(o, "abyss-lock-outcome: {w}");
                let _ = o.flush();
            };
            let Some(ls) = aqua::lock_screen::LockScreen::new(display, tk) else {
                eprintln!("AquaDemo: cannot lock (does the compositor offer ext-session-lock?).");
                outcome("refused");
                exit(1)
            };
            let unlocked = Rc::new(Cell::new(false));
            let (u, d) = (unlocked.clone(), Rc::downgrade(display));
            ls.on_done(move |ok| {
                u.set(ok);
                if let Some(d) = d.upgrade() {
                    d.stop()
                }
            });
            ls.on_locked(move || outcome("locked"));
            display.run();
            outcome(if unlocked.get() { "unlocked" } else { "refused" });
            exit(if unlocked.get() { 0 } else { 1 })
        }
        // The greeter session's one surface (P16.5a).
        // ABYSS_LOGINWINDOW_ACCOUNTS="name:Full Name:uid,…" stands in for the
        // password database in a test; the daemon still checks the named
        // account's real password, so a made-up list opens nothing.
        "loginwindow" => {
            let accounts = match env("ABYSS_LOGINWINDOW_ACCOUNTS") {
                Some(list) => list
                    .split(',')
                    .filter_map(|e| {
                        let f: Vec<&str> = e.split(':').collect();
                        let [name, full, uid] = f[..] else { return None };
                        Some(login::LoginAccount { name: name.into(), full_name: if full.is_empty() { name } else { full }.into(), uid: uid.parse().ok()? })
                    })
                    .collect(),
                None => login::accounts::system(),
            };
            let Some(_lw) = aqua::login_window::LoginWindow::new(display, tk, accounts) else {
                println!("AquaDemo: could not open the login window (does the compositor offer wlr-layer-shell?).");
                exit(1)
            };
            display.run();
            exit(0)
        }
        // An account's first login (P16.7).
        _ => {
            let Some(app) = aqua::setup_assistant::SetupAssistant::new(display, tk) else {
                println!("AquaDemo: could not open the Setup Assistant.");
                exit(1)
            };
            let d = Rc::downgrade(display);
            app.on_quit(move || {
                if let Some(d) = d.upgrade() {
                    d.stop()
                }
            });
            display.run();
            exit(0)
        }
    }
}
