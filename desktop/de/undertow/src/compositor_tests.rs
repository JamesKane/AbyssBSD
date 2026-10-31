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
use crate::seat::Seat;
use std::collections::BTreeMap;
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
    let opts = Options { config_dir: Some(&dir), socket_name: Some(&socket), privileged_socket: None };
    let c = Compositor::new(session, layout, opts, Theme::default(), aquadraw::scene::runner(1)).unwrap();
    assert_eq!(c.socket_name, socket);
    Rig { c, _dir: dir }
}

/// Serve clients until `done`, or five seconds.
fn pump(c: &Compositor, done: impl FnMut() -> bool) -> bool {
    pump_for(c, 5, done)
}

fn pump_for(c: &Compositor, secs: u64, mut done: impl FnMut() -> bool) -> bool {
    let until = Instant::now() + Duration::from_secs(secs);
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
    assert!(!c.explicit_sync.borrow().offered, "pixman keeps neither half: not offered");

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

/// The menus' policy, through the hooks menus.c calls: the bar is told the
/// focused window's address, only when it changes; GTK's properties are an
/// address only with menus to read; the desktop is the fallback; and
/// window_at, lower and Force Quit answer as the compositor would.
#[test]
fn the_menu_bar_is_told_the_focused_windows_menus() {
    use abyss_sys::wlr::menus::{GtkProperties, MenuHooks};
    let dir = std::env::temp_dir().join(format!("undertow-priv-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let private = format!("{}/privileged", dir.display());
    let session = Rc::new(WlrootsSession::headless(1, 640, 480, 60_000, false).unwrap());
    let name = session.outputs()[0].name();
    let socket = format!("undertow-test-menus-{}", std::process::id());
    let opts = Options { config_dir: Some(&dir.to_string_lossy()), socket_name: Some(&socket), privileged_socket: Some(&private) };
    let c = Compositor::new(session, DisplayLayout { displays: vec![DisplayBox::new(&name, 0, 0, 640, 480)] }, opts, Theme::default(), None).unwrap();
    assert!(std::path::Path::new(&private).exists(), "the privileged socket");
    let hooks = crate::menus::Hooks(Rc::downgrade(&c));

    let (tx, _rx) = mpsc::channel();
    let _a = client(&c.socket_name, "Doc", "org.test.edit", (100, 60), (1.0, 0.0, 0.0), 5.0, tx.clone());
    assert!(pump(&c, || c.mapped_toplevels().len() == 1));
    let doc = by_title(&c, "Doc");
    assert_eq!(c.menus_current().app_id, "org.test.edit");
    assert_eq!(c.menus_current().kind, crate::menus::Kind::None, "publishes no menus yet");

    hooks.set_address(doc.surface, "abyss-menu:/run/edit.sock");
    let f = c.menus_current();
    assert_eq!((f.kind, f.address.as_str()), (crate::menus::Kind::Abyss, "abyss-menu:/run/edit.sock"));
    let sent = c.menu_state.borrow().sent_count;
    c.menus_focus_changed();
    assert_eq!(c.menu_state.borrow().sent_count, sent, "nothing changed, nothing sent");

    let _b = client(&c.socket_name, "Gimp", "org.test.gtk", (100, 60), (0.0, 1.0, 0.0), 5.0, tx);
    assert!(pump(&c, || c.mapped_toplevels().len() == 2));
    let gtk = by_title(&c, "Gimp");
    hooks.set_gtk_properties(gtk.surface, GtkProperties { application_id: "org.test.gtk".into(), unique_bus_name: ":1.7".into(), menubar_path: "/org/test/menus/menubar".into(), ..GtkProperties::default() });
    let f = c.menus_current();
    assert_eq!(f.kind, crate::menus::Kind::Gtk);
    assert_eq!(menu_model::GtkMenuAddress::from_encoded(&f.address).unwrap().bus_name, ":1.7");
    hooks.set_gtk_properties(gtk.surface, GtkProperties { unique_bus_name: ":1.7".into(), ..GtkProperties::default() });
    assert_eq!(c.menus_current().kind, crate::menus::Kind::None, "no menus to read: no address");

    c.focus(&doc);
    assert_eq!(c.menus_current().address, "abyss-menu:/run/edit.sock", "focus moved back");

    let w = hooks.window_at(doc.x.get() + 5, doc.y.get() + 5).expect("a window there");
    assert_eq!((w.title.as_str(), w.width, w.height), ("Doc", 100, 60));
    assert!(hooks.window_at(-50, -50).is_none());
    hooks.lower(doc.surface);
    assert!(Rc::ptr_eq(&c.toplevels.borrow()[0], &doc), "the depth gadget, from a toolkit window");
    assert!(c.force_quit("org.test.edit").is_empty(), "never ourselves (these clients are this process)");

    for t in [doc, gtk] {
        t.xdg.send_close();
    }
    pump(&c, || c.toplevels.borrow().is_empty());
    assert_eq!(c.menus_current(), crate::menus::Focus::nothing());
    drop(c);
    let _ = std::fs::remove_dir_all(&dir);
}

/// One of abyss/tests' probe clients (lockclient, vpointer, vkeyboard),
/// built as the live scripts build them, once each: None (and the test
/// skips) without wayland-scanner, wayland-protocols or xkbcommon.
fn tool(name: &str) -> Option<std::path::PathBuf> {
    use std::process::Command;
    static BUILT: std::sync::Mutex<BTreeMap<String, Option<std::path::PathBuf>>> = std::sync::Mutex::new(BTreeMap::new());
    let mut built = BUILT.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(b) = built.get(name) {
        return b.clone();
    }
    let build = || -> Option<std::path::PathBuf> {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");
        let out = std::env::temp_dir().join(format!("undertow-tools-{}", std::process::id()));
        std::fs::create_dir_all(&out).ok()?;
        let ok = |c: &mut Command| c.status().is_ok_and(|s| s.success());
        let scan = |xml: &str, stem: &str| ok(Command::new("wayland-scanner").args(["client-header", xml]).arg(out.join(format!("{stem}-proto.h")))) && ok(Command::new("wayland-scanner").args(["private-code", xml]).arg(out.join(format!("{stem}-proto.c"))));
        let pc = |pkgs: &[&str]| String::from_utf8(Command::new("pkg-config").arg("--cflags").arg("--libs").args(pkgs).output().ok()?.stdout).ok();
        let bin = out.join(name);
        let mut cc = Command::new("cc");
        cc.arg(format!("-I{}", out.display()));
        match name {
            "lockclient" => {
                let protos = String::from_utf8(Command::new("pkg-config").args(["--variable=pkgdatadir", "wayland-protocols"]).output().ok()?.stdout).ok()?;
                if !scan(&format!("{}/staging/ext-session-lock/ext-session-lock-v1.xml", protos.trim()), "ext-session-lock") {
                    return None;
                }
                cc.arg(format!("-I{root}/de/cwayland/include"))
                    .arg(format!("{root}/abyss/tests/lockclient.c"))
                    .arg(format!("{root}/de/cabyssprotocols/xdg-shell-protocol.c"))
                    .arg(out.join("ext-session-lock-proto.c"))
                    .args(pc(&["wayland-client"])?.split_whitespace());
            }
            "vpointer" | "vkeyboard" | "imetest" => {
                let xml = match name {
                    "vpointer" => "wlr-virtual-pointer-unstable-v1",
                    "vkeyboard" => "virtual-keyboard-unstable-v1",
                    _ => "input-method-unstable-v2",
                };
                if !scan(&format!("{root}/abyss/tests/{xml}.xml"), name) {
                    return None;
                }
                cc.arg(format!("{root}/abyss/tests/{name}.c")).arg(out.join(format!("{name}-proto.c"))).args(pc(&["wayland-client", "xkbcommon"])?.split_whitespace());
            }
            "locktest" => {
                for n in ["relative-pointer", "pointer-constraints"] {
                    if !scan(&format!("{root}/protocols/{n}-unstable-v1.xml"), n) {
                        return None;
                    }
                }
                cc.arg(format!("-I{root}/de/cwayland/include"))
                    .arg(format!("{root}/abyss/tests/locktest.c"))
                    .arg(format!("{root}/de/cabyssprotocols/xdg-shell-protocol.c"))
                    .arg(out.join("relative-pointer-proto.c"))
                    .arg(out.join("pointer-constraints-proto.c"))
                    .args(pc(&["wayland-client"])?.split_whitespace());
            }
            _ => return None,
        }
        cc.arg("-o").arg(&bin);
        ok(&mut cc).then_some(bin)
    };
    let b = build();
    built.insert(name.to_owned(), b.clone());
    b
}

fn lockclient() -> Option<std::path::PathBuf> {
    tool("lockclient")
}

/// A probe process: commands on its stdin, its lines from stdout.
struct LockClient {
    child: std::process::Child,
    lines: mpsc::Receiver<String>,
}

impl LockClient {
    fn start(bin: &std::path::Path, socket: &str, args: &[&str]) -> LockClient {
        use std::io::BufRead;
        use std::process::{Command, Stdio};
        let mut child = Command::new(bin).args(args).env("WAYLAND_DISPLAY", socket).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().unwrap();
        let out = child.stdout.take().unwrap();
        let (tx, lines) = mpsc::channel();
        thread::spawn(move || {
            for l in std::io::BufReader::new(out).lines().map_while(Result::ok) {
                if tx.send(l).is_err() {
                    break;
                }
            }
        });
        LockClient { child, lines }
    }
    fn say(&mut self, cmd: &str) {
        use std::io::Write;
        let stdin = self.child.stdin.as_mut().unwrap();
        writeln!(stdin, "{cmd}").unwrap();
        stdin.flush().unwrap();
    }
    /// Serve the compositor until the client prints `line`.
    fn wait(&self, c: &Compositor, line: &str) -> bool {
        let mut seen = false;
        pump(c, || {
            seen = seen || self.lines.try_iter().any(|l| l == line);
            seen
        })
    }
}

impl Drop for LockClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// ext-session-lock (P16.2a), with Swift's own probe client: `locked`
/// only after a frame, one lock at a time, an abandoned lock that stays
/// locked and can be taken over, and windows behind the lock neither drawn
/// nor focused.
#[test]
fn the_session_lock_holds() {
    let Some(bin) = lockclient() else { return };
    let r = rig("lock");
    let _seat = Seat::new(&r.c).unwrap();
    let c = &r.c;
    let (tx, _rx) = mpsc::channel();
    let _w = client(&c.socket_name, "Desk", "org.test.desk", (100, 60), (1.0, 0.0, 0.0), 8.0, tx.clone());
    assert!(pump(c, || c.mapped_toplevels().len() == 1));
    let desk = by_title(c, "Desk");

    let mut l1 = LockClient::start(&bin, &c.socket_name, &["lock", "ff2a5a2a"]);
    assert!(l1.wait(c, "ready"));
    l1.say("l");
    assert!(l1.wait(c, "locked"), "locked, after a frame");
    assert!(c.is_locked());
    assert!(pump(c, || !c.lock_mapped().is_empty()), "the lock surface drew");

    let display = c.layout.borrow().displays[0].clone();
    let mut scene = SurfaceScene::new(c.world(), &display, c.metrics.get(), 64);
    scene.latch_and_composite(0, 0);
    assert_eq!(scene.count, 1, "the lock surface, and nothing of the desktop");
    assert_eq!(scene.entry(0).1, None);

    let _late = client(&c.socket_name, "Late", "org.test.late", (100, 60), (0.0, 1.0, 0.0), 8.0, tx);
    assert!(pump(c, || c.toplevels.borrow().len() == 2 && c.toplevels.borrow()[1].mapped.get()));
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &desk)), "a window mapping behind the lock takes nothing");

    let mut l2 = LockClient::start(&bin, &c.socket_name, &["lock", "ff802020"]);
    assert!(l2.wait(c, "ready"));
    l2.say("l");
    assert!(l2.wait(c, "finished"), "one lock at a time");
    assert_eq!(c.lock.borrow().refused, 1);

    l1.say("q"); // quits holding the lock
    assert!(pump(c, || c.lock.borrow().abandoned()));
    assert!(c.is_locked(), "an abandoned lock stays locked");
    let mut l3 = LockClient::start(&bin, &c.socket_name, &["lock", "ff2a5a2a"]);
    assert!(l3.wait(c, "ready"));
    l3.say("l");
    assert!(l3.wait(c, "locked"), "and can be taken over");
    l3.say("u");
    assert!(pump(c, || !c.is_locked()), "unlocked");
    let st = c.lock.borrow();
    assert_eq!((st.locks, st.unlocks, st.abandonments), (2, 1, 1));
    drop(st);
    while !c.toplevels.borrow().is_empty() {
        c.close_focused_window();
        let n = c.toplevels.borrow().len();
        if !pump(c, || c.toplevels.borrow().len() < n) {
            let t = c.toplevels.borrow()[0].clone();
            t.xdg.send_close();
        }
    }
}

/// Display sleep (U.9): a short timeout sleeps the displays, every client
/// then gets the slow clock, and activity wakes them; the hook hears both.
#[test]
fn the_displays_sleep_and_wake() {
    let r = rig("sleep");
    let c = &r.c;
    let (tx, _rx) = mpsc::channel();
    let _a = client(&c.socket_name, "Video", "org.test.video", (100, 60), (1.0, 0.0, 0.0), 5.0, tx);
    assert!(pump(c, || c.mapped_toplevels().len() == 1));
    c.update_surface_outputs(); // enter, and the scale: on the one display
    c.start_display_sleep(Some(0.05));
    let heard = Rc::new(RefCell::new(vec![]));
    let h = heard.clone();
    c.display_sleep.borrow().as_ref().unwrap().on_change(move |asleep| h.borrow_mut().push(asleep));
    c.display_sleep_tick();
    assert!(!c.displays_asleep());
    thread::sleep(Duration::from_millis(80));
    c.display_sleep_tick();
    assert!(c.displays_asleep(), "after the timeout without input");
    c.end_frame(); // the slow clock: no panic, nothing owed
    c.activity(None);
    assert!(!c.displays_asleep());
    assert_eq!(*heard.borrow(), [true, false]);
    let ds = c.display_sleep.borrow();
    assert_eq!((ds.as_ref().unwrap().sleeps.get(), ds.as_ref().unwrap().wakes.get()), (1, 1));
    drop(ds);
    c.close_focused_window();
    pump(c, || c.toplevels.borrow().is_empty());
}

/// A saved setting (displays.ini) put on an output before the run.
#[test]
fn a_saved_display_setting_is_committed() {
    use crate::displays::DisplaySetting;
    use crate::output_management::commit_setting;
    let r = rig("setting");
    let o = r.c.session.outputs()[0];
    let s = DisplaySetting { name: o.name(), enabled: true, mode_width: 800, mode_height: 600, refresh_milli_hz: 60_000, x: 0, y: 0, scale: 2.0 };
    assert!(commit_setting(&s, o));
    assert_eq!((o.width(), o.height(), o.scale()), (800, 600, 2.0));
    assert!(r.c.output_management.borrow().is_some(), "wlr-output-management is offered");
    r.c.publish_outputs();
}

impl LockClient {
    /// Serve the compositor until a line starting `prefix` comes; the line.
    fn wait_prefix(&self, c: &Compositor, prefix: &str) -> Option<String> {
        let mut found = None;
        pump(c, || {
            if found.is_none() {
                found = self.lines.try_iter().find(|l| l.starts_with(prefix));
            }
            found.is_some()
        });
        found
    }
}

/// The seat with real devices: the pointer enters the window it is over and
/// its clicks reach it; a click focuses and raises; keys reach the focused
/// window; a bound chord is the desktop's and is never delivered; a press on
/// a frame's title bar moves the window and is forwarded to nobody.
#[test]
fn the_seat_routes_pointer_and_keys() {
    let (Some(lc), Some(vp), Some(vk)) = (lockclient(), tool("vpointer"), tool("vkeyboard")) else { return };
    let r = rig("seat");
    let c = &r.c;
    let seat = Seat::new(c).unwrap();
    let a = LockClient::start(&lc, &c.socket_name, &["window", "ff336699", "org.test.a"]);
    assert!(pump(c, || c.mapped_toplevels().len() == 1));
    let b = LockClient::start(&lc, &c.socket_name, &["window", "ffcc2222", "org.test.b"]);
    assert!(pump(c, || c.mapped_toplevels().len() == 2));
    let ta = c.toplevels.borrow().iter().find(|t| t.app_id().as_deref() == Some("org.test.a")).cloned().unwrap();
    let tb = c.toplevels.borrow().iter().find(|t| t.app_id().as_deref() == Some("org.test.b")).cloned().unwrap();
    // Apart, so a point is in one of them only.
    ta.x.set(20);
    ta.y.set(40);
    tb.x.set(340);
    tb.y.set(40);
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &tb)), "the last mapped");

    let mut p = LockClient::start(&vp, &c.socket_name, &["640", "480"]);
    let mut k = LockClient::start(&vk, &c.socket_name, &[]);
    assert!(pump(c, || seat.capabilities.get() == 3), "a pointer and a keyboard");
    let (ax, ay) = (ta.x.get() + ta.width() / 2, ta.y.get() + ta.height() / 2);
    p.say(&format!("m {ax} {ay}"));
    assert!(a.wait_prefix(c, "enter").is_some(), "the pointer entered A");
    assert_eq!(seat.cursor.get(), (ax as f64, ay as f64));
    p.say("p");
    p.say("r");
    assert!(a.wait_prefix(c, "button").is_some(), "the click reached A");
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &ta)), "and focused it");
    assert!(Rc::ptr_eq(c.toplevels.borrow().last().unwrap(), &ta), "and raised it");

    k.say("k 30"); // a
    assert!(a.wait_prefix(c, "key").is_some(), "keys go to the focused window");
    let before = seat.keybinds_fired.get();
    k.say("c 64 15"); // Cmd-Tab
    assert!(pump(c, || seat.keybinds_fired.get() > before), "the chord is the desktop's");
    assert!(c.focused().is_some_and(|f| Rc::ptr_eq(&f, &tb)), "Cmd-Tab: the window under the top");
    assert!(!b.lines.try_iter().any(|l| l == "key 15"), "and never delivered");

    // A press on B's frame title bar: a move, owned by the pointer.
    tb.decorated.set(true);
    // The middle of the title bar: the lights are at its left.
    let (fx, fy) = (tb.x.get() + tb.width() / 2, tb.y.get() - 10);
    p.say(&format!("m {fx} {fy}"));
    assert!(pump(c, || seat.cursor.get() == (fx as f64, fy as f64)));
    p.say("p");
    assert!(pump(c, || c.moving().is_some()), "the title bar moves the window");
    p.say(&format!("m {} {}", fx + 30, fy + 20));
    assert!(pump(c, || tb.x.get() == 370));
    p.say("r");
    assert!(pump(c, || c.moving().is_none()));
    assert_eq!((tb.x.get(), tb.y.get()), (370, 60), "it went with the pointer");
    assert!(!tb.maximized.get());
    assert_eq!(seat.frame_clicks.get(), 1);
    drop((a, b, p, k));
    pump(c, || c.toplevels.borrow().is_empty());
}

/// Pointer constraints (U.6), with live-lock.sh's own locktest: a lock
/// holds the pointer while deltas still arrive, ⌘-Tab ends it, a
/// confinement pulls the pointer back, and a hint is where it lands.
#[test]
fn pointer_locks_and_confinements_hold() {
    let (Some(lt), Some(lc), Some(vp), Some(vk)) = (tool("locktest"), lockclient(), tool("vpointer"), tool("vkeyboard")) else { return };
    let r = rig("plock");
    let c = &r.c;
    let seat = Seat::new(c).unwrap();
    // The devices first: locktest binds wl_pointer at once, as live-lock.sh
    // orders it.
    let mut p = LockClient::start(&vp, &c.socket_name, &["640", "480"]);
    let mut k = LockClient::start(&vk, &c.socket_name, &[]);
    assert!(pump(c, || seat.capabilities.get() == 3));
    let mut game = LockClient::start(&lt, &c.socket_name, &["org.test.game"]);
    assert!(game.wait(c, "ready"));
    let other = LockClient::start(&lc, &c.socket_name, &["window", "ffcc2222", "org.test.other"]);
    assert!(pump(c, || c.mapped_toplevels().len() == 2));
    let g = c.toplevels.borrow().iter().find(|t| t.app_id().as_deref() == Some("org.test.game")).cloned().unwrap();
    let o = c.toplevels.borrow().iter().find(|t| t.app_id().as_deref() == Some("org.test.other")).cloned().unwrap();
    g.x.set(0);
    g.y.set(0);
    o.x.set(400);
    o.y.set(300);
    p.say("m 50 50");
    p.say("p");
    p.say("r");
    assert!(pump(c, || c.focused().is_some_and(|f| Rc::ptr_eq(&f, &g))), "the game focused");

    game.say("l");
    assert!(game.wait(c, "locked"), "the lock took effect");
    let pc = seat.pointer_constraints.as_ref().unwrap();
    assert_eq!(pc.locks.get(), 1);
    let before = seat.cursor.get();
    p.say("d 10 5");
    assert!(game.wait_prefix(c, "rel").is_some(), "the delta still arrives");
    assert_eq!(seat.cursor.get(), before, "and the pointer stays put");
    assert!(pc.held.get() >= 1);

    k.say("c 64 15"); // ⌘-Tab: the other window
    assert!(game.wait(c, "unlocked"), "a lock does not survive ⌘-Tab");
    assert!(!pc.is_active());

    // Back to the game: a persistent lock comes back with the focus.
    c.focus(&g);
    assert!(game.wait(c, "locked"), "persistent: it holds again once the game is focused");
    // Destroyed by the client: no event to it, and gone from us.
    game.say("u");
    assert!(pump(c, || !pc.is_active()));
    // Confine it to a 40x40 box at (10,10), the pointer inside it (a
    // confinement starts only there).
    p.say("m 30 30");
    assert!(pump(c, || seat.cursor.get() == (30.0, 30.0)));
    game.say("c 10 10 40 40");
    assert!(game.wait(c, "confined"));
    p.say("d 200 0");
    assert!(pump(c, || seat.cursor.get().0 < 60.0 && pc.held.get() >= 2), "pulled back into its box");
    assert!(seat.cursor.get().0 >= 10.0 && seat.cursor.get().0 < 50.0, "{:?}", seat.cursor.get());
    game.say("u");
    assert!(pump(c, || !pc.is_active()));

    // A lock with a hint: when it ends, the pointer lands on the hint.
    game.say("l");
    assert!(game.wait(c, "locked"));
    game.say("h 70 80");
    // A moment for the hint's commit: nothing announces it.
    for _ in 0..20 {
        c.session.dispatch(5);
        c.end_frame();
    }
    game.say("u");
    assert!(pump(c, || !pc.is_active()));
    assert_eq!(seat.cursor.get(), (70.0, 80.0), "the pointer went to the hint");
    assert!(pc.warps.get() >= 1);
    drop((game, other, p, k));
    pump(c, || c.toplevels.borrow().is_empty());
}

/// An input method composes into another toolkit's field, through us
/// (live-ime.sh's claims, with its own imetest and zenity's GTK entry):
/// focus activates the method, told the surrounding text; a grab takes
/// the keys and its release gives them back; a commit of 日本語 reaches the
/// field; and when the field goes the method is deactivated.
#[test]
fn an_input_method_composes_into_a_gtk_field() {
    use std::process::{Command, Stdio};
    let (Some(ime), Some(vk)) = (tool("imetest"), tool("vkeyboard")) else { return };
    if !Command::new("zenity").arg("--version").stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success()) {
        return;
    }
    let r = rig("ime");
    let c = &r.c;
    let seat = Seat::new(c).unwrap();
    // A keyboard first: GTK makes its text input only for a seat with one.
    let mut k = LockClient::start(&vk, &c.socket_name, &[]);
    let mut m = LockClient::start(&ime, &c.socket_name, &[]);
    assert!(m.wait(c, "ready"), "the input method bound");
    let mut zen = Command::new("zenity")
        .args(["--entry", "--text=Name"])
        .env("WAYLAND_DISPLAY", &c.socket_name)
        .env("GDK_BACKEND", "wayland")
        .env("GTK_IM_MODULE", "wayland")
        .env("GSK_RENDERER", "cairo")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();

    // 1. activated, told the surrounding text.
    let mut said = vec![];
    assert!(
        pump_for(c, 20, || {
            said.extend(m.lines.try_iter());
            said.iter().any(|l| l == "done active=1")
        }),
        "focusing the entry did not activate the input method: {said:?}"
    );
    assert!(said.iter().any(|l| l == "activate") && said.iter().any(|l| l.starts_with("surrounding ")), "{said:?}");

    // 3. the grab: 'a' to the method; released, 'b' to the application.
    m.say("g");
    pump_for(c, 1, || false);
    k.say("t a");
    assert!(m.wait(c, "key 30 1"), "a key typed while the method held the keyboard did not reach it");
    m.say("u");
    pump_for(c, 1, || false);
    k.say("t b");
    pump_for(c, 1, || false);
    assert!(!m.lines.try_iter().any(|l| l.starts_with("key 48 ")), "after the release 'b' still went to the method");

    // 2. preedit, then the commit, into the field; Return prints it.
    m.say("p にほんご");
    pump_for(c, 1, || false);
    m.say("c 日本語");
    assert!(m.wait_prefix(c, "surrounding ").is_some(), "the field's text did not change after the commit");
    k.say("k 28");
    // Waited on while serving it: this thread is its compositor.
    let mut exited = false;
    pump_for(c, 10, || {
        exited = exited || zen.try_wait().is_ok_and(|s| s.is_some());
        exited
    });
    if !exited {
        let _ = zen.kill();
    }
    let mut got = String::new();
    std::io::Read::read_to_string(&mut zen.stdout.take().unwrap(), &mut got).unwrap();
    assert_eq!(got.trim_end(), "b日本語", "the b typed after the release, then the commit");

    // 4. the field gone, the method deactivated.
    assert!(m.wait(c, "done active=0"), "the input method was not deactivated when the field went");
    let tr = seat.text_input.as_ref().unwrap();
    assert!(tr.enters.get() >= 1 && tr.activations.get() >= 1 && tr.commits_relayed.get() >= 1 && tr.keys_grabbed.get() >= 1);
    drop((k, m));
}

// MARK: the compositor's own sockets and globals, with no client

fn bare(tag: &str, privileged: Option<&str>) -> Result<Rc<Compositor>, BackendError> {
    let session = Rc::new(WlrootsSession::headless(1, 64, 48, 60_000, false).unwrap());
    let name = session.outputs()[0].name();
    let dir = std::env::temp_dir().join(format!("undertow-{tag}-{}", std::process::id())).to_string_lossy().into_owned();
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let layout = DisplayLayout { displays: vec![DisplayBox::new(&name, 0, 0, 64, 48)] };
    let opts = Options { config_dir: Some(&dir), socket_name: None, privileged_socket: privileged };
    Compositor::new(session, layout, opts, Theme::default(), None)
}

/// Asked for no particular name, it takes the next `wayland-N`, and starts
/// with no windows.
#[test]
fn the_compositor_offers_a_socket_and_the_globals_a_client_needs() {
    if std::env::var("XDG_RUNTIME_DIR").map_or(true, |d| d.is_empty()) {
        return; // nowhere to put a socket
    }
    let c = bare("auto", None).unwrap();
    assert!(c.socket_name.starts_with("wayland-"), "{}", c.socket_name);
    assert!(c.toplevels.borrow().is_empty());
    assert!(c.mapped_toplevels().is_empty());
}

/// Each compositor makes its own menu globals (nothing static outlives a
/// display), starts with nothing focused, and has no privileged socket
/// unless asked for one.
#[test]
fn every_compositor_has_its_own_menu_globals_and_starts_with_nothing_focused() {
    if std::env::var("XDG_RUNTIME_DIR").map_or(true, |d| d.is_empty()) {
        return;
    }
    let c1 = bare("menus1", None).unwrap();
    let c2 = bare("menus2", None).unwrap();
    assert!(c1.menus.borrow().is_some() && c2.menus.borrow().is_some());
    assert_eq!(c2.menus_current(), crate::menus::Focus::nothing());
    assert_eq!(c2.menus.borrow().as_ref().unwrap().menubar_count(), 0);
    assert!(c1.privileged_socket_name.is_none(), "no privileged socket unless asked for");
}

/// The privileged socket is the user's alone, and goes with its compositor.
#[test]
fn the_privileged_socket_is_the_users_alone_and_is_removed_after() {
    use std::os::unix::fs::PermissionsExt;
    if std::env::var("XDG_RUNTIME_DIR").map_or(true, |d| d.is_empty()) {
        return;
    }
    let path = std::env::temp_dir().join(format!("undertow-priv-perm-{}", std::process::id())).to_string_lossy().into_owned();
    let _ = std::fs::remove_file(&path);
    let c = bare("privperm", Some(&path)).unwrap();
    assert_eq!(c.privileged_socket_name.as_deref(), Some(path.as_str()));
    let meta = std::fs::metadata(&path).expect("no privileged socket");
    assert_eq!(meta.permissions().mode() & 0o777, 0o600);
    drop(c);
    assert!(!std::path::Path::new(&path).exists(), "the privileged socket outlived its compositor");
}

#[test]
fn an_impossible_privileged_socket_is_an_error() {
    if std::env::var("XDG_RUNTIME_DIR").map_or(true, |d| d.is_empty()) {
        return;
    }
    match bare("privbad", Some("/nonexistent-dir/priv")) {
        Ok(_) => panic!("a socket in a directory that does not exist"),
        Err(e) => assert!(e.to_string().contains("/nonexistent-dir/priv"), "{e}"),
    }
}

/// With no windows the scene draws the desktop: no surfaces, no damage.
#[test]
fn an_empty_scene_composites_the_desktop_and_nothing_else() {
    let r = rig("empty");
    let c = &r.c;
    let display = c.layout.borrow().displays[0].clone();
    let mut scene = SurfaceScene::new(c.world(), &display, c.metrics.get(), 64);
    let stats = scene.latch_and_composite(0, 0);
    assert_eq!((stats.surfaces, stats.damage_area), (0, 0));
    assert_eq!(scene.count, 0);
}

/// The seat starts with the cursor in the middle of the main display, so a
/// capture with no input is still sane, and nothing focused.
#[test]
fn the_seat_offers_the_virtual_input_globals() {
    let r = rig("seatbare");
    let c = &r.c;
    let seat = Seat::new(c).unwrap();
    assert_eq!(seat.cursor.get(), (320.0, 240.0));
    assert_eq!(c.cursor.get(), Some((320.0, 240.0)));
    assert!(c.focused().is_none());
    assert!(c.mapped_toplevels().is_empty(), "there are no windows yet");
}

// MARK: the keymap a keyboard with none of its own is given (T.2)
//
// Swift's versions gave a bare wlr_keyboard the keymap and read its layout
// name back; here the choice is asserted, and that it compiles. Setting
// XKB_DEFAULT_LAYOUT from a test is `unsafe` in Rust 2024, so the tests
// pass the environment's say to `keymap_choice_given` instead: they run the
// same whether or not the developer's session sets it.

/// An rc.conf holding `keymap="<kbdmap>"`, for `keymap_choice`.
fn rc_conf_with(kbdmap: &str) -> String {
    let p = std::env::temp_dir().join(format!("undertow-rc-{}-{kbdmap}", std::process::id()));
    std::fs::write(&p, format!("hostname=\"abyss\"\nkeymap=\"{kbdmap}\"\n")).unwrap();
    p.to_string_lossy().into_owned()
}

/// False when xkeyboard-config is missing.
fn keymaps_testable() -> bool {
    abyss_sys::wlr::keymap_compiles("us", "")
}

fn choice(rc: Option<&str>, session: &str) -> Option<(String, String)> {
    choice_given(false, rc, session)
}

fn choice_given(environment_sets_it: bool, rc: Option<&str>, session: &str) -> Option<(String, String)> {
    let path = rc.map(rc_conf_with);
    let paths: Vec<&str> = path.iter().map(String::as_str).collect();
    let c = Seat::keymap_choice_given(environment_sets_it, &paths, session);
    if let Some(p) = path {
        let _ = std::fs::remove_file(p);
    }
    c
}

#[test]
fn every_layout_the_installer_offers_reaches_the_seat() {
    if !keymaps_testable() {
        return;
    }
    let expected = ["us.kbd", "uk.kbd", "de.kbd", "fr.kbd", "es.kbd", "it.kbd", "us.dvorak.kbd", "colemak.acc.kbd"];
    let mut offered: Vec<String> = install::keymaps::offered().into_iter().map(|k| k.kbdmap).collect();
    offered.sort();
    let mut e: Vec<String> = expected.iter().map(|s| (*s).to_owned()).collect();
    e.sort();
    assert_eq!(offered, e, "a layout was added to the installer without a test here");
    for k in install::keymaps::offered() {
        assert_eq!(choice(Some(&k.kbdmap), ""), Some((k.layout.clone(), k.variant.clone())), "{}", k.kbdmap);
    }
}

#[test]
fn a_guess_xkb_refuses_falls_back_to_the_default() {
    if !keymaps_testable() {
        return;
    }
    assert_eq!(choice(Some("de.acc.kbd"), "").map(|c| c.0).as_deref(), Some("de"), "a name the installer never offered, guessed from its prefix");
    assert_eq!(choice(Some("zz.kbd"), ""), None, "no layout zz, so the default: not a keyboard with no keymap");
    assert_eq!(choice(None, ""), None, "nothing configured: the default");
}

#[test]
fn the_sessions_layout_beats_rc_conf() {
    if !keymaps_testable() {
        return;
    }
    assert_eq!(choice(Some("uk.kbd"), "de.kbd").map(|c| c.0).as_deref(), Some("de"));
}

#[test]
fn a_session_layout_that_will_not_compile_falls_back_to_rc_confs() {
    if !keymaps_testable() {
        return;
    }
    assert_eq!(choice(Some("uk.kbd"), "zz.kbd").map(|c| c.0).as_deref(), Some("gb"));
}

/// Where the environment sets XKB_DEFAULT_LAYOUT (as a developer's session
/// often does): it beats rc.conf and the session both, so the choice is
/// left to xkbcommon, which reads it itself.
#[test]
fn the_environment_beats_rc_conf_and_the_session() {
    assert_eq!(choice_given(true, Some("uk.kbd"), ""), None);
    assert_eq!(choice_given(true, Some("uk.kbd"), "de.kbd"), None);
    assert_eq!(choice_given(true, None, "de.kbd"), None);
}
