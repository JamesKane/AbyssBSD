//! The password and group databases (getpwuid, getpwnam, getpwent,
//! getgrouplist, getgrgid), copied out into owned values. Not reentrant:
//! like Swift's callers, these are for one thread at a time.

use libc::{c_char, c_int, gid_t, passwd};
use std::ffi::{CStr, CString};

/// One account, as passwd(5) has it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Account {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    pub gecos: String,
    pub home: String,
    pub shell: String,
}

fn text(p: *const c_char) -> String {
    if p.is_null() { String::new() } else { unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned() }
}

fn copy(pw: *const passwd) -> Option<Account> {
    if pw.is_null() {
        return None;
    }
    let p = unsafe { &*pw };
    Some(Account { name: text(p.pw_name), uid: p.pw_uid, gid: p.pw_gid, gecos: text(p.pw_gecos), home: text(p.pw_dir), shell: text(p.pw_shell) })
}

pub fn by_uid(uid: u32) -> Option<Account> {
    copy(unsafe { libc::getpwuid(uid) })
}

pub fn by_name(name: &str) -> Option<Account> {
    let c = CString::new(name).ok()?;
    copy(unsafe { libc::getpwnam(c.as_ptr()) })
}

/// Every account in the database.
pub fn all() -> Vec<Account> {
    let mut out = vec![];
    unsafe { libc::setpwent() };
    loop {
        let p = unsafe { libc::getpwent() };
        match copy(p) {
            Some(a) => out.push(a),
            None => break,
        }
    }
    unsafe { libc::endpwent() };
    out
}

/// The names of the groups `uid` is in, its own included.
pub fn group_names(uid: u32) -> Vec<String> {
    let Some(a) = by_uid(uid) else { return vec![] };
    let Ok(name) = CString::new(a.name) else { return vec![] };
    let mut n: c_int = 64;
    let mut list = vec![0 as gid_t; 64];
    #[cfg(target_os = "macos")]
    let rc = unsafe { libc::getgrouplist(name.as_ptr(), a.gid as c_int, list.as_mut_ptr().cast(), &mut n) };
    #[cfg(not(target_os = "macos"))]
    let rc = unsafe { libc::getgrouplist(name.as_ptr(), a.gid, list.as_mut_ptr(), &mut n) };
    if rc < 0 {
        return vec![];
    }
    list.truncate(n.max(0) as usize);
    list.into_iter()
        .filter_map(|g| {
            let gr = unsafe { libc::getgrgid(g) };
            (!gr.is_null()).then(|| text(unsafe { (*gr).gr_name }))
        })
        .collect()
}
