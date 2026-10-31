//! de/ctls: a TLS client over OpenSSL (P18.12a), with the `tls` feature.
//! The certificate must chain to a trusted CA (the system's, or a file's)
//! and name the host; TLS 1.2 at least.

use libc::{c_char, c_int, c_long, c_void};
use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd};

#[repr(C)]
struct ApTls {
    _p: [u8; 0],
}

unsafe extern "C" {
    fn ap_tls_open(fd: c_int, host: *const c_char, cafile: *const c_char, err: *mut c_char, errlen: usize) -> *mut ApTls;
    fn ap_tls_read(t: *mut ApTls, buf: *mut c_void, len: usize) -> c_long;
    fn ap_tls_write(t: *mut ApTls, buf: *const c_void, len: usize) -> c_long;
    fn ap_tls_close(t: *mut ApTls);
}

/// A TLS session on a connected socket. The socket must outlive it.
pub struct Tls(*mut ApTls);

impl Tls {
    /// The handshake, verified; or OpenSSL's reason, in words.
    pub fn open(fd: BorrowedFd<'_>, host: &str, cafile: Option<&str>) -> Result<Tls, String> {
        let h = CString::new(host).map_err(|_| "a host holds a NUL".to_owned())?;
        let ca = cafile.map(CString::new).transpose().map_err(|_| "a path holds a NUL".to_owned())?;
        let mut err = [0 as c_char; 512];
        let t = unsafe { ap_tls_open(fd.as_raw_fd(), h.as_ptr(), ca.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()), err.as_mut_ptr(), err.len()) };
        if t.is_null() {
            let bytes: Vec<u8> = err.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
            return Err(String::from_utf8_lossy(&bytes).into_owned());
        }
        Ok(Tls(t))
    }
}

impl io::Read for Tls {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = unsafe { ap_tls_read(self.0, buf.as_mut_ptr().cast(), buf.len()) };
        if n < 0 {
            return Err(io::Error::other("the TLS connection failed"));
        }
        Ok(n as usize)
    }
}

impl io::Write for Tls {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let n = unsafe { ap_tls_write(self.0, buf.as_ptr().cast(), buf.len()) };
        if n <= 0 {
            return Err(io::Error::other("the TLS connection failed"));
        }
        Ok(n as usize)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for Tls {
    fn drop(&mut self) {
        unsafe { ap_tls_close(self.0) }
    }
}
