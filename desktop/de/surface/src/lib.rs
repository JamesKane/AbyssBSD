//! Surface: the toolkit's Wayland client (RUST.md R5d). The connection and
//! its globals, the seat's input routed to the surface it names, and the
//! surfaces themselves: toplevel windows, popups and layer surfaces.
//!
//! The protocol is abyss-sys's generated `wlc`: a module per interface,
//! events to a closure, no `unsafe` here.

mod backing;
pub mod display;
pub mod keyboard;
pub mod layer;
pub mod popup;
pub mod window;

pub use backing::RenderTarget;
pub use display::Display;
pub use keyboard::{KeyEvent, KeyModifiers, KeySym};
pub use layer::{LayerConfig, LayerSurface, LayerSurfaceDelegate};
pub use popup::{Popup, PopupDelegate};
pub use window::{ResizeEdge, Window, WindowDelegate};
