// SPDX-License-Identifier: BSD-2-Clause

//! The libcap_dns FFI — compiled only on FreeBSD.

use std::ffi::{CString, c_char, c_int, c_void};
use std::io;

use freebsd_libcasper_sys::CapChannel;

// `libcap_dns.so` references symbols in `libcasper.so` (e.g.
// `service_register`) but does not declare it as `DT_NEEDED`, so the
// linker must — without it the dynamic loader fails to resolve the
// constructor's `service_register` call. Listing `casper` first keeps it
// before `cap_dns` on the link line, so `--as-needed` keeps both.
#[link(name = "casper")]
#[link(name = "cap_dns")]
unsafe extern "C" {
    fn cap_getaddrinfo(
        chan: *mut c_void,
        hostname: *const c_char,
        servname: *const c_char,
        hints: *const c_void,
        res: *mut *mut c_void,
    ) -> c_int;
}

// `freeaddrinfo` is libc, not libcap_dns. It belongs in `libc`/`libsys`
// but no extra link is needed — the C runtime is always linked.
unsafe extern "C" {
    fn freeaddrinfo(res: *mut c_void);
}

/// Pin one symbol from `libcap_dns.so` so the linker keeps it as
/// `DT_NEEDED` in the calling binary — the library's constructor must
/// run at process startup to register `system.dns` with `libcasper`
/// (§5.7). Idempotent and effectively a no-op at runtime.
///
/// The broker calls this; tests that exercise `system.dns` through the
/// broker call it before launching the session.
pub fn ensure_loaded() {
    // `#[used]` keeps each static alive even though nothing reads it,
    // and the function pointers force the linker to keep `-lcap_dns`
    // and `-lcasper` on the link line (so DT_NEEDED carries them and
    // their constructors run at process startup). `libcap_dns.so` calls
    // `service_register` from libcasper at load — without libcasper as
    // DT_NEEDED the dynamic loader refuses to load libcap_dns at all.
    #[used]
    static FORCE_LINK_CAP_DNS: unsafe extern "C" fn(
        *mut c_void,
        *const c_char,
        *const c_char,
        *const c_void,
        *mut *mut c_void,
    ) -> c_int = cap_getaddrinfo;
    #[used]
    static FORCE_LINK_CASPER: fn() -> io::Result<CapChannel> = CapChannel::root;
    let _ = (&FORCE_LINK_CAP_DNS, &FORCE_LINK_CASPER);
}

/// Resolve `hostname` through the Casper DNS service over `chan` (§5.7).
///
/// `chan` must be a channel opened to `system.dns`. The result list is
/// freed before return — this checks the lookup *succeeds*; a caller
/// wanting the addresses themselves needs a richer wrapping.
pub fn lookup(chan: &CapChannel, hostname: &str) -> io::Result<()> {
    let host = CString::new(hostname).map_err(io::Error::other)?;
    let mut res: *mut c_void = std::ptr::null_mut();
    // SAFETY: `chan` is a live cap_channel_t (it owns its handle);
    // `host` is a valid NUL-terminated string; `servname` and `hints`
    // are NULL (legal — `cap_getaddrinfo` accepts both); `res` is a
    // valid out-pointer.
    let rc = unsafe {
        cap_getaddrinfo(
            chan.as_raw_handle(),
            host.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            &mut res,
        )
    };
    if rc == 0 {
        // SAFETY: a successful `cap_getaddrinfo` writes a valid list.
        unsafe { freeaddrinfo(res) };
        Ok(())
    } else {
        // `cap_getaddrinfo` returns an EAI_* code, not an errno —
        // surface it as a plain io::Error::other with the code in the
        // message. A richer wrapper would translate via `gai_strerror`.
        Err(io::Error::other(format!(
            "cap_getaddrinfo failed (rc {rc})",
        )))
    }
}
