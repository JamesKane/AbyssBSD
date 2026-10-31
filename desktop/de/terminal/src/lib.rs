//! Terminal (PHASE15 P15.4): what a terminal does with a program's bytes,
//! with no pty and no display, so "vi draws correctly" is an assertion on
//! `Screen::lines`.
//!
//! - [`parser`]: bytes into actions, Paul Williams' VT500 state machine.
//! - [`screen`]: the grid, the cursor, the modes and the alternate screen.
//! - [`selection`]: text across scrollback, for Copy; and what Paste sends.
//! - [`keys`]: a key press into what xterm sends.

pub mod keys;
pub mod parser;
pub mod screen;
pub mod selection;

pub use keys::{encode, KeyMods};
pub use parser::{VtAction, VtParser};
pub use screen::{Cell, CellAttributes, Screen, TermColor};
pub use selection::{paste_bytes, TextPoint};

#[cfg(test)]
mod tests;
