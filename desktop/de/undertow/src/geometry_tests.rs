//! The placement rules (Tests/UndertowTests): layer shell, snapping, Ebb's
//! grid, the slide, hit-testing, and remembered places.

use crate::geometry::*;
use crate::places::{WindowPlace, WindowPlaces};

const FULL: Rect = Rect::new(0, 0, 800, 600);
/// The usable area, not the output: a window snapped under the menu bar is
/// the same defect as one placed there.
const SNAP_AREA: Rect = Rect::new(0, 22, 800, 578);

fn req(anchor: LayerAnchor, w: i32, h: i32) -> LayerRequest {
    LayerRequest::new(anchor, w, h)
}

use LayerAnchor as A;

// MARK: layer shell (P6.6)

/// The menu bar: a top strip that reserves its height (HANDOFF §2.26).
#[test]
fn a_top_strip_with_an_exclusive_zone_reserves_it() {
    let bar = LayerRequest { exclusive_zone: 22, ..req(A::TOP | A::LEFT | A::RIGHT, 0, 22) };
    assert_eq!(place_layer(&bar, FULL, FULL), (Rect::new(0, 0, 800, 22), Rect::new(0, 22, 800, 578)));
}

/// The Dock: anchored to the bottom, reserving nothing.
#[test]
fn a_zero_zone_surface_overlaps_and_reserves_nothing() {
    let (rect, usable) = place_layer(&req(A::BOTTOM, 320, 64), FULL, FULL);
    assert_eq!(rect, Rect::new(240, 536, 320, 64));
    assert_eq!(usable, FULL, "a zero zone must reserve nothing");
}

/// The desktop: a zone of -1 ignores everyone's reservations.
#[test]
fn an_exclusive_zone_of_minus_one_ignores_reservations() {
    let wallpaper = LayerRequest { exclusive_zone: -1, ..req(A::TOP | A::BOTTOM | A::LEFT | A::RIGHT, 0, 0) };
    let after_bar = Rect::new(0, 22, 800, 578);
    let (rect, usable) = place_layer(&wallpaper, after_bar, FULL);
    assert_eq!(rect, FULL, "the desktop must cover the whole output");
    assert_eq!(usable, after_bar, "and must not change anyone else's area");
}

/// Arranged in order, reservations accumulate.
#[test]
fn reservations_accumulate_in_order() {
    let bar = LayerRequest { exclusive_zone: 22, ..req(A::TOP | A::LEFT | A::RIGHT, 0, 22) };
    let shelf = LayerRequest { exclusive_zone: 60, ..req(A::BOTTOM | A::LEFT | A::RIGHT, 0, 60) };
    let (_, usable) = place_layer(&bar, FULL, FULL);
    let (shelf_rect, last) = place_layer(&shelf, usable, FULL);
    assert_eq!(shelf_rect, Rect::new(0, 540, 800, 60), "at the bottom of what was left, not of the output");
    assert_eq!(last, Rect::new(0, 22, 800, 518));
}

/// Anchored to opposite edges means "span", and reserves nothing.
#[test]
fn spanning_both_edges_reserves_nothing() {
    let all = LayerRequest { exclusive_zone: 40, ..req(A::TOP | A::BOTTOM | A::LEFT | A::RIGHT, 0, 0) };
    assert_eq!(place_layer(&all, FULL, FULL), (FULL, FULL));
}

/// Margins push a surface off its edge and count toward the reservation.
#[test]
fn margins_offset_the_surface_and_count_toward_the_reservation() {
    let toast = LayerRequest { margin_top: 30, margin_right: 12, ..req(A::TOP | A::RIGHT, 300, 58) };
    let (rect, usable) = place_layer(&toast, FULL, FULL);
    assert_eq!(rect, Rect::new(800 - 300 - 12, 30, 300, 58));
    assert_eq!(usable, FULL, "a toast reserves nothing (PHASE7 P7.4)");
    let bar = LayerRequest { exclusive_zone: 22, margin_top: 4, ..req(A::TOP | A::LEFT | A::RIGHT, 0, 22) };
    assert_eq!(place_layer(&bar, FULL, FULL).1.y, 26, "the margin is part of the space taken");
}

/// A reservation can never make the usable area negative.
#[test]
fn an_oversized_reservation_cannot_invert_the_usable_area() {
    let greedy = LayerRequest { exclusive_zone: 9999, ..req(A::TOP | A::LEFT | A::RIGHT, 0, 9999) };
    let (_, usable) = place_layer(&greedy, FULL, FULL);
    assert!(usable.height >= 0 && usable.width >= 0);
}

// MARK: edge snapping (P9.4)

#[test]
fn snap_zones_are_the_three_edges_and_nothing_else() {
    let a = SNAP_AREA;
    assert_eq!(snap_zone(2, 300, a), Some(SnapZone::Left));
    assert_eq!(snap_zone(799, 300, a), Some(SnapZone::Right));
    assert_eq!(snap_zone(400, 24, a), Some(SnapZone::Maximize));
    assert_eq!(snap_zone(400, 300, a), None, "the middle snaps to nothing");
    assert_eq!(snap_zone(400, 599, a), None, "the bottom edge is the Dock's");
}

#[test]
fn the_top_corners_maximize_rather_than_halve() {
    assert_eq!(snap_zone(0, 22, SNAP_AREA), Some(SnapZone::Maximize));
    assert_eq!(snap_zone(799, 22, SNAP_AREA), Some(SnapZone::Maximize));
}

#[test]
fn snap_halves_tile_the_area_exactly() {
    let a = SNAP_AREA;
    let (l, r) = (snap_rect(SnapZone::Left, a), snap_rect(SnapZone::Right, a));
    assert_eq!(l.x, a.x);
    assert_eq!(l.x + l.width, r.x, "no gutter");
    assert_eq!(r.x + r.width, a.x + a.width, "no overhang");
    assert_eq!(l.height, a.height);
    assert_eq!(snap_rect(SnapZone::Maximize, a), a);
    let odd = Rect::new(0, 0, 801, 100);
    let (ol, or) = (snap_rect(SnapZone::Left, odd), snap_rect(SnapZone::Right, odd));
    assert_eq!(ol.width + or.width, odd.width);
    assert_eq!(ol.x + ol.width, or.x);
}

#[test]
fn an_empty_area_snaps_to_nothing() {
    assert_eq!(snap_zone(0, 0, Rect::new(0, 0, 0, 0)), None);
}

// MARK: hit-testing (P6.4)

#[test]
fn the_topmost_window_under_the_pointer_wins() {
    let rects = [Rect::new(0, 0, 200, 200), Rect::new(100, 100, 200, 200)];
    assert_eq!(hit(150.0, 150.0, &rects).map(|h| h.0), Some(1));
    assert_eq!(hit(50.0, 50.0, &rects).map(|h| h.0), Some(0));
    assert_eq!(hit(250.0, 250.0, &rects).map(|h| h.0), Some(1));
    assert_eq!(hit(400.0, 400.0, &rects), None);
    assert_eq!(hit(150.0, 150.0, &[]), None);
}

/// A click arrives in the surface's own coordinates, not the output's.
#[test]
fn a_hit_reports_surface_local_coordinates() {
    let (_, x, y) = hit(540.0, 415.0, &[Rect::new(170, 120, 460, 360)]).expect("inside the window");
    assert!((x - 370.0).abs() < 0.001 && (y - 295.0).abs() < 0.001);
}

/// Half-open: the top-left corner is inside, the bottom-right is not.
#[test]
fn hit_test_bounds_are_half_open() {
    let rects = [Rect::new(10, 10, 100, 100)];
    assert!(hit(10.0, 10.0, &rects).is_some());
    assert!(hit(109.9, 109.9, &rects).is_some());
    assert!(hit(110.0, 60.0, &rects).is_none());
    assert!(hit(60.0, 110.0, &rects).is_none());
    assert!(hit(9.9, 60.0, &rects).is_none());
}

#[test]
fn the_cursor_is_clamped_to_the_output() {
    assert_eq!(clamp_cursor(-50.0, -50.0, 800.0, 600.0), (0.0, 0.0));
    assert_eq!(clamp_cursor(9999.0, 9999.0, 800.0, 600.0), (799.0, 599.0));
    assert_eq!(clamp_cursor(400.0, 300.0, 800.0, 600.0), (400.0, 300.0));
}

// MARK: the slide (P13.3)

/// From where it was to where it is going, fast then settling, then gone.
#[test]
fn a_slide_moves_the_view_then_stops() {
    let s = IslandSlide { from: 1.0, to: 2, start: 1_000, duration_ns: 150_000_000 };
    assert_eq!(s.view(1_000), Some(1.0));
    assert_eq!(s.view(1_000 + 150_000_000), None, "arrived: nothing left to draw specially");
    let mut last = 1.0;
    for ms in (10..150).step_by(10) {
        let v = s.view(1_000 + ms * 1_000_000).unwrap();
        assert!(v > last && v < 2.0, "monotonic");
        last = v;
    }
    assert!(s.view(1_000 + 75_000_000).unwrap() > 1.5, "ease-out: past half way at half time");
    let back = IslandSlide { from: 4.0, to: 1, start: 0, duration_ns: 100 };
    assert!(back.view(50).unwrap() < 4.0);
}

// MARK: Ebb (P13.5)

fn ebb_items(sizes: &[(i32, i32)]) -> Vec<EbbItem> {
    sizes.iter().enumerate().map(|(i, &(width, height))| EbbItem { id: i as u32 + 1, width, height }).collect()
}

/// Inside the area, never overlapping, aspect kept, never enlarged.
#[test]
fn ebb_slots_are_inside_apart_in_proportion_and_never_larger() {
    let area = Rect::new(0, 22, 1280, 700);
    let cases: Vec<Vec<(i32, i32)>> =
        vec![vec![(800, 600)], vec![(800, 600), (400, 300), (1200, 900)], vec![(640, 480); 7], vec![(300, 900), (1600, 200), (500, 500), (90, 60)]];
    for sizes in cases {
        let items = ebb_items(&sizes);
        let slots = ebb_arrange(&items, area, 24);
        assert_eq!(slots.len(), items.len());
        for (i, (id, r)) in slots.iter().enumerate() {
            let it = items[i];
            assert_eq!(*id, it.id);
            assert!(r.x >= area.x && r.y >= area.y && r.x + r.width <= area.x + area.width && r.y + r.height <= area.y + area.height);
            assert!(r.width <= it.width, "never drawn larger than it is");
            let (want, got) = (f64::from(it.width) / f64::from(it.height), f64::from(r.width) / f64::from(r.height));
            assert!((got - want).abs() <= want * 0.05 + 0.05, "aspect kept");
            for (_, q) in &slots[i + 1..] {
                let apart = r.x + r.width <= q.x || q.x + q.width <= r.x || r.y + r.height <= q.y || q.y + q.height <= r.y;
                assert!(apart, "slots overlap: {r:?} and {q:?}");
            }
        }
    }
}

/// One window that fits is shown at its own size; a new window does not
/// move the others' reading order.
#[test]
fn ebb_is_stable_and_does_not_enlarge() {
    let area = Rect::new(0, 0, 1600, 1000);
    let one = ebb_arrange(&ebb_items(&[(400, 300)]), area, 24);
    assert_eq!((one[0].1.width, one[0].1.height), (400, 300));
    let order = |slots: &[(u32, Rect)], ids: &[u32]| {
        let mut v: Vec<u32> = ids.to_vec();
        let at = |id: u32| slots.iter().find(|s| s.0 == id).unwrap().1;
        v.sort_by_key(|&id| (at(id).y, at(id).x));
        v
    };
    let three = ebb_arrange(&ebb_items(&[(640, 480); 3]), area, 24);
    let four = ebb_arrange(&ebb_items(&[(640, 480); 4]), area, 24);
    assert_eq!(order(&three, &[1, 2, 3]), [1, 2, 3]);
    assert_eq!(order(&four, &[1, 2, 3]), [1, 2, 3], "the first three keep their reading order");
    assert!(ebb_arrange(&[], area, 24).is_empty());
}

// MARK: remembered places (P6.7)

/// app_id alone would be wrong: one window per folder from one application.
#[test]
fn a_window_key_distinguishes_windows_of_the_same_app() {
    let a = WindowPlaces::key(Some("org.abyssbsd.finder"), Some("Documents"));
    let b = WindowPlaces::key(Some("org.abyssbsd.finder"), Some("Pictures"));
    assert!(a.is_some());
    assert_ne!(a, b, "two folders of one app must not share a key");
}

/// A window with no title still gets a key; one with neither gets none.
#[test]
fn a_window_key_needs_something_stable() {
    assert_eq!(WindowPlaces::key(Some("org.abyssbsd.demo"), None).as_deref(), Some("org.abyssbsd.demo"));
    assert_eq!(WindowPlaces::key(Some("org.abyssbsd.demo"), Some("  ")).as_deref(), Some("org.abyssbsd.demo"), "whitespace is not a title");
    assert_eq!(WindowPlaces::key(None, None), None);
    assert_eq!(WindowPlaces::key(Some(""), Some("")), None);
}

/// The separator is not forgeable through a title.
#[test]
fn a_window_key_cannot_be_forged_through_the_separator() {
    let honest = WindowPlaces::key(Some("app"), Some("a/b")).unwrap();
    let sneaky = WindowPlaces::key(Some("app/a"), Some("b")).unwrap();
    assert_ne!(honest, sneaky, "a title holding the separator collided with another window's key");
    assert_eq!(honest.matches('/').count(), 1);
    assert_eq!(sneaky.matches('/').count(), 1);
    assert!(!WindowPlaces::key(Some("app"), Some("a=b")).unwrap().contains('='));
}

fn scratch(name: &str) -> String {
    let d = std::env::temp_dir().join(format!("abyss-places-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d.to_string_lossy().into_owned()
}

/// A position outlives the process that recorded it.
#[test]
fn a_position_round_trips_through_the_config_file() {
    let dir = scratch("trip");
    let mut writer = WindowPlaces::new(Some(&dir));
    assert_eq!(writer.place("app/Documents"), None, "nothing remembered yet");
    writer.remember(WindowPlace { x: 460, y: 345 }, "app/Documents");
    let reader = WindowPlaces::new(Some(&dir));
    assert_eq!(reader.place("app/Documents"), Some(WindowPlace { x: 460, y: 345 }));
    assert_eq!(reader.place("app/Pictures"), None);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A malformed entry reads as not remembered, never as (0,0).
#[test]
fn a_malformed_position_is_not_remembered() {
    let dir = scratch("bad");
    std::fs::write(format!("{dir}/windows.ini"), "[windows]\napp/Broken = not-a-position\napp/Half = 12\n").unwrap();
    let p = WindowPlaces::new(Some(&dir));
    assert_eq!((p.place("app/Broken"), p.place("app/Half")), (None, None));
    let _ = std::fs::remove_dir_all(&dir);
}
