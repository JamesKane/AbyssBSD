// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD bootstrap-bundle schema (`docs/design/broker-and-transport.md`
//! §5.8).
//!
//! A component is spawned holding one descriptor — its bootstrap socket —
//! on which the broker sends one envelope, the **bundle**. The bundle's
//! handle table carries every capability the component was granted (each a
//! descriptor via `SCM_RIGHTS`); its payload, a [`Bundle`], names them.
//!
//! - [`Bundle`] — a component's whole grant: a list of [`Grant`]s.
//! - [`Grant`] — one capability: the [interface](Grant::interface) it
//!   speaks, the [`Role`] the component plays on it, the [`CapBody`]
//!   rights, and the ring-endpoint descriptor.
//!
//! `Bundle` is [`Wire`]: `to_wire` duplicates each grant's descriptor onto
//! the handle table beside its `CapBody` (the §3.4 pattern `Cap` follows),
//! `from_wire` claims each back. This crate is the schema and nothing
//! else — the contract between the broker, which builds a `Bundle`, and a
//! component's startup shim, which decodes one. It is a host-slice crate:
//! the schema and its round-trip use no FreeBSD facility, so it builds and
//! tests on any host.

#![forbid(unsafe_code)]

use std::os::fd::{AsFd, OwnedFd};

use abyss_cap::{CapBody, KIND_FD_CAPABILITY};
use abyss_msg::{HandleSink, HandleStore, RawHandle, Value, Wire, WireError};

/// The dict key naming a grant's interface.
const KEY_INTERFACE: &str = "interface";
/// The dict key naming a grant's role.
const KEY_ROLE: &str = "role";
/// The dict key carrying a grant's capability handle.
const KEY_CAPABILITY: &str = "capability";

/// The `role` wire token for [`Role::Client`].
const ROLE_CLIENT: &str = "client";
/// The `role` wire token for [`Role::Server`].
const ROLE_SERVER: &str = "server";

/// Which face a component puts on its end of a granted ring.
///
/// Both ends of a `SOCK_SEQPACKET` ring are descriptors; the role records
/// which one this component holds, and so how its startup shim uses it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// The component *uses* the interface: it holds the ring's send end,
    /// which the startup shim turns into a `Cap` (§3.5).
    Client,
    /// The component *exports* the interface: it holds the service end and
    /// accepts requests on it.
    Server,
}

impl Role {
    /// The wire token for this role.
    fn as_token(self) -> &'static str {
        match self {
            Role::Client => ROLE_CLIENT,
            Role::Server => ROLE_SERVER,
        }
    }

    /// The role a wire token names.
    fn from_token(token: &str) -> Result<Role, WireError> {
        match token {
            ROLE_CLIENT => Ok(Role::Client),
            ROLE_SERVER => Ok(Role::Server),
            other => Err(WireError::UnknownVariant(other.to_owned())),
        }
    }
}

/// One capability in a [`Bundle`]: a named ring endpoint and its rights.
#[derive(Debug)]
pub struct Grant {
    /// The interface the capability speaks — resolved against the
    /// component's own manifest.
    pub interface: String,
    /// Whether the component uses or exports `interface`.
    pub role: Role,
    /// The §3.2 rights metadata the broker minted for the capability.
    pub rights: CapBody,
    /// The ring-endpoint descriptor.
    pub endpoint: OwnedFd,
}

/// A bootstrap bundle's payload: every capability a component was granted.
#[derive(Debug)]
pub struct Bundle {
    /// The grants, in the order the broker laid them out.
    pub grants: Vec<Grant>,
}

impl Wire for Grant {
    fn to_wire(&self, handles: &mut HandleSink) -> Value {
        // `&self`, so the endpoint is *duplicated* onto the handle table,
        // not moved — the §3.4 pattern. The duplicate rides `SCM_RIGHTS`;
        // this `Grant` keeps its own descriptor.
        let endpoint = self
            .endpoint
            .as_fd()
            .try_clone_to_owned()
            .expect("duplicate a bundle grant's endpoint descriptor");
        let handle = RawHandle {
            kind: KIND_FD_CAPABILITY,
            body: self.rights.encode(),
        };
        let index = handles.push(handle, endpoint);
        Value::Dict(vec![
            (KEY_INTERFACE.to_owned(), Value::Str(self.interface.clone())),
            (
                KEY_ROLE.to_owned(),
                Value::Str(self.role.as_token().to_owned()),
            ),
            (KEY_CAPABILITY.to_owned(), Value::Handle(index)),
        ])
    }

    fn from_wire(value: &Value, handles: &mut HandleStore) -> Result<Self, WireError> {
        let fields = match value {
            Value::Dict(fields) => fields,
            other => {
                return Err(WireError::TypeMismatch {
                    expected: "dict",
                    found: other.kind_name(),
                });
            }
        };
        let interface = dict_str(fields, KEY_INTERFACE)?.to_owned();
        let role = Role::from_token(dict_str(fields, KEY_ROLE)?)?;
        let index = match dict_get(fields, KEY_CAPABILITY)? {
            Value::Handle(index) => *index,
            other => {
                return Err(WireError::TypeMismatch {
                    expected: "handle",
                    found: other.kind_name(),
                });
            }
        };
        let (handle, endpoint) = handles.take(index)?;
        if handle.kind != KIND_FD_CAPABILITY {
            return Err(WireError::MalformedHandle(format!(
                "a bundle grant must be an fd capability (kind {KIND_FD_CAPABILITY}), \
                 got kind {}",
                handle.kind
            )));
        }
        let rights = CapBody::decode(&handle.body)
            .map_err(|err| WireError::MalformedHandle(err.to_string()))?;
        Ok(Grant {
            interface,
            role,
            rights,
            endpoint,
        })
    }
}

impl Wire for Bundle {
    fn to_wire(&self, handles: &mut HandleSink) -> Value {
        self.grants.to_wire(handles)
    }

    fn from_wire(value: &Value, handles: &mut HandleStore) -> Result<Self, WireError> {
        Ok(Bundle {
            grants: <Vec<Grant>>::from_wire(value, handles)?,
        })
    }
}

/// Look a key up in a decoded dict's ordered field list.
fn dict_get<'v>(fields: &'v [(String, Value)], key: &'static str) -> Result<&'v Value, WireError> {
    fields
        .iter()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value)
        .ok_or(WireError::MissingField(key))
}

/// Look up a key whose value must be a string.
fn dict_str<'v>(fields: &'v [(String, Value)], key: &'static str) -> Result<&'v str, WireError> {
    match dict_get(fields, key)? {
        Value::Str(text) => Ok(text),
        other => Err(WireError::TypeMismatch {
            expected: "string",
            found: other.kind_name(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use abyss_msg::{Envelope, Header, MessageKind};

    /// A throwaway descriptor — `/dev/null`, open on every host the dev bed
    /// and the VM run on. The bundle schema does not care what the
    /// descriptor *is*, only that one rides each grant.
    fn a_descriptor() -> OwnedFd {
        std::fs::File::open("/dev/null")
            .expect("/dev/null opens")
            .into()
    }

    /// A `CapBody` stamped with a recognisable byte, to check it round-trips.
    fn rights(mark: u8) -> CapBody {
        CapBody {
            cap_rights: [mark; 16],
            object_rights: u32::from(mark),
        }
    }

    fn sample_bundle() -> Bundle {
        Bundle {
            grants: vec![
                Grant {
                    interface: "input".to_owned(),
                    role: Role::Client,
                    rights: rights(0x11),
                    endpoint: a_descriptor(),
                },
                Grant {
                    interface: "display".to_owned(),
                    role: Role::Server,
                    rights: rights(0x22),
                    endpoint: a_descriptor(),
                },
            ],
        }
    }

    fn assert_matches_sample(decoded: &Bundle) {
        assert_eq!(decoded.grants.len(), 2);
        assert_eq!(decoded.grants[0].interface, "input");
        assert_eq!(decoded.grants[0].role, Role::Client);
        assert_eq!(decoded.grants[0].rights, rights(0x11));
        assert_eq!(decoded.grants[1].interface, "display");
        assert_eq!(decoded.grants[1].role, Role::Server);
        assert_eq!(decoded.grants[1].rights, rights(0x22));
    }

    #[test]
    fn a_bundle_round_trips_through_the_handle_table() {
        let mut sink = HandleSink::new();
        let value = sample_bundle().to_wire(&mut sink);
        let (handles, fds) = sink.into_parts();

        // One handle and one descriptor per grant.
        assert_eq!(handles.len(), 2);
        assert_eq!(fds.len(), 2);
        assert!(handles.iter().all(|h| h.kind == KIND_FD_CAPABILITY));

        let mut store = HandleStore::new(handles, fds).expect("the handle store builds");
        let decoded = Bundle::from_wire(&value, &mut store).expect("the bundle decodes");
        assert_matches_sample(&decoded);
    }

    #[test]
    fn a_bundle_survives_a_full_envelope_round_trip() {
        // The bundle is carried as an ordinary envelope payload (§5.3).
        let header = Header {
            kind: MessageKind::Event,
            interface_id: 0,
            method_id: 0,
        };
        let (envelope, fds) = Envelope::from_message(header, &sample_bundle());
        let decoded = envelope
            .into_message::<Bundle>(fds)
            .expect("the bundle decodes from its envelope");
        assert_matches_sample(&decoded);
    }

    #[test]
    fn an_empty_bundle_round_trips() {
        let mut sink = HandleSink::new();
        let value = Bundle { grants: Vec::new() }.to_wire(&mut sink);
        let (handles, fds) = sink.into_parts();
        assert!(handles.is_empty());

        let mut store = HandleStore::new(handles, fds).expect("store");
        let decoded = Bundle::from_wire(&value, &mut store).expect("decode");
        assert!(decoded.grants.is_empty());
    }

    #[test]
    fn a_grant_handle_of_the_wrong_kind_is_rejected() {
        // A handle table entry that is not an fd capability — the grant
        // must not decode.
        let value = Value::List(vec![Value::Dict(vec![
            (KEY_INTERFACE.to_owned(), Value::Str("input".to_owned())),
            (KEY_ROLE.to_owned(), Value::Str(ROLE_CLIENT.to_owned())),
            (KEY_CAPABILITY.to_owned(), Value::Handle(0)),
        ])]);
        let handles = vec![RawHandle {
            kind: KIND_FD_CAPABILITY + 1,
            body: rights(0).encode(),
        }];
        let mut store = HandleStore::new(handles, vec![a_descriptor()]).expect("store");

        match Bundle::from_wire(&value, &mut store) {
            Err(WireError::MalformedHandle(_)) => {}
            other => panic!("expected MalformedHandle, got {other:?}"),
        }
    }

    #[test]
    fn an_unknown_role_token_is_rejected() {
        let value = Value::List(vec![Value::Dict(vec![
            (KEY_INTERFACE.to_owned(), Value::Str("input".to_owned())),
            (KEY_ROLE.to_owned(), Value::Str("bystander".to_owned())),
            (KEY_CAPABILITY.to_owned(), Value::Handle(0)),
        ])]);
        let handles = vec![RawHandle {
            kind: KIND_FD_CAPABILITY,
            body: rights(0).encode(),
        }];
        let mut store = HandleStore::new(handles, vec![a_descriptor()]).expect("store");

        match Bundle::from_wire(&value, &mut store) {
            Err(WireError::UnknownVariant(token)) => assert_eq!(token, "bystander"),
            other => panic!("expected UnknownVariant, got {other:?}"),
        }
    }
}
