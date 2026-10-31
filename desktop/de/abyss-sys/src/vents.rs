//! de/cvents, and the libc calls Vents makes directly: the C floor under
//! the FreeBSD hardware bridges. sysctl, kenv, the OSS mixer, sndstat and
//! the process table are C (cvents.c); getifaddrs,
//! poll and getpwuid are libc's. Everything comes back owned or copied, so
//! nothing above this file holds a pointer.

use libc::{c_char, c_int, c_long, c_uchar};
use std::ffi::{CStr, CString};
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd};

pub use libc::{IFF_LOOPBACK, IFF_UP};

/// `struct av_proc`, as cvents.h lays it out.
#[repr(C)]
#[derive(Clone, Copy)]
struct AvProc {
    pid: i32,
    ppid: i32,
    uid: u32,
    threads: i32,
    rss_bytes: u64,
    vsize_bytes: u64,
    cpu_usec: u64,
    start_sec: i64,
    state: c_char,
    system: u8,
    name: [c_char; 40],
}

unsafe extern "C" {
    fn av_sysctl_read(name: *const c_char, buf: *mut libc::c_void, len: usize) -> c_long;
    fn av_kenv_read(name: *const c_char, buf: *mut c_char, len: usize) -> c_long;
    fn av_sysctl_supported() -> c_int;
    fn av_mixer_open(path: *const c_char) -> c_int;
    fn av_mixer_get_volume(fd: c_int, level: *mut c_int) -> c_int;
    fn av_mixer_set_volume(fd: c_int, level: *mut c_int) -> c_int;
    fn av_if_link(ifname: *const c_char) -> c_int;
    fn av_if_mac(ifname: *const c_char, out: *mut c_uchar) -> c_int;
    fn av_route_watch_open() -> c_int;
    fn av_route_watch_drain(fd: c_int) -> c_int;
    fn av_sndstat_read(buf: *mut c_char, len: usize) -> c_long;
    fn av_mixer_describe(unit: c_int, buf: *mut c_char, len: usize) -> c_long;
    fn av_mixer_set(unit: c_int, control: *const c_char, left: c_int, right: c_int) -> c_int;
    fn av_mixer_mute(unit: c_int, control: *const c_char, muted: c_int) -> c_int;
    fn av_proc_list(out: *mut AvProc, max: c_int) -> c_int;
    fn av_memory(total: *mut u64, available: *mut u64) -> c_int;
}

fn cstr(s: &str) -> Option<CString> {
    CString::new(s).ok()
}

/// The text a C reader left in `buf`, up to its NUL, as lenient UTF-8.
fn text(buf: &[u8]) -> String {
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

// MARK: sysctl and kenv

/// Whether this platform answers sysctl (and kenv) at all: false on Linux,
/// where cvents is stubs.
pub fn sysctl_supported() -> bool {
    unsafe { av_sysctl_supported() != 0 }
}

/// A sysctl's bytes, or None when there is no such name: the two-call
/// dance, size then value.
pub fn sysctl_read(name: &str) -> Option<Vec<u8>> {
    let n = cstr(name)?;
    let size = unsafe { av_sysctl_read(n.as_ptr(), std::ptr::null_mut(), 0) };
    if size < 0 {
        return None;
    }
    let mut buf = vec![0u8; size as usize];
    if buf.is_empty() {
        return Some(buf);
    }
    let got = unsafe { av_sysctl_read(n.as_ptr(), buf.as_mut_ptr().cast(), buf.len()) };
    if got < 0 {
        return None;
    }
    buf.truncate(got as usize);
    Some(buf)
}

/// A kernel-environment variable, or None when it is not set. kenv(2)
/// caps a value well under 1024.
pub fn kenv_read(name: &str) -> Option<String> {
    let n = cstr(name)?;
    let mut buf = vec![0u8; 1024];
    let got = unsafe { av_kenv_read(n.as_ptr(), buf.as_mut_ptr().cast(), buf.len()) };
    (got >= 0).then(|| text(&buf))
}

// MARK: the OSS mixer

/// Open `path`, or `/dev/mixer` then `/dev/mixer0`.
pub fn mixer_open(path: Option<&str>) -> io::Result<OwnedFd> {
    let p = path.map(cstr).map(|c| c.ok_or_else(|| io::Error::from_raw_os_error(libc::EINVAL))).transpose()?;
    let fd = unsafe { av_mixer_open(p.as_ref().map_or(std::ptr::null(), |c| c.as_ptr())) };
    if fd < 0 { Err(io::Error::last_os_error()) } else { Ok(unsafe { OwnedFd::from_raw_fd(fd) }) }
}

/// The master level, packed as OSS packs it.
pub fn mixer_get_volume(fd: BorrowedFd<'_>) -> Option<i32> {
    let mut v: c_int = 0;
    (unsafe { av_mixer_get_volume(fd.as_raw_fd(), &mut v) } == 0).then_some(v)
}

/// Set the master level; what the kernel applied.
pub fn mixer_set_volume(fd: BorrowedFd<'_>, level: i32) -> Option<i32> {
    let mut v: c_int = level;
    (unsafe { av_mixer_set_volume(fd.as_raw_fd(), &mut v) } == 0).then_some(v)
}

/// A device's controls, as cvents' `ctl` lines; None without a mixer.
pub fn mixer_describe(unit: i32) -> Option<String> {
    let mut buf = vec![0u8; 65536];
    let n = unsafe { av_mixer_describe(unit, buf.as_mut_ptr().cast(), buf.len()) };
    (n >= 0).then(|| text(&buf))
}

pub fn mixer_set(unit: i32, control: &str, left: i32, right: i32) -> io::Result<()> {
    let c = cstr(control).ok_or_else(|| io::Error::from_raw_os_error(libc::EINVAL))?;
    if unsafe { av_mixer_set(unit, c.as_ptr(), left, right) } == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

pub fn mixer_mute(unit: i32, control: &str, muted: bool) -> io::Result<()> {
    let c = cstr(control).ok_or_else(|| io::Error::from_raw_os_error(libc::EINVAL))?;
    if unsafe { av_mixer_mute(unit, c.as_ptr(), muted.into()) } == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

/// /dev/sndstat's devices and channels, as cvents' `dev` and `chan` lines;
/// None where there is none (Linux).
pub fn sndstat_read() -> Option<String> {
    let mut buf = vec![0u8; 65536];
    let n = unsafe { av_sndstat_read(buf.as_mut_ptr().cast(), buf.len()) };
    (n >= 0).then(|| text(&buf))
}

// MARK: the network

/// 1 up, 0 down, -1 unknown.
pub fn if_link(ifname: &str) -> i32 {
    cstr(ifname).map_or(-1, |c| unsafe { av_if_link(c.as_ptr()) })
}

pub fn if_mac(ifname: &str) -> Option<[u8; 6]> {
    let c = cstr(ifname)?;
    let mut out = [0u8; 6];
    (unsafe { av_if_mac(c.as_ptr(), out.as_mut_ptr()) } == 0).then_some(out)
}

/// A routing socket (rtnetlink on Linux), non-blocking.
pub fn route_watch_open() -> Option<OwnedFd> {
    let fd = unsafe { av_route_watch_open() };
    (fd >= 0).then(|| unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Read all that is waiting; whether anything was.
pub fn route_watch_drain(fd: BorrowedFd<'_>) -> bool {
    unsafe { av_route_watch_drain(fd.as_raw_fd()) == 1 }
}

/// One `getifaddrs` entry: its interface, flags and, for IPv4, the address
/// and netmask in host order.
pub struct IfAddr {
    pub name: String,
    pub flags: u32,
    pub ipv4: Option<(u32, Option<u32>)>,
}

/// Every `getifaddrs` entry, in the kernel's order.
pub fn ifaddrs() -> Vec<IfAddr> {
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return vec![];
    }
    let mut out = vec![];
    let mut p = head;
    while !p.is_null() {
        let a = unsafe { &*p };
        p = a.ifa_next;
        if a.ifa_name.is_null() {
            continue;
        }
        let name = unsafe { CStr::from_ptr(a.ifa_name) }.to_string_lossy().into_owned();
        let v4 = |sa: *const libc::sockaddr| -> Option<u32> {
            if sa.is_null() || unsafe { (*sa).sa_family } as i32 != libc::AF_INET {
                return None;
            }
            Some(u32::from_be(unsafe { (*(sa as *const libc::sockaddr_in)).sin_addr.s_addr }))
        };
        let ipv4 = v4(a.ifa_addr).map(|addr| {
            let mask = (!a.ifa_netmask.is_null()).then(|| u32::from_be(unsafe { (*(a.ifa_netmask as *const libc::sockaddr_in)).sin_addr.s_addr }));
            (addr, mask)
        });
        out.push(IfAddr { name, flags: a.ifa_flags as u32, ipv4 });
    }
    unsafe { libc::freeifaddrs(head) };
    out
}

// MARK: processes and memory

/// One process, as cvents reads it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcRecord {
    pub pid: i32,
    pub ppid: i32,
    pub uid: u32,
    pub threads: i32,
    pub rss_bytes: u64,
    pub vsize_bytes: u64,
    pub cpu_usec: u64,
    pub start_sec: i64,
    pub state: u8,
    pub system: bool,
    pub name: String,
}

/// Up to `max` processes; Ok(n == max) means ask again, bigger.
pub fn proc_list(max: usize) -> io::Result<Vec<ProcRecord>> {
    let zero = AvProc { pid: 0, ppid: 0, uid: 0, threads: 0, rss_bytes: 0, vsize_bytes: 0, cpu_usec: 0, start_sec: 0, state: 0, system: 0, name: [0; 40] };
    let mut buf = vec![zero; max];
    let n = unsafe { av_proc_list(buf.as_mut_ptr(), max.min(i32::MAX as usize) as c_int) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(buf[..n as usize]
        .iter()
        .map(|p| ProcRecord {
            pid: p.pid,
            ppid: p.ppid,
            uid: p.uid,
            threads: p.threads,
            rss_bytes: p.rss_bytes,
            vsize_bytes: p.vsize_bytes,
            cpu_usec: p.cpu_usec,
            start_sec: p.start_sec,
            state: p.state as u8,
            system: p.system != 0,
            name: text(&p.name.map(|c| c as u8)),
        })
        .collect())
}

/// Physical memory, and how much is available without paging.
pub fn memory() -> (u64, u64) {
    let (mut t, mut a) = (0u64, 0u64);
    unsafe { av_memory(&mut t, &mut a) };
    (t, a)
}

/// The name an account goes by, or None.
pub fn user_name(uid: u32) -> Option<String> {
    crate::users::by_uid(uid).map(|a| a.name)
}

/// Wait up to `timeout_ms` for `fd` to be readable (or hung up).
pub fn poll_readable(fd: BorrowedFd<'_>, timeout_ms: i32) -> bool {
    let mut p = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    unsafe { libc::poll(&mut p, 1, timeout_ms) > 0 }
}
