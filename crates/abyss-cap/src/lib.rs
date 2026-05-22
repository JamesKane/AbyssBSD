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
//! The `Wire` impl that puts a `Cap` through that body — pulling its fd
//! onto `SCM_RIGHTS` — is the next Gate D step; in-process (Phase 2) a
//! capability moves as an ordinary value, with no serialization to do.

#![forbid(unsafe_code)]

mod rights;
mod wire;

pub use rights::{Rights, SubsetOf};
pub use wire::{CAP_BODY_LEN, CapBody, CapBodyError, KIND_FD_CAPABILITY};

use std::marker::PhantomData;

use abyss_looper::{Delivery, Receiver, RingClosed, Sender, TrySendError, channel, responder};
use abyss_msg::Request;

#[cfg(target_os = "freebsd")]
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};

#[cfg(target_os = "freebsd")]
use abyss_msg::{Envelope, Header, Method, Wire};
#[cfg(target_os = "freebsd")]
use abyss_transport::Connection;

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

/// The ring a [`Cap`] dispatches to (`broker-and-transport.md` §2.8).
/// `Local` is the in-process ring (looper-framework §3); the IPC backend
/// joins it as the FreeBSD transport work lands.
enum Backend<I: Interface> {
    /// An in-process `abyss-looper` channel. It carries a [`Delivery`] —
    /// a message and, for a request, the responder that answers it.
    Local(Sender<Delivery<I::Message>>),
    /// An IPC ring — a `SOCK_SEQPACKET` connection. `encode` is the
    /// message-to-envelope function captured when the ring was built,
    /// where `I::Message: Wire + Method` was in scope (§2.8, §2.9); it
    /// lets the `Cap` methods serialize without that bound themselves.
    #[cfg(target_os = "freebsd")]
    Ipc {
        connection: Connection,
        encode: fn(&I::Message) -> (Envelope, Vec<OwnedFd>),
    },
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
/// ring (`broker-and-transport.md` §2.8). The broker builds these as it
/// wires the authority graph (§5.2); [`cap_channel`] is the in-process
/// counterpart.
///
/// The `Wire` and `Method` bounds are this constructor's, not the
/// [`Interface`] trait's (§2.9): they are needed only to build an IPC
/// ring, so the message serializer is captured here, and `Cap`'s own
/// methods carry no such bound.
#[cfg(target_os = "freebsd")]
pub fn ipc_cap<I, R>(connection: Connection) -> Cap<I, R>
where
    I: Interface,
    R: Rights,
    I::Message: Wire + Method,
{
    Cap {
        backend: Backend::Ipc {
            connection,
            encode: encode_message::<I>,
        },
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
            Backend::Ipc { connection, encode } => {
                let (envelope, fds) = (*encode)(&msg);
                let borrowed: Vec<BorrowedFd<'_>> = fds.iter().map(AsFd::as_fd).collect();
                // A broken IPC ring is, to the holder of the capability,
                // a closed ring — the peer can no longer be reached.
                connection
                    .send(&envelope, &borrowed)
                    .await
                    .map_err(|_| RingClosed)
            }
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
            Backend::Ipc { .. } => todo!("Cap::try_send over an IPC ring is not yet wired"),
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
    /// `Err(RingClosed)` means the peer was gone before it could reply.
    pub async fn call<Q>(&self, request: Q) -> Result<Q::Reply, RingClosed>
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
                reply_rx.recv().await
            }
            #[cfg(target_os = "freebsd")]
            Backend::Ipc { connection, encode } => {
                let (envelope, fds) = (*encode)(&request.into());
                let borrowed: Vec<BorrowedFd<'_>> = fds.iter().map(AsFd::as_fd).collect();
                let (reply_envelope, reply_fds) = connection
                    .call(&envelope, &borrowed)
                    .await
                    .map_err(|_| RingClosed)?;
                reply_envelope
                    .into_message::<Q::Reply>(reply_fds)
                    .map_err(|_| RingClosed)
            }
        }
    }
}
