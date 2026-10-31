//! de/ccap: Capsicum capability mode (PHASE7 P7.3). After `enter` the
//! process has no filesystem and no global namespace: no `open` of a path,
//! no `connect` to an address. FreeBSD only; elsewhere `supported` says no.

use libc::c_int;
use std::io;

unsafe extern "C" {
    fn ap_sandbox_supported() -> c_int;
    fn ap_sandbox_enter() -> c_int;
    fn ap_sandbox_active() -> c_int;
}

pub fn supported() -> bool {
    unsafe { ap_sandbox_supported() != 0 }
}

/// Enter capability mode. There is no way back.
pub fn enter() -> io::Result<()> {
    if unsafe { ap_sandbox_enter() } == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

/// Whether this process is in capability mode now.
pub fn active() -> bool {
    unsafe { ap_sandbox_active() == 1 }
}
