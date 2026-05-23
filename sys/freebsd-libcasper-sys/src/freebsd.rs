// SPDX-License-Identifier: BSD-2-Clause

//! The libcasper FFI — compiled only on FreeBSD.
//!
//! Binds the four functions the broker needs from `libcasper.so`:
//! `cap_init`, `cap_service_open`, `cap_close`, and `cap_sock`. The
//! signatures are verified against `<libcasper.h>` when the crate is
//! first built on FreeBSD.

use std::ffi::{CString, c_char, c_int, c_void};
use std::io;
use std::os::fd::{AsFd, BorrowedFd, RawFd};
use std::ptr::NonNull;

#[link(name = "casper")]
unsafe extern "C" {
    fn cap_init() -> *mut c_void;
    fn cap_service_open(chan: *mut c_void, name: *const c_char) -> *mut c_void;
    fn cap_close(chan: *mut c_void);
    fn cap_sock(chan: *const c_void) -> c_int;
}

/// A `cap_channel_t` — the broker's handle to libcasper.
///
/// Either the root channel ([`root`](CapChannel::root)) or a per-service
/// channel ([`open_service`](CapChannel::open_service)). Drop calls
/// `cap_close`, which closes the channel's underlying fd.
///
/// A `CapChannel` is not [`Send`]: `libcasper` channels are not
/// thread-safe, and there is no need for them to cross threads — the
/// broker uses them from one place.
#[derive(Debug)]
pub struct CapChannel {
    handle: NonNull<c_void>,
}

impl CapChannel {
    /// Open the root channel to `casperd` — `cap_init(3)`.
    ///
    /// `libcasper` forks the `casperd` helper in the calling process's
    /// tree on first call; the broker, the one component that runs
    /// unsandboxed (§5.1), is where this happens. Returns the libc error
    /// if `cap_init` fails (usually the helper could not be forked).
    pub fn root() -> io::Result<CapChannel> {
        // SAFETY: `cap_init` takes no arguments.
        let raw = unsafe { cap_init() };
        let handle = NonNull::new(raw).ok_or_else(io::Error::last_os_error)?;
        Ok(CapChannel { handle })
    }

    /// Open a per-service channel — `cap_service_open(3)`.
    ///
    /// `service` is a Casper service name (e.g. `"system.dns"`). Returns
    /// the libc error if the service is unknown to `casperd` or its
    /// helper could not be set up. An interior NUL in `service` is also
    /// reported as an error.
    pub fn open_service(&self, service: &str) -> io::Result<CapChannel> {
        let name = CString::new(service).map_err(io::Error::other)?;
        // SAFETY: `self.handle` is a live cap_channel_t; `name` is a
        // valid NUL-terminated string.
        let raw = unsafe { cap_service_open(self.handle.as_ptr(), name.as_ptr()) };
        let handle = NonNull::new(raw).ok_or_else(io::Error::last_os_error)?;
        Ok(CapChannel { handle })
    }

    /// The channel's underlying socket descriptor — `cap_sock(3)`.
    ///
    /// The `cap_channel_t` keeps owning the fd; closing the channel
    /// closes the fd. The broker passes a copy of the fd by `SCM_RIGHTS`
    /// to the child in the bootstrap bundle (the kernel duplicates the
    /// descriptor on send, so the child gets its own fd that survives
    /// the broker dropping the channel).
    pub fn as_raw_fd(&self) -> RawFd {
        // SAFETY: `self.handle` is a live cap_channel_t.
        unsafe { cap_sock(self.handle.as_ptr()) }
    }
}

impl AsFd for CapChannel {
    fn as_fd(&self) -> BorrowedFd<'_> {
        // SAFETY: `cap_sock` returns the channel's owned fd, valid for
        // the lifetime of `self`.
        unsafe { BorrowedFd::borrow_raw(self.as_raw_fd()) }
    }
}

impl Drop for CapChannel {
    fn drop(&mut self) {
        // SAFETY: `self.handle` is a live cap_channel_t we built.
        unsafe { cap_close(self.handle.as_ptr()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cap_init_opens_a_root_channel() {
        let root = CapChannel::root().expect("cap_init succeeds");
        assert!(root.as_raw_fd() >= 0, "cap_sock yields a real descriptor");
    }

    #[test]
    fn open_service_reports_a_missing_service() {
        // Whether any particular Casper service library is installed in
        // the test VM (e.g. `libcap_dns.so`) is out of this crate's
        // hands; what it owns is reporting the absence. An unknown
        // service must produce a libc-error result, not a silent success.
        let root = CapChannel::root().expect("cap_init");
        match root.open_service("system.never-existed") {
            Ok(_) => panic!("an unknown service must not open"),
            Err(err) => assert!(!err.to_string().is_empty(), "the error is reported"),
        }
    }
}
