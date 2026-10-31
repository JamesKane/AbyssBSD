//! de/cjail: jail(2), jail and process descriptors, a kqueue that says when a
//! jail is removed, and the login class's limits (PHASE18 P18.2). FreeBSD
//! only: elsewhere every call fails with ENOSYS, so what is built on it
//! compiles and is tested on Linux. Descriptors come back owned.

use libc::{c_char, c_int, c_long, c_uint, c_ulonglong, c_void};
use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use std::ptr;

/// Bytes of a login class's limits (`AP_LIMITS_SIZE`).
const LIMITS_SIZE: usize = 1024;

unsafe extern "C" {
    fn ap_jail_create(keys: *const *const c_char, values: *const *const c_char, n: c_int, owning: *mut c_int, err: *mut c_char, errlen: usize) -> c_int;
    fn ap_jail_desc_by_name(name: *const c_char) -> c_int;
    fn ap_jail_identify(desc: c_int, jid: *mut c_int, name: *mut c_char, namelen: usize) -> c_int;
    fn ap_kqueue() -> c_int;
    fn ap_jail_watch(kq: c_int, desc: c_int) -> c_int;
    fn ap_jail_removed(kq: c_int) -> c_int;
    fn ap_class_limits(uid: c_uint, out: *mut c_void) -> c_int;
    fn ap_limit_of(limits: *const c_void, resource: c_int, cur: *mut c_ulonglong, max: *mut c_ulonglong) -> c_int;
    #[allow(clippy::too_many_arguments)]
    fn ap_jail_spawn(
        desc: c_int,
        uid: c_uint,
        gid: c_uint,
        argv: *const *const c_char,
        envp: *const *const c_char,
        cwd: *const c_char,
        input: c_int,
        out: c_int,
        err: c_int,
        daemon: c_int,
        limits: *const c_void,
        procfd: *mut c_int,
    ) -> c_int;
    fn ap_mount_points(buf: *mut c_char, len: usize) -> c_long;
    fn ap_procdesc_exited(procfd: c_int) -> c_int;
    fn ap_procdesc_wait(procfd: c_int) -> c_int;
}

fn c_strings(xs: &[String]) -> io::Result<Vec<CString>> {
    xs.iter().map(|s| CString::new(s.as_str()).map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))).collect()
}

/// NULL-terminated pointers to `xs`, valid while `xs` lives.
fn pointers(xs: &[CString]) -> Vec<*const c_char> {
    xs.iter().map(|c| c.as_ptr()).chain([ptr::null()]).collect()
}

fn c_text(buf: &[c_char]) -> String {
    let bytes: Vec<u8> = buf.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// Create a jail from its parameters as strings (libjail converts each),
/// and return its jid and an OWNING descriptor: closing every copy removes
/// the jail and kills what runs in it. The error is libjail's or the
/// kernel's own sentence.
pub fn create(params: &[(String, String)]) -> Result<(i32, OwnedFd), String> {
    let keys: Vec<String> = params.iter().map(|p| p.0.clone()).collect();
    let values: Vec<String> = params.iter().map(|p| p.1.clone()).collect();
    let (k, v) = match (c_strings(&keys), c_strings(&values)) {
        (Ok(k), Ok(v)) => (k, v),
        _ => return Err("a parameter holds a NUL".into()),
    };
    let (kp, vp) = (pointers(&k), pointers(&v));
    let mut desc: c_int = -1;
    let mut err = [0 as c_char; 256];
    let jid = unsafe { ap_jail_create(kp.as_ptr(), vp.as_ptr(), k.len() as c_int, &mut desc, err.as_mut_ptr(), err.len()) };
    if jid < 0 {
        let why = c_text(&err);
        return Err(if why.is_empty() { io::Error::last_os_error().to_string() } else { why });
    }
    Ok((jid, unsafe { OwnedFd::from_raw_fd(desc) }))
}

/// A NON-owning descriptor for the jail named `name`.
pub fn desc_by_name(name: &str) -> io::Result<OwnedFd> {
    let n = CString::new(name).map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))?;
    let d = unsafe { ap_jail_desc_by_name(n.as_ptr()) };
    if d < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(d) })
}

/// The jid and name of the jail a descriptor refers to.
pub fn identify(desc: BorrowedFd<'_>) -> io::Result<(i32, String)> {
    let mut jid: c_int = 0;
    let mut name = [0 as c_char; 256];
    if unsafe { ap_jail_identify(desc.as_raw_fd(), &mut jid, name.as_mut_ptr(), name.len()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((jid, c_text(&name)))
}

/// A kqueue watching jail descriptors for their jail's removal. Pollable:
/// readable when one is waiting.
pub struct Watch(OwnedFd);

impl Watch {
    pub fn new() -> io::Result<Watch> {
        let kq = unsafe { ap_kqueue() };
        if kq < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Watch(unsafe { OwnedFd::from_raw_fd(kq) }))
    }

    pub fn fd(&self) -> RawFd {
        self.0.as_raw_fd()
    }

    /// Say when `desc`'s jail is removed. The caller keeps `desc` open.
    pub fn add(&self, desc: BorrowedFd<'_>) -> io::Result<()> {
        if unsafe { ap_jail_watch(self.0.as_raw_fd(), desc.as_raw_fd()) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    /// One watched descriptor whose jail is gone, without blocking; None
    /// when there is none.
    pub fn removed(&self) -> Option<RawFd> {
        let d = unsafe { ap_jail_removed(self.0.as_raw_fd()) };
        (d >= 0).then_some(d)
    }
}

/// A login class's resource limits, resolved before the fork: the child of
/// a pdfork may only make async-signal-safe calls, and setusercontext(3)
/// allocates (PHASE18 P18.9).
pub struct Limits(Box<[u8; LIMITS_SIZE]>);

impl Limits {
    /// `uid`'s class limits, over this process's own.
    pub fn of_class(uid: u32) -> io::Result<Limits> {
        let mut l = Box::new([0u8; LIMITS_SIZE]);
        if unsafe { ap_class_limits(uid, l.as_mut_ptr().cast()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Limits(l))
    }

    /// One limit, (cur, max): for a test.
    pub fn get(&self, resource: i32) -> io::Result<(u64, u64)> {
        let (mut cur, mut max) = (0, 0);
        if unsafe { ap_limit_of(self.0.as_ptr().cast(), resource, &mut cur, &mut max) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok((cur, max))
    }
}

/// What to start in a jail.
pub struct Spawn<'a> {
    pub uid: u32,
    pub gid: u32,
    /// argv[0] is looked up on `env`'s PATH, inside the jail.
    pub argv: &'a [String],
    /// Exactly the environment it gets.
    pub env: &'a [String],
    pub cwd: &'a str,
    /// Its 0, 1 and 2; None is /dev/null.
    pub stdio: [Option<RawFd>; 3],
    /// Runs on after the descriptor closes (PD_DAEMON); either way it dies
    /// with its jail.
    pub daemon: bool,
    pub limits: Option<&'a Limits>,
}

/// Start a program in the jail `desc` as `s.uid`, and return its pid and
/// its process descriptor: closing the last copy kills it unless `daemon`.
pub fn spawn(desc: BorrowedFd<'_>, s: &Spawn<'_>) -> io::Result<(i32, OwnedFd)> {
    let argv = c_strings(s.argv)?;
    let env = c_strings(s.env)?;
    let cwd = CString::new(s.cwd).map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))?;
    let (ap, ep) = (pointers(&argv), pointers(&env));
    let limits = s.limits.map_or(ptr::null(), |l| l.0.as_ptr().cast());
    let [i, o, e] = s.stdio.map(|f| f.unwrap_or(-1));
    let mut proc: c_int = -1;
    let pid = unsafe {
        ap_jail_spawn(desc.as_raw_fd(), s.uid, s.gid, ap.as_ptr(), ep.as_ptr(), cwd.as_ptr(), i, o, e, s.daemon as c_int, limits, &mut proc)
    };
    if pid <= 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((pid, unsafe { OwnedFd::from_raw_fd(proc) }))
}

/// Every mount point, as the kernel has it (getmntinfo(3)): never parsed
/// from `mount -p`, which prints a path with spaces as it is (HANDOFF
/// §2.127). Empty when the kernel would not say.
pub fn mount_points() -> Vec<String> {
    let mut size = 1usize << 16;
    while size <= 1 << 24 {
        let mut buf = vec![0 as c_char; size];
        let n = unsafe { ap_mount_points(buf.as_mut_ptr(), buf.len()) };
        if n >= 0 {
            let bytes: Vec<u8> = buf[..n as usize].iter().map(|&c| c as u8).collect();
            return bytes.split(|&b| b == 0).filter(|p| !p.is_empty()).map(|p| String::from_utf8_lossy(p).into_owned()).collect();
        }
        if io::Error::last_os_error().raw_os_error() != Some(libc::ERANGE) {
            return vec![];
        }
        size *= 4;
    }
    vec![]
}

/// Whether a process descriptor's process has exited.
pub fn exited(proc: BorrowedFd<'_>) -> bool {
    unsafe { ap_procdesc_exited(proc.as_raw_fd()) == 1 }
}

/// Wait for a process descriptor's process to exit; its wait(2) status,
/// which the holder gets, parent or not.
pub fn wait(proc: BorrowedFd<'_>) -> io::Result<i32> {
    let s = unsafe { ap_procdesc_wait(proc.as_raw_fd()) };
    if s < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(s)
}

