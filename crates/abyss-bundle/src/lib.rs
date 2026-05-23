// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD bootstrap-bundle schema (`docs/design/broker-and-transport.md`
//! §5.8).
//!
//! A component is spawned holding one descriptor — its bootstrap socket —
//! on which the broker sends one envelope, the **bundle**. The bundle's
//! handle table carries every capability the component was granted (each a
//! descriptor via `SCM_RIGHTS`); its payload, a [`Bundle`], names them.
//!
//! - [`Bundle`] — a component's whole grant: a list of [`Grant`]s and a
//!   list of [`CasperChannel`]s.
//! - [`Grant`] — one capability: the [interface](Grant::interface) it
//!   speaks, the [`Role`] the component plays on it, the [`CapBody`]
//!   rights, and the ring-endpoint descriptor.
//! - [`CasperChannel`] — one Casper service channel, a `cap_channel_t`
//!   the broker opened to a named service (§5.7); carries no AbyssBSD
//!   rights — its restriction is the Casper-side limit.
//! - [`PeerRestarted`] — a control message delivered after boot, carrying
//!   one fresh `Grant` that re-wires a restarted peer (§5.5).
//! - [`SpawnChild`] / [`SpawnReply`] — the delegated-spawn request a
//!   component sends the broker over its control connection, and the
//!   broker's answer (§5.6).
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

use abyss_cap::KIND_FD_CAPABILITY;
use abyss_msg::{HandleSink, HandleStore, RawHandle, Value, Wire, WireError};

/// A capability's rights metadata (`broker-and-transport.md` §3.2),
/// re-exported so a [`Grant`] can be built without naming `abyss-cap`.
pub use abyss_cap::CapBody;

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

/// The dict key naming a [`SpawnReply`]'s outcome.
const KEY_OUTCOME: &str = "outcome";
/// The dict key carrying a [`SpawnReply::Refused`] reason.
const KEY_REASON: &str = "reason";
/// The `outcome` wire token for [`SpawnReply::Spawned`].
const OUTCOME_SPAWNED: &str = "spawned";
/// The `outcome` wire token for [`SpawnReply::Refused`].
const OUTCOME_REFUSED: &str = "refused";

/// The dict key naming a [`CasperChannel`]'s Casper service.
const KEY_SERVICE: &str = "service";
/// The dict key carrying a [`CasperChannel`]'s channel handle.
const KEY_CHANNEL: &str = "channel";
/// The dict key carrying a [`Bundle`]'s peer grants.
const KEY_GRANTS: &str = "grants";
/// The dict key carrying a [`Bundle`]'s Casper channels (§5.7).
const KEY_CASPER_CHANNELS: &str = "casper_channels";

/// The handle-table kind of a [`CasperChannel`] descriptor — distinct from
/// `KIND_FD_CAPABILITY` (an AbyssBSD ring), so the decoder knows whether
/// it is unwrapping a typed peer ring or a Casper service channel (§5.7).
const KIND_CASPER_CHANNEL: u8 = 2;

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

/// One Casper service channel a component was granted (§5.7) — a
/// `cap_channel_t` the broker opened to a named Casper service, passed as
/// its underlying fd via `SCM_RIGHTS`.
///
/// A Casper channel carries no AbyssBSD-side rights: its restriction is
/// the Casper-side limit the broker placed on it when it opened the
/// channel. The component wraps the fd back into a `cap_channel_t` via
/// libcasper's `cap_wrap` and uses libcasper's per-service client API.
#[derive(Debug)]
pub struct CasperChannel {
    /// The Casper service this channel is opened to — `system.dns`,
    /// `system.pwd`, …
    pub service: String,
    /// The channel's underlying socket descriptor — `cap_channel_t`'s
    /// `cap_sock()`.
    pub channel: OwnedFd,
}

/// A bootstrap bundle's payload: every capability a component was granted.
#[derive(Debug)]
pub struct Bundle {
    /// The peer-ring grants, in the order the broker laid them out.
    pub grants: Vec<Grant>,
    /// The Casper service channels (§5.7), independent of `grants` — a
    /// Casper channel is not a peer ring.
    pub casper_channels: Vec<CasperChannel>,
}

/// A control message re-wiring one of a component's peers
/// (`broker-and-transport.md` §5.5).
///
/// When the broker restarts a component, each surviving peer is sent a
/// `PeerRestarted` over its control connection: one fresh [`Grant`] — the
/// same interface and role as the grant in the original bundle, but a new
/// ring endpoint — that replaces the peer's now-dead ring. It is the unit
/// a [`Bundle`] is a list of, delivered one at a time after boot.
#[derive(Debug)]
pub struct PeerRestarted {
    /// The fresh grant for the re-wired connection.
    pub grant: Grant,
}

/// A request to the broker to spawn a child — delegated spawn
/// (`broker-and-transport.md` §5.6).
///
/// A component (chiefly the shell) sends this to the broker over the
/// component→broker direction of its control connection. It names a
/// manifest in the broker's *spawnable* set; a component never supplies a
/// manifest, because authoring authority is the broker's alone. The broker
/// answers with a [`SpawnReply`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnChild {
    /// The name of the manifest to spawn, in the broker's spawnable set.
    pub manifest: String,
}

/// The broker's answer to a [`SpawnChild`] request (§5.6).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SpawnReply {
    /// The child was spawned, wired, and is now supervised.
    Spawned,
    /// The request was refused; the string says why — no such spawnable
    /// manifest, the requester holds no `spawn` capability, or the child's
    /// authority graph does not resolve.
    Refused(String),
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

impl Wire for PeerRestarted {
    fn to_wire(&self, handles: &mut HandleSink) -> Value {
        self.grant.to_wire(handles)
    }

    fn from_wire(value: &Value, handles: &mut HandleStore) -> Result<Self, WireError> {
        Ok(PeerRestarted {
            grant: Grant::from_wire(value, handles)?,
        })
    }
}

impl Wire for CasperChannel {
    fn to_wire(&self, handles: &mut HandleSink) -> Value {
        // Duplicate the channel descriptor rather than move it — the §3.4
        // pattern; the duplicate rides `SCM_RIGHTS`, this struct keeps its
        // own. The handle's body is empty: a Casper channel carries no
        // AbyssBSD-side rights metadata (§5.7).
        let channel = self
            .channel
            .as_fd()
            .try_clone_to_owned()
            .expect("duplicate a Casper channel descriptor");
        let handle = RawHandle {
            kind: KIND_CASPER_CHANNEL,
            body: Vec::new(),
        };
        let index = handles.push(handle, channel);
        Value::Dict(vec![
            (KEY_SERVICE.to_owned(), Value::Str(self.service.clone())),
            (KEY_CHANNEL.to_owned(), Value::Handle(index)),
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
        let service = dict_str(fields, KEY_SERVICE)?.to_owned();
        let index = match dict_get(fields, KEY_CHANNEL)? {
            Value::Handle(index) => *index,
            other => {
                return Err(WireError::TypeMismatch {
                    expected: "handle",
                    found: other.kind_name(),
                });
            }
        };
        let (handle, channel) = handles.take(index)?;
        if handle.kind != KIND_CASPER_CHANNEL {
            return Err(WireError::MalformedHandle(format!(
                "a Casper channel must be kind {KIND_CASPER_CHANNEL}, got kind {}",
                handle.kind,
            )));
        }
        Ok(CasperChannel { service, channel })
    }
}

impl Wire for Bundle {
    fn to_wire(&self, handles: &mut HandleSink) -> Value {
        // A dict, so the bundle can carry more than one list — peer grants
        // and Casper channels are independent (§5.7). The bundle previously
        // wired as a bare grant list; the dict is the durable form.
        Value::Dict(vec![
            (KEY_GRANTS.to_owned(), self.grants.to_wire(handles)),
            (
                KEY_CASPER_CHANNELS.to_owned(),
                self.casper_channels.to_wire(handles),
            ),
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
        let grants = <Vec<Grant>>::from_wire(dict_get(fields, KEY_GRANTS)?, handles)?;
        let casper_channels =
            <Vec<CasperChannel>>::from_wire(dict_get(fields, KEY_CASPER_CHANNELS)?, handles)?;
        Ok(Bundle {
            grants,
            casper_channels,
        })
    }
}

impl Wire for SpawnChild {
    fn to_wire(&self, handles: &mut HandleSink) -> Value {
        // Just the manifest name — a `SpawnChild` carries no descriptors.
        self.manifest.to_wire(handles)
    }

    fn from_wire(value: &Value, handles: &mut HandleStore) -> Result<Self, WireError> {
        Ok(SpawnChild {
            manifest: String::from_wire(value, handles)?,
        })
    }
}

impl Wire for SpawnReply {
    fn to_wire(&self, _handles: &mut HandleSink) -> Value {
        match self {
            SpawnReply::Spawned => Value::Dict(vec![(
                KEY_OUTCOME.to_owned(),
                Value::Str(OUTCOME_SPAWNED.to_owned()),
            )]),
            SpawnReply::Refused(reason) => Value::Dict(vec![
                (
                    KEY_OUTCOME.to_owned(),
                    Value::Str(OUTCOME_REFUSED.to_owned()),
                ),
                (KEY_REASON.to_owned(), Value::Str(reason.clone())),
            ]),
        }
    }

    fn from_wire(value: &Value, _handles: &mut HandleStore) -> Result<Self, WireError> {
        let fields = match value {
            Value::Dict(fields) => fields,
            other => {
                return Err(WireError::TypeMismatch {
                    expected: "dict",
                    found: other.kind_name(),
                });
            }
        };
        match dict_str(fields, KEY_OUTCOME)? {
            OUTCOME_SPAWNED => Ok(SpawnReply::Spawned),
            OUTCOME_REFUSED => Ok(SpawnReply::Refused(
                dict_str(fields, KEY_REASON)?.to_owned(),
            )),
            other => Err(WireError::UnknownVariant(other.to_owned())),
        }
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
            casper_channels: Vec::new(),
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
        let value = Bundle {
            grants: Vec::new(),
            casper_channels: Vec::new(),
        }
        .to_wire(&mut sink);
        let (handles, fds) = sink.into_parts();
        assert!(handles.is_empty());

        let mut store = HandleStore::new(handles, fds).expect("store");
        let decoded = Bundle::from_wire(&value, &mut store).expect("decode");
        assert!(decoded.grants.is_empty());
        assert!(decoded.casper_channels.is_empty());
    }

    /// A `Bundle` wire form holding one grant dict, with empty Casper
    /// channels — for tests that build malformed grants to assert the
    /// rejection paths.
    fn bundle_value_with_one_grant(grant: Value) -> Value {
        Value::Dict(vec![
            (KEY_GRANTS.to_owned(), Value::List(vec![grant])),
            (KEY_CASPER_CHANNELS.to_owned(), Value::List(Vec::new())),
        ])
    }

    #[test]
    fn a_grant_handle_of_the_wrong_kind_is_rejected() {
        // A handle table entry that is not an fd capability — the grant
        // must not decode.
        let value = bundle_value_with_one_grant(Value::Dict(vec![
            (KEY_INTERFACE.to_owned(), Value::Str("input".to_owned())),
            (KEY_ROLE.to_owned(), Value::Str(ROLE_CLIENT.to_owned())),
            (KEY_CAPABILITY.to_owned(), Value::Handle(0)),
        ]));
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
        let value = bundle_value_with_one_grant(Value::Dict(vec![
            (KEY_INTERFACE.to_owned(), Value::Str("input".to_owned())),
            (KEY_ROLE.to_owned(), Value::Str("bystander".to_owned())),
            (KEY_CAPABILITY.to_owned(), Value::Handle(0)),
        ]));
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

    #[test]
    fn a_peer_restarted_round_trips_through_the_handle_table() {
        let restarted = PeerRestarted {
            grant: Grant {
                interface: "input".to_owned(),
                role: Role::Client,
                rights: rights(0x33),
                endpoint: a_descriptor(),
            },
        };
        let mut sink = HandleSink::new();
        let value = restarted.to_wire(&mut sink);
        let (handles, fds) = sink.into_parts();
        assert_eq!(handles.len(), 1, "the fresh ring rides one handle");

        let mut store = HandleStore::new(handles, fds).expect("the handle store builds");
        let decoded = PeerRestarted::from_wire(&value, &mut store).expect("the message decodes");
        assert_eq!(decoded.grant.interface, "input");
        assert_eq!(decoded.grant.role, Role::Client);
        assert_eq!(decoded.grant.rights, rights(0x33));
    }

    #[test]
    fn a_spawn_child_request_round_trips() {
        let request = SpawnChild {
            manifest: "text-editor".to_owned(),
        };
        let mut sink = HandleSink::new();
        let value = request.to_wire(&mut sink);
        let (handles, fds) = sink.into_parts();
        assert!(handles.is_empty(), "a SpawnChild carries no descriptors");

        let mut store = HandleStore::new(handles, fds).expect("the handle store builds");
        let decoded = SpawnChild::from_wire(&value, &mut store).expect("the request decodes");
        assert_eq!(decoded, request);
    }

    #[test]
    fn a_spawn_reply_round_trips_both_outcomes() {
        for reply in [
            SpawnReply::Spawned,
            SpawnReply::Refused("no such spawnable manifest".to_owned()),
        ] {
            let mut sink = HandleSink::new();
            let value = reply.to_wire(&mut sink);
            let (handles, fds) = sink.into_parts();
            let mut store = HandleStore::new(handles, fds).expect("the handle store builds");
            let decoded = SpawnReply::from_wire(&value, &mut store).expect("the reply decodes");
            assert_eq!(decoded, reply);
        }
    }

    #[test]
    fn an_unknown_spawn_outcome_is_rejected() {
        let value = Value::Dict(vec![(
            KEY_OUTCOME.to_owned(),
            Value::Str("maybe".to_owned()),
        )]);
        let mut store = HandleStore::new(vec![], vec![]).expect("store");
        match SpawnReply::from_wire(&value, &mut store) {
            Err(WireError::UnknownVariant(token)) => assert_eq!(token, "maybe"),
            other => panic!("expected UnknownVariant, got {other:?}"),
        }
    }

    #[test]
    fn a_casper_channel_round_trips_through_the_handle_table() {
        let channel = CasperChannel {
            service: "system.dns".to_owned(),
            channel: a_descriptor(),
        };
        let mut sink = HandleSink::new();
        let value = channel.to_wire(&mut sink);
        let (handles, fds) = sink.into_parts();
        assert_eq!(handles.len(), 1, "the channel rides one handle");
        assert_eq!(
            handles[0].kind, KIND_CASPER_CHANNEL,
            "kind tags it a Casper channel, not an fd capability",
        );
        assert!(handles[0].body.is_empty(), "no AbyssBSD rights metadata");

        let mut store = HandleStore::new(handles, fds).expect("the handle store builds");
        let decoded = CasperChannel::from_wire(&value, &mut store).expect("the channel decodes");
        assert_eq!(decoded.service, "system.dns");
    }

    #[test]
    fn a_bundle_carries_grants_and_casper_channels_side_by_side() {
        let bundle = Bundle {
            grants: vec![Grant {
                interface: "input".to_owned(),
                role: Role::Client,
                rights: rights(0x55),
                endpoint: a_descriptor(),
            }],
            casper_channels: vec![CasperChannel {
                service: "system.dns".to_owned(),
                channel: a_descriptor(),
            }],
        };
        let mut sink = HandleSink::new();
        let value = bundle.to_wire(&mut sink);
        let (handles, fds) = sink.into_parts();
        // One handle per grant + one per Casper channel; their kinds
        // distinguish them on the wire (§5.7).
        assert_eq!(handles.len(), 2);
        assert_eq!(fds.len(), 2);
        let kinds: Vec<u8> = handles.iter().map(|h| h.kind).collect();
        assert!(kinds.contains(&KIND_FD_CAPABILITY));
        assert!(kinds.contains(&KIND_CASPER_CHANNEL));

        let mut store = HandleStore::new(handles, fds).expect("the handle store builds");
        let decoded = Bundle::from_wire(&value, &mut store).expect("the bundle decodes");
        assert_eq!(decoded.grants.len(), 1);
        assert_eq!(decoded.grants[0].interface, "input");
        assert_eq!(decoded.casper_channels.len(), 1);
        assert_eq!(decoded.casper_channels[0].service, "system.dns");
    }

    #[test]
    fn a_casper_handle_of_the_wrong_kind_is_rejected() {
        // A Casper channel dict pointing at an fd-capability-kind handle —
        // the decoder must catch the kind mismatch.
        let value = Value::Dict(vec![
            (KEY_SERVICE.to_owned(), Value::Str("system.dns".to_owned())),
            (KEY_CHANNEL.to_owned(), Value::Handle(0)),
        ]);
        let handles = vec![RawHandle {
            kind: KIND_FD_CAPABILITY,
            body: Vec::new(),
        }];
        let mut store = HandleStore::new(handles, vec![a_descriptor()]).expect("store");
        match CasperChannel::from_wire(&value, &mut store) {
            Err(WireError::MalformedHandle(_)) => {}
            other => panic!("expected MalformedHandle, got {other:?}"),
        }
    }
}
