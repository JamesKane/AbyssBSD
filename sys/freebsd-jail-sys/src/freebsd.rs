// SPDX-License-Identifier: BSD-2-Clause

//! The FreeBSD jail binding — compiled only on FreeBSD.
//!
//! `jail_set(2)` consumes an array of `iovec` name/value parameters. This
//! module builds the parameter set the broker needs — a filesystem `path`,
//! a `name`, and the `persist` flag — and calls it. The exact parameter
//! encoding is verified against `<sys/jail.h>` when the crate is first
//! built on FreeBSD.

use std::ffi::{CString, c_int, c_uint, c_void};
use std::io;
use std::path::Path;
use std::ptr;

/// `JAIL_CREATE` — create a new jail (`<sys/jail.h>`).
const JAIL_CREATE: c_int = 0x01;

/// A `struct iovec` — the (base, len) pair `jail_set(2)` consumes.
#[repr(C)]
struct IoVec {
    base: *mut c_void,
    len: usize,
}

unsafe extern "C" {
    fn jail_set(iov: *mut IoVec, niov: c_uint, flags: c_int) -> c_int;
    fn jail_attach(jid: c_int) -> c_int;
    fn jail_remove(jid: c_int) -> c_int;
}

/// An `iovec` pointing at `bytes`. `jail_set` treats the parameter iovecs
/// as input only, so casting the shared pointer to `*mut` is sound here.
fn iovec(bytes: &[u8]) -> IoVec {
    IoVec {
        base: bytes.as_ptr() as *mut c_void,
        len: bytes.len(),
    }
}

/// Encode `bytes` as a NUL-terminated C string, rejecting an interior NUL.
fn cstring(bytes: &[u8]) -> io::Result<CString> {
    CString::new(bytes).map_err(|_| io::Error::other("jail parameter contains an interior NUL"))
}

/// A jail to be created — a filesystem root and a name (§5.3).
pub struct JailSpec {
    path: CString,
    name: CString,
}

impl JailSpec {
    /// Describe a jail rooted at `path`, identified by `name`.
    pub fn new(path: &Path, name: &str) -> io::Result<Self> {
        Ok(Self {
            path: cstring(path.as_os_str().as_encoded_bytes())?,
            name: cstring(name.as_bytes())?,
        })
    }

    /// Create the jail; returns its jail id (`jid`).
    pub fn create(&self) -> io::Result<c_int> {
        // jail_set takes name/value iovec pairs. `path` and `name` carry a
        // NUL-terminated string; `persist` is a valueless boolean — its
        // presence makes the jail outlive its creating process.
        let mut iov = [
            iovec(c"path".to_bytes_with_nul()),
            iovec(self.path.as_bytes_with_nul()),
            iovec(c"name".to_bytes_with_nul()),
            iovec(self.name.as_bytes_with_nul()),
            iovec(c"persist".to_bytes_with_nul()),
            IoVec {
                base: ptr::null_mut(),
                len: 0,
            },
        ];
        // SAFETY: every pointee — the `c"..."` literals and `self`'s
        // `CString`s — outlives the call, and `niov` matches the array.
        let jid = unsafe { jail_set(iov.as_mut_ptr(), iov.len() as c_uint, JAIL_CREATE) };
        if jid < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(jid)
    }
}

/// Attach the calling process to the jail `jid`. Wraps `jail_attach(2)`.
pub fn attach(jid: c_int) -> io::Result<()> {
    // SAFETY: `jail_attach` takes only the integer jail id.
    if unsafe { jail_attach(jid) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Remove the jail `jid`, killing every process in it. Wraps `jail_remove(2)`.
pub fn remove(jid: c_int) -> io::Result<()> {
    // SAFETY: `jail_remove` takes only the integer jail id.
    if unsafe { jail_remove(jid) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_then_remove_a_jail() {
        // `path = "/"` is a jail without filesystem isolation — enough to
        // exercise jail_set and jail_remove without staging a root tree.
        let name = format!("abyss-jail-test-{}", std::process::id());
        let spec = JailSpec::new(Path::new("/"), &name).expect("jail spec");
        let jid = spec.create().expect("jail_set creates the jail");
        assert!(jid > 0, "a created jail has a positive jid");
        remove(jid).expect("jail_remove tears it down");
    }
}
