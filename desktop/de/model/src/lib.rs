//! Model in Rust (RUST.md): the one wire to a model (PHASE18 P18.7). So far
//! its JSON (JSON.swift), which is a wire format and pure, so R2's, and what
//! the vocabulary bridge writes its transcript lines in. HTTP, the session's
//! budget and transcript, and the backends come with `abyss-model` in R3.

pub mod json;

pub use json::{Json, ParseError};
