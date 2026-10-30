//! CurrentIPC in Rust (RUST.md R2): ADE's control plane, ported from
//! Msg.swift and Current.swift beside it. The same bytes on the wire, so a
//! Swift and a Rust component talk to each other (the fixtures in
//! abyss/tests/wire/current hold both to that).

mod msg;
mod transport;

pub use msg::{Error, Msg, Value};
pub use transport::{call, connect, connect_path, receive, runtime_dir, send, socket_path, Server};
