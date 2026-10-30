//! TextModel in Rust (RUST.md R2): the model under the toolkit's text view
//! (PHASE15 P15.5), ported from TextModel.swift and TextLayout.swift beside
//! it, and the grapheme clusters Swift's `Character` gave it for free,
//! from the Unicode Character Database (gen-graphemes.py).

pub mod grapheme;
mod grapheme_tables;
mod layout;
mod model;

pub use layout::{TextLayout, VisualRow};
pub use model::{EditKind, Line, Motion, TextEdit, TextModel, TextPosition, TextRange, UndoHistory};

#[cfg(test)]
mod tests;
