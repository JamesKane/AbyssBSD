// SPDX-License-Identifier: BSD-2-Clause

//! The [`Wire`] trait — typed views over [`Value`] — and the handle
//! sink/store that thread capabilities through the §3.4 payload/handle
//! split (`docs/design/wire-format.md` §6).

use std::os::fd::OwnedFd;

use crate::envelope::{Envelope, Header, RawHandle};
use crate::error::WireError;
use crate::value::Value;

/// A type that may cross the bus: convertible to and from a [`Value`].
///
/// Encoding threads a [`HandleSink`] so capability fields land in the
/// handle table; decoding threads a [`HandleStore`] they are moved out of.
/// Plain data types ignore both.
pub trait Wire: Sized {
    /// Encode into a value, pushing any capability into `handles`.
    fn to_wire(&self, handles: &mut HandleSink) -> Value;

    /// Decode from a value, moving any capability out of `handles`.
    fn from_wire(value: &Value, handles: &mut HandleStore) -> Result<Self, WireError>;
}

/// Append-only collector for the handle table during encoding — the
/// handle-table metadata, and the fds those handles ride `SCM_RIGHTS` with.
#[derive(Debug, Default)]
pub struct HandleSink {
    handles: Vec<RawHandle>,
    fds: Vec<OwnedFd>,
}

impl HandleSink {
    pub fn new() -> Self {
        Self::default()
    }

    /// Append a capability — its handle-table metadata and the fd that
    /// rides `SCM_RIGHTS` beside it (§2.2). Returns the index a
    /// `Value::Handle` should carry.
    pub fn push(&mut self, handle: RawHandle, fd: OwnedFd) -> u32 {
        let index = u32::try_from(self.handles.len()).expect("more than 4 billion handles");
        self.handles.push(handle);
        self.fds.push(fd);
        index
    }

    pub fn len(&self) -> usize {
        self.handles.len()
    }

    pub fn is_empty(&self) -> bool {
        self.handles.is_empty()
    }

    /// Consume the sink: the handle table to encode into the envelope, and
    /// the fds to hand the transport for `SCM_RIGHTS`.
    pub fn into_parts(self) -> (Vec<RawHandle>, Vec<OwnedFd>) {
        (self.handles, self.fds)
    }
}

/// Owns received capabilities during decoding — each handle's metadata
/// paired with its fd. Each may be taken exactly once — a handle is
/// move-only (`DESIGN.md` §6.10).
#[derive(Debug)]
pub struct HandleStore {
    slots: Vec<Option<(RawHandle, OwnedFd)>>,
}

impl HandleStore {
    /// Build from a received handle table and the `SCM_RIGHTS` fds that
    /// rode beside it; the two correspond by order (§2.2). Every handle is
    /// an fd capability (§3.2), so the counts must match.
    pub fn new(handles: Vec<RawHandle>, fds: Vec<OwnedFd>) -> Result<Self, WireError> {
        if handles.len() != fds.len() {
            return Err(WireError::HandleFdMismatch {
                handles: handles.len(),
                fds: fds.len(),
            });
        }
        Ok(Self {
            slots: handles.into_iter().zip(fds).map(Some).collect(),
        })
    }

    /// Move capability `index` — its metadata and its fd — out of the store.
    pub fn take(&mut self, index: u32) -> Result<(RawHandle, OwnedFd), WireError> {
        let count = u16::try_from(self.slots.len()).unwrap_or(u16::MAX);
        let slot = self
            .slots
            .get_mut(index as usize)
            .ok_or(WireError::BadHandleIndex { index, count })?;
        slot.take().ok_or(WireError::HandleTaken(index))
    }

    pub fn len(&self) -> usize {
        self.slots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }
}

/// A binary blob — the `bytes` value kind. A plain `Vec<u8>` is `Wire` as a
/// `list` of integers; a `bytes` field uses this newtype instead (§6).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Bytes(pub Vec<u8>);

impl Envelope {
    /// Build an envelope from a typed message, returning it with the fds
    /// its capabilities surrendered — for the transport to send over
    /// `SCM_RIGHTS` (§2.2).
    pub fn from_message<M: Wire>(header: Header, message: &M) -> (Envelope, Vec<OwnedFd>) {
        let mut sink = HandleSink::new();
        let payload = message.to_wire(&mut sink);
        let (handles, fds) = sink.into_parts();
        (
            Envelope {
                header,
                payload,
                handles,
            },
            fds,
        )
    }

    /// Decode the typed message carried by this envelope, claiming the fds
    /// the transport received over `SCM_RIGHTS` alongside it.
    pub fn into_message<M: Wire>(self, fds: Vec<OwnedFd>) -> Result<M, WireError> {
        let mut store = HandleStore::new(self.handles, fds)?;
        M::from_wire(&self.payload, &mut store)
    }
}

// --- primitive impls -------------------------------------------------------

impl Wire for bool {
    fn to_wire(&self, _: &mut HandleSink) -> Value {
        Value::Bool(*self)
    }
    fn from_wire(value: &Value, _: &mut HandleStore) -> Result<Self, WireError> {
        match value {
            Value::Bool(b) => Ok(*b),
            other => Err(WireError::TypeMismatch {
                expected: "bool",
                found: other.kind_name(),
            }),
        }
    }
}

impl Wire for i64 {
    fn to_wire(&self, _: &mut HandleSink) -> Value {
        Value::Int(*self)
    }
    fn from_wire(value: &Value, _: &mut HandleStore) -> Result<Self, WireError> {
        match value {
            Value::Int(i) => Ok(*i),
            other => Err(WireError::TypeMismatch {
                expected: "int",
                found: other.kind_name(),
            }),
        }
    }
}

impl Wire for f64 {
    fn to_wire(&self, _: &mut HandleSink) -> Value {
        Value::Float(*self)
    }
    fn from_wire(value: &Value, _: &mut HandleStore) -> Result<Self, WireError> {
        match value {
            Value::Float(x) => Ok(*x),
            other => Err(WireError::TypeMismatch {
                expected: "float",
                found: other.kind_name(),
            }),
        }
    }
}

impl Wire for String {
    fn to_wire(&self, _: &mut HandleSink) -> Value {
        Value::Str(self.clone())
    }
    fn from_wire(value: &Value, _: &mut HandleStore) -> Result<Self, WireError> {
        match value {
            Value::Str(s) => Ok(s.clone()),
            other => Err(WireError::TypeMismatch {
                expected: "string",
                found: other.kind_name(),
            }),
        }
    }
}

impl Wire for Bytes {
    fn to_wire(&self, _: &mut HandleSink) -> Value {
        Value::Bytes(self.0.clone())
    }
    fn from_wire(value: &Value, _: &mut HandleStore) -> Result<Self, WireError> {
        match value {
            Value::Bytes(b) => Ok(Bytes(b.clone())),
            other => Err(WireError::TypeMismatch {
                expected: "bytes",
                found: other.kind_name(),
            }),
        }
    }
}

impl Wire for Value {
    fn to_wire(&self, _: &mut HandleSink) -> Value {
        self.clone()
    }
    fn from_wire(value: &Value, _: &mut HandleStore) -> Result<Self, WireError> {
        Ok(value.clone())
    }
}

impl<T: Wire> Wire for Vec<T> {
    fn to_wire(&self, handles: &mut HandleSink) -> Value {
        Value::List(self.iter().map(|item| item.to_wire(handles)).collect())
    }
    fn from_wire(value: &Value, handles: &mut HandleStore) -> Result<Self, WireError> {
        match value {
            Value::List(items) => items
                .iter()
                .map(|item| T::from_wire(item, handles))
                .collect(),
            other => Err(WireError::TypeMismatch {
                expected: "list",
                found: other.kind_name(),
            }),
        }
    }
}

/// The narrow integer types: encoded as `int`, range-checked on decode.
macro_rules! wire_narrow_int {
    ($($t:ty),+) => {
        $(
            impl Wire for $t {
                fn to_wire(&self, _: &mut HandleSink) -> Value {
                    Value::Int(i64::from(*self))
                }
                fn from_wire(value: &Value, _: &mut HandleStore) -> Result<Self, WireError> {
                    match value {
                        Value::Int(i) => <$t>::try_from(*i).map_err(|_| {
                            WireError::IntOutOfRange { value: *i, target: stringify!($t) }
                        }),
                        other => Err(WireError::TypeMismatch {
                            expected: "int",
                            found: other.kind_name(),
                        }),
                    }
                }
            }
        )+
    };
}

wire_narrow_int!(i8, i16, i32, u8, u16, u32);
