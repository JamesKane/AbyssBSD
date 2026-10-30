//! DBus in Rust (RUST.md R2), the wire half: the type system, the
//! marshalling rules and the message (PHASE8 P8.1), ported from Value.swift,
//! Marshal.swift and Message.swift beside it, and the bus address from
//! Connection.swift. The connection itself, SASL and dispatch, is R3.
//!
//! **No library**: not libdbus, not GDBus (GLib), not sd-bus (systemd).
//! And no bus: ADE's bridge answers for its own services and nothing else
//! (PRODUCT §5.6). This is the format both ends of it speak.

mod marshal;
mod message;
mod value;

pub use marshal::{Marshaller, Unmarshaller, MAX_DEPTH};
pub use message::{Flags, Message, MessageType};
pub use value::{alignment_of, split_signature, Value};

use std::fmt;

/// Why bytes are not a message, or a value cannot be one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error(pub String);

impl Error {
    pub fn new(m: impl Into<String>) -> Error {
        Error(m.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

/// A bus address of the form `unix:path=…` or `unix:abstract=…`, with
/// perhaps more `key=value` pairs after a comma: the socket, and whether it
/// is in the abstract namespace. Abstract first, as the more specific.
pub fn parse_address(address: &str) -> Option<(String, bool)> {
    let after = |needle: &str| address.find(needle).map(|i| &address[i + needle.len()..]);
    let (rest, abstract_) = match after("unix:abstract=") {
        Some(r) => (r, true),
        None => (after("unix:path=")?, false),
    };
    Some((rest.split(',').next().unwrap_or("").to_owned(), abstract_))
}

#[cfg(test)]
mod tests;
