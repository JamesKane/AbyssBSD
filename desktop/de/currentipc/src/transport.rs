//! The transport (Current.swift): where sockets live, how a frame is framed,
//! and the service/client pair.
//!
//! Brokerless: a client connects straight to `<runtime_dir>/<service>.sock`.
//! One message goes out as a 4-byte big-endian length in a `sendmsg` that
//! carries its descriptors, then the body. The receiver reads the length
//! with `recvmsg`, which is where SCM_RIGHTS arrives (the kernel delivers it
//! with the first byte of its transfer), then the body with plain reads.

use crate::msg::{Error, Msg};
use abyss_sys::platform;
use std::fs::{self, DirBuilder, Permissions};
use std::io::{ErrorKind, Read};
use std::os::fd::{AsFd, AsRawFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::time::Duration;

/// The per-user runtime directory holding service sockets, created 0700:
/// `$ABYSS_RUNTIME_DIR`, else `$XDG_RUNTIME_DIR/abyss`, else
/// `/var/run/user/<uid>/abyss`.
pub fn runtime_dir() -> Result<String, Error> {
    let var = |k: &str| std::env::var(k).ok();
    let dir = choose_runtime_dir(var("ABYSS_RUNTIME_DIR").as_deref(), var("XDG_RUNTIME_DIR").as_deref(), platform::euid());
    make_private_dir(&dir)?;
    Ok(dir)
}

/// The precedence, without the environment: an empty variable counts as
/// unset.
fn choose_runtime_dir(abyss: Option<&str>, xdg: Option<&str>, uid: u32) -> String {
    match (abyss.filter(|v| !v.is_empty()), xdg.filter(|v| !v.is_empty())) {
        (Some(d), _) => d.to_owned(),
        (None, Some(x)) => format!("{x}/abyss"),
        (None, None) => format!("/var/run/user/{uid}/abyss"),
    }
}

/// `dir`, created if missing, and 0700 either way.
fn make_private_dir(dir: &str) -> Result<(), Error> {
    // Existing already is success, as mkdir's EEXIST was.
    if let Err(e) = DirBuilder::new().mode(0o700).create(dir)
        && e.kind() != ErrorKind::AlreadyExists
    {
        return Err(Error::system(&e, format!("mkdir {dir}")));
    }
    fs::set_permissions(dir, Permissions::from_mode(0o700))
        .map_err(|e| Error::system(&e, format!("chmod 0700 {dir}")))?;
    Ok(())
}

/// The socket path for a named service.
pub fn socket_path(service: &str) -> Result<String, Error> {
    Ok(format!("{}/{service}.sock", runtime_dir()?))
}

// MARK: client

/// Connect to a service.
pub fn connect(service: &str) -> Result<UnixStream, Error> {
    connect_path(&socket_path(service)?)
}

/// Connect to a socket at an explicit path: a system service outside any
/// session's runtime directory (the authenticator).
pub fn connect_path(path: &str) -> Result<UnixStream, Error> {
    check_sun_path(path)?;
    let s = UnixStream::connect(path).map_err(|e| Error::system(&e, format!("connect {path}")))?;
    platform::socket_nosigpipe(s.as_fd());
    Ok(s)
}

/// One request, one reply: connect, send, read the reply, close.
pub fn call(service: &str, request: &Msg) -> Result<Msg, Error> {
    let s = connect(service)?;
    send(request, &s)?;
    receive(&s)
}

// MARK: framing

/// Send one message, and its descriptors, on a connected socket.
pub fn send(msg: &Msg, sock: &UnixStream) -> Result<(), Error> {
    let body = msg.pack();
    if body.len() + 4 > Msg::MAX_FRAME {
        return Err(Error::TooLarge(body.len()));
    }
    let fds = msg.attached_fds();
    if fds.len() > Msg::MAX_FDS {
        return Err(Error::Malformed(format!(
            "{} descriptors exceeds the {} cap",
            fds.len(),
            Msg::MAX_FDS
        )));
    }
    // The length goes in its own sendmsg, carrying the descriptors, so the
    // receiver's one recvmsg is sure to collect them.
    let header = (body.len() as u32).to_be_bytes();
    match platform::sendmsg_fds(sock.as_fd(), &header, &fds) {
        Ok(4) => {}
        Ok(_) => return Err(Error::Closed),
        Err(e) => return Err(Error::system(&e, "sendmsg")),
    }
    platform::send_all(sock.as_fd(), &body).map_err(|e| {
        if e.kind() == ErrorKind::BrokenPipe { Error::Closed } else { Error::system(&e, "send") }
    })
}

/// Receive one message. Descriptors that arrive belong to the message.
pub fn receive(sock: &UnixStream) -> Result<Msg, Error> {
    let mut header = [0u8; 4];
    let (n, fds) = platform::recvmsg_fds(sock.as_fd(), &mut header).map_err(|e| Error::system(&e, "recvmsg"))?;
    // From here `fds` close themselves on any early return.
    if n == 0 {
        return Err(Error::Closed);
    }
    if n != 4 {
        return Err(Error::Malformed(format!("short length prefix ({n} bytes)")));
    }
    let length = u32::from_be_bytes(header) as usize;
    if length + 4 > Msg::MAX_FRAME {
        return Err(Error::TooLarge(length));
    }
    let mut body = vec![0u8; length];
    let mut r = sock;
    r.read_exact(&mut body).map_err(|e| {
        if e.kind() == ErrorKind::UnexpectedEof { Error::Closed } else { Error::system(&e, "read") }
    })?;
    Msg::unpack(&body, fds)
}

// MARK: server

/// A service listening on `<runtime_dir>/<service>.sock`. Its descriptor is
/// public, for a component's own event loop.
pub struct Server {
    listener: Option<UnixListener>,
    pub path: String,
    /// How long an accepted connection may take to send its request: a
    /// client that connects and says nothing cannot stall the service.
    pub request_timeout: Duration,
}

impl Server {
    /// Bind the service socket 0600, replacing a stale one left by a crash.
    pub fn new(service: &str) -> Result<Server, Error> {
        Server::bind(&socket_path(service)?, 0o600)
    }

    /// Bind at an explicit path with an explicit mode. A system service every
    /// user may reach is 0666 and asks the kernel who called
    /// ([`peer_uid`](abyss_sys::platform::peer_uid)).
    pub fn bind(path: &str, mode: u32) -> Result<Server, Error> {
        check_sun_path(path)?;
        // A leftover socket file would make bind fail with EADDRINUSE.
        let _ = fs::remove_file(path);
        let l = UnixListener::bind(path).map_err(|e| Error::system(&e, format!("bind {path}")))?;
        let _ = fs::set_permissions(path, Permissions::from_mode(mode));
        Ok(Server {
            listener: Some(l),
            path: path.to_owned(),
            request_timeout: Duration::from_secs(2),
        })
    }

    /// The listening descriptor, for a run loop.
    pub fn fd(&self) -> RawFd {
        self.listener.as_ref().map_or(-1, |l| l.as_raw_fd())
    }

    /// Accept one client, blocking, with the request timeout applied.
    pub fn accept(&self) -> Result<UnixStream, Error> {
        let l = self.listener.as_ref().ok_or(Error::Closed)?;
        let (c, _) = l.accept().map_err(|e| Error::system(&e, "accept"))?;
        platform::socket_nosigpipe(c.as_fd());
        // A connection accepted from a non-blocking listener inherits
        // O_NONBLOCK on the BSDs but not on Linux (HANDOFF §2.33): force
        // blocking, or recvmsg gets EAGAIN before the request lands.
        c.set_nonblocking(false).map_err(|e| Error::system(&e, "fcntl F_SETFL"))?;
        if !self.request_timeout.is_zero() {
            let _ = c.set_read_timeout(Some(self.request_timeout));
        }
        Ok(c)
    }

    /// Non-blocking accept, for a component polling from its own loop.
    pub fn set_nonblocking(&self, nb: bool) -> Result<(), Error> {
        let l = self.listener.as_ref().ok_or(Error::Closed)?;
        l.set_nonblocking(nb).map_err(|e| Error::system(&e, "fcntl F_SETFL"))
    }

    /// Accept one connection, read one request, reply with `handler`'s
    /// answer. A malformed request or a peer that hangs up costs that one
    /// connection: false, and nothing else.
    pub fn serve_one(&self, handler: &mut dyn FnMut(&mut Msg) -> Msg) -> Result<bool, Error> {
        let c = self.accept()?;
        let Ok(mut request) = receive(&c) else { return Ok(false) };
        let reply = handler(&mut request);
        // Whatever the handler didn't take closes with the request.
        drop(request);
        let _ = send(&reply, &c);
        Ok(true)
    }

    /// Serve request and reply until `stop` says so (checked between
    /// connections).
    pub fn serve(&self, stop: &mut dyn FnMut() -> bool, handler: &mut dyn FnMut(&mut Msg) -> Msg) -> Result<(), Error> {
        while !stop() {
            self.serve_one(handler)?;
        }
        Ok(())
    }

    /// Close the socket and remove its file. Again is a no-op.
    pub fn shutdown_and_unlink(&mut self) {
        if self.listener.take().is_some() {
            let _ = fs::remove_file(&self.path);
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.shutdown_and_unlink();
    }
}

/// Refuse a path that would not fit `sun_path` rather than truncating to a
/// different socket. Its capacity is 104 bytes on the BSDs, 108 on Linux.
fn check_sun_path(path: &str) -> Result<(), Error> {
    let capacity = if cfg!(target_os = "linux") { 108 } else { 104 };
    if path.len() >= capacity {
        return Err(Error::Malformed(format!(
            "socket path too long ({} >= {capacity}): {path}",
            path.len()
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::MetadataExt;

    // CurrentIPCTests.testRuntimeDirPrecedenceAndPermissions, without
    // touching this process's environment (set_var is unsafe and racy in a
    // threaded test run).
    #[test]
    fn runtime_dir_precedence_and_permissions() {
        assert_eq!(choose_runtime_dir(Some("/a"), Some("/x"), 7), "/a", "ABYSS_RUNTIME_DIR wins");
        assert_eq!(choose_runtime_dir(None, Some("/x"), 7), "/x/abyss", "XDG appends /abyss");
        assert_eq!(choose_runtime_dir(Some(""), Some("/x"), 7), "/x/abyss", "empty is unset");
        assert_eq!(choose_runtime_dir(None, None, 7), "/var/run/user/7/abyss");

        let dir = std::env::temp_dir().join(format!("abyss-ipc-rt-{}", std::process::id()));
        let d = dir.to_str().unwrap();
        make_private_dir(d).unwrap();
        fs::set_permissions(d, Permissions::from_mode(0o755)).unwrap();
        make_private_dir(d).unwrap(); // exists: fine, and made private again
        assert_eq!(fs::metadata(d).unwrap().mode() & 0o777, 0o700, "the runtime dir must be private");
        fs::remove_dir(d).unwrap();
    }
}
