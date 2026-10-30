//! ADE's D-Bus bridge in Rust (RUST.md R3; BACKLOG D.1, PRODUCT §5.6),
//! ported from Router.swift and Endpoint.swift beside it: the router, which
//! decides and is pure, and the endpoint, which owns the sockets.

mod endpoint;
mod router;

pub use endpoint::{Endpoint, MAX_MESSAGE};
pub use router::{Action, MatchRule, Peer, PeerKind, Router};

#[cfg(test)]
mod tests;
