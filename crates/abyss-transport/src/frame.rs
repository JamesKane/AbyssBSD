// SPDX-License-Identifier: BSD-2-Clause

//! The IPC ring frame (`docs/design/broker-and-transport.md` §2.6).
//!
//! On the IPC backend a datagram is a fixed 8-byte [`RingFrame`] followed
//! by an envelope. The frame is the IPC ring's own protocol layer — it
//! carries the request/reply correlation id — and the envelope inside
//! (wire-format §3) is unchanged, so `abyss-msg` and the Gate A wire
//! format are untouched.
//!
//! The frame is plain bytes with no platform dependency, so it is built
//! and tested on every host, not only FreeBSD.

/// The encoded size of a ring frame, in bytes.
pub const RING_FRAME_LEN: usize = 8;

/// What an IPC datagram carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameKind {
    /// A message inbound to a handler — a Request, Command, or Event, by
    /// the envelope's own `MessageKind`.
    Message,
    /// A reply to an earlier Request, matched by `correlation`.
    Reply,
    /// A refusal of an earlier Request, matched by `correlation` — the
    /// service declined it, for want of rights or otherwise (§3.6). It
    /// carries no meaningful payload.
    Error,
}

/// The fixed 8-byte header an IPC ring puts ahead of every envelope.
///
/// Layout: `kind` (1 byte), 3 reserved bytes (zero), `correlation`
/// (`u32`, little-endian).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RingFrame {
    /// Whether this datagram is a message or a reply.
    pub kind: FrameKind,
    /// The request/reply correlation id. A Request carries a fresh id and
    /// its reply echoes it; a Command, an Event, or any non-correlated
    /// message carries `0` (§2.7).
    pub correlation: u32,
}

impl RingFrame {
    /// Encode the frame into its 8 bytes.
    pub fn encode(&self) -> [u8; RING_FRAME_LEN] {
        let mut out = [0u8; RING_FRAME_LEN];
        out[0] = match self.kind {
            FrameKind::Message => 0,
            FrameKind::Reply => 1,
            FrameKind::Error => 2,
        };
        // out[1..4] are reserved and stay zero.
        out[4..8].copy_from_slice(&self.correlation.to_le_bytes());
        out
    }

    /// Decode a frame from the first [`RING_FRAME_LEN`] bytes of `bytes`;
    /// any further bytes (the envelope) are ignored. Total — a malformed
    /// frame is a [`FrameError`], never a panic.
    pub fn decode(bytes: &[u8]) -> Result<RingFrame, FrameError> {
        if bytes.len() < RING_FRAME_LEN {
            return Err(FrameError::Short);
        }
        let kind = match bytes[0] {
            0 => FrameKind::Message,
            1 => FrameKind::Reply,
            2 => FrameKind::Error,
            other => return Err(FrameError::BadKind(other)),
        };
        let correlation = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
        Ok(RingFrame { kind, correlation })
    }
}

/// A ring frame that could not be decoded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameError {
    /// Fewer than [`RING_FRAME_LEN`] bytes were available.
    Short,
    /// The `kind` byte was not a known [`FrameKind`].
    BadKind(u8),
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FrameError::Short => {
                write!(f, "ring frame is shorter than {RING_FRAME_LEN} bytes")
            }
            FrameError::BadKind(byte) => {
                write!(f, "unknown ring frame kind byte {byte}")
            }
        }
    }
}

impl std::error::Error for FrameError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_a_message_frame() {
        let frame = RingFrame {
            kind: FrameKind::Message,
            correlation: 0,
        };
        let bytes = frame.encode();
        assert_eq!(bytes.len(), RING_FRAME_LEN);
        assert_eq!(RingFrame::decode(&bytes), Ok(frame));
    }

    #[test]
    fn round_trips_a_reply_frame() {
        let frame = RingFrame {
            kind: FrameKind::Reply,
            correlation: 0xDEAD_BEEF,
        };
        assert_eq!(RingFrame::decode(&frame.encode()), Ok(frame));
    }

    #[test]
    fn round_trips_an_error_frame() {
        let frame = RingFrame {
            kind: FrameKind::Error,
            correlation: 0x00C0_FFEE,
        };
        assert_eq!(RingFrame::decode(&frame.encode()), Ok(frame));
    }

    #[test]
    fn kind_and_correlation_land_in_the_right_bytes() {
        let bytes = RingFrame {
            kind: FrameKind::Reply,
            correlation: 1,
        }
        .encode();
        assert_eq!(bytes[0], 1, "kind byte");
        assert_eq!(&bytes[1..4], &[0, 0, 0], "reserved bytes");
        assert_eq!(
            &bytes[4..8],
            &1u32.to_le_bytes(),
            "correlation, little-endian"
        );
    }

    #[test]
    fn decode_rejects_a_short_frame() {
        assert_eq!(RingFrame::decode(&[0u8; 4]), Err(FrameError::Short));
        assert_eq!(RingFrame::decode(&[]), Err(FrameError::Short));
    }

    #[test]
    fn decode_rejects_an_unknown_kind() {
        let mut bytes = [0u8; RING_FRAME_LEN];
        bytes[0] = 9;
        assert_eq!(RingFrame::decode(&bytes), Err(FrameError::BadKind(9)));
    }

    #[test]
    fn decode_reads_only_the_header() {
        // A real datagram is the frame followed by the envelope; decode
        // takes the first 8 bytes and leaves the rest alone.
        let frame = RingFrame {
            kind: FrameKind::Message,
            correlation: 7,
        };
        let mut datagram = frame.encode().to_vec();
        datagram.extend_from_slice(b"...the envelope would follow here...");
        assert_eq!(RingFrame::decode(&datagram), Ok(frame));
    }
}
