// SPDX-License-Identifier: BSD-2-Clause

//! Decode and typed-conversion errors.

use std::fmt;

/// Every way decoding bytes or converting a [`Value`](crate::Value) to a
/// typed view can fail.
///
/// Decoding untrusted input is *total*: it yields one of these, never a
/// panic (`docs/design/wire-format.md` §4).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireError {
    // --- byte layer (bytes → Value / Envelope) ---
    /// A length or count ran past the end of the input.
    Truncated,
    /// An unknown value type tag (§3.2).
    BadTag(u8),
    /// A `bool` or variant-presence byte that was neither `0x00` nor `0x01`.
    BadBool(u8),
    /// A string, dict name, or variant tag that was not valid UTF-8.
    BadUtf8,
    /// An envelope `version` this build does not speak.
    BadVersion(u8),
    /// A nonzero `flags` field — reserved, must be zero in v1.
    BadFlags(u16),
    /// An envelope `kind` byte that was not 1, 2, or 3.
    BadKind(u8),
    /// Value nesting deeper than [`MAX_DEPTH`](crate::MAX_DEPTH) (§4).
    DepthExceeded,
    /// A `dict` carried the same name twice.
    DuplicateKey(String),
    /// A `Value::Handle` index with no matching handle-table entry.
    BadHandleIndex { index: u32, count: u16 },
    /// Bytes left over after a complete value or envelope.
    TrailingBytes,

    // --- typed layer (Value → T) ---
    /// A typed field held the wrong value kind.
    TypeMismatch {
        expected: &'static str,
        found: &'static str,
    },
    /// A required (non-`Option`) field was absent from a `dict`.
    MissingField(&'static str),
    /// An `enum`'s variant tag matched no known variant.
    UnknownVariant(String),
    /// An integer did not fit the narrower target type.
    IntOutOfRange { value: i64, target: &'static str },
    /// A handle was already moved out of the store.
    HandleTaken(u32),
    /// The received handle table and the `SCM_RIGHTS` fd count disagree —
    /// every handle is an fd capability, so the two must correspond
    /// (`broker-and-transport.md` §2.2, §3.2).
    HandleFdMismatch { handles: usize, fds: usize },
}

impl fmt::Display for WireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WireError::Truncated => write!(f, "input ended mid-value"),
            WireError::BadTag(t) => write!(f, "unknown value tag {t:#04x}"),
            WireError::BadBool(b) => write!(f, "bad boolean byte {b:#04x}"),
            WireError::BadUtf8 => write!(f, "string was not valid UTF-8"),
            WireError::BadVersion(v) => write!(f, "unsupported wire version {v}"),
            WireError::BadFlags(x) => write!(f, "reserved flags must be zero, got {x:#06x}"),
            WireError::BadKind(k) => write!(f, "unknown message kind {k}"),
            WireError::DepthExceeded => {
                write!(f, "value nested deeper than {}", crate::MAX_DEPTH)
            }
            WireError::DuplicateKey(k) => write!(f, "duplicate dict key {k:?}"),
            WireError::BadHandleIndex { index, count } => {
                write!(f, "handle index {index} out of range (count {count})")
            }
            WireError::TrailingBytes => write!(f, "unexpected trailing bytes"),
            WireError::TypeMismatch { expected, found } => {
                write!(f, "expected {expected}, found {found}")
            }
            WireError::MissingField(name) => write!(f, "missing required field {name:?}"),
            WireError::UnknownVariant(tag) => write!(f, "unknown variant {tag:?}"),
            WireError::IntOutOfRange { value, target } => {
                write!(f, "integer {value} out of range for {target}")
            }
            WireError::HandleTaken(i) => write!(f, "handle {i} already taken"),
            WireError::HandleFdMismatch { handles, fds } => write!(
                f,
                "handle table has {handles} entries but {fds} descriptors arrived"
            ),
        }
    }
}

impl std::error::Error for WireError {}
