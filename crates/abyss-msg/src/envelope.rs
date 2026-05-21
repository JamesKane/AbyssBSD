//! The cross-process envelope (`docs/design/wire-format.md` §3.3).

use crate::cursor::Decoder;
use crate::error::WireError;
use crate::value::Value;

/// The wire-format version this build speaks.
pub const WIRE_VERSION: u8 = 1;

/// Fixed envelope header size, in bytes (§3.3).
const HEADER_LEN: usize = 16;

/// The kind of a message (`interfaces/README.md`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageKind {
    Request = 1,
    Command = 2,
    Event = 3,
}

impl MessageKind {
    fn from_byte(byte: u8) -> Result<Self, WireError> {
        match byte {
            1 => Ok(MessageKind::Request),
            2 => Ok(MessageKind::Command),
            3 => Ok(MessageKind::Event),
            other => Err(WireError::BadKind(other)),
        }
    }
}

/// The semantic fields of an envelope header. `version` and `flags` are
/// format-level constants the codec handles; they are not carried here, so
/// they cannot drift out of sync.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub kind: MessageKind,
    pub interface_id: u32,
    pub method_id: u16,
}

/// One handle-table entry. Opaque to `abyss-msg` (§3.4): this crate frames
/// `kind` + `body` but does not interpret them — capability meaning is
/// `abyss-cap`'s (Phase 2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawHandle {
    pub kind: u8,
    pub body: Vec<u8>,
}

/// A complete envelope: header, payload value, and handle table.
#[derive(Debug, Clone, PartialEq)]
pub struct Envelope {
    pub header: Header,
    pub payload: Value,
    pub handles: Vec<RawHandle>,
}

impl Envelope {
    /// Encode to bytes (§3.3).
    pub fn encode(&self) -> Vec<u8> {
        let payload = self.payload.encode();
        let handle_count =
            u16::try_from(self.handles.len()).expect("envelope exceeds 65535 handles");
        let payload_len = u32::try_from(payload.len()).expect("payload exceeds 4 GiB");

        let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
        out.push(WIRE_VERSION);
        out.push(self.header.kind as u8);
        out.extend_from_slice(&0u16.to_le_bytes()); // flags — reserved, zero
        out.extend_from_slice(&self.header.interface_id.to_le_bytes());
        out.extend_from_slice(&self.header.method_id.to_le_bytes());
        out.extend_from_slice(&handle_count.to_le_bytes());
        out.extend_from_slice(&payload_len.to_le_bytes());
        out.extend_from_slice(&payload);
        for handle in &self.handles {
            out.push(handle.kind);
            let body_len = u32::try_from(handle.body.len()).expect("handle body exceeds 4 GiB");
            out.extend_from_slice(&body_len.to_le_bytes());
            out.extend_from_slice(&handle.body);
        }
        out
    }

    /// Decode an envelope. Total — never panics on malformed input (§4).
    pub fn decode(bytes: &[u8]) -> Result<Envelope, WireError> {
        let mut d = Decoder::new(bytes);

        let version = d.u8()?;
        if version != WIRE_VERSION {
            return Err(WireError::BadVersion(version));
        }
        let kind = MessageKind::from_byte(d.u8()?)?;
        let flags = d.u16()?;
        if flags != 0 {
            return Err(WireError::BadFlags(flags));
        }
        let interface_id = d.u32()?;
        let method_id = d.u16()?;
        let handle_count = d.u16()?;
        let payload_len = d.u32()? as usize;

        let payload = Value::decode(d.take(payload_len)?)?;

        let mut handles = Vec::new();
        for _ in 0..handle_count {
            let kind = d.u8()?;
            let body = d.blob()?.to_vec();
            handles.push(RawHandle { kind, body });
        }
        if !d.at_end() {
            return Err(WireError::TrailingBytes);
        }
        check_handle_indices(&payload, handle_count)?;

        Ok(Envelope {
            header: Header {
                kind,
                interface_id,
                method_id,
            },
            payload,
            handles,
        })
    }
}

/// Every `Value::Handle` in the payload must name a real handle-table
/// entry (§4). The payload tree is already depth-bounded by `Value::decode`,
/// so this recursion is bounded too.
fn check_handle_indices(value: &Value, count: u16) -> Result<(), WireError> {
    match value {
        Value::Handle(index) if u32::from(count) <= *index => Err(WireError::BadHandleIndex {
            index: *index,
            count,
        }),
        Value::List(items) => {
            for item in items {
                check_handle_indices(item, count)?;
            }
            Ok(())
        }
        Value::Dict(entries) => {
            for (_, item) in entries {
                check_handle_indices(item, count)?;
            }
            Ok(())
        }
        Value::Variant {
            value: Some(inner), ..
        } => check_handle_indices(inner, count),
        _ => Ok(()),
    }
}
