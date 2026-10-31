//! A scrolling list against a real clipped viewport (Scroll.swift): one
//! layout feeds the painter and the hit-tester, so the thumb dragged is the
//! thumb seen. Jaguar pairs both arrows at the bottom.

use aquadraw::canvas::{Arrow, Canvas};
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::{DrawState, Role};
use aquadraw::runner::Rect;
use aquadraw::text::Style;

pub const ITEM_COUNT: usize = 24;
pub const ROW_HEIGHT: f64 = 26.0;
pub const BAR_WIDTH: f64 = 15.0;

/// What does not depend on the offset.
#[derive(Clone, Copy, Debug, Default)]
pub struct ScrollLayout {
    /// The clipped content viewport.
    pub list: Rect,
    /// The thumb's travel channel.
    pub track: Rect,
    pub up_arrow: Rect,
    pub down_arrow: Rect,
}

pub fn content_height() -> f64 {
    ITEM_COUNT as f64 * ROW_HEIGHT
}

/// The largest offset for a viewport `viewport_h` high.
pub fn max_offset(viewport_h: f64) -> f64 {
    (content_height() - viewport_h).max(0.0)
}

pub fn scroll_layout(w: f64, h: f64, title_bar: f64) -> ScrollLayout {
    let (m, bar) = (14.0, BAR_WIDTH);
    let top = title_bar + m;
    let outer = Rect::new(m, top, w - 2.0 * m, h - top - m);
    let bar_x = outer.x + outer.w - bar;
    ScrollLayout {
        list: Rect::new(outer.x, outer.y, outer.w - bar, outer.h),
        track: Rect::new(bar_x, outer.y, bar, outer.h - 2.0 * bar),
        up_arrow: Rect::new(bar_x, outer.y + outer.h - 2.0 * bar, bar, bar),
        down_arrow: Rect::new(bar_x, outer.y + outer.h - bar, bar, bar),
    }
}

/// The thumb for `offset` over content `content_h` high, or None when the
/// content fits (Aqua hides the thumb then). Every scrolling view sizes
/// its thumb from this.
pub fn thumb_rect(track: Rect, offset: f64, viewport_h: f64, content_h: f64) -> Option<Rect> {
    if content_h <= viewport_h || track.h <= 0.0 {
        return None;
    }
    let thumb_h = (track.h * (viewport_h / content_h)).max(24.0);
    let max_off = content_h - viewport_h;
    let t = if max_off > 0.0 { (offset / max_off).clamp(0.0, 1.0) } else { 0.0 };
    Some(Rect::new(track.x + 2.0, track.y + t * (track.h - thumb_h), track.w - 4.0, thumb_h))
}

/// Paint the scene, and return its layout.
pub fn paint_scroll(c: &mut Canvas, w: f64, h: f64, offset: f64) -> ScrollLayout {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, "Scroll", false, true);
    let t = c.theme.tokens.clone();
    let l = scroll_layout(w, h, t.title_bar_height);
    let viewport_h = l.list.h;
    let off = offset.clamp(0.0, max_offset(viewport_h));
    // The clipped, striped content.
    c.cr.save();
    c.cr.rectangle(l.list.x, l.list.y, l.list.w, l.list.h);
    c.cr.clip();
    c.paint_simple("listview", l.list, DrawState::NORMAL);
    let first = (off / ROW_HEIGHT) as usize;
    let last = (ITEM_COUNT - 1).min(((off + viewport_h) / ROW_HEIGHT) as usize);
    for i in first..=last {
        let ry = l.list.y + i as f64 * ROW_HEIGHT - off;
        if i % 2 == 1 {
            c.paint_simple("listview.stripe", Rect::new(l.list.x, ry, l.list.w, ROW_HEIGHT), DrawState::NORMAL);
        }
        c.text_left(&format!("Item {:02}", i + 1), l.list.x + 12.0, ry + ROW_HEIGHT - 8.0, t.body_text, t.font_size, Style::Regular, Role::Interface);
    }
    c.cr.restore();
    c.paint_simple("listview.frame", l.list, DrawState::NORMAL);
    // The scrollbar: track, thumb, the paired arrows.
    c.scroll_track(l.track);
    if let Some(thumb) = thumb_rect(l.track, off, viewport_h, content_height()) {
        c.scroll_thumb(thumb)
    }
    let max_off = max_offset(viewport_h);
    c.scroll_arrow(l.up_arrow, Arrow::Up, off > 0.5);
    c.scroll_arrow(l.down_arrow, Arrow::Down, off < max_off - 0.5);
    l
}
