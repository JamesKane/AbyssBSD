// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD capability layer — the typed, rights-bearing face of a ring
//! endpoint (`docs/design/looper-framework.md` §7).
//!
//! - [`Cap`] — a typed send capability, parameterized by the interface it
//!   speaks and the rights its holder was granted. Move-only.
//! - [`Interface`] — what messages a capability of an interface carries.
//! - [`Rights`] / [`SubsetOf`] — rights as compile-time phantom typestate.
//! - [`CapBody`] — the handle-table body a capability serializes to when
//!   it crosses a process boundary (`broker-and-transport.md` §3.2).
//!
//! On FreeBSD a `Cap` is [`Wire`](abyss_msg::Wire) (§3.4–§3.5): `to_wire`
//! duplicates its ring socket onto `SCM_RIGHTS` and pushes the [`CapBody`];
//! `from_wire` yields an *unbound* `Cap`, and [`Cap::bind`] attaches that
//! to a looper to make it usable. In-process (Phase 2) a capability moves
//! as an ordinary value, with no serialization to do.

#![forbid(unsafe_code)]

mod rights;
mod wire;

pub use rights::{Rights, SubsetOf};
pub use wire::{CAP_BODY_LEN, CapBody, CapBodyError, KIND_FD_CAPABILITY};

use std::marker::PhantomData;

use abyss_looper::{Delivery, Receiver, RingClosed, Sender, TrySendError, channel, responder};
use abyss_msg::Request;

#[cfg(target_os = "freebsd")]
use std::future::Future;
#[cfg(target_os = "freebsd")]
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
#[cfg(target_os = "freebsd")]
use std::sync::Arc;

#[cfg(target_os = "freebsd")]
use abyss_looper::Spawner;
#[cfg(target_os = "freebsd")]
use abyss_msg::{
    Envelope, HandleSink, HandleStore, Header, MessageKind, Method, RawHandle, Value, Wire,
    WireError,
};
#[cfg(target_os = "freebsd")]
use abyss_transport::{
    AsyncChannel, CallOutcome, Connection, FramedChannel, Inbound, Inbox, ReactorSource, Responder,
};

/// An interface — the set of messages a capability of this interface
/// carries. `Message` is typically an enum of the interface's requests,
/// commands, and events.
pub trait Interface: 'static {
    /// This interface's id — stamped into the header of every envelope on
    /// its IPC ring (`docs/design/broker-and-transport.md` §2.9). Unique
    /// per interface; assigned in the interface catalogue. The id belongs
    /// to the interface, not the message: a ring speaks one interface, so
    /// `Cap` stamps it once rather than deriving it per message.
    const ID: u32;

    /// The message type carried by this interface's ring.
    type Message: Send + 'static;
}

/// The ring a [`Cap`] dispatches to (`broker-and-transport.md` §2.8). A
/// `Cap`'s backend has three forms (§3.5): `Local` is the in-process ring
/// (looper-framework §3); `Ipc` is a live IPC ring; `IpcUnbound` is a
/// capability received over IPC but not yet attached to a looper.
enum Backend<I: Interface> {
    /// An in-process `abyss-looper` channel. It carries a [`Delivery`] —
    /// a message and, for a request, the responder that answers it.
    Local(Sender<Delivery<I::Message>>),
    /// A live IPC ring — a `SOCK_SEQPACKET` connection. `encode` is the
    /// message-to-envelope function captured when the ring was built,
    /// where `I::Message: Wire + Method` was in scope (§2.8, §2.9); it
    /// lets the `Cap` methods serialize without that bound themselves.
    /// `body` is the §3.2 handle-table body the broker minted for this
    /// capability — what `to_wire` re-emits when the cap is passed on.
    #[cfg(target_os = "freebsd")]
    Ipc {
        connection: Connection,
        encode: fn(&I::Message) -> (Envelope, Vec<OwnedFd>),
        body: CapBody,
    },
    /// A capability decoded from a message but not yet usable (§3.5):
    /// `from_wire` reaches no reactor, so it yields this — the received
    /// ring socket and its [`CapBody`], no live `Connection`. [`Cap::bind`]
    /// is the single edge that turns it into [`Ipc`](Self::Ipc).
    #[cfg(target_os = "freebsd")]
    IpcUnbound { fd: OwnedFd, body: CapBody },
}

/// A typed, rights-bearing **send** capability — the send endpoint of a
/// ring (§7.1), typed by the interface `I` it speaks and the rights `R`
/// its holder was granted.
///
/// Move-only: there is deliberately no `Clone`. Sharing a service among
/// many clients is many capabilities, each minted for one connection —
/// never a duplicated one (§10.1).
pub struct Cap<I: Interface, R: Rights> {
    backend: Backend<I>,
    _marker: PhantomData<fn() -> (I, R)>,
}

/// Why a [`Cap::call`] did not return a reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallError {
    /// The peer was gone before it could answer — the ring closed.
    PeerGone,
    /// The service refused the request: it named a method outside the
    /// caller's object rights (`broker-and-transport.md` §3.6). Reached
    /// only over an IPC ring; an in-process call never yields it.
    RightsDenied,
}

impl From<RingClosed> for CallError {
    fn from(_: RingClosed) -> Self {
        CallError::PeerGone
    }
}

/// Create a connected capability and its receiver over an in-process ring
/// — the [`Backend::Local`] backend — of the given capacity.
///
/// This is the constructor for host tests and bring-up; the broker builds
/// IPC-backed capabilities when it wires the authority graph (§5.2).
///
/// # Panics
///
/// Panics if `capacity` is zero.
pub fn cap_channel<I: Interface, R: Rights>(
    capacity: usize,
) -> (Cap<I, R>, Receiver<Delivery<I::Message>>) {
    let (sender, receiver) = channel(capacity);
    (
        Cap {
            backend: Backend::Local(sender),
            _marker: PhantomData,
        },
        receiver,
    )
}

/// Build an IPC-backed capability over `connection` — its `SOCK_SEQPACKET`
/// ring (`broker-and-transport.md` §2.8) — carrying the rights `body` the
/// broker minted for it (§3.2). The broker builds these as it wires the
/// authority graph (§5.2); [`cap_channel`] is the in-process counterpart.
///
/// The `Wire` and `Method` bounds are this constructor's, not the
/// [`Interface`] trait's (§2.9): they are needed only to build an IPC
/// ring, so the message serializer is captured here, and `Cap`'s own
/// methods carry no such bound.
#[cfg(target_os = "freebsd")]
pub fn ipc_cap<I, R>(connection: Connection, body: CapBody) -> Cap<I, R>
where
    I: Interface,
    R: Rights,
    I::Message: Wire + Method,
{
    Cap {
        backend: Backend::Ipc {
            connection,
            encode: encode_message::<I>,
            body,
        },
        _marker: PhantomData,
    }
}

/// Build an *unbound* IPC capability from a received ring descriptor and
/// its rights (`broker-and-transport.md` §3.5) — the form a bootstrap
/// bundle's client grant takes before the framework binds it to a looper.
///
/// This is what [`Wire::from_wire`] yields, exposed as a constructor so the
/// startup shim can build the same unbound `Cap` from a bundle [`CapBody`]
/// it has already decoded. The result is unusable until [`Cap::bind`]
/// attaches it to a looper.
#[cfg(target_os = "freebsd")]
pub fn unbound_ipc_cap<I, R>(endpoint: OwnedFd, body: CapBody) -> Cap<I, R>
where
    I: Interface,
    R: Rights,
{
    Cap {
        backend: Backend::IpcUnbound { fd: endpoint, body },
        _marker: PhantomData,
    }
}

/// Encode an interface message into an envelope and the descriptors its
/// capabilities surrender. The header's interface id is the ring's
/// (`I::ID`); its method id and kind are the message's (§2.9).
#[cfg(target_os = "freebsd")]
fn encode_message<I: Interface>(message: &I::Message) -> (Envelope, Vec<OwnedFd>)
where
    I::Message: Wire + Method,
{
    let header = Header {
        kind: message.kind(),
        interface_id: I::ID,
        method_id: message.method_id(),
    };
    Envelope::from_message(header, message)
}

impl<I: Interface, R: Rights> Cap<I, R> {
    /// Send a message. Awaiting suspends the calling handler — never the
    /// looper thread — if the ring is full (§3.1).
    pub async fn send(&self, msg: I::Message) -> Result<(), RingClosed> {
        match &self.backend {
            Backend::Local(sender) => {
                sender
                    .send(Delivery {
                        message: msg,
                        responder: None,
                    })
                    .await
            }
            #[cfg(target_os = "freebsd")]
            Backend::Ipc {
                connection, encode, ..
            } => {
                let (envelope, fds) = (*encode)(&msg);
                let borrowed: Vec<BorrowedFd<'_>> = fds.iter().map(AsFd::as_fd).collect();
                // A broken IPC ring is, to the holder of the capability,
                // a closed ring — the peer can no longer be reached.
                connection
                    .send(&envelope, &borrowed)
                    .await
                    .map_err(|_| RingClosed)
            }
            #[cfg(target_os = "freebsd")]
            Backend::IpcUnbound { .. } => unbound_use_panic(),
        }
    }

    /// Send without waiting; on a full ring the message is returned.
    pub fn try_send(&self, msg: I::Message) -> Result<(), TrySendError<I::Message>> {
        match &self.backend {
            Backend::Local(sender) => {
                // The message is wrapped in a `Delivery` to send; unwrap it
                // back out of the error so the caller is handed its message.
                match sender.try_send(Delivery {
                    message: msg,
                    responder: None,
                }) {
                    Ok(()) => Ok(()),
                    Err(TrySendError::Full(d)) => Err(TrySendError::Full(d.message)),
                    Err(TrySendError::Closed(d)) => Err(TrySendError::Closed(d.message)),
                }
            }
            #[cfg(target_os = "freebsd")]
            Backend::Ipc {
                connection, encode, ..
            } => {
                let (envelope, fds) = (*encode)(&msg);
                let borrowed: Vec<BorrowedFd<'_>> = fds.iter().map(AsFd::as_fd).collect();
                // The ring socket is non-blocking and a `SOCK_SEQPACKET`
                // datagram is sent whole or not at all: a momentarily full
                // send buffer is `WouldBlock` — the message is returned,
                // not buffered. Any other error is a dead ring.
                match connection.try_send(&envelope, &borrowed) {
                    Ok(()) => Ok(()),
                    Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                        Err(TrySendError::Full(msg))
                    }
                    Err(_) => Err(TrySendError::Closed(msg)),
                }
            }
            #[cfg(target_os = "freebsd")]
            Backend::IpcUnbound { .. } => unbound_use_panic(),
        }
    }

    /// Narrow to a weaker rights set.
    ///
    /// The `R2: SubsetOf<R>` bound makes the monotonic law of §10.1 a
    /// *compile error* to break — widening does not type-check:
    ///
    /// ```compile_fail
    /// use abyss_cap::{Cap, Interface, Rights, SubsetOf, cap_channel};
    ///
    /// struct Iface;
    /// impl Interface for Iface { const ID: u32 = 1; type Message = i32; }
    ///
    /// struct Broad;
    /// struct Narrow;
    /// impl Rights for Broad {}
    /// impl Rights for Narrow {}
    /// impl SubsetOf<Broad> for Narrow {}
    ///
    /// let (cap, _rx) = cap_channel::<Iface, Narrow>(1);
    /// // Broad is not a subset of Narrow — this must not compile.
    /// let _wider: Cap<Iface, Broad> = cap.narrow::<Broad>();
    /// ```
    pub fn narrow<R2: SubsetOf<R>>(self) -> Cap<I, R2> {
        Cap {
            backend: self.backend,
            _marker: PhantomData,
        }
    }

    /// Send a request and await its reply (`broker-and-transport.md`
    /// §2.10). The reply type is the request's own — `Q::Reply` — so the
    /// caller is handed back exactly what the request is answered with.
    ///
    /// The reply path is framework-mediated, never an embedded `Sender`
    /// (§2.7): in-process the request rides a [`Delivery`] carrying a
    /// `Responder`; over IPC it rides a Request frame and the reply
    /// correlates back. Awaiting suspends the calling handler, never the
    /// looper thread.
    ///
    /// A [`CallError`] tells a gone peer ([`PeerGone`](CallError::PeerGone))
    /// from a service that refused the request
    /// ([`RightsDenied`](CallError::RightsDenied), §3.6).
    pub async fn call<Q>(&self, request: Q) -> Result<Q::Reply, CallError>
    where
        Q: Request + Into<I::Message>,
    {
        match &self.backend {
            Backend::Local(sender) => {
                let (reply, mut reply_rx) = responder::<Q::Reply>();
                sender
                    .send(Delivery {
                        message: request.into(),
                        responder: Some(Box::new(reply)),
                    })
                    .await?;
                reply_rx.recv().await.map_err(CallError::from)
            }
            #[cfg(target_os = "freebsd")]
            Backend::Ipc {
                connection, encode, ..
            } => {
                let (envelope, fds) = (*encode)(&request.into());
                let borrowed: Vec<BorrowedFd<'_>> = fds.iter().map(AsFd::as_fd).collect();
                match connection
                    .call(&envelope, &borrowed)
                    .await
                    .map_err(|_| CallError::PeerGone)?
                {
                    CallOutcome::Answered(reply_envelope, reply_fds) => reply_envelope
                        .into_message::<Q::Reply>(reply_fds)
                        .map_err(|_| CallError::PeerGone),
                    CallOutcome::Refused => Err(CallError::RightsDenied),
                }
            }
            #[cfg(target_os = "freebsd")]
            Backend::IpcUnbound { .. } => unbound_use_panic(),
        }
    }
}

/// The contract violation §3.5 names: using an unbound capability — to
/// `send`, `try_send`, `call`, or serialize it — before the framework has
/// bound it to a looper. A handler only ever receives bound capabilities,
/// so reaching this is a framework bug, not a runtime input error.
#[cfg(target_os = "freebsd")]
fn unbound_use_panic() -> ! {
    panic!("an unbound Cap must be bound to a looper before use (broker-and-transport.md §3.5)")
}

/// A `Cap` crosses a process boundary as an fd capability
/// (`broker-and-transport.md` §3.4–§3.5): `to_wire` duplicates its ring
/// socket onto `SCM_RIGHTS` beside the [`CapBody`]; `from_wire` yields an
/// *unbound* `Cap` — a decode reaches no reactor — which [`Cap::bind`]
/// then makes usable.
#[cfg(target_os = "freebsd")]
impl<I: Interface, R: Rights> Wire for Cap<I, R> {
    fn to_wire(&self, handles: &mut HandleSink) -> Value {
        match &self.backend {
            // An in-process ring has no fd to cross a boundary (§2.8); an
            // unbound cap is not the framework's to pass on (§3.5).
            Backend::Local(_) => {
                panic!("an in-process Cap cannot cross a process boundary (§2.8, §3.5)")
            }
            Backend::IpcUnbound { .. } => unbound_use_panic(),
            Backend::Ipc {
                connection, body, ..
            } => {
                // `&self`: duplicate the ring socket rather than move it —
                // the duplicate rides `SCM_RIGHTS`, this `Cap` keeps its
                // own live ring.
                let fd = connection
                    .as_fd()
                    .try_clone_to_owned()
                    .expect("duplicate the capability's ring socket");
                let handle = RawHandle {
                    kind: KIND_FD_CAPABILITY,
                    body: body.encode(),
                };
                Value::Handle(handles.push(handle, fd))
            }
        }
    }

    fn from_wire(value: &Value, handles: &mut HandleStore) -> Result<Self, WireError> {
        let index = match value {
            Value::Handle(index) => *index,
            other => {
                return Err(WireError::TypeMismatch {
                    expected: "handle",
                    found: other.kind_name(),
                });
            }
        };
        let (handle, fd) = handles.take(index)?;
        if handle.kind != KIND_FD_CAPABILITY {
            return Err(WireError::MalformedHandle(format!(
                "expected an fd capability (kind {KIND_FD_CAPABILITY}), got kind {}",
                handle.kind
            )));
        }
        let body = CapBody::decode(&handle.body)
            .map_err(|err| WireError::MalformedHandle(err.to_string()))?;
        // Unbound: the received socket and its rights, no live ring — a
        // decode reaches no reactor (§3.5). `Cap::bind` completes it.
        Ok(Cap {
            backend: Backend::IpcUnbound { fd, body },
            _marker: PhantomData,
        })
    }
}

#[cfg(target_os = "freebsd")]
impl<I: Interface, R: Rights> Cap<I, R>
where
    I::Message: Wire + Method,
{
    /// Bind a capability received over IPC to a looper, making it usable
    /// (`broker-and-transport.md` §3.5).
    ///
    /// [`from_wire`](Wire::from_wire) yields an *unbound* `Cap` — a ring
    /// socket with no live connection, because a decode reaches no
    /// reactor. `bind` lifts that socket into a live [`Connection`] on
    /// `reactor`, and spawns the connection's `serve` loop onto the looper
    /// through `spawner` so replies to this cap's `call`s route. It
    /// consumes the unbound `Cap` and returns the bound one.
    ///
    /// The *framework* binds — never component code: the startup shim
    /// binds the capabilities the bootstrap bundle delivered, and a
    /// capability arriving in a later message is bound as the looper
    /// dispatches that message. A handler only ever sees a bound `Cap`.
    ///
    /// # Panics
    ///
    /// Panics on a `Cap` that is not unbound — a `Local` or already-`Ipc`
    /// capability has nothing to bind.
    pub fn bind(self, reactor: Arc<ReactorSource>, spawner: &Spawner) -> Cap<I, R> {
        let (fd, body) = match self.backend {
            Backend::IpcUnbound { fd, body } => (fd, body),
            Backend::Local(_) => panic!("a Local Cap is in-process — nothing to bind (§3.5)"),
            Backend::Ipc { .. } => panic!("this Cap is already bound (§3.5)"),
        };
        let framed = FramedChannel::from_fd(fd);
        let channel = AsyncChannel::new(framed, reactor)
            .expect("drive the received ring on the looper's reactor");
        let (connection, _inbox) = Connection::open(channel);
        // The receive loop routes replies back to this cap's `call`s; a
        // send capability accepts no inbound requests, so the `Inbox` is
        // dropped.
        spawner.spawn(connection.clone().serve());
        Cap {
            backend: Backend::Ipc {
                connection,
                encode: encode_message::<I>,
                body,
            },
            _marker: PhantomData,
        }
    }
}

/// A service over an interface — it answers the messages a `Cap<I>` sends
/// (`broker-and-transport.md` §3.6).
///
/// The IPC counterpart of an `abyss-looper` `Handler`. A service answers
/// with an *encoded* reply, where a `Handler` moves a value through a
/// `Responder` channel, so a `Service` takes a typed [`Reply`] handle.
#[cfg(target_os = "freebsd")]
pub trait Service: Send + 'static {
    /// The interface this service exports.
    type Interface: Interface;

    /// Handle one inbound message. For a request, answer it through
    /// `reply`; a command or event carries no reply (§2.7). The framework
    /// has already checked the message against the connection's object
    /// rights — a handler sees only what it was authorized (§3.6).
    fn handle(
        &mut self,
        message: <Self::Interface as Interface>::Message,
        reply: Reply,
    ) -> impl Future<Output = ()> + Send;
}

/// The handle a [`Service`] answers a request through (§3.6).
#[cfg(target_os = "freebsd")]
pub struct Reply {
    /// `Some` for a request; `None` for a command or event.
    responder: Option<Responder>,
}

#[cfg(target_os = "freebsd")]
impl Reply {
    /// Answer the request with `value`, encoded onto the ring. A command
    /// or event carries no responder, so answering one is a no-op.
    pub async fn answer<R: Wire>(self, value: R) -> Result<(), RingClosed> {
        let Some(responder) = self.responder else {
            return Ok(());
        };
        let (envelope, fds) = Envelope::from_message(reply_header(), &value);
        let borrowed: Vec<BorrowedFd<'_>> = fds.iter().map(AsFd::as_fd).collect();
        responder
            .respond(&envelope, &borrowed)
            .await
            .map_err(|_| RingClosed)
    }
}

/// The envelope header a reply rides under. A reply is a bare `Wire` value,
/// not a `Method`, and `Cap::call` decodes it by the request's `Q::Reply`
/// type without consulting the header — so the ids are zero.
#[cfg(target_os = "freebsd")]
fn reply_header() -> Header {
    Header {
        kind: MessageKind::Event,
        interface_id: 0,
        method_id: 0,
    }
}

/// Bind a `Role::Server` grant — a service ring's descriptor and the
/// rights minted for it — to a looper, serving `service` over it (§3.6).
///
/// The server counterpart of [`Cap::bind`]: it lifts the descriptor into
/// a live `Connection`, spawns the connection's `serve` loop, and spawns
/// the accept loop. The accept loop checks each inbound `method_id`
/// against the grant's object-rights mask before `service` sees the
/// message — a method outside the mask is refused, never dispatched.
#[cfg(target_os = "freebsd")]
pub fn bind_service<S>(
    endpoint: OwnedFd,
    rights: CapBody,
    service: S,
    reactor: Arc<ReactorSource>,
    spawner: &Spawner,
) where
    S: Service,
    <S::Interface as Interface>::Message: Wire + Method,
{
    let framed = FramedChannel::from_fd(endpoint);
    let channel =
        AsyncChannel::new(framed, reactor).expect("drive the service ring on the looper's reactor");
    let (connection, inbox) = Connection::open(channel);
    spawner.spawn(connection.serve());
    spawner.spawn(serve_loop::<S>(inbox, rights.object_rights, service));
}

/// The accept loop [`bind_service`] spawns: decode each inbound message,
/// check it against `object_rights`, and dispatch it — or refuse it.
#[cfg(target_os = "freebsd")]
async fn serve_loop<S>(mut inbox: Inbox, object_rights: u32, mut service: S)
where
    S: Service,
    <S::Interface as Interface>::Message: Wire + Method,
{
    while let Some(Inbound {
        envelope,
        fds,
        responder,
    }) = inbox.accept().await
    {
        let message = match envelope.into_message::<<S::Interface as Interface>::Message>(fds) {
            Ok(message) => message,
            // A malformed message — drop it; a well-formed peer sends
            // none.
            Err(_) => continue,
        };
        // The §3.3 object-rights check, before the handler sees anything.
        if !rights_allow(object_rights, message.method_id()) {
            if let Some(responder) = responder {
                let _ = responder.refuse().await;
            }
            continue;
        }
        service.handle(message, Reply { responder }).await;
    }
}

/// Whether `object_rights` grants the method of ordinal `method_id`. A
/// method past ordinal 31 has no bit in the `u32` mask, so it is never
/// granted (§3.3).
#[cfg(target_os = "freebsd")]
fn rights_allow(object_rights: u32, method_id: u16) -> bool {
    method_id < 32 && (object_rights & (1u32 << method_id)) != 0
}
