// SPDX-License-Identifier: BSD-2-Clause

//! Ring errors (`docs/design/looper-framework.md` §3.2).

use std::fmt;

/// The peer endpoint of a ring is gone — its sole receiver was dropped, or
/// its last sender was.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RingClosed;

impl fmt::Display for RingClosed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ring closed: the peer endpoint is gone")
    }
}

impl std::error::Error for RingClosed {}

/// Failure of a non-blocking [`try_send`](crate::Sender::try_send). The
/// message is handed back so the caller does not lose it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrySendError<M> {
    /// The ring was at capacity.
    Full(M),
    /// The ring is closed — the receiver is gone.
    Closed(M),
}

/// Failure of a non-blocking [`try_recv`](crate::Receiver::try_recv).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TryRecvError {
    /// The ring was empty, but senders remain — try again later.
    Empty,
    /// The ring is empty and closed — every sender is gone.
    Closed,
}
