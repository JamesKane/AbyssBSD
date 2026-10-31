//! The session's side of abyss-jaild (JailClient in Service.swift): what the
//! keeper, `abyss-jail` and the jail's portal ask it.

use crate::wire;
use current_ipc::Msg;
use std::os::fd::{AsRawFd, BorrowedFd, OwnedFd, RawFd};

/// A jail, opened.
#[derive(Debug)]
pub struct Opened {
    /// Owning, unless `shared`: hold it, and the jail lives.
    pub jail: OwnedFd,
    pub jid: u64,
    pub name: String,
    pub root: String,
    /// The jail's runtime directory as the host sees it: where its Wayland
    /// socket is bound (P18.3).
    pub runtime: String,
    /// The jail's home's source on the host (P18.9): a core it left is
    /// here, outside every jail's root.
    pub home: String,
    pub shared: bool,
}

/// One request; its answer when it says yes, its words when it does not.
pub fn call(m: &Msg, socket: &str) -> Result<Msg, String> {
    let s = current_ipc::connect_path(socket).map_err(|e| e.to_string())?;
    current_ipc::send(m, &s).map_err(|e| e.to_string())?;
    let mut r = current_ipc::receive(&s).map_err(|e| e.to_string())?;
    if r.bool("ok") != Some(true) {
        r.close_fds();
        return Err(r.string("error").unwrap_or("refused").to_owned());
    }
    Ok(r)
}

fn request(method: &str) -> Msg {
    let mut m = Msg::new();
    m.set_string("method", method);
    m
}

pub fn open(class: &str, socket: &str) -> Result<Opened, String> {
    let mut m = request("open");
    m.set_string("class", class);
    let mut r = call(&m, socket)?;
    let jail = r.take_fd("jail").ok_or("no jail descriptor in the answer")?;
    let text = |k: &str| r.string(k).unwrap_or("").to_owned();
    Ok(Opened {
        jid: r.u64("jid").unwrap_or(0),
        name: text("name"),
        root: text("root"),
        runtime: text("runtime"),
        home: text("home"),
        shared: r.bool("shared").unwrap_or(false),
        jail,
    })
}

/// Mount `path` into the caller's jail `name`, proven by `file` (the
/// caller's descriptor of it): where it is inside, and the grant's number.
pub fn grant(jail: &str, path: &str, file: BorrowedFd<'_>, socket: &str) -> Result<(String, u64), String> {
    let mut m = request("grant");
    m.set_string("jail", jail);
    m.set_string("path", path);
    m.set_fd("file", file.as_raw_fd());
    let r = call(&m, socket)?;
    Ok((r.string("path").unwrap_or("").to_owned(), r.u64("grant").unwrap_or(0)))
}

pub fn revoke(jail: &str, grant: u64, socket: &str) -> Result<(), String> {
    let mut m = request("revoke");
    m.set_string("jail", jail);
    m.set_u64("grant", grant);
    call(&m, socket).map(|_| ())
}

/// "N<TAB>rw|ro<TAB>inside<TAB>source", one per grant.
pub fn grants(jail: &str, socket: &str) -> Result<Vec<String>, String> {
    let mut m = request("grants");
    m.set_string("jail", jail);
    let r = call(&m, socket)?;
    Ok(wire::unlist(r.bytes("grants").unwrap_or(&[])))
}

/// What to start, and on what.
#[derive(Default)]
pub struct Start<'a> {
    pub argv: &'a [String],
    pub env: &'a [String],
    pub stdin: Option<RawFd>,
    pub stdout: Option<RawFd>,
    pub stderr: Option<RawFd>,
    pub daemon: bool,
}

/// Start a program in `jail`: its pid, and its process descriptor, which is
/// the caller's; closing it kills the process unless `daemon`.
pub fn spawn(jail: BorrowedFd<'_>, s: &Start<'_>, socket: &str) -> Result<(u64, OwnedFd), String> {
    let mut m = request("spawn");
    m.set_fd("jail", jail.as_raw_fd());
    m.set_bytes("argv", &wire::list(s.argv));
    m.set_bytes("env", &wire::list(s.env));
    for (k, fd) in [("stdin", s.stdin), ("stdout", s.stdout), ("stderr", s.stderr)] {
        if let Some(fd) = fd {
            m.set_fd(k, fd);
        }
    }
    m.set_bool("daemon", s.daemon);
    let mut r = call(&m, socket)?;
    let proc = r.take_fd("proc").ok_or("no process descriptor in the answer")?;
    Ok((r.u64("pid").unwrap_or(0), proc))
}
