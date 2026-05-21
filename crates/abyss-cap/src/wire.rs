// SPDX-License-Identifier: BSD-2-Clause

//! The handle-table body layout for a capability —
//! `docs/design/broker-and-transport.md` §3.2.
//!
//! A `RawHandle` (abyss-msg) frames a `kind: u8` and an opaque `body`;
//! abyss-msg deliberately does not interpret the body — capability meaning
//! is this crate's. [`CapBody`] is that body for `kind`
//! [`KIND_FD_CAPABILITY`]: the metadata that travels in the datagram
//! beside a capability's fd, which itself rides `SCM_RIGHTS` (§2.2).

use std::error::Error;
use std::fmt;

/// The `RawHandle` kind of an fd capability — every capability is an fd
/// (`broker-and-transport.md` §3.1). `kind` 2 was the bus-token backing
/// and is reserved (§3.2).
pub const KIND_FD_CAPABILITY: u8 = 1;

/// The encoded length of a [`CapBody`]: the 16-byte `cap_rights_t` mask
/// followed by the 4-byte object-rights set.
pub const CAP_BODY_LEN: usize = 20;

/// The handle-table body of an fd capability (`broker-and-transport.md`
/// §3.2) — the metadata that rides in the datagram beside an fd passed
/// over `SCM_RIGHTS`. The fd itself is never in the body.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CapBody {
    /// The FreeBSD `cap_rights_t` mask the fd carries — kernel-enforced
    /// (§3.3). Sixteen bytes: FreeBSD's `cap_rights_t` is two `u64`s. It is
    /// opaque here; the broker fills it and the kernel checks it.
    pub cap_rights: [u8; 16],
    /// The per-interface object-rights set — service-enforced (§3.3); zero
    /// for a kernel-resource fd that carries no interface.
    pub object_rights: u32,
}

impl CapBody {
    /// Encode to the `body` bytes of a `RawHandle` — always [`CAP_BODY_LEN`].
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(CAP_BODY_LEN);
        out.extend_from_slice(&self.cap_rights);
        out.extend_from_slice(&self.object_rights.to_le_bytes());
        out
    }

    /// Decode from the `body` bytes of a `RawHandle`.
    pub fn decode(body: &[u8]) -> Result<CapBody, CapBodyError> {
        if body.len() != CAP_BODY_LEN {
            return Err(CapBodyError::WrongLength { found: body.len() });
        }
        let mut cap_rights = [0u8; 16];
        cap_rights.copy_from_slice(&body[..16]);
        let object_rights =
            u32::from_le_bytes(body[16..CAP_BODY_LEN].try_into().expect("four bytes"));
        Ok(CapBody {
            cap_rights,
            object_rights,
        })
    }
}

/// Why a [`CapBody`] failed to decode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapBodyError {
    /// The body was not exactly [`CAP_BODY_LEN`] bytes.
    WrongLength {
        /// The byte count the body actually had.
        found: usize,
    },
}

impl fmt::Display for CapBodyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CapBodyError::WrongLength { found } => write!(
                f,
                "a capability body must be {CAP_BODY_LEN} bytes, got {found}"
            ),
        }
    }
}

impl Error for CapBodyError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> CapBody {
        CapBody {
            cap_rights: [
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e,
                0x0f, 0x10,
            ],
            object_rights: 0xDEAD_BEEF,
        }
    }

    #[test]
    fn round_trips_through_its_body_bytes() {
        let body = sample();
        let bytes = body.encode();
        assert_eq!(bytes.len(), CAP_BODY_LEN);
        assert_eq!(CapBody::decode(&bytes), Ok(body));
    }

    #[test]
    fn object_rights_is_little_endian_after_the_rights_mask() {
        let bytes = sample().encode();
        assert_eq!(&bytes[16..], &0xDEAD_BEEF_u32.to_le_bytes());
    }

    #[test]
    fn decode_rejects_a_body_of_the_wrong_length() {
        for len in [0, CAP_BODY_LEN - 1, CAP_BODY_LEN + 1] {
            assert_eq!(
                CapBody::decode(&vec![0u8; len]),
                Err(CapBodyError::WrongLength { found: len }),
            );
        }
    }
}
