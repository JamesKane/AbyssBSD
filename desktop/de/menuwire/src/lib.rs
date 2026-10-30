//! MenuWire in Rust (RUST.md R2): an application's vocabulary on the control
//! plane (PHASE10.md P10.2), ported from the Swift beside it. The same
//! messages, so a Swift application answers a Rust menu bar and the other
//! way about (the fixtures in abyss/tests/wire/menu hold both to that).

pub mod client;
mod service;
mod wire;

pub use service::{MenuProvider, MenuService};
pub use wire::{
    activate_request, arguments, decode_describe, decode_result, decode_validate, describe_reply, error_reply,
    result_reply, service_name, validate_reply, Described, SERVICE_PREFIX,
};

#[doc(hidden)]
pub mod fixtures {
    //! For tests/wire_fixtures.rs: re-encoding what was decoded, and the
    //! key names.
    pub use crate::wire::{describe_reply_with, key_name, key_named};
}

use std::fmt;

/// MenuWireError, and the control plane's own errors beneath it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The connection, or bytes that are not the vocabulary.
    Ipc(current_ipc::Error),
    /// The service answered, and said no.
    Service(String),
    NoSuchApplication(String),
    /// The name typed, and every live service it matches.
    Ambiguous(String, Vec<String>),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Ipc(e) => e.fmt(f),
            Error::Service(why) => f.write_str(why),
            Error::NoSuchApplication(name) => write!(f, "no application called {name} is publishing menus"),
            Error::Ambiguous(name, all) => write!(f, "{name} matches {} services: {}", all.len(), all.join(", ")),
        }
    }
}

impl std::error::Error for Error {}

impl From<current_ipc::Error> for Error {
    fn from(e: current_ipc::Error) -> Error {
        Error::Ipc(e)
    }
}
