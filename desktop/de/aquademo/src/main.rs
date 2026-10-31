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
