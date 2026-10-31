//! JailD in Rust: abyss-jaild's steps, performer, service and client
//! (PHASE18 P18.2), ported from de/jaild/*.swift beside it.
//!
//! Root, one socket, and every request for the caller's own uid: the kernel
//! says who that is, and a request names nobody.
//!
//!   open  class=NAME   → builds the class's root for the caller (P18.1's
//!                        plan, refused if it has any violation), creates the
//!                        jail, and hands back an OWNING jail descriptor: the
//!                        jail lives exactly as long as the caller holds it
//!                        (§4.2). Pooled: a second open of a live jail gets a
//!                        non-owning descriptor of the same one.
//!   spawn jail=FD argv=… → starts argv in that jail as the caller, and hands
//!                        back its process descriptor. The descriptor proves
//!                        which jail; the jail's name proves whose.
//!   grant jail=NAME path=P file=FD → mounts that one file into the caller's
//!                        jail (P18.4) and answers where it is inside. FD is
//!                        the caller's own descriptor of P, and it is the
//!                        proof: a grant reaches nothing the caller could not
//!                        open, and is writable only if FD is.
//!   revoke jail=NAME grant=N, grants jail=NAME → take one back; list them.

pub mod client;
pub mod performer;
mod service;
pub mod steps;

pub use performer::{Failure, Performer};
pub use service::{Grant, JailService};
pub use steps::{JailCommands, JailStep};

use jails::JailUser;

/// The wire's shared pieces.
pub mod wire {
    use current_ipc::Msg;

    pub const DEFAULT_SOCKET: &str = "/var/run/abyss-jaild.sock";

    pub fn error(why: &str) -> Msg {
        let mut m = Msg::new();
        m.set_bool("ok", false);
        m.set_string("error", why);
        m
    }

    /// A list of strings as one field: NUL-separated, so nothing in an
    /// argument can be mistaken for a separator.
    pub fn list(xs: &[String]) -> Vec<u8> {
        xs.join("\0").into_bytes()
    }

    pub fn unlist(b: &[u8]) -> Vec<String> {
        if b.is_empty() {
            return vec![];
        }
        b.split(|&c| c == 0).map(|s| String::from_utf8_lossy(s).into_owned()).collect()
    }

    /// The environment a spawn gets: the plan's, with the caller's extras
    /// added, but never over the plan's own keys, which say where the jail's
    /// home and runtime directory are.
    pub fn environment(plan: &[(String, String)], extra: &[String]) -> Vec<String> {
        let mut out: Vec<String> = plan.iter().map(|(k, v)| format!("{k}={v}")).collect();
        for e in extra {
            match e.split_once('=') {
                Some((k, _)) if !k.is_empty() && !plan.iter().any(|(p, _)| p == k) => out.push(e.clone()),
                _ => {}
            }
        }
        out
    }

    /// Whether `uid` may use the jail named `name`: only its own.
    pub fn owns(uid: u32, name: &str) -> bool {
        name.starts_with(&format!("abyss-{uid}-"))
    }
}

/// Who an account is, as a jail needs it: the person, and where their real
/// home is (resolved, so a symlinked /home is seen for what it is).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JailAccount {
    pub user: JailUser,
    pub home: String,
}

impl JailAccount {
    /// From the password database; never root, who is not confined.
    pub fn system(uid: u32) -> Option<JailAccount> {
        if uid == 0 {
            return None;
        }
        let a = abyss_sys::users::by_uid(uid)?;
        let home = std::fs::canonicalize(&a.home).map_or(a.home.clone(), |p| p.to_string_lossy().into_owned());
        Some(JailAccount { user: JailUser { name: a.name, uid, gid: a.gid }, home })
    }
}

#[cfg(test)]
mod tests;
