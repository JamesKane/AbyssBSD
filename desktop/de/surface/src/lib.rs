//! Surface: the toolkit's Wayland client (RUST.md R5d). The connection and
//! its globals, the seat's input routed to the surface it names, and the
//! surfaces themselves: toplevel windows first.
//!
//! The protocol is abyss-sys's generated `wlc`: a module per interface,
//! events to a closure, no `unsafe` here.

pub mod display;
pub mod keyboard;
pub mod window;

pub use display::Display;
pub use keyboard::{KeyEvent, KeyModifiers, KeySym};
pub use window::{RenderTarget, ResizeEdge, Window, WindowDelegate};
