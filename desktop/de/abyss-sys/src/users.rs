//! The password and group databases (getpwuid, getpwnam, getpwent,
//! getgrouplist, getgrgid), copied out into owned values.
//!
//! libc answers these in buffers it shares between calls, and the walk
//! (setpwent/getpwent) keeps its place there too, so every lookup here holds
//! one lock from the call until its answer is copied out. They are safe to
//! call from any thread, then, as long as nothing else in the process calls
//! those functions itself: go through here. (Unlocked, cargo's parallel tests
//! read each other's answers: settings-run's admin test lost its account two
//! runs in fifteen.)

use libc::{c_char, c_int, gid_t, passwd};
use std::ffi::{CStr, CString};
use std::sync::{Mutex, MutexGuard};

static DATABASES: Mutex<()> = Mutex::new(());

/// The lock; a panic while holding it left nothing half-done in libc.
fn lock() -> MutexGuard<'static, ()> {
    DATABASES.lock().unwrap_or_else(|e| e.into_inner())
}

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

/// This process's real user.
pub fn uid() -> u32 {
    unsafe { libc::getuid() }
}

pub fn by_uid(uid: u32) -> Option<Account> {
    let _held = lock();
    copy(unsafe { libc::getpwuid(uid) })
}

pub fn by_name(name: &str) -> Option<Account> {
    let c = CString::new(name).ok()?;
    let _held = lock();
    copy(unsafe { libc::getpwnam(c.as_ptr()) })
}

/// Every account in the database.
pub fn all() -> Vec<Account> {
    let mut out = vec![];
    let _held = lock();
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
    let _held = lock();
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
