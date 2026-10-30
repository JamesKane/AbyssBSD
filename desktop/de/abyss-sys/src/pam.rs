//! de/cpam: PAM for the authenticator (PHASE16 P16.1), and a wipe the
//! optimiser cannot drop. In C because PAM's conversation is a callback
//! handing back malloc'd answers. Without PAM's headers (the Linux dev box)
//! the check says so instead of answering.

use libc::{c_char, c_int, c_void};
use std::ffi::CString;

unsafe extern "C" {
    fn abyss_pam_check(service: *const c_char, user: *const c_char, password: *const u8, length: usize, why: *mut c_char, whylen: usize) -> c_int;
    fn abyss_wipe(p: *mut c_void, n: usize);
}

/// What PAM said.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PamAnswer {
    /// The password is the account's, and it may log in.
    Yes,
    /// It is not, or the account may not log in; PAM's words.
    No(String),
    /// PAM could not answer: none on this platform, or it failed.
    Unavailable(String),
}

/// Is `password` the password of `user`, by PAM service `service`? Every
/// copy the C side makes is wiped before it returns.
pub fn check(service: &str, user: &str, password: &[u8]) -> PamAnswer {
    let (Ok(s), Ok(u)) = (CString::new(service), CString::new(user)) else {
        return PamAnswer::No("a name with a NUL in it".into());
    };
    let mut why = [0 as c_char; 256];
    let rc = unsafe { abyss_pam_check(s.as_ptr(), u.as_ptr(), password.as_ptr(), password.len(), why.as_mut_ptr(), why.len()) };
    let text: Vec<u8> = why.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
    let text = String::from_utf8_lossy(&text).into_owned();
    match rc {
        1 => PamAnswer::Yes,
        0 => PamAnswer::No(text),
        _ => PamAnswer::Unavailable(text),
    }
}

/// Zero `bytes` through volatile writes.
pub fn wipe(bytes: &mut [u8]) {
    unsafe { abyss_wipe(bytes.as_mut_ptr().cast(), bytes.len()) }
}
