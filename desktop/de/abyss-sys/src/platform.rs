//! The descriptor-passing and peer calls of de/cplatform: SCM_RIGHTS lives
//! in C because cmsg(3) is all macros (the same reason as for Swift), and
//! the peer's uid is a different call on each system. Safe wrappers: a
//! received descriptor comes back owned, so nothing leaks or double-closes.

use libc::{c_int, c_long, c_uint, c_void};
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};

/// Most descriptors one call carries (`AP_MAX_FDS`).
pub const MAX_FDS: usize = 16;

unsafe extern "C" {
    fn ap_sendmsg_fds(sock: c_int, buf: *const c_void, len: usize, fds: *const c_int, nfds: c_int) -> c_long;
    fn ap_send_all(sock: c_int, buf: *const c_void, len: usize) -> c_int;
    fn ap_socket_nosigpipe(sock: c_int) -> c_int;
    fn ap_recvmsg_fds(
        sock: c_int,
        buf: *mut c_void,
        len: usize,
        fds: *mut c_int,
        max_fds: c_int,
        nfds_out: *mut c_int,
    ) -> c_long;
    fn ap_peer_uid(sock: c_int, uid: *mut c_uint) -> c_int;
}

/// `sendmsg` of `buf` (non-empty: SCM_RIGHTS rides on payload) with `fds`
/// attached. Sending a number that is not an open descriptor is EBADF, not
/// undefined behaviour, so the descriptors are plain `RawFd`s the caller
/// keeps open until this returns.
pub fn sendmsg_fds(sock: BorrowedFd<'_>, buf: &[u8], fds: &[RawFd]) -> io::Result<usize> {
    if fds.len() > MAX_FDS {
        return Err(io::Error::from_raw_os_error(libc::EINVAL));
    }
    let n = unsafe {
        ap_sendmsg_fds(
            sock.as_raw_fd(),
            buf.as_ptr() as *const c_void,
            buf.len(),
            if fds.is_empty() { std::ptr::null() } else { fds.as_ptr() },
            fds.len() as c_int,
        )
    };
    if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n as usize) }
}

/// Write all of `buf` with MSG_NOSIGNAL: a peer that has gone is EPIPE, never
/// SIGPIPE.
pub fn send_all(sock: BorrowedFd<'_>, buf: &[u8]) -> io::Result<()> {
    let rc = unsafe { ap_send_all(sock.as_raw_fd(), buf.as_ptr() as *const c_void, buf.len()) };
    if rc != 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
}

/// SO_NOSIGPIPE where the system has it; nothing elsewhere.
pub fn socket_nosigpipe(sock: BorrowedFd<'_>) {
    unsafe { ap_socket_nosigpipe(sock.as_raw_fd()) };
}

/// `recvmsg` into `buf`, with whatever descriptors rode along, owned.
/// `Ok((0, _))` is the peer having closed.
pub fn recvmsg_fds(sock: BorrowedFd<'_>, buf: &mut [u8]) -> io::Result<(usize, Vec<OwnedFd>)> {
    let mut raw = [-1 as c_int; MAX_FDS];
    let mut n_fds: c_int = 0;
    let n = unsafe {
        ap_recvmsg_fds(
            sock.as_raw_fd(),
            buf.as_mut_ptr() as *mut c_void,
            buf.len(),
            raw.as_mut_ptr(),
            MAX_FDS as c_int,
            &mut n_fds,
        )
    };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    // The kernel installed these in our table; each is ours exactly once.
    let fds = raw[..n_fds.clamp(0, MAX_FDS as c_int) as usize]
        .iter()
        .map(|&f| unsafe { OwnedFd::from_raw_fd(f) })
        .collect();
    Ok((n as usize, fds))
}

/// The effective uid of the peer of a connected unix socket.
pub fn peer_uid(sock: BorrowedFd<'_>) -> io::Result<u32> {
    let mut uid: c_uint = 0;
    if unsafe { ap_peer_uid(sock.as_raw_fd(), &mut uid) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(uid)
}

/// This process's effective uid.
pub fn euid() -> u32 {
    unsafe { libc::geteuid() }
}

/// Whether `fd` is an open descriptor in this process (`fcntl(F_GETFD)`):
/// for tests that check a descriptor was really closed.
pub fn fd_is_open(fd: RawFd) -> bool {
    unsafe { libc::fcntl(fd, libc::F_GETFD) != -1 }
}

/// Whether `fd` has O_NONBLOCK set.
pub fn is_nonblocking(fd: BorrowedFd<'_>) -> io::Result<bool> {
    let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(flags & libc::O_NONBLOCK != 0)
}

unsafe extern "C" {
    fn ap_crypt_sha512(password: *const libc::c_char, out: *mut libc::c_char, len: usize) -> c_int;
}

/// A crypt(3) SHA-512 hash of `password` with a fresh random salt, as
/// `pw -H 0` takes it; None if crypt refused.
pub fn crypt_sha512(password: &str) -> Option<String> {
    let pw = std::ffi::CString::new(password).ok()?;
    let mut out = [0 as libc::c_char; 256];
    if unsafe { ap_crypt_sha512(pw.as_ptr(), out.as_mut_ptr(), out.len()) } != 0 {
        return None;
    }
    let s = unsafe { std::ffi::CStr::from_ptr(out.as_ptr()) };
    Some(s.to_string_lossy().into_owned())
}

/// The interface's index, or None when there is no interface by that name.
pub fn interface_index(name: &str) -> Option<u32> {
    let n = std::ffi::CString::new(name).ok()?;
    let i = unsafe { libc::if_nametoindex(n.as_ptr()) };
    (i != 0).then_some(i)
}

/// Now in local time, `YYYY-MM-DD HH:MM:SS`: a journal's stamp.
pub fn local_timestamp() -> String {
    let t = unsafe { libc::time(std::ptr::null_mut()) };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::localtime_r(&t, &mut tm) }.is_null() {
        return String::new();
    }
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec
    )
}

/// Bytes free to an unprivileged writer on the volume holding `path`.
pub fn free_space(path: &str) -> Option<u64> {
    let p = std::ffi::CString::new(path).ok()?;
    let mut v: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(p.as_ptr(), &mut v) } != 0 {
        return None;
    }
    Some(v.f_bavail as u64 * v.f_frsize as u64)
}

/// Now in local time: (hour 0…23, minute, weekday 0 = Sunday). A menu
/// bar's clock.
/// The time `t` (seconds since the epoch, or now when None) broken down,
/// in the local zone or UTC: year, month 1–12, day, hour, minute, second.
pub fn civil_time(t: Option<i64>, utc: bool) -> Option<[i32; 6]> {
    let t: libc::time_t = t.map_or_else(|| unsafe { libc::time(std::ptr::null_mut()) }, |t| t as libc::time_t);
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let r = if utc { unsafe { libc::gmtime_r(&t, &mut tm) } } else { unsafe { libc::localtime_r(&t, &mut tm) } };
    (!r.is_null()).then_some([tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec])
}

pub fn local_clock() -> Option<(i32, i32, i32)> {
    let t = unsafe { libc::time(std::ptr::null_mut()) };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::localtime_r(&t, &mut tm) }.is_null() {
        return None;
    }
    Some((tm.tm_hour, tm.tm_min, tm.tm_wday))
}

/// Whether `fd` was opened for writing (O_WRONLY or O_RDWR).
pub fn is_writable(fd: BorrowedFd<'_>) -> io::Result<bool> {
    let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(flags & libc::O_ACCMODE != libc::O_RDONLY)
}

/// `secs` since the epoch as local HH:MM:SS: a transcript's clock.
pub fn local_time_of_day(secs: i64) -> String {
    let t = secs as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::localtime_r(&t, &mut tm) }.is_null() {
        return String::new();
    }
    format!("{:02}:{:02}:{:02}", tm.tm_hour, tm.tm_min, tm.tm_sec)
}

unsafe extern "C" {
    fn ap_request_realtime(priority: libc::c_int) -> libc::c_int;
}

/// Real-time priority for this process (FreeBSD rtprio(2), 0 highest, 31
/// lowest): root's, or group `realtime`'s with mac_priority(4) loaded.
/// Elsewhere, and refused, the error says why.
pub fn request_realtime(priority: i32) -> std::io::Result<()> {
    if unsafe { ap_request_realtime(priority) } == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}
