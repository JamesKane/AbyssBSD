//! The compositor core, with real clients: an shm xdg_toplevel on its own
//! thread, against a headless undertow on the test's.

use super::*;
use crate::backend::WlrootsOutput;
use crate::displays::DisplayBox;
use crate::output::{FrameSink, Output};
use crate::scene::SurfaceScene;
use abyss_sys::wl::ShmWindow;
use abyss_sys::Context;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use crate::geometry::EbbScope;
use abyss_sys::mono;
use aquadraw::theme::Theme;

struct Rig {
    c: Rc<Compositor>,
    _dir: String,
}

fn rig(tag: &str) -> Rig {
    rig_with(tag, &[])
}

/// A rig whose config directory holds `files` (name, text) before start.
fn rig_with(tag: &str, files: &[(&str, &str)]) -> Rig {
    let session = Rc::new(WlrootsSession::headless(1, 640, 480, 60_000, false).unwrap());
    let name = session.outputs()[0].name();
    let dir = std::env::temp_dir().join(format!("undertow-{tag}-{}", std::process::id())).to_string_lossy().into_owned();
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    for (name, text) in files {
        std::fs::write(format!("{dir}/{name}"), text).unwrap();
    }
    let layout = DisplayLayout { displays: vec![DisplayBox::new(&name, 0, 0, 640, 480)] };
    let socket = format!("undertow-test-{tag}-{}", std::process::id());
    let c = Compositor::new(session, layout, Some(&dir), Some(&socket), Theme::default(), aquadraw::scene::runner(1)).unwrap();
    assert_eq!(c.socket_name, socket);
    Rig { c, _dir: dir }
}

/// Serve clients until `done`, or five seconds.
fn pump(c: &Compositor, mut done: impl FnMut() -> bool) -> bool {
    let until = Instant::now() + Duration::from_secs(5);
    while Instant::now() < until {
        if done() {
            return true;
        }
        c.session.dispatch(5);
        c.end_frame();
    }
    done()
}

/// A client window, `w`×`h`, filled with `rgb`, served until the compositor
/// closes it (or `secs` pass). Says on `mapped` once its buffer is up.
fn client(socket: &str, title: &str, app: &str, (w, h): (i32, i32), rgb: (f64, f64, f64), secs: f64, mapped: mpsc::Sender<()>) -> thread::JoinHandle<bool> {
    let (socket, title, app) = (socket.to_owned(), title.to_owned(), app.to_owned());
    thread::spawn(move || {
        let Ok(mut win) = ShmWindow::open_on(Some(&socket), &title, &app, w, h, 1) else { return false };
        win.draw(|cs| {
            let cr = Context::new(cs);
            cr.set_source_rgb(rgb.0, rgb.1, rgb.2);
            cr.paint();
        });
        win.present();
        let _ = mapped.send(());
        win.run_for(secs);
        win.closed()
    })
}

#[test]
fn a_window_maps_centred_focused_and_published_and_closes_on_request() {
    let r = rig("map");
    let c = &r.c;
    let (tx, rx) = mpsc::channel();
    let j = client(&c.socket_name, "Notes", "org.test.notes", (200, 100), (1.0, 0.0, 0.0), 5.0, tx);
    assert!(pump(c, || rx.try_recv().is_ok() && c.mapped_toplevels().len() == 1), "the window never mapped");
    let t = c.mapped_toplevels()[0].clone();
    assert_eq!((t.width(), t.height()), (200, 100));
    assert_eq!((t.x.get(), t.y.get()), ((640 - 200) / 2, (480 - 100) / 2), "centred in the usable area");
    assert_eq!(t.place_key().as_deref(), Some("org.test.notes/Notes"));
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &t)), "a window that appears takes the keyboard");
    assert!(t.foreign.get().is_some(), "and has a Dock tile");
    assert_eq!(*t.island_display.borrow(), c.layout.borrow().displays[0].name);
    assert!(c.surfaces_created.get() >= 1);

    // Asked to close, the client closes, and the place is remembered.
    c.close_focused_window();
    assert!(pump(c, || c.toplevels.borrow().is_empty()), "the window was never destroyed");
    assert!(j.join().unwrap(), "the client heard close");
    assert!(c.focused().is_none());
    let p = c.places.borrow().place("org.test.notes/Notes");
    assert_eq!(p, Some(WindowPlace { x: 220, y: 190 }));
}

/// The spatial Finder's whole behaviour: a window reopens where it was.
#[test]
fn a_remembered_window_opens_where_it_was() {
    let r = rig("places");
    let c = &r.c;
    c.places.borrow_mut().remember(WindowPlace { x: 30, y: 40 }, "org.test.finder/Home");
    let (tx, rx) = mpsc::channel();
    let _j = client(&c.socket_name, "Home", "org.test.finder", (100, 80), (0.0, 1.0, 0.0), 1.0, tx);
    assert!(pump(c, || rx.try_recv().is_ok() && c.mapped_toplevels().len() == 1));
    let t = c.mapped_toplevels()[0].clone();
    assert_eq!((t.x.get(), t.y.get()), (30, 40));
    assert_eq!(c.restored_count.get(), 1);
    c.close_focused_window();
    pump(c, || c.toplevels.borrow().is_empty());
}

/// Stacking, minimize and maximize: the keyboard follows the front, a
/// minimized window leaves the showing list and gives the keyboard back,
/// and maximize fills the usable area and restores.
#[test]
fn stacking_minimize_and_maximize() {
    let r = rig("stack");
    let c = &r.c;
    let (tx, rx) = mpsc::channel();
    let a = client(&c.socket_name, "A", "org.test.a", (120, 60), (1.0, 0.0, 0.0), 5.0, tx.clone());
    assert!(pump(c, || c.mapped_toplevels().len() == 1));
    let b = client(&c.socket_name, "B", "org.test.b", (120, 60), (0.0, 0.0, 1.0), 5.0, tx);
    assert!(pump(c, || c.mapped_toplevels().len() == 2));
    let _ = rx.try_iter().count();
    let ts = c.mapped_toplevels();
    let (ta, tb) = (ts[0].clone(), ts[1].clone());
    assert_eq!(tb.title().as_deref(), Some("B"));
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &tb)));
    assert_eq!(tb.x.get() - ta.x.get(), 24, "cascaded");

    c.set_minimized(&tb, true);
    assert_eq!(c.mapped_toplevels().len(), 1);
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &ta)), "the keyboard went to the one left");
    c.bring_to_front(&tb);
    assert!(!tb.minimized.get() && c.focused().is_some_and(|f| Rc::ptr_eq(&f, &tb)));

    let before = ta.rect();
    c.set_maximized(&ta, true);
    assert_eq!((ta.x.get(), ta.y.get()), (0, 0));
    assert_eq!(ta.restore_box.get(), Some(before));
    c.set_maximized(&ta, false);
    assert_eq!((ta.x.get(), ta.y.get()), (before.x, before.y));
    c.set_maximized(&ta, false); // leaving a state it is not in: nothing

    c.lower(&tb);
    assert!(Rc::ptr_eq(&c.toplevels.borrow()[0], &tb));
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &ta)), "the keyboard goes with the front");
    c.quit_focused_application();
    assert!(pump(c, || c.toplevels.borrow().len() == 1));
    c.close_focused_window();
    assert!(pump(c, || c.toplevels.borrow().is_empty()));
    assert!(a.join().unwrap() && b.join().unwrap());
}

/// The scene, over the compositor: a client's pixels are what is drawn
/// where the compositor put its window.
#[test]
fn the_scene_draws_a_clients_window_where_it_was_placed() {
    let r = rig("scene");
    let c = &r.c;
    let (tx, rx) = mpsc::channel();
    let _j = client(&c.socket_name, "Red", "org.test.red", (100, 50), (1.0, 0.0, 0.0), 5.0, tx);
    assert!(pump(c, || rx.try_recv().is_ok() && c.mapped_toplevels().len() == 1 && c.mapped_toplevels()[0].surface.texture().is_some()));
    let display = c.layout.borrow().displays[0].clone();
    let scene = Rc::new(RefCell::new(SurfaceScene::new(c.world(), &display, c.metrics.get(), 64)));
    let stats = scene.borrow_mut().latch_and_composite(0, 0);
    assert_eq!(stats.surfaces, 1);
    let mut out = WlrootsOutput::new(c.session.outputs()[0], &c.session);
    out.set_painter(scene);
    let path = std::env::temp_dir().join(format!("undertow-scene-window-{}.ppm", std::process::id()));
    assert!(out.capture_ppm(&path.to_string_lossy()));
    let ppm = std::fs::read(&path).unwrap();
    let _ = std::fs::remove_file(&path);
    let px = |x: usize, y: usize| {
        let o = ppm.len() - 640 * 480 * 3 + (y * 640 + x) * 3;
        [ppm[o], ppm[o + 1], ppm[o + 2]]
    };
    let t = c.mapped_toplevels()[0].clone();
    let (cx, cy) = ((t.x.get() + 50) as usize, (t.y.get() + 25) as usize);
    assert_eq!(px(cx, cy), [255, 0, 0], "the window");
    assert_eq!(px(5, 5), [61, 102, 161], "the desktop, Jaguar blue");
    assert_eq!(out.width(), 640);
    let _ = out.period_hint_ns();
    c.close_focused_window();
    pump(c, || c.toplevels.borrow().is_empty());
}

/// A decorated window: its frame drawn around it at the theme's metrics,
/// rasterised once while nothing changes and again when focus moves.
#[test]
fn a_decorated_window_is_framed_and_its_frame_is_cached() {
    let r = rig("frames");
    let c = &r.c;
    if c.runner.borrow().is_none() {
        return; // no fonts: no frames
    }
    let (tx, rx) = mpsc::channel();
    let _a = client(&c.socket_name, "Framed", "org.test.framed", (160, 80), (1.0, 0.0, 0.0), 5.0, tx.clone());
    assert!(pump(c, || rx.try_recv().is_ok() && c.mapped_toplevels().len() == 1 && c.mapped_toplevels()[0].surface.texture().is_some()));
    let t = c.mapped_toplevels()[0].clone();
    t.decorated.set(true);
    let m = c.metrics.get();
    assert_eq!((m.title_height, m.border), (22.0, 1.0), "Jaguar's, from the theme");

    let display = c.layout.borrow().displays[0].clone();
    let scene = Rc::new(RefCell::new(SurfaceScene::new(c.world(), &display, m, 64)));
    scene.borrow_mut().latch_and_composite(0, 0);
    scene.borrow_mut().latch_and_composite(1, 1);
    assert_eq!(c.frames.borrow().rasterisations, 1, "a still window rasterises its frame once");
    let (frame, _, r) = scene.borrow().entry(0);
    assert!(frame.is_some());
    assert_eq!(r, Rect::new(t.x.get() - 1, t.y.get() - 22, 162, 103), "the frame under the window it frames");

    let mut out = WlrootsOutput::new(c.session.outputs()[0], &c.session);
    out.set_painter(scene.clone());
    let path = std::env::temp_dir().join(format!("undertow-frame-{}.ppm", std::process::id()));
    assert!(out.capture_ppm(&path.to_string_lossy()));
    let ppm = std::fs::read(&path).unwrap();
    let _ = std::fs::remove_file(&path);
    let px = |x: i32, y: i32| {
        let o = ppm.len() - 640 * 480 * 3 + (y as usize * 640 + x as usize) * 3;
        [ppm[o], ppm[o + 1], ppm[o + 2]]
    };
    let title_bar = px(t.x.get() + 120, t.y.get() - 4);
    assert!(title_bar != [61, 102, 161] && title_bar[0] > 150 && title_bar[0].abs_diff(title_bar[2]) < 40, "a pale title bar: {title_bar:?}");
    assert_eq!(px(t.x.get() + 80, t.y.get() + 40), [255, 0, 0], "the client's own pixels inside it");

    // Another window takes focus: the first's frame is drawn inactive.
    let _b = client(&c.socket_name, "Other", "org.test.other", (60, 40), (0.0, 1.0, 0.0), 5.0, tx);
    assert!(pump(c, || c.mapped_toplevels().len() == 2));
    scene.borrow_mut().latch_and_composite(2, 2);
    assert_eq!(c.frames.borrow().rasterisations, 2, "redrawn once, inactive");
    while !c.toplevels.borrow().is_empty() {
        c.close_focused_window();
        let n = c.toplevels.borrow().len();
        pump(c, || c.toplevels.borrow().len() < n);
    }
}

const ISLANDS: (&str, &str) = ("islands.ini", "[islands]\ncount = 3\nanimate = false\n");

fn by_title(c: &Compositor, title: &str) -> Rc<Toplevel> {
    c.toplevels.borrow().iter().find(|t| t.title().as_deref() == Some(title)).cloned().expect(title)
}

/// A switch is a commit (C6): what shows and who has the keyboard change at
/// once, a hidden window is told it is suspended, the switch is stamped for
/// the frame that draws it, and asking for a window elsewhere goes there.
#[test]
fn islands_switch_what_shows_and_who_has_the_keyboard() {
    let r = rig_with("islands", &[ISLANDS]);
    let c = &r.c;
    let d = c.layout.borrow().displays[0].name.clone();
    let (tx, _rx) = mpsc::channel();
    let _a = client(&c.socket_name, "One", "org.test.one", (100, 60), (1.0, 0.0, 0.0), 5.0, tx.clone());
    assert!(pump(c, || c.mapped_toplevels().len() == 1));
    let one = by_title(c, "One");
    assert_eq!(one.island.get(), 1);

    c.switch_island(2, None);
    assert_eq!(c.active_island(&d), 2);
    assert!(c.mapped_toplevels().is_empty(), "island 1's window is not shown");
    assert!(c.focused().is_none(), "nor focused");
    assert!(one.suspended_said.get(), "and is told it is suspended");
    assert!(c.island_inputs.borrow().contains_key(&d), "stamped for C6");

    let _b = client(&c.socket_name, "Two", "org.test.two", (100, 60), (0.0, 1.0, 0.0), 5.0, tx);
    assert!(pump(c, || c.mapped_toplevels().len() == 1 && c.mapped_toplevels()[0].title().as_deref() == Some("Two")));
    let two = by_title(c, "Two");
    assert_eq!(two.island.get(), 2, "a window maps on the island shown");

    c.bring_to_front(&one);
    assert_eq!(c.active_island(&d), 1, "asking for a window goes to its island");
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &one)));
    assert!(!one.suspended_said.get() && two.suspended_said.get());

    c.move_focused_window_to_island(3, false);
    assert_eq!(one.island.get(), 3);
    assert!(c.mapped_toplevels().is_empty(), "it went, and you stayed");
    c.step_island(1);
    c.step_island(1);
    assert_eq!(c.active_island(&d), 3, "1 → 2 → 3");
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &one)));
    c.step_island(1);
    assert_eq!(c.active_island(&d), 1, "and wraps");
    assert_eq!(c.island_switches.get(), 5);
    for t in [one, two] {
        t.xdg.send_close();
    }
    pump(c, || c.toplevels.borrow().is_empty());
}

/// Ebb lays the island's windows out, the scene draws them in their slots,
/// and a click on one goes to it and puts the tide back.
#[test]
fn ebb_opens_draws_and_picks() {
    let r = rig_with("ebb", &[ISLANDS]);
    let c = &r.c;
    let (tx, _rx) = mpsc::channel();
    let _a = client(&c.socket_name, "Left", "org.test.left", (200, 120), (1.0, 0.0, 0.0), 5.0, tx.clone());
    assert!(pump(c, || c.mapped_toplevels().len() == 1));
    let _b = client(&c.socket_name, "Right", "org.test.right", (200, 120), (0.0, 0.0, 1.0), 5.0, tx);
    assert!(pump(c, || c.mapped_toplevels().len() == 2 && c.mapped_toplevels().iter().all(|t| t.surface.texture().is_some())));
    let d = c.layout.borrow().displays[0].name.clone();
    c.toggle_ebb(EbbScope::Island);
    let e = c.ebb_frame(&d, mono::now()).expect("open");
    assert_eq!(e.slots.len(), 2);
    assert_eq!(c.ebb_opens.get(), 1);
    let left = by_title(c, "Left");
    let slot = e.slots.iter().find(|s| s.window == left.id).unwrap().slot;

    let display = c.layout.borrow().displays[0].clone();
    let mut scene = SurfaceScene::new(c.world(), &display, c.metrics.get(), 64);
    scene.latch_and_composite(mono::now(), 0);
    assert_eq!(scene.count, 3, "the dimming and two windows in their slots");
    assert_eq!(scene.entry(1).2.width, slot.width.min(200));

    c.ebb_hover(slot.x as f64 + 5.0, slot.y as f64 + 5.0);
    assert_eq!(c.ebb.borrow().as_ref().unwrap().hovered, Some(left.id));
    c.ebb_click(slot.x as f64 + 5.0, slot.y as f64 + 5.0);
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &left)), "picked");
    assert!(c.ebb_frame(&d, mono::now()).is_none(), "and the tide put back");
    while !c.toplevels.borrow().is_empty() {
        c.close_focused_window();
        let n = c.toplevels.borrow().len();
        pump(c, || c.toplevels.borrow().len() < n);
    }
}

/// A shoal: made of one window, joined by another, recalled together from
/// the Dock, and from the strip.
#[test]
fn shoals_are_made_joined_and_recalled() {
    let r = rig_with("shoals", &[ISLANDS]);
    let c = &r.c;
    let (tx, _rx) = mpsc::channel();
    let _a = client(&c.socket_name, "Mail", "org.test.mail", (100, 60), (1.0, 0.0, 0.0), 5.0, tx.clone());
    assert!(pump(c, || c.mapped_toplevels().len() == 1));
    c.new_shoal();
    let _b = client(&c.socket_name, "Calendar", "org.test.cal", (100, 60), (0.0, 1.0, 0.0), 5.0, tx);
    assert!(pump(c, || c.mapped_toplevels().len() == 2));
    c.add_focused_to_shoal(None);
    {
        let book = c.shoal_book.borrow();
        assert_eq!(book.shoals.len(), 1);
        assert_eq!(book.shoals[0].members, ["org.test.mail/Mail", "org.test.cal/Calendar"]);
    }
    let saved = std::fs::read_to_string(format!("{}/shoals.ini", r._dir)).unwrap();
    assert!(saved.contains("org.test.cal/Calendar"), "{saved}");

    let (mail, cal) = (by_title(c, "Mail"), by_title(c, "Calendar"));
    c.set_minimized(&mail, true);
    c.set_minimized(&cal, true);
    c.recall_shoal_number(1);
    assert!(!mail.minimized.get() && !cal.minimized.get(), "both back");
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &cal)), "the last focused");
    assert_eq!(c.recalls.get(), 1);

    c.set_minimized(&mail, true);
    c.toggle_shoal_strip();
    let d = c.layout.borrow().displays[0].name.clone();
    let tiles = c.strip_tiles(&d);
    assert_eq!(tiles.len(), 1);
    let (_, t) = tiles[0];
    assert!(c.strip_click(t.x as f64 + 3.0, t.y as f64 + 3.0));
    assert!(!mail.minimized.get() && !c.strip_shown.get(), "recalled, and the strip went");
    if c.runner.borrow().is_some() {
        assert!(c.strip_label("Shoal 1").is_some_and(|l| l.width > 24 && l.height == 22));
    }
    c.remove_focused_from_shoal();
    assert_eq!(c.shoal_book.borrow().shoals[0].members, ["org.test.mail/Mail"]);
    for t in [mail, cal] {
        t.xdg.send_close();
    }
    pump(c, || c.toplevels.borrow().is_empty());
}
