//! The bridge, headless: what Backend.swift's tests and the bench hold it
//! to, short of a client.

use super::*;
use crate::metronome::{Config, Metronome};
use crate::recorder::FlightRecorder;

fn session(outputs: usize) -> WlrootsSession {
    WlrootsSession::headless(outputs, 64, 48, 60_000, false).unwrap()
}

#[test]
fn outputs_are_announced_configured_and_advertised() {
    let s = session(2);
    let outs = s.outputs();
    assert_eq!(outs.len(), 2);
    assert_eq!(outs.iter().map(|o| (o.width(), o.height(), o.refresh())).collect::<Vec<_>>(), [(64, 48, 60_000); 2]);
    assert!(outs.iter().all(|o| o.enabled() && o.backend_name() == "headless"));
    assert_eq!(s.output_named(&outs[1].name()), Some(outs[1]));
    assert!(!s.change_vt(2), "no session to ask, headless");
}

/// The test pattern, committed and presented, through the metronome's own
/// trait: flips come back, on the snapped grid, never refused.
#[test]
fn frames_are_committed_and_their_flips_come_back() {
    let s = session(1);
    let mut out = WlrootsOutput::new(s.outputs()[0], &s);
    assert_eq!(out.period_hint_ns(), 16_666_666);
    let mut flips = vec![];
    for i in 0..6u64 {
        let target = mono::now() + 2_000_000;
        out.submit(target, mono::now());
        out.wait_until(target + i);
        while let Some(f) = out.poll_flip() {
            flips.push(f);
        }
    }
    assert_eq!(out.commits_made, 6);
    assert_eq!(out.commits_refused, 0);
    assert!(flips.len() >= 5, "{flips:?}");
    assert!(flips.iter().all(|f| !f.refused && f.done >= f.target.saturating_sub(3_000_000)));
    assert!(!out.saw_hardware_clock, "headless has no hardware clock");
}

#[test]
fn a_capture_is_the_frame_drawn() {
    let s = session(1);
    let mut out = WlrootsOutput::new(s.outputs()[0], &s);
    let dir = std::env::temp_dir().join(format!("undertow-capture-{}", std::process::id()));
    let path = dir.to_string_lossy().into_owned() + ".ppm";
    assert!(out.capture_ppm(&path));
    let ppm = std::fs::read(&path).unwrap();
    let _ = std::fs::remove_file(&path);
    assert!(ppm.starts_with(b"P6\n64 48\n255\n"));
    assert_eq!(ppm.len(), 13 + 64 * 48 * 3);
    // The test pattern: one colour, green at 0.25.
    let px = &ppm[13..16];
    assert!((63..=64).contains(&px[1]), "{px:?}");
    assert!(ppm[13..].chunks(3).all(|p| p == px));
}

/// The stand-in VT does to headless outputs what a VT switch does to DRM
/// ones: away destroys them all, back announces them by the same names, at
/// the same sizes; the hooks hear both, and a detached output waits.
#[test]
fn the_stand_in_vt_takes_the_outputs_away_and_brings_them_back() {
    let mut s = WlrootsSession::new(Kind::Headless { sizes: vec![HeadlessSize::new(64, 48), HeadlessSize::new(80, 60)], refresh_mhz: 60_000 }, false).unwrap();
    let names: Vec<String> = s.outputs().iter().map(|o| o.name()).collect();
    let out = Rc::new(RefCell::new(WlrootsOutput::new(s.outputs()[1], &s)));
    let (removed, added) = (Rc::new(Cell::new(0)), Rc::new(Cell::new(0)));
    let (r, o2) = (removed.clone(), out.clone());
    s.on_output_removed(move |o| {
        r.set(r.get() + 1);
        if o2.borrow().is_bound_to(o) {
            o2.borrow_mut().detach()
        }
    });
    let (a, o3) = (added.clone(), out.clone());
    s.on_output_added(move |o| {
        a.set(a.get() + 1);
        if o.name() == o3.borrow().name {
            o3.borrow_mut().attach(o)
        }
    });
    let fifo = std::env::temp_dir().join(format!("undertow-vt-{}", std::process::id()));
    let _ = std::fs::remove_file(&fifo);
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    assert!(s.add_stand_in_vt(&fifo.to_string_lossy()));
    let say = |w: &str| std::fs::OpenOptions::new().write(true).open(&fifo).unwrap().write_all(w.as_bytes()).unwrap();

    say("away\n");
    for _ in 0..20 {
        s.dispatch(5);
    }
    assert_eq!((removed.get(), s.outputs().len(), s.outputs_lost()), (2, 0, 2));
    assert!(!out.borrow().attached());
    assert_eq!((out.borrow().width(), out.borrow().height()), (80, 60), "a detached output keeps its last size");
    out.borrow_mut().submit(mono::now(), mono::now()); // draws nothing, and does not crash

    say("back\n");
    for _ in 0..20 {
        s.dispatch(5);
    }
    assert_eq!((added.get(), s.outputs_returned()), (2, 2));
    let back: Vec<(String, i32, i32)> = s.outputs().iter().map(|o| (o.name(), o.width(), o.height())).collect();
    assert_eq!(back, [(names[0].clone(), 64, 48), (names[1].clone(), 80, 60)]);
    assert!(out.borrow().attached(), "the same name came back");
    let _ = std::fs::remove_file(&fifo);
}

/// The metronome drives a wlroots output as it drives the synthetic one.
#[test]
fn the_metronome_drives_a_wlroots_output() {
    struct Still;
    impl crate::output::FrameSink for Still {
        fn latch_and_composite(&mut self, _: u64, _: u64) -> crate::output::FrameStats {
            crate::output::FrameStats::default()
        }
    }
    let s = session(1);
    let mut out = WlrootsOutput::new(s.outputs()[0], &s);
    let mut m = Metronome::new(out.period_hint_ns(), Config::default());
    let mut rec = FlightRecorder::new(64);
    m.run(30, &mut out, &mut Still, &mut rec);
    assert!(out.commits_made >= 28, "{}", out.commits_made);
    assert_eq!(rec.count(), 30);
}
