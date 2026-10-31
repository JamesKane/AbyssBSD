//! A headless wlroots session, end to end: the backend announces an output,
//! it is given a mode, a frame is drawn into it, committed, presented, and
//! its pixels read back. Everything R4c builds on.

use super::*;
use std::cell::RefCell;
use std::rc::Rc;

#[test]
fn a_headless_frame_is_drawn_committed_presented_and_read_back() {
    log(false);
    // Pixman, as undertow pins it for headless: CPU-readable buffers.
    // SAFETY: the test sets it before any thread could read the environment.
    unsafe { std::env::set_var("WLR_RENDERER", "pixman") };
    let display = Display::create().unwrap();
    let l = display.event_loop();
    let backend = Backend::headless(l).unwrap();
    let renderer = backend.renderer().unwrap();
    let allocator = backend.allocator(renderer).unwrap();

    let seen: Rc<RefCell<Vec<Output>>> = Rc::default();
    let s = seen.clone();
    let new_output = backend.on_new_output(move |o| s.borrow_mut().push(o)).unwrap();
    assert!(backend.start());
    backend.headless_add_output(64, 48).unwrap();
    let out = seen.borrow()[0];
    assert!(out.name().starts_with("HEADLESS-"), "{}", out.name());
    assert_eq!(out.backend_name(), "headless");

    assert!(out.init_render(allocator, renderer));
    let mut st = OutputState::new();
    st.set_enabled(true);
    st.set_custom_mode(64, 48, 60_000);
    assert!(out.commit(&st));
    drop(st);
    out.create_global(&display);
    assert_eq!((out.width(), out.height(), out.refresh()), (64, 48, 60_000));
    assert!(out.enabled());

    let presents: Rc<RefCell<Vec<Present>>> = Rc::default();
    let p = presents.clone();
    let present = out.on_present(move |e| p.borrow_mut().push(e)).unwrap();

    // A red frame with a green square in it.
    let mut st = OutputState::new();
    let mut pass = out.begin_render_pass(&mut st).unwrap();
    pass.add_rect(&RectDraw::new(0, 0, 64, 48, (1.0, 0.0, 0.0, 1.0), Blend::None));
    pass.add_rect(&RectDraw::new(8, 8, 16, 16, (0.0, 1.0, 0.0, 1.0), Blend::Premultiplied));
    // And a blue texture, uploaded, over the right half.
    let blue: Vec<u8> = [0xffu8, 0, 0, 0xff].repeat(4 * 4); // B,G,R,A: ARGB8888
    let tex = renderer.texture_from_pixels(0x3432_5241, 16, 4, 4, &blue).unwrap();
    pass.add_texture(&TextureDraw::new(tex, (40, 0, 24, 48)));
    assert!(pass.submit());
    let pixel = |x: usize, y: usize| st.buffer().unwrap().read(48, |b, _, stride| u32::from_le_bytes(b[y * stride + x * 4..][..4].try_into().unwrap())).unwrap() & 0x00ff_ffff;
    assert_eq!(pixel(2, 2), 0xff0000, "red");
    assert_eq!(pixel(12, 12), 0x00ff00, "green");
    assert_eq!(pixel(50, 30), 0x0000ff, "blue texture");
    assert!(out.commit(&st));
    // What undertow records after each commit, to match its present by.
    let seq = out.commit_seq();
    drop(st);
    tex.destroy();
    let ours = || presents.borrow().iter().copied().find(|e| e.commit_seq == seq);
    for _ in 0..20 {
        if ours().is_some() {
            break;
        }
        l.dispatch(10);
    }
    let e = ours().expect("the frame's commit was presented");
    assert!(e.presented && !e.hw_clock, "{e:?}: headless has no hardware clock");

    // An output's destroy listener may let go of itself as it fires.
    let gone: Rc<RefCell<Option<Listener>>> = Rc::default();
    let g = gone.clone();
    let fired = Rc::new(RefCell::new(false));
    let f = fired.clone();
    *gone.borrow_mut() = out.on_destroy(move |_| {
        *f.borrow_mut() = true;
        g.borrow_mut().take();
    });
    drop(present);
    out.destroy();
    assert!(*fired.borrow() && gone.borrow().is_none());

    // A timer on the loop.
    let ticks = Rc::new(RefCell::new(0));
    let t = ticks.clone();
    let timer = l.add_timer(move || *t.borrow_mut() += 1).unwrap();
    timer.arm(1);
    for _ in 0..20 {
        if *ticks.borrow() > 0 {
            break;
        }
        l.dispatch(10);
    }
    assert_eq!(*ticks.borrow(), 1);
    drop(timer);

    drop(new_output);
    allocator.destroy();
    renderer.destroy();
    backend.destroy();
    drop(display);
}
