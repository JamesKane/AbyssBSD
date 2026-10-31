//! Surface: the toolkit's Wayland client (RUST.md R5d). The connection and
//! its globals, the seat's input routed to the surface it names, and the
//! surfaces themselves: toplevel windows, popups and layer surfaces.
//!
//! The protocol is abyss-sys's generated `wlc`: a module per interface,
//! events to a closure, no `unsafe` here.

mod activation;
mod backing;
pub mod clipboard;
pub mod display;
pub mod display_config;
pub mod idle;
pub mod keyboard;
pub mod layer;
pub mod lock;
pub mod menubar_focus;
pub mod popup;
pub mod screencopy;
pub mod toplevels;
pub mod window;

pub use backing::RenderTarget;
pub use clipboard::Clipboard;
pub use display::Display;
pub use idle::IdleNotification;
pub use keyboard::{KeyEvent, KeyModifiers, KeySym};
pub use menubar_focus::MenuBarFocus;
pub use lock::{LockSurface, SessionLock, SessionLockDelegate};
pub use layer::{LayerConfig, LayerSurface, LayerSurfaceDelegate};
pub use popup::{Popup, PopupDelegate};
pub use screencopy::{ScreenCapture, ScreencopyError};
pub use toplevels::{ForeignToplevels, ToplevelInfo};
pub use window::{ResizeEdge, Window, WindowDelegate};
