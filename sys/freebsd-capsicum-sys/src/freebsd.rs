// SPDX-License-Identifier: BSD-2-Clause

//! The FreeBSD Capsicum binding — compiled only on FreeBSD.
//!
//! The `extern` declarations here match `c/capsicum_shim.c`; the safe
//! wrappers are what the broker programs against. Both are verified when
//! the crate is first built on FreeBSD.

use std::ffi::c_uint;
use std::io;
use std::os::fd::RawFd;

/// An object-rights set, passed to the shim and translated to a
/// `cap_rights_t` there.
///
/// The bit values mirror the `ABYSS_CAP_*` macros in `capsicum_shim.c` —
/// the two definitions must stay in lock-step.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rights(u64);

impl Rights {
    /// `CAP_READ` — read, `recv`.
    pub const READ: Self = Self(1 << 0);
    /// `CAP_WRITE` — write, `send`.
    pub const WRITE: Self = Self(1 << 1);
    /// `CAP_MMAP` — map the descriptor into memory.
    pub const MMAP: Self = Self(1 << 2);
    /// `CAP_IOCTL` — issue `ioctl`s (further narrowable with `cap_ioctls_limit`).
    pub const IOCTL: Self = Self(1 << 3);
    /// `CAP_EVENT` — `poll`/`kqueue` the descriptor.
    pub const EVENT: Self = Self(1 << 4);
    /// `CAP_FSTAT` — `fstat` the descriptor.
    pub const FSTAT: Self = Self(1 << 5);
    /// `CAP_SEND` — send on a socket.
    pub const SEND: Self = Self(1 << 6);
    /// `CAP_RECV` — receive on a socket.
    pub const RECV: Self = Self(1 << 7);
    /// `CAP_FCNTL` — issue `fcntl`s (the async transport sets a ring
    /// non-blocking with `fcntl(F_SETFL)`).
    pub const FCNTL: Self = Self(1 << 8);

    /// No rights at all.
    pub const fn empty() -> Self {
        Self(0)
    }

    /// This set together with another — the union.
    pub const fn with(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

unsafe extern "C" {
    fn abyss_cap_enter() -> i32;
    fn abyss_cap_rights_size() -> usize;
    fn abyss_cap_rights_build(out: *mut u8, flags: u64);
    fn abyss_cap_rights_limit(fd: RawFd, rights: *const u8) -> i32;
    fn abyss_cap_getmode(modep: *mut c_uint) -> i32;
}

/// Enter Capsicum capability mode — irreversibly (`broker-and-transport.md`
/// §5.4). After this the process can name nothing it does not already hold.
pub fn cap_enter() -> io::Result<()> {
    // SAFETY: `cap_enter` takes no arguments and only ever restricts the
    // calling process; the shim forwards it directly.
    let rc = unsafe { abyss_cap_enter() };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Whether the process has entered Capsicum capability mode. Wraps
/// `cap_getmode(2)`.
pub fn cap_getmode() -> io::Result<bool> {
    let mut mode: c_uint = 0;
    // SAFETY: `mode` is a valid out-pointer for the `u_int` result.
    let rc = unsafe { abyss_cap_getmode(&mut mode) };
    if rc == 0 {
        Ok(mode != 0)
    } else {
        Err(io::Error::last_os_error())
    }
}

/// An opaque, kernel-shaped `cap_rights_t`, built from a [`Rights`] set.
pub struct CapRights {
    /// Exactly `abyss_cap_rights_size()` bytes, holding a `cap_rights_t`.
    bytes: Vec<u8>,
}

impl CapRights {
    /// The built `cap_rights_t` as raw bytes — exactly
    /// `abyss_cap_rights_size()` of them. The broker records these in a
    /// capability's handle-table body (`broker-and-transport.md` §3.2).
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    /// Build a `cap_rights_t` from an object-rights set.
    pub fn new(rights: Rights) -> Self {
        // SAFETY: `abyss_cap_rights_size` returns `sizeof(cap_rights_t)`;
        // the buffer is exactly that size, and `abyss_cap_rights_build`
        // writes only within it.
        let size = unsafe { abyss_cap_rights_size() };
        let mut bytes = vec![0u8; size];
        unsafe { abyss_cap_rights_build(bytes.as_mut_ptr(), rights.0) };
        Self { bytes }
    }

    /// Limit `fd` to these rights. Wraps `cap_rights_limit(2)` — monotonic,
    /// it only ever restricts (`broker-and-transport.md` §3.3).
    pub fn limit(&self, fd: RawFd) -> io::Result<()> {
        // SAFETY: `bytes` holds a `cap_rights_t` the shim built and sized.
        let rc = unsafe { abyss_cap_rights_limit(fd, self.bytes.as_ptr()) };
        if rc == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}
