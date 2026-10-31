//! AquaDemo (main.swift beside it): the toolkit's scenes. So far offscreen
//! only, the scenes ported so far: AQUA_SCENE picks one, AQUA_SCALE its
//! scale, AQUA_RENDER_PNG where its one frame goes.

use aqua::scene::{render_scene_png, SceneKind};
use aquadraw::theme::{announcement, role_announcements, Outcome, Theme};
use std::process::exit;

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn main() {
    let scale: i32 = env("AQUA_SCALE").and_then(|s| s.parse().ok()).unwrap_or(1).max(1);
    let Some(mut runner) = aquadraw::scene::runner(scale) else {
        eprintln!("AquaDemo: no fonts (the toy-text fallback is not ported)");
        exit(1)
    };
    // The look is a file (P11.2): load it before a pixel is painted, and say
    // which, or that it fell back.
    let mut theme = Theme::default();
    let outcome = theme.load_current(None, Some(&mut runner));
    eprintln!("{}", announcement(&outcome));
    if let Outcome::Loaded(t, _) = &outcome {
        for l in role_announcements(&t.tokens) {
            eprintln!("{l}")
        }
    }
    let scene = env("AQUA_SCENE");
    let Some((kind, title, w, h)) = SceneKind::named(scene.as_deref()) else {
        eprintln!("AquaDemo: the scene {} is not ported to Rust yet", scene.unwrap_or_default());
        exit(2)
    };
    let Some(out) = env("AQUA_RENDER_PNG") else {
        eprintln!("AquaDemo: only AQUA_RENDER_PNG is ported so far (no window yet)");
        exit(2)
    };
    // Three clicks, as the golden has them.
    if render_scene_png(&out, kind, w, h, scale, title, 3, &mut runner, &theme) {
        println!("AquaDemo: wrote {out}");
    } else {
        println!("AquaDemo: PNG render failed");
        exit(1)
    }
}
