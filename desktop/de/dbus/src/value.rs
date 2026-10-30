//! The type system and the signature grammar (Value.swift).
//!
//! **Everything is aligned to its own natural boundary, from the start of
//! the message**, not of whatever buffer is being filled: the rule where
//! hand-written D-Bus goes wrong, and why the marshallers carry an origin.

use crate::Error;
use std::os::fd::RawFd;

/// A D-Bus value: only the types the portal API and the bridge use, every
/// one with a caller.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Byte(u8),          // y
    Bool(bool),        // b
    UInt16(u16),       // q
    Int32(i32),        // i
    UInt32(u32),       // u
    UInt64(u64),       // t
    /// IEEE 754, for `org.freedesktop.appearance`'s `(ddd)` accent colour.
    Double(f64),       // d
    String(String),    // s
    ObjectPath(String), // o
    Signature(String), // g
    /// A descriptor. On the wire, a *32-bit index* into the message's
    /// descriptors, which travel out of band over SCM_RIGHTS.
    UnixFd(RawFd),     // h
    /// `a<sig>`: the element signature, and the items.
    Array(String, Vec<Value>),
    Struct(Vec<Value>),
    Variant(Box<Value>),
    DictEntry(Box<Value>, Box<Value>),
}

impl Value {
    /// The signature of this value, as the wire spells it.
    pub fn signature(&self) -> String {
        match self {
            Value::Byte(_) => "y".into(),
            Value::Bool(_) => "b".into(),
            Value::UInt16(_) => "q".into(),
            Value::Int32(_) => "i".into(),
            Value::UInt32(_) => "u".into(),
            Value::UInt64(_) => "t".into(),
            Value::Double(_) => "d".into(),
            Value::String(_) => "s".into(),
            Value::ObjectPath(_) => "o".into(),
            Value::Signature(_) => "g".into(),
            Value::UnixFd(_) => "h".into(),
            Value::Array(elem, _) => format!("a{elem}"),
            Value::Struct(items) => format!("({})", items.iter().map(Value::signature).collect::<String>()),
            Value::Variant(_) => "v".into(),
            Value::DictEntry(k, v) => format!("{{{}{}}}", k.signature(), v.signature()),
        }
    }

    /// Alignment of this type's *start*, in bytes.
    pub fn alignment(&self) -> usize {
        match self {
            Value::Byte(_) | Value::Signature(_) | Value::Variant(_) => 1,
            Value::UInt16(_) => 2,
            Value::Bool(_) | Value::Int32(_) | Value::UInt32(_) | Value::String(_) | Value::ObjectPath(_) | Value::UnixFd(_) | Value::Array(..) => 4,
            Value::UInt64(_) | Value::Double(_) | Value::Struct(_) | Value::DictEntry(..) => 8,
        }
    }

    /// The `a{sv}` every portal method takes as its options.
    pub fn options(pairs: Vec<(&str, Value)>) -> Value {
        Value::Array(
            "{sv}".into(),
            pairs.into_iter().map(|(k, v)| Value::DictEntry(Box::new(Value::String(k.into())), Box::new(Value::Variant(Box::new(v))))).collect(),
        )
    }
}

/// Alignment for a type named by its signature, needed when *reading*,
/// where the value's type is not yet known.
pub fn alignment_of(sig: &str) -> usize {
    match sig.as_bytes().first() {
        Some(b'q' | b'n') => 2,
        Some(b'b' | b'i' | b'u' | b's' | b'o' | b'h' | b'a') => 4,
        Some(b'x' | b't' | b'd' | b'(' | b'{') => 8,
        _ => 1,
    }
}

/// Split a signature into its top-level complete types: `"sa{sv}u"` is
/// `["s", "a{sv}", "u"]`. **Refused when it is not a signature**: an array
/// with no element, a struct with no fields or no end, a dict entry that is
/// not two types. Swift splits whatever it is given, and an array of `()`
/// then loops for ever reading nothing.
pub fn split_signature(sig: &str) -> Result<Vec<&str>, Error> {
    let mut out = vec![];
    let mut i = 0;
    while i < sig.len() {
        let end = complete_type(sig.as_bytes(), i)?;
        out.push(&sig[i..end]);
        i = end;
    }
    Ok(out)
}

/// The end of the complete type starting at `i`.
fn complete_type(s: &[u8], i: usize) -> Result<usize, Error> {
    match s[i] {
        b'a' => {
            if i + 1 >= s.len() {
                return Err(Error::new("array with no element type"));
            }
            complete_type(s, i + 1)
        }
        open @ (b'(' | b'{') => {
            let close = if open == b'(' { b')' } else { b'}' };
            let (mut j, mut n) = (i + 1, 0);
            loop {
                match s.get(j) {
                    None => return Err(Error::new("unbalanced signature")),
                    Some(&c) if c == close => break,
                    Some(_) => {
                        j = complete_type(s, j)?;
                        n += 1;
                    }
                }
            }
            match (open, n) {
                (b'(', 0) => Err(Error::new("a struct with no fields")),
                (b'{', n) if n != 2 => Err(Error::new("dict entry needs exactly two types")),
                _ => Ok(j + 1),
            }
        }
        b')' | b'}' => Err(Error::new("unbalanced signature")),
        // Not every character is a type, which reading says.
        _ => Ok(i + char_len(s, i)),
    }
}

/// The length of the UTF-8 character starting at `i`: a signature from the
/// wire is any text until it is read.
fn char_len(s: &[u8], i: usize) -> usize {
    match s[i] {
        0xf0.. => 4,
        0xe0.. => 3,
        0xc0.. => 2,
        _ => 1,
    }
}
