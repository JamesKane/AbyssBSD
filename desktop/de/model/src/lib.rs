//! Model in Rust (RUST.md): the one wire to a model (PHASE18 P18.7), ported
//! from the Swift beside it. Its JSON (R2's), HTTP over a unix socket, TCP
//! or TLS, the session that holds the budget and writes the transcript, the
//! backends (canned replies, a server, llama-server run here), and reading a
//! transcript back for a person.

pub mod http;
pub mod json;
pub mod local;
pub mod session;
pub mod transcript;

pub use http::{Endpoint, Failure, Request, Response, WebUrl};
pub use json::{Json, ParseError};
pub use session::{open_transcript, Backend, HttpBackend, ModelSession, StubBackend, Tier};

#[cfg(test)]
mod tests;
