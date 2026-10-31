//! Several outputs (Tests/UndertowTests/DisplaysTests.swift, P14.7): the
//! layout's arithmetic, the projection onto one output, the loop that
//! serves them all, and what a client may ask for.

use crate::displays::*;
use crate::geometry::{project, Rect};
use crate::metronome::{Conductor, Config};
use crate::recorder::FlightRecorder;
use crate::synthetic::{SyntheticOutput, SyntheticScene};
use abyss_sys::mono;
use std::collections::BTreeMap;

fn three() -> DisplayLayout {
    DisplayLayout { displays: vec![DisplayBox::new("A", 0, 0, 1024, 768), DisplayBox::new("B", 1024, 0, 800, 600), DisplayBox::new("C", -320, 100, 320, 240)] }
}

fn name(d: Option<&DisplayBox>) -> Option<&str> {
    d.map(|d| d.name.as_str())
}

#[test]
fn a_row_places_outputs_left_to_right() {
    let l = DisplayLayout::row(&[("A", 1024, 768), ("B", 800, 600)]);
    assert_eq!(l.displays.iter().map(|d| d.x).collect::<Vec<_>>(), [0, 1024]);
    assert_eq!(name(l.main()), Some("A"), "the first is the main display");
    assert_eq!(l.summary(), "A 1024x768@0,0 main; B 800x600@1024,0");
}

#[test]
fn a_scaled_display_is_summarised_as_swift_wrote_it() {
    let mut l = DisplayLayout::row(&[("A", 1024, 768)]);
    l.displays[0].scale = 2.0;
    assert_eq!(l.summary(), "A 1024x768@0,0 scale 2.0 main");
}

#[test]
fn bounds_hold_every_display() {
    assert_eq!(three().bounds(), Rect::new(-320, 0, 2144, 768));
    assert_eq!(DisplayLayout::default().bounds(), Rect::new(0, 0, 0, 0));
}

#[test]
fn a_point_is_on_a_display_or_in_a_gap() {
    let t = three();
    assert_eq!(name(t.display_at(10.0, 10.0)), Some("A"));
    assert_eq!(name(t.display_at(1024.0, 0.0)), Some("B"), "the edge belongs to the display that starts there");
    assert_eq!(name(t.display_at(-1.0, 150.0)), Some("C"));
    assert_eq!(t.display_at(1500.0, 700.0), None, "below B's bottom, beside A: a gap");
    assert_eq!(t.display_at(-100.0, 50.0), None, "above C: a gap");
}

#[test]
fn the_cursor_is_kept_off_the_gaps() {
    let t = three();
    let (x, y) = t.clamp(1500.0, 700.0);
    assert_eq!(name(t.display_at(x, y)), Some("B"), "the nearest display");
    assert_eq!(y, 599.0);
    let (x2, y2) = t.clamp(-100.0, 50.0);
    assert_eq!(name(t.display_at(x2, y2)), Some("C"));
    assert_eq!(t.clamp(10.0, 10.0).0, 10.0, "a point on a display stays where it is");
    assert_eq!(t.clamp(5000.0, 10.0).0, 1823.0, "past the last display's edge: its last column");
}

#[test]
fn a_window_is_on_the_display_holding_its_centre() {
    let t = three();
    assert_eq!(name(t.display_for(Rect::new(900, 10, 300, 200))), Some("B"));
    assert_eq!(name(t.display_for(Rect::new(900, 10, 200, 200))), Some("A"));
    assert_eq!(name(t.display_for(Rect::new(1300, 550, 400, 400))), Some("B"), "centre in a gap: the display it overlaps most");
    assert_eq!(name(t.display_for(Rect::new(9000, 9000, 10, 10))), Some("A"), "on no display at all: the main one");
}

#[test]
fn an_output_draws_its_own_rectangle_of_the_layout() {
    assert_eq!(project(Rect::new(1000, 20, 100, 50), 1024, 0, 1.0), Rect::new(-24, 20, 100, 50));
    let a = project(Rect::new(1024, 0, 33, 10), 1024, 0, 1.5);
    let b = project(Rect::new(1057, 0, 33, 10), 1024, 0, 1.5);
    assert_eq!(a.x + a.width, b.x, "no seam at a fractional scale");
    assert_eq!(project(Rect::new(10, 10, 20, 20), 0, 0, 2.0), Rect::new(20, 20, 40, 40));
}

fn recorders(n: usize, capacity: usize) -> Vec<FlightRecorder> {
    (0..n).map(|_| FlightRecorder::new(capacity)).collect()
}

/// Half a second of real time on `c`, after a warm-up.
fn serve_half_a_second(c: &mut Conductor<SyntheticOutput, SyntheticScene>, n: usize) -> Vec<FlightRecorder> {
    let mut warm = recorders(n, 256);
    for _ in 0..30 {
        c.serve_next(&mut warm);
    }
    let mut recs = recorders(n, 4096);
    let start = mono::now();
    while mono::now() - start < 500_000_000 {
        c.serve_next(&mut recs);
    }
    recs
}

/// Real time, on synthetic displays: a 144 Hz and a 60 Hz output on one
/// loop are each served at their own rate, and neither misses.
#[test]
fn mixed_rates_are_each_served_at_their_own() {
    let outputs = vec![SyntheticOutput::new(16_666_667, 200_000), SyntheticOutput::new(6_944_444, 200_000)];
    let sinks = vec![SyntheticScene::new(4, (640, 480)), SyntheticScene::new(4, (640, 480))];
    let mut c = Conductor::new(outputs, sinks, Config::default());
    let recs = serve_half_a_second(&mut c, 2);
    let (f60, f144) = (recs[0].retained() as f64, recs[1].retained() as f64);
    assert!((f60 - 30.0).abs() <= 3.0, "the 60 Hz output made {f60} frames in half a second");
    assert!((f144 - 72.0).abs() <= 5.0, "the 144 Hz output made {f144} frames in half a second");
    assert!(recs[0].missed_count() + recs[1].missed_count() <= 1, "misses: {} at 60, {} at 144", recs[0].missed_count(), recs[1].missed_count());
}

/// Three outputs at one rate: the third is not starved by ties. Per unit of
/// time, not per call (a per-call count was a test of timing luck).
#[test]
fn equal_outputs_are_all_served() {
    let outputs = (0..3).map(|_| SyntheticOutput::new(16_666_667, 200_000)).collect();
    let sinks = (0..3).map(|_| SyntheticScene::new(2, (320, 240))).collect();
    let mut c = Conductor::new(outputs, sinks, Config::default());
    let frames: Vec<usize> = serve_half_a_second(&mut c, 3).iter().map(FlightRecorder::retained).collect();
    let (lo, hi) = (frames.iter().min().copied().unwrap_or(0), frames.iter().max().copied().unwrap_or(0));
    assert!(hi - lo <= 2, "frames per output: {frames:?}");
    assert!(frames.iter().all(|&f| (f as f64 - 30.0).abs() <= 3.0), "frames per output in half a second: {frames:?}");
}

// MARK: what a client may ask for, and what is kept (P14.7b)

fn s(n: &str, w: i32, h: i32, x: i32, y: i32, scale: f64, on: bool) -> DisplaySetting {
    DisplaySetting { name: n.into(), enabled: on, mode_width: w, mode_height: h, refresh_milli_hz: 60000, x, y, scale }
}

fn plain(n: &str, w: i32, h: i32, x: i32, y: i32) -> DisplaySetting {
    s(n, w, h, x, y, 1.0, true)
}

#[test]
fn a_layout_box_is_the_mode_over_the_scale() {
    assert_eq!(s("B", 1024, 768, -1024, 100, 2.0, true).display_box(), DisplayBox { scale: 2.0, ..DisplayBox::new("B", -1024, 100, 512, 384) });
    assert_eq!(s("B", 1920, 1080, 0, 0, 1.5, true).display_box().width, 1280);
}

#[test]
fn a_request_is_refused_in_words() {
    assert!(problems(&[plain("A", 640, 480, 0, 0), plain("B", 800, 600, 640, 0)]).is_empty(), "side by side");
    assert_eq!(problems(&[plain("A", 640, 480, 0, 0), plain("B", 800, 600, 600, 0)]), ["A and B overlap"]);
    assert!(problems(&[plain("A", 640, 480, 0, 0), s("B", 1600, 1200, 640, 0, 2.0, true)]).is_empty(), "a scaled display's box is its mode over its scale");
    assert_eq!(problems(&[plain("A", 640, 480, 0, 0), s("B", 800, 600, 640, 0, 1.0, false)]), ["B: turning a display off is not supported yet"]);
    assert_eq!(problems(&[s("A", 640, 480, 0, 0, 8.0, true)]), ["A: a scale of 8.0 is outside 0.5 to 4"]);
    assert_eq!(problems(&[plain("A", 0, 480, 0, 0)]), ["A: 0x480 is not a mode"]);
    assert_eq!(problems(&[]), ["a configuration must name at least one display"]);
}

#[test]
fn a_line_of_displays_ini_round_trips() {
    for d in [s("HEADLESS-2", 1024, 768, -1024, 100, 2.0, true), s("DP-1", 2560, 1440, 0, 0, 1.25, true)] {
        assert_eq!(parse_setting(&d.name, &format_setting(&d)), Some(d.clone()));
    }
    assert_eq!(format_setting(&plain("A", 640, 480, 0, 0)), "0,0 640x480@60000 1");
    assert_eq!(parse_setting("A", "0,0 640x480 1"), None, "a line without a refresh is not one");
    assert_eq!(parse_setting("A", "garbage"), None);
}

#[test]
fn displays_ini_is_stored_and_loaded() {
    let dir = std::env::temp_dir().join(format!("abyss-displays-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let d = dir.to_string_lossy().into_owned();
    let (a, b) = (plain("HEADLESS-1", 640, 480, 0, 0), s("HEADLESS-2", 1024, 768, -1024, 100, 2.0, true));
    store_settings(&[a.clone(), b.clone()], Some(&d)).unwrap();
    assert_eq!(load_settings(Some(&d)), BTreeMap::from([("HEADLESS-1".to_owned(), a.clone()), ("HEADLESS-2".to_owned(), b)]));
    store_settings(&[plain("HEADLESS-2", 800, 600, 640, 0)], Some(&d)).unwrap();
    assert_eq!(load_settings(Some(&d))["HEADLESS-2"].x, 640, "a later apply replaces the line");
    assert_eq!(load_settings(Some(&d))["HEADLESS-1"], a, "and leaves the others");
    assert!(load_settings(Some(&format!("{d}/none"))).is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}
