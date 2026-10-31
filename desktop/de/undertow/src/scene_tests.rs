//! The scene, short of a client: what it latches, culls and draws when the
//! compositor's own pictures are all there is (the lock, Ebb's dimming, the
//! Shoals strip), drawn through a headless output and read back. Windows
//! need clients, and come with the shell protocols (R4e).

use super::*;
use crate::backend::{WlrootsOutput, WlrootsSession};
use crate::ebb::{Ebb, EbbSlot};
use crate::geometry::EbbScope;
use std::cell::RefCell;

#[derive(Default)]
struct Fake {
    locked: bool,
    ebb: Option<Ebb>,
    tiles: Vec<(usize, Rect)>,
    label: Option<Label>,
    cursor: u64,
    inputs: u64,
}

impl World for Fake {
    fn take_island_input(&mut self, _: &str) -> u64 {
        std::mem::take(&mut self.inputs)
    }
    fn is_locked(&self) -> bool {
        self.locked
    }
    fn lock_surfaces(&self) -> Vec<(Surface, i32, i32)> {
        vec![]
    }
    fn mapped_layers(&self) -> Vec<SceneLayer> {
        vec![]
    }
    fn toplevels(&self) -> Vec<SceneWindow> {
        vec![]
    }
    fn is_on_active_island(&self, _: &SceneWindow) -> bool {
        true
    }
    fn ebb_frame(&mut self, _: &str, _: u64) -> Option<Ebb> {
        self.ebb.clone()
    }
    fn island_view(&mut self, _: &str, _: u64) -> Option<f64> {
        None
    }
    fn strip_tiles(&self, _: &str) -> Vec<(usize, Rect)> {
        self.tiles.clone()
    }
    fn shoal(&self, _: usize) -> (String, Vec<String>) {
        ("Work".into(), vec![])
    }
    fn frame_texture(&mut self, _: &SceneWindow) -> Option<Texture> {
        None
    }
    fn ebb_label(&mut self, _: &SceneWindow) -> Option<Label> {
        None
    }
    fn strip_label(&mut self, _: &str) -> Option<Label> {
        self.label
    }
    fn mapped_popups(&self) -> Vec<(Surface, i32, i32)> {
        vec![]
    }
    fn input_method_popups(&self) -> Vec<(Surface, i32, i32)> {
        vec![]
    }
    fn acquire(&self, _: Surface) -> Option<(Timeline, u64)> {
        None
    }
    fn cursor_signature(&self) -> u64 {
        self.cursor
    }
    fn theme_generation(&self) -> u64 {
        0
    }
}

fn display(name: &str, x: i32, w: i32, h: i32, scale: f64) -> DisplayBox {
    DisplayBox { scale, ..DisplayBox::new(name, x, 0, w, h) }
}

fn metrics() -> FrameMetrics {
    FrameMetrics { title_height: 22.0, border: 1.0 }
}

/// Draw `scene` on a 64×48 headless output and read the pixels back.
fn draw(session: &WlrootsSession, scene: Rc<RefCell<SurfaceScene<Fake>>>) -> Vec<[u8; 3]> {
    let mut out = WlrootsOutput::new(session.outputs()[0], session);
    out.set_painter(scene);
    let path = std::env::temp_dir().join(format!("undertow-scene-{}-{:?}.ppm", std::process::id(), std::thread::current().id()));
    assert!(out.capture_ppm(&path.to_string_lossy()));
    let ppm = std::fs::read(&path).unwrap();
    let _ = std::fs::remove_file(&path);
    ppm[ppm.len() - out.width() as usize * out.height() as usize * 3..].chunks(3).map(|p| [p[0], p[1], p[2]]).collect()
}

fn at(px: &[[u8; 3]], x: usize, y: usize) -> [u8; 3] {
    px[y * 64 + x]
}

#[test]
fn a_locked_display_shows_the_lock_colour_and_nothing_else() {
    let s = WlrootsSession::headless(1, 64, 48, 60_000, false).unwrap();
    let world = Fake { locked: true, tiles: vec![(0, Rect::new(4, 4, 20, 20))], ..Fake::default() };
    let scene = Rc::new(RefCell::new(SurfaceScene::new(world, &display("HEADLESS-1", 0, 64, 48, 1.0), metrics(), 64)));
    let px = draw(&s, scene.clone());
    assert_eq!(scene.borrow().count, 0, "not the strip, not anything");
    let c = |v: f32| (v * 255.0) as u8;
    let want = [c(LOCKED_COLOUR.0), c(LOCKED_COLOUR.1), c(LOCKED_COLOUR.2)];
    assert!(px.iter().all(|p| p.iter().zip(want).all(|(a, b)| a.abs_diff(b) <= 1)), "{:?}", at(&px, 10, 10));
}

/// Ebb dims the whole display by half its progress: open, the desktop is
/// half as bright.
#[test]
fn ebb_dims_the_desktop() {
    let s = WlrootsSession::headless(1, 64, 48, 60_000, false).unwrap();
    let ebb = Ebb::new("HEADLESS-1", EbbScope::Island, vec![EbbSlot { window: 9, home: Rect::default(), slot: Rect::default() }], 0, 0);
    let world = Fake { ebb: Some(ebb), tiles: vec![(0, Rect::new(4, 4, 20, 20))], ..Fake::default() };
    let scene = Rc::new(RefCell::new(SurfaceScene::new(world, &display("HEADLESS-1", 0, 64, 48, 1.0), metrics(), 64)));
    let px = draw(&s, scene.clone());
    assert_eq!(scene.borrow().count, 1, "the dimming alone: a slot whose window is gone is skipped, and no strip under Ebb");
    // Jaguar blue (0.24, 0.40, 0.63), half covered by black.
    let p = at(&px, 30, 30);
    assert!(p[0].abs_diff(31) <= 2 && p[1].abs_diff(51) <= 2 && p[2].abs_diff(80) <= 2, "{p:?}");
}

/// The strip: a dark plate per tile, its name's label centred at the foot.
#[test]
fn the_strip_draws_its_plate_and_label() {
    let s = WlrootsSession::headless(1, 64, 48, 60_000, false).unwrap();
    let white = [0xffu8; 4].repeat(8 * 4);
    let tex = s.renderer().texture_from_pixels(0x3432_5241, 32, 8, 4, &white).unwrap();
    let world = Fake { tiles: vec![(0, Rect::new(4, 4, 40, 30))], label: Some(Label { texture: tex, width: 8, height: 4 }), ..Fake::default() };
    let scene = Rc::new(RefCell::new(SurfaceScene::new(world, &display("HEADLESS-1", 0, 64, 48, 1.0), metrics(), 64)));
    let px = draw(&s, scene.clone());
    assert_eq!(scene.borrow().count, 2);
    let (_, _, label) = scene.borrow().entry(1);
    assert_eq!(label, Rect::new(4 + (40 - 8) / 2, 4 + 30 - 4 - 4, 8, 4));
    assert_eq!(at(&px, 22, 27), [255, 255, 255], "the label");
    // The plate, 0.08 0.10 0.16 at 0.78, over Jaguar blue.
    let plate = at(&px, 10, 10);
    assert!(plate.iter().zip([29, 41, 67]).all(|(a, b)| a.abs_diff(b) <= 1), "{plate:?}");
    assert_eq!(at(&px, 50, 40), [61, 102, 161], "outside it, Jaguar blue");
    tex.destroy();
}

/// Present on damage (M.1): a frame like the last one is not drawn, until
/// something changes, the scene is invalidated, or wlroots asks.
#[test]
fn an_unchanged_frame_is_said_to_be_unchanged() {
    let world = Fake { tiles: vec![(0, Rect::new(4, 4, 40, 30))], ..Fake::default() };
    let mut scene = SurfaceScene::new(world, &display("HEADLESS-1", 0, 64, 48, 1.0), metrics(), 64);
    assert!(!scene.latch_and_composite(0, 0).unchanged, "the first frame draws");
    let again = scene.latch_and_composite(1, 1);
    assert!(again.unchanged && again.damage_area == 0);
    scene.world.cursor = 7;
    assert!(!scene.latch_and_composite(2, 2).unchanged, "the cursor moved");
    assert!(scene.latch_and_composite(3, 3).unchanged);
    scene.invalidate();
    assert!(!scene.latch_and_composite(4, 4).unchanged, "invalidated");
    scene.dirty().set(true); // what needs_frame does
    assert!(!scene.latch_and_composite(5, 5).unchanged, "wlroots asked");
    scene.world.inputs = 42;
    assert_eq!(scene.latch_and_composite(6, 6).input_at, 42, "an island switch's stamp rides the frame that draws it");
}

/// The cull is in layout coordinates: a second display sees only what is
/// on it, clipped to its edges.
#[test]
fn the_cull_counts_what_is_on_this_display() {
    let world = Fake { tiles: vec![(0, Rect::new(1000, 4, 40, 30)), (1, Rect::new(4, 4, 40, 30))], ..Fake::default() };
    let mut scene = SurfaceScene::new(world, &display("RIGHT", 1024, 800, 600, 2.0), metrics(), 64);
    let f = scene.latch_and_composite(0, 0);
    assert_eq!(scene.count, 2);
    assert_eq!((f.surfaces, f.damage_area), (1, 16 * 30), "only the 16 px of the first plate that cross onto this display");
    assert_eq!(scene.project(Rect::new(1030, 10, 5, 5)), Rect::new(12, 20, 10, 10), "drawn at its scale");
}
