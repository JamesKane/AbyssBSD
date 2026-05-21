//! The self-describing value vocabulary (`docs/design/wire-format.md` §2)
//! and its byte codec (§3.2).

use crate::cursor::Decoder;
use crate::error::WireError;

/// Maximum value nesting depth the decoder accepts (§4). A hostile payload
/// must not be able to exhaust the stack.
pub const MAX_DEPTH: u32 = 64;

const TAG_BOOL: u8 = 0x01;
const TAG_INT: u8 = 0x02;
const TAG_FLOAT: u8 = 0x03;
const TAG_STR: u8 = 0x04;
const TAG_BYTES: u8 = 0x05;
const TAG_LIST: u8 = 0x06;
const TAG_DICT: u8 = 0x07;
const TAG_VARIANT: u8 = 0x08;
const TAG_HANDLE: u8 = 0x09;

/// A self-describing value — one of the nine kinds of §2.
///
/// `PartialEq` but not `Eq`: `Float` holds an `f64`. Equality of two
/// values therefore follows IEEE-754 (`NaN != NaN`).
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Bytes(Vec<u8>),
    List(Vec<Value>),
    /// An ordered map; names are unique (the decoder rejects duplicates).
    Dict(Vec<(String, Value)>),
    /// A tagged union — the wire form of a Rust `enum`.
    Variant {
        tag: String,
        value: Option<Box<Value>>,
    },
    /// An index into the envelope handle table (§3.4).
    Handle(u32),
}

impl Value {
    /// The kind name, for diagnostics and `TypeMismatch` errors.
    pub fn kind_name(&self) -> &'static str {
        match self {
            Value::Bool(_) => "bool",
            Value::Int(_) => "int",
            Value::Float(_) => "float",
            Value::Str(_) => "string",
            Value::Bytes(_) => "bytes",
            Value::List(_) => "list",
            Value::Dict(_) => "dict",
            Value::Variant { .. } => "variant",
            Value::Handle(_) => "handle",
        }
    }

    /// Encode to bytes (§3.2). Infallible for any value whose every
    /// section fits 4 GiB — exceeding that is a defect and panics.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.encode_into(&mut out);
        out
    }

    fn encode_into(&self, out: &mut Vec<u8>) {
        match self {
            Value::Bool(b) => {
                out.push(TAG_BOOL);
                out.push(u8::from(*b));
            }
            Value::Int(i) => {
                out.push(TAG_INT);
                out.extend_from_slice(&i.to_le_bytes());
            }
            Value::Float(x) => {
                out.push(TAG_FLOAT);
                out.extend_from_slice(&x.to_le_bytes());
            }
            Value::Str(s) => {
                out.push(TAG_STR);
                write_blob(out, s.as_bytes());
            }
            Value::Bytes(b) => {
                out.push(TAG_BYTES);
                write_blob(out, b);
            }
            Value::List(items) => {
                out.push(TAG_LIST);
                write_len(out, items.len());
                for item in items {
                    item.encode_into(out);
                }
            }
            Value::Dict(entries) => {
                out.push(TAG_DICT);
                write_len(out, entries.len());
                for (name, value) in entries {
                    write_blob(out, name.as_bytes());
                    value.encode_into(out);
                }
            }
            Value::Variant { tag, value } => {
                out.push(TAG_VARIANT);
                write_blob(out, tag.as_bytes());
                match value {
                    Some(inner) => {
                        out.push(1);
                        inner.encode_into(out);
                    }
                    None => out.push(0),
                }
            }
            Value::Handle(index) => {
                out.push(TAG_HANDLE);
                out.extend_from_slice(&index.to_le_bytes());
            }
        }
    }

    /// Decode exactly one value from `bytes`. Total — never panics on
    /// malformed input (§4) — and rejects any trailing bytes.
    pub fn decode(bytes: &[u8]) -> Result<Value, WireError> {
        let mut decoder = Decoder::new(bytes);
        let value = decode_value(&mut decoder, 0)?;
        if decoder.at_end() {
            Ok(value)
        } else {
            Err(WireError::TrailingBytes)
        }
    }
}

fn write_len(out: &mut Vec<u8>, n: usize) {
    let n = u32::try_from(n).expect("wire section length exceeds 4 GiB");
    out.extend_from_slice(&n.to_le_bytes());
}

fn write_blob(out: &mut Vec<u8>, bytes: &[u8]) {
    write_len(out, bytes.len());
    out.extend_from_slice(bytes);
}

/// Decode one value at nesting `depth`. Counts are never used to
/// pre-allocate — elements are decoded one at a time, so a hostile count
/// runs the input out rather than the heap (§4).
fn decode_value(d: &mut Decoder<'_>, depth: u32) -> Result<Value, WireError> {
    if depth > MAX_DEPTH {
        return Err(WireError::DepthExceeded);
    }
    let tag = d.u8()?;
    Ok(match tag {
        TAG_BOOL => Value::Bool(d.bool_byte()?),
        TAG_INT => Value::Int(d.i64()?),
        TAG_FLOAT => Value::Float(d.f64()?),
        TAG_STR => Value::Str(d.string()?),
        TAG_BYTES => Value::Bytes(d.blob()?.to_vec()),
        TAG_LIST => {
            let count = d.u32()?;
            let mut items = Vec::new();
            for _ in 0..count {
                items.push(decode_value(d, depth + 1)?);
            }
            Value::List(items)
        }
        TAG_DICT => {
            let count = d.u32()?;
            let mut entries = Vec::new();
            let mut seen = std::collections::HashSet::new();
            for _ in 0..count {
                let name = d.string()?;
                if !seen.insert(name.clone()) {
                    return Err(WireError::DuplicateKey(name));
                }
                let value = decode_value(d, depth + 1)?;
                entries.push((name, value));
            }
            Value::Dict(entries)
        }
        TAG_VARIANT => {
            let tag = d.string()?;
            let value = if d.bool_byte()? {
                Some(Box::new(decode_value(d, depth + 1)?))
            } else {
                None
            };
            Value::Variant { tag, value }
        }
        TAG_HANDLE => Value::Handle(d.u32()?),
        other => return Err(WireError::BadTag(other)),
    })
}
