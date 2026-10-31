//! Server-side decorations (Decorations.swift, PHASE9.md P9.6, §6.1).
//!
//! `xdg-decoration` is how a client asks who draws the frame, and **we
//! always answer: we do.** A desktop with two window styles has failed at
//! the one thing this project is for.
//!
//! **The frame is rasterised once per size, never on the frame path.** Cairo
//! is in the compositor because a rect-and-gradient renderer cannot draw a
//! gel traffic light. The cost is bounded by a cache: a window not being
//! resized rasterises its frame once, and the present path samples a texture
//! like any other.

use crate::cursor_images::ARGB8888;
use aquadraw::draw;
use aquadraw::drawlist::DrawState;
use aquadraw::runner::{Rect as ARect, Runner};
use aquadraw::theme::Theme;
use abyss_sys::wlr::{Renderer, Texture};
use abyss_sys::{self as ffi, Context, Surface};
use std::collections::HashMap;

/// A rasterised frame, kept until its size, focus, title or theme changes.
struct FrameTexture {
    texture: Texture,
    width: i32,
    height: i32,
    active: bool,
    title: String,
    theme_generation: u64,
}

impl Drop for FrameTexture {
    fn drop(&mut self) {
        self.texture.destroy()
    }
}

/// The frames themselves, one per window, by its id.
#[derive(Default)]
pub struct Frames {
    frames: HashMap<u32, FrameTexture>,
    /// How many rasterisations: the number §6.1 wanted measured. If it
    /// climbs while nothing is resized, the cache is not working.
    pub rasterisations: u64,
}

impl Frames {
    /// The frame texture for window `id`, `w`×`h` with `title`, rasterised
    /// only if something changed (the theme too, P14.2: a frame from an old
    /// theme matches nothing).
    #[allow(clippy::too_many_arguments)]
    pub fn texture(&mut self, id: u32, w: i32, h: i32, active: bool, title: &str, renderer: Renderer, runner: &mut Runner, theme: &Theme) -> Option<Texture> {
        if let Some(f) = self.frames.get(&id)
            && (f.width, f.height, f.active, f.theme_generation) == (w, h, active, theme.generation)
            && f.title == title
        {
            return Some(f.texture);
        }
        let texture = rasterise(w, h, active, title, renderer, runner, theme)?;
        self.frames.insert(id, FrameTexture { texture, width: w, height: h, active, title: title.into(), theme_generation: theme.generation });
        self.rasterisations += 1;
        Some(texture)
    }

    /// A window's frame goes with the window.
    pub fn forget(&mut self, id: u32) {
        self.frames.remove(&id);
    }

    pub fn release(&mut self) {
        self.frames.clear();
    }
}

fn rasterise(w: i32, h: i32, active: bool, title: &str, renderer: Renderer, runner: &mut Runner, theme: &Theme) -> Option<Texture> {
    if w <= 0 || h <= 0 {
        return None;
    }
    let cs = Surface::image(ffi::FORMAT_ARGB32, w, h);
    {
        let cr = Context::new(&cs);
        // Transparent to start: the frame is drawn over what is behind it,
        // and the client's pixels land in the hole it leaves.
        cr.set_operator(ffi::OPERATOR_SOURCE);
        cr.set_source_rgba(0.0, 0.0, 0.0, 0.0);
        cr.paint();
        cr.set_operator(ffi::OPERATOR_OVER);
        // The toolkit's own chrome at the frame's size. It fills the body
        // too: for the one frame between a resize and the client catching
        // up, a Jaguar-grey body rather than a hole.
        draw::paint_window_chrome(runner, theme, &cr, w as f64, h as f64, title, true, true);
        if !active {
            // Inactive windows are lighter on 10.2: one wash over the frame.
            draw::paint(runner, theme, "window.inactive", &cr, ARect::new(0.0, 0.0, w as f64, h as f64), DrawState::NORMAL, "", &[]);
        }
    }
    cs.flush();
    // DRM_FORMAT_ARGB8888: cairo's ARGB32, premultiplied, as is.
    let bytes: Vec<u8> = cs.argb_pixels(w, h).iter().flat_map(|p| p.to_ne_bytes()).collect();
    renderer.texture_from_pixels(ARGB8888, w as u32 * 4, w as u32, h as u32, &bytes)
}
