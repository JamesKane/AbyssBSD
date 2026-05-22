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

use abyss_looper::{Receiver, RingClosed, Sender, TrySendError, channel};

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
    /// An in-process `abyss-looper` channel of typed messages.
    Local(Sender<I::Message>),
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
pub fn cap_channel<I: Interface, R: Rights>(capacity: usize) -> (Cap<I, R>, Receiver<I::Message>) {
    let (sender, receiver) = channel(capacity);
    (
        Cap {
            backend: Backend::Local(sender),
            _marker: PhantomData,
        },
        receiver,
    )
}

impl<I: Interface, R: Rights> Cap<I, R> {
    /// Send a message. Awaiting suspends the calling handler — never the
    /// looper thread — if the ring is full (§3.1).
    pub async fn send(&self, msg: I::Message) -> Result<(), RingClosed> {
        match &self.backend {
            Backend::Local(sender) => sender.send(msg).await,
        }
    }

    /// Send without waiting; on a full ring the message is returned.
    pub fn try_send(&self, msg: I::Message) -> Result<(), TrySendError<I::Message>> {
        match &self.backend {
            Backend::Local(sender) => sender.try_send(msg),
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

    /// Request/reply (§6). `build` is handed a fresh reply [`Sender`] to
    /// embed in the request message; the reply is awaited on the matching
    /// receiver. Awaiting suspends the calling handler, never the thread.
    ///
    /// `Err(RingClosed)` means the peer was gone before it could reply.
    pub async fn call<Rep, F>(&self, build: F) -> Result<Rep, RingClosed>
    where
        Rep: Send + 'static,
        F: FnOnce(Sender<Rep>) -> I::Message,
    {
        match &self.backend {
            Backend::Local(sender) => {
                let (reply_tx, mut reply_rx) = channel::<Rep>(1);
                sender.send(build(reply_tx)).await?;
                reply_rx.recv().await
            }
        }
    }
}
