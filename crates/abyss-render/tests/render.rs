// SPDX-License-Identifier: BSD-2-Clause

//! `abyss-render` tests — geometry, and the CPU rasterizer proven with
//! precise pixel assertions (`docs/design/toolkit.md` §12).

use abyss_render::{
    Canvas, Color, CpuBackend, FillRule, GradientStop, Paint, Path, Pixmap, Point, Rect, Transform,
};

const RED: Color = Color::rgb(255, 0, 0);
const BLUE: Color = Color::rgb(0, 0, 255);

/// Render `draw` onto a fresh `w`×`h` transparent target.
fn render(w: u32, h: u32, draw: impl FnOnce(&mut Canvas)) -> Pixmap {
    let mut backend = CpuBackend::new(w, h);
    {
        let mut canvas = Canvas::new(&mut backend);
        draw(&mut canvas);
    }
    backend.into_pixmap()
}

/// Per-channel equality within `tol`.
fn near(a: Color, b: Color, tol: u8) -> bool {
    a.r.abs_diff(b.r) <= tol
        && a.g.abs_diff(b.g) <= tol
        && a.b.abs_diff(b.b) <= tol
        && a.a.abs_diff(b.a) <= tol
}

#[test]
fn transform_compose_and_apply() {
    // scaling applied first, then translation
    let t = Transform::translation(10.0, 20.0).concat(&Transform::scaling(2.0, 3.0));
    let p = t.apply(Point::new(1.0, 1.0));
    assert!((p.x - 12.0).abs() < 1e-4 && (p.y - 23.0).abs() < 1e-4);
    assert!((Transform::IDENTITY.scale_factor() - 1.0).abs() < 1e-4);
    assert!((Transform::scaling(4.0, 4.0).scale_factor() - 4.0).abs() < 1e-4);
}

#[test]
fn flatten_rect_and_rounded_rect() {
    let rect = Path::rect(Rect::new(0.0, 0.0, 10.0, 10.0)).flatten(0.1);
    assert_eq!(rect.len(), 1);
    assert_eq!(rect[0].len(), 4);

    let rounded = Path::rounded_rect(Rect::new(0.0, 0.0, 40.0, 40.0), 10.0).flatten(0.1);
    assert_eq!(rounded.len(), 1);
    assert!(rounded[0].len() > 8, "corners should be subdivided");
}

#[test]
fn integer_aligned_rect_is_crisp() {
    let pm = render(40, 40, |c| {
        c.fill_rect(Rect::new(10.0, 10.0, 20.0, 20.0), &Paint::solid(RED));
    });
    assert_eq!(pm.pixel(15, 15), RED, "interior is exactly the fill color");
    assert_eq!(pm.pixel(10, 10), RED, "origin pixel is inside");
    assert_eq!(pm.pixel(29, 29), RED, "last interior pixel");
    assert_eq!(pm.pixel(5, 5), Color::TRANSPARENT, "exterior untouched");
    assert_eq!(pm.pixel(30, 30), Color::TRANSPARENT, "past the far edge");
    assert_eq!(pm.pixel(9, 15), Color::TRANSPARENT, "just left of the edge");
}

#[test]
fn fractional_edge_is_anti_aliased() {
    // left edge at x = 10.5 — column 10 should be ~half covered
    let pm = render(40, 40, |c| {
        c.fill_rect(Rect::new(10.5, 10.0, 10.0, 10.0), &Paint::solid(RED));
    });
    let edge = pm.pixel(10, 13);
    assert!(
        edge.a > 100 && edge.a < 160,
        "edge pixel ~50% covered, got alpha {}",
        edge.a
    );
    assert_eq!(pm.pixel(11, 13), RED, "fully-covered interior column");
    assert_eq!(pm.pixel(9, 13), Color::TRANSPARENT, "outside the edge");
}

#[test]
fn triangle_fill() {
    let mut path = Path::new();
    path.move_to(Point::new(20.0, 4.0))
        .line_to(Point::new(36.0, 36.0))
        .line_to(Point::new(4.0, 36.0))
        .close();
    let pm = render(40, 40, |c| {
        c.fill(&path, &Paint::solid(RED), FillRule::NonZero)
    });
    assert_eq!(pm.pixel(20, 30), RED, "inside the triangle");
    assert_eq!(pm.pixel(4, 6), Color::TRANSPARENT, "outside, near the apex");
}

#[test]
fn rounded_rect_corner_is_cut() {
    let pm = render(40, 40, |c| {
        c.fill(
            &Path::rounded_rect(Rect::new(0.0, 0.0, 40.0, 40.0), 10.0),
            &Paint::solid(RED),
            FillRule::NonZero,
        );
    });
    assert_eq!(pm.pixel(20, 20), RED, "center is filled");
    assert_eq!(pm.pixel(1, 1), Color::TRANSPARENT, "corner is rounded away");
    assert_eq!(pm.pixel(20, 1), RED, "the straight top edge is filled");
}

#[test]
fn linear_gradient_runs_across() {
    let paint = Paint::Linear {
        start: Point::new(0.0, 0.0),
        end: Point::new(40.0, 0.0),
        stops: vec![GradientStop::new(0.0, RED), GradientStop::new(1.0, BLUE)],
    };
    let pm = render(40, 12, |c| {
        c.fill_rect(Rect::new(0.0, 0.0, 40.0, 12.0), &paint)
    });
    let left = pm.pixel(2, 6);
    let right = pm.pixel(37, 6);
    assert!(left.r > right.r, "red fades out left→right");
    assert!(left.b < right.b, "blue fades in left→right");
    assert_eq!(left.a, 255);
    assert!(
        near(pm.pixel(20, 6), Color::rgb(128, 0, 128), 24),
        "midpoint is purple"
    );
}

#[test]
fn clip_confines_drawing() {
    let pm = render(40, 40, |c| {
        c.clip_rect(Rect::new(10.0, 10.0, 10.0, 10.0));
        c.fill_rect(Rect::new(0.0, 0.0, 40.0, 40.0), &Paint::solid(RED));
    });
    assert_eq!(pm.pixel(15, 15), RED, "inside the clip");
    assert_eq!(pm.pixel(5, 5), Color::TRANSPARENT, "outside the clip");
    assert_eq!(pm.pixel(25, 25), Color::TRANSPARENT, "past the clip");
}

#[test]
fn source_over_compositing() {
    let pm = render(20, 20, |c| {
        c.fill_rect(Rect::new(0.0, 0.0, 20.0, 20.0), &Paint::solid(RED));
        c.fill_rect(
            Rect::new(0.0, 0.0, 20.0, 20.0),
            &Paint::solid(Color::rgba(0, 0, 255, 128)),
        );
    });
    assert!(
        near(pm.pixel(10, 10), Color::rgb(128, 0, 128), 4),
        "50% blue over red is purple, got {:?}",
        pm.pixel(10, 10)
    );
}

#[test]
fn non_zero_winding_makes_a_hole() {
    // outer contour clockwise, inner contour counter-clockwise → a ring
    let mut path = Path::new();
    path.move_to(Point::new(0.0, 0.0))
        .line_to(Point::new(40.0, 0.0))
        .line_to(Point::new(40.0, 40.0))
        .line_to(Point::new(0.0, 40.0))
        .close()
        .move_to(Point::new(10.0, 10.0))
        .line_to(Point::new(10.0, 30.0))
        .line_to(Point::new(30.0, 30.0))
        .line_to(Point::new(30.0, 10.0))
        .close();
    let pm = render(40, 40, |c| {
        c.fill(&path, &Paint::solid(RED), FillRule::NonZero)
    });
    assert_eq!(pm.pixel(5, 5), RED, "the ring is filled");
    assert_eq!(pm.pixel(20, 20), Color::TRANSPARENT, "the hole is empty");
}

#[test]
fn even_odd_winding_makes_a_hole() {
    // two same-wound overlapping rects → the overlap is a hole
    let mut path = Path::new();
    path.move_to(Point::new(0.0, 0.0))
        .line_to(Point::new(25.0, 0.0))
        .line_to(Point::new(25.0, 25.0))
        .line_to(Point::new(0.0, 25.0))
        .close()
        .move_to(Point::new(15.0, 15.0))
        .line_to(Point::new(40.0, 15.0))
        .line_to(Point::new(40.0, 40.0))
        .line_to(Point::new(15.0, 40.0))
        .close();
    let pm = render(40, 40, |c| {
        c.fill(&path, &Paint::solid(RED), FillRule::EvenOdd)
    });
    assert_eq!(pm.pixel(5, 5), RED, "first rectangle alone");
    assert_eq!(pm.pixel(35, 35), RED, "second rectangle alone");
    assert_eq!(pm.pixel(20, 20), Color::TRANSPARENT, "the overlap cancels");
}

#[test]
fn color_compositing_helpers() {
    assert_eq!(
        Color::WHITE.over(Color::BLACK),
        Color::WHITE,
        "opaque hides"
    );
    assert_eq!(
        Color::TRANSPARENT.over(RED),
        RED,
        "transparent shows through"
    );
    assert_eq!(RED.lerp(BLUE, 0.5), Color::rgb(128, 0, 128));
    assert_eq!(RED.scale_alpha(0.5).a, 128);
}
