//! wlr-screencopy-unstable-v1 (Screencopy.swift, P7.5): ask the compositor
//! to copy an output into a buffer of ours. It is what lets the screenshot
//! portal be an ordinary client.
//!
//!   capture_output(overlay_cursor, output)  → a frame
//!   ← buffer(format, w, h, stride)          the buffer it will take
//!   ← buffer_done                           (v3) that is every type
//!   copy(buffer)                            ours, exactly as asked
//!   ← flags(y_invert)                       the copy may be bottom-up
//!   ← ready | failed
//!
//! **The compositor dictates the buffer**: the one place that cannot pick
//! its own pixel layout. A capture pumps the connection itself, bounded, so
//! a one-shot grabber is a straight-line program and a compositor that
//! never answers times out.

use crate::backing::ShmBuffer;
use crate::display::Display;
use abyss_sys::proc::{poll, poll_fd};
use abyss_sys::wlc::{zwlr_screencopy_frame_v1 as frame, zwlr_screencopy_manager_v1, Connection};
use std::cell::RefCell;
use std::fmt;
use std::rc::Rc;
use std::time::{Duration, Instant};

/// A captured frame, normalised: packed native-endian ARGB8888, rows top
/// down, opaque. That is cairo's ARGB32, so `pixels` goes straight to it.
#[derive(Clone, Debug)]
pub struct ScreenCapture {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

impl ScreenCapture {
    pub fn stride(&self) -> usize {
        self.width * 4
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ScreencopyError {
    Unsupported,
    NoOutput(usize),
    Failed(String),
    TimedOut,
    UnsupportedFormat(u32),
}

impl fmt::Display for ScreencopyError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            ScreencopyError::Unsupported => write!(f, "the compositor does not offer wlr-screencopy"),
            ScreencopyError::NoOutput(i) => write!(f, "there is no output {i} to capture"),
            ScreencopyError::Failed(why) => write!(f, "{why}"),
            ScreencopyError::TimedOut => write!(f, "the compositor never finished the copy"),
            ScreencopyError::UnsupportedFormat(x) => write!(f, "the compositor offered a pixel format we can't read (0x{x:x})"),
        }
    }
}

impl std::error::Error for ScreencopyError {}

/// The formats read: wl_shm numbers ARGB8888 and XRGB8888 0 and 1, every
/// other is its DRM fourcc. Whether red and blue are swapped from cairo's
/// order, and bytes a pixel. **Three bytes a pixel is what a GPU renderer
/// offers** (U.3): wlroots' GLES2 screencopy is `BG24`, R,G,B in memory.
fn format_layout(format: u32) -> Option<(bool, usize)> {
    match format {
        0 | 1 => Some((false, 4)),
        0x3432_4241 | 0x3432_4258 => Some((true, 4)), // AB24, XB24
        0x3432_4742 => Some((true, 3)),               // BG24
        0x3432_4752 => Some((false, 3)),              // RG24
        _ => None,
    }
}

/// A raw frame to packed ARGB8888, top down, opaque: the compositor's
/// stride is its own (not `width * 4`), the copy may be bottom-up, and the
/// channels may be BGR. None if `raw` is short for the geometry or the
/// format is not one read.
pub fn normalise(raw: &[u8], format: u32, width: usize, height: usize, stride: usize, y_invert: bool) -> Option<Vec<u8>> {
    let (swap, bpp) = format_layout(format)?;
    if width == 0 || height == 0 || stride < width * bpp || raw.len() < stride * height {
        return None;
    }
    let mut out = vec![0u8; width * 4 * height];
    for y in 0..height {
        let src = (if y_invert { height - 1 - y } else { y }) * stride;
        for x in 0..width {
            let (s, d) = (src + x * bpp, (y * width + x) * 4);
            // A little-endian ARGB8888 pixel is B,G,R,A in memory: cairo's
            // order, so the common case is a copy.
            out[d] = raw[if swap { s + 2 } else { s }];
            out[d + 1] = raw[s + 1];
            out[d + 2] = raw[if swap { s } else { s + 2 }];
            // A screenshot is opaque: the X formats carry no alpha, and a
            // compositor may leave garbage in the A formats' byte.
            out[d + 3] = 0xFF;
        }
    }
    Some(out)
}

#[derive(Default)]
struct Session {
    buffer: Option<(u32, u32, u32, u32)>,
    buffer_done: bool,
    y_invert: bool,
    ready: bool,
    failure: Option<String>,
}

impl Session {
    fn settled(&self) -> bool {
        self.ready || self.failure.is_some()
    }
}

/// Dispatch until `done` or the deadline: `run`'s prepare_read discipline,
/// a successful prepare always resolved, bounded, and without the caller's
/// run loop. False on the deadline or a dead connection.
pub(crate) fn pump(conn: &Connection, done: impl Fn() -> bool, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while !done() {
        while conn.prepare_read() != 0 {
            if conn.dispatch_pending() < 0 {
                return false;
            }
            if done() {
                return true;
            }
        }
        conn.flush();
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            conn.cancel_read();
            return false;
        }
        let mut p = [poll_fd(conn.fd(), libc::POLLIN)];
        let n = poll(&mut p, left.as_millis().min(i32::MAX as u128) as i32).unwrap_or(0);
        if n > 0 && p[0].revents & libc::POLLIN != 0 {
            if conn.read_events() < 0 || conn.dispatch_pending() < 0 {
                return false;
            }
        } else {
            conn.cancel_read();
            if n == 0 {
                return false;
            }
        }
    }
    true
}

impl Display {
    pub fn can_capture_screen(&self) -> bool {
        self.globals.borrow().screencopy.is_some()
    }

    /// Capture output `index` (registry order), blocking until the copy is
    /// done or `timeout` passes. `overlay_cursor` draws the pointer in; a
    /// portal screenshot leaves it out.
    pub fn capture_output(self: &Rc<Self>, index: usize, overlay_cursor: bool, timeout: Duration) -> Result<ScreenCapture, ScreencopyError> {
        let (manager, version) = self.globals.borrow().screencopy.ok_or(ScreencopyError::Unsupported)?;
        let output = self.output(index).ok_or(ScreencopyError::NoOutput(index))?;
        let f = zwlr_screencopy_manager_v1::capture_output(manager, overlay_cursor as i32, output).ok_or_else(|| ScreencopyError::Failed("the compositor refused to open a frame".into()))?;
        // The frame is per request: destroyed on every way out, which drops
        // its closure too.
        struct Frame(abyss_sys::wlc::Obj);
        impl Drop for Frame {
            fn drop(&mut self) {
                frame::destroy(self.0)
            }
        }
        let _f = Frame(f);
        let s = Rc::new(RefCell::new(Session::default()));
        let w = s.clone();
        frame::listen(f, move |e| {
            let mut s = w.borrow_mut();
            match e {
                frame::Event::Buffer { format, width, height, stride } => s.buffer = Some((format, width, height, stride)),
                frame::Event::BufferDone {} => s.buffer_done = true,
                frame::Event::Flags { flags } => s.y_invert = flags & frame::FLAGS_Y_INVERT != 0,
                frame::Event::Ready { .. } => s.ready = true,
                frame::Event::Failed {} => s.failure = Some("the compositor could not copy that output".into()),
                _ => {}
            }
        });
        // 1. Which buffer to make. Below v3 there is no buffer_done, and the
        //    wl_shm `buffer` event is itself the signal.
        let described = || {
            let s = s.borrow();
            s.settled() || if version >= 3 { s.buffer_done } else { s.buffer.is_some() }
        };
        if !pump(&self.conn, described, timeout) {
            return Err(ScreencopyError::TimedOut);
        }
        if let Some(why) = s.borrow().failure.clone() {
            return Err(ScreencopyError::Failed(why));
        }
        let (format, width, height, stride) = s.borrow().buffer.ok_or_else(|| ScreencopyError::Failed("the compositor offered no wl_shm buffer".into()))?;
        if format_layout(format).is_none() {
            return Err(ScreencopyError::UnsupportedFormat(format));
        }
        // 2. Exactly the buffer it asked for.
        let buffer = ShmBuffer::new(self, width as i32, height as i32, Some(stride as i32), format).ok_or_else(|| ScreencopyError::Failed("could not allocate the capture buffer".into()))?;
        frame::copy(f, buffer.buffer);
        // 3. The copy.
        if !pump(&self.conn, || s.borrow().settled(), timeout) {
            return Err(ScreencopyError::TimedOut);
        }
        if let Some(why) = s.borrow().failure.clone() {
            return Err(ScreencopyError::Failed(why));
        }
        let y_invert = s.borrow().y_invert;
        let mem = buffer.memory.borrow();
        let pixels = normalise(mem.bytes(), format, width as usize, height as usize, stride as usize, y_invert).ok_or(ScreencopyError::UnsupportedFormat(format))?;
        Ok(ScreenCapture { width: width as usize, height: height as usize, pixels })
    }
}

#[cfg(test)]
mod tests {
    use super::normalise;

    /// The compositor's stride is its own: read as packed, every row slides
    /// a little further left than the last.
    #[test]
    fn captured_rows_honour_the_compositors_stride() {
        let (w, h, stride) = (2, 2, 12);
        let mut raw = vec![0xEE; stride * h];
        raw[0..8].copy_from_slice(&[10, 11, 12, 0, 20, 21, 22, 0]);
        raw[12..20].copy_from_slice(&[30, 31, 32, 0, 40, 41, 42, 0]);
        let out = normalise(&raw, 1, w, h, stride, false).expect("a padded stride normalises");
        assert_eq!(out.len(), w * h * 4);
        assert_eq!(out[0..3], [10, 11, 12]);
        assert_eq!(out[4..7], [20, 21, 22]);
        assert_eq!(out[8..11], [30, 31, 32]);
        assert_eq!(out[12..15], [40, 41, 42]);
    }

    /// y_invert: the bottom row came first. Ignored, it is a valid,
    /// upside-down screenshot.
    #[test]
    fn y_invert_flips_rows_back_the_right_way_up() {
        let raw = [1, 1, 1, 0, 2, 2, 2, 0, 3, 3, 3, 0];
        let up = normalise(&raw, 1, 1, 3, 4, false).unwrap();
        let flipped = normalise(&raw, 1, 1, 3, 4, true).unwrap();
        assert_eq!([up[0], up[4], up[8]], [1, 2, 3]);
        assert_eq!([flipped[0], flipped[4], flipped[8]], [3, 2, 1]);
    }

    #[test]
    fn bgr_formats_swap_red_and_blue() {
        let pixel = [0x10, 0x20, 0x30, 0];
        assert_eq!(normalise(&pixel, 1, 1, 1, 4, false).unwrap()[0..3], [0x10, 0x20, 0x30]);
        assert_eq!(normalise(&pixel, 0x3432_4258, 1, 1, 4, false).unwrap()[0..3], [0x30, 0x20, 0x10]);
    }

    /// What a GPU renderer offers (U.3): both 24-bit orders, padded.
    #[test]
    fn twenty_four_bit_formats_are_read() {
        let raw = [0x30, 0x20, 0x10, 0x31, 0x21, 0x11, 0xEE, 0xEE];
        assert_eq!(normalise(&raw, 0x3432_4742, 2, 1, 8, false).unwrap(), [0x10, 0x20, 0x30, 0xFF, 0x11, 0x21, 0x31, 0xFF]);
        assert_eq!(normalise(&raw, 0x3432_4752, 2, 1, 8, false).unwrap(), [0x30, 0x20, 0x10, 0xFF, 0x31, 0x21, 0x11, 0xFF]);
        assert!(normalise(&raw, 0x3432_4742, 3, 1, 8, false).is_none(), "a stride too short for three 3-byte pixels");
    }

    #[test]
    fn captured_pixels_are_forced_opaque() {
        assert_eq!(normalise(&[1, 2, 3, 0], 1, 1, 1, 4, false).unwrap()[3], 0xFF);
    }

    /// A short buffer, a stride that cannot hold a row, a format not read:
    /// each would be a read past a shared mapping or a wrong image.
    #[test]
    fn capture_normalisation_refuses_what_it_cannot_read() {
        let ok = [0u8; 16];
        assert!(normalise(&ok, 0, 2, 2, 8, false).is_some());
        assert!(normalise(&ok[0..12], 0, 2, 2, 8, false).is_none());
        assert!(normalise(&ok, 0, 4, 2, 8, false).is_none());
        assert!(normalise(&ok, 0x3231_3457, 2, 2, 8, false).is_none());
        assert!(normalise(&ok, 0, 0, 2, 8, false).is_none());
    }
}
