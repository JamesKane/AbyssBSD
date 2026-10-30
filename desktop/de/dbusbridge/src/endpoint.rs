//! The bridge's sockets (Endpoint.swift, BACKLOG D.1).
//!
//! Two listening sockets: the address applications are given
//! (`DBUS_SESSION_BUS_ADDRESS`, or a jail's), and a private one in the
//! session's runtime directory for ADE's own services. Both are 0600, and
//! both admit only a peer whose uid is this process's: the kernel says so
//! (`getpeereid`), and SASL `EXTERNAL` must say the same. Then each
//! connection is framed into messages and handed to the router, which
//! decides.
//!
//! Non-blocking throughout, with a queue per connection: an application
//! that stops reading fills its own queue, and is dropped when that passes
//! a limit, rather than stalling the bridge for everyone else.

use crate::router::{Action, PeerKind, Router};
use abyss_sys::platform;
use current_ipc::Server;
use dbus::Message;
use std::collections::{BTreeMap, VecDeque};
use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsFd, AsRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;

struct Outgoing {
    bytes: Vec<u8>,
    /// Sent with the first byte, and then dropped (closed: ours were copies).
    fds: Vec<OwnedFd>,
    at: usize,
}

struct Conn {
    stream: UnixStream,
    kind: PeerKind,
    saw_nul: bool,
    authed: bool,
    buf: Vec<u8>,
    fds: VecDeque<OwnedFd>,
    out: VecDeque<Outgoing>,
    queued: usize,
}

pub struct Endpoint {
    pub router: Router,
    listeners: Vec<(Server, PeerKind)>,
    conns: BTreeMap<usize, Conn>,
    next_id: usize,
    say: Box<dyn FnMut(&str)>,
    /// A connection whose unsent bytes pass this is dropped (it stopped
    /// reading).
    pub queue_limit: usize,
}

pub const MAX_MESSAGE: usize = 64 << 20;

/// 32 hex digits from /dev/urandom: the bridge's id for `GetId`.
fn guid() -> String {
    let mut r = [0u8; 16];
    let _ = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut r));
    r.iter().map(|b| format!("{b:02x}")).collect()
}

impl Endpoint {
    pub fn new(log: impl FnMut(&str) + 'static) -> Endpoint {
        Endpoint { router: Router::new(&guid()), listeners: vec![], conns: BTreeMap::new(), next_id: 1, say: Box::new(log), queue_limit: 16 << 20 }
    }

    /// Listen at `path` for peers of `kind`.
    pub fn listen(&mut self, path: &str, kind: PeerKind) -> Result<(), current_ipc::Error> {
        let s = Server::bind(path, 0o600)?;
        s.set_nonblocking(true)?;
        self.listeners.push((s, kind));
        Ok(())
    }

    pub fn connection_count(&self) -> usize {
        self.conns.len()
    }

    pub fn shutdown(&mut self) {
        for (s, _) in &mut self.listeners {
            s.shutdown_and_unlink();
        }
        self.conns.clear();
    }

    /// Serve until `keep_going` says otherwise.
    pub fn run(&mut self, keep_going: &mut dyn FnMut() -> bool) {
        while keep_going() {
            self.step(1000);
        }
    }

    pub fn step(&mut self, timeout_ms: i32) {
        use abyss_sys::proc::{poll, poll_fd};
        let mut fds: Vec<_> = self.listeners.iter().map(|(s, _)| poll_fd(s.fd(), libc::POLLIN)).collect();
        let ids: Vec<usize> = self.conns.keys().copied().collect();
        for c in self.conns.values() {
            fds.push(poll_fd(c.stream.as_raw_fd(), libc::POLLIN | if c.out.is_empty() { 0 } else { libc::POLLOUT }));
        }
        if !matches!(poll(&mut fds, timeout_ms), Ok(n) if n > 0) {
            return;
        }
        let ready: Vec<usize> = fds[..self.listeners.len()].iter().enumerate().filter(|(_, p)| p.revents != 0).map(|(i, _)| i).collect();
        for i in ready {
            self.accept(i);
        }
        for (j, id) in ids.into_iter().enumerate() {
            let ev = fds[self.listeners.len() + j].revents;
            if ev == 0 || !self.conns.contains_key(&id) {
                continue;
            }
            if ev & libc::POLLOUT != 0 {
                self.flush(id);
            }
            if ev & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 && self.conns.contains_key(&id) {
                self.readable(id);
            }
        }
    }

    fn accept(&mut self, i: usize) {
        let kind = self.listeners[i].1;
        while let Ok(stream) = self.listeners[i].0.accept() {
            match platform::peer_uid(stream.as_fd()) {
                Ok(uid) if uid == platform::euid() => {}
                _ => {
                    (self.say)(&format!("bridge: refused a {kind} whose uid is not ours"));
                    continue;
                }
            }
            if stream.set_nonblocking(true).is_err() {
                continue;
            }
            let id = self.next_id;
            self.next_id += 1;
            self.conns.insert(id, Conn { stream, kind, saw_nul: false, authed: false, buf: vec![], fds: VecDeque::new(), out: VecDeque::new(), queued: 0 });
            self.router.attach(id, kind, platform::euid(), 0);
        }
    }

    fn drop_conn(&mut self, id: usize, why: &str) {
        let Some(c) = self.conns.remove(&id) else { return };
        if !why.is_empty() {
            let who = self.router.peers.get(&id).map_or("a connection".to_owned(), |p| p.unique.clone());
            (self.say)(&format!("bridge: dropped {who} ({}): {why}", c.kind));
        }
        let actions = self.router.detach(id);
        self.apply(actions, &[]);
    }

    // MARK: reading

    fn readable(&mut self, id: usize) {
        let mut chunk = vec![0u8; 65536];
        let c = self.conns.get_mut(&id).unwrap();
        match platform::recvmsg_fds(c.stream.as_fd(), &mut chunk) {
            Ok((0, _)) => return self.drop_conn(id, ""),
            Ok((n, fds)) => {
                c.buf.extend_from_slice(&chunk[..n]);
                c.fds.extend(fds);
            }
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted) => return,
            Err(e) => return self.drop_conn(id, &format!("read: {}", words(&e))),
        }
        if !self.conns[&id].authed {
            self.authenticate(id);
        }
        if self.conns.get(&id).is_some_and(|c| c.authed) {
            self.frames(id);
        }
    }

    /// SASL, as D-Bus uses it: a NUL, then lines. EXTERNAL only, and the
    /// uid it names must be ours (the kernel already said whose the socket
    /// is).
    fn authenticate(&mut self, id: usize) {
        let c = self.conns.get_mut(&id).unwrap();
        if !c.saw_nul {
            match c.buf.first() {
                None => return,
                Some(0) => {
                    c.buf.remove(0);
                    c.saw_nul = true;
                }
                Some(_) => return self.drop_conn(id, "no credentials byte"),
            }
        }
        loop {
            let c = self.conns.get_mut(&id).unwrap();
            if c.authed {
                return;
            }
            let Some(nl) = c.buf.iter().position(|&b| b == b'\n') else {
                if c.buf.len() > 16384 {
                    self.drop_conn(id, "too much before BEGIN");
                }
                return;
            };
            let line: Vec<u8> = c.buf.drain(..=nl).collect();
            let line = String::from_utf8_lossy(&line);
            let words: Vec<&str> = line.trim_end_matches(['\n', '\r']).split(' ').filter(|w| !w.is_empty()).collect();
            let answer = match words.first().copied().unwrap_or("") {
                "AUTH" if words.get(1) == Some(&"EXTERNAL") => match words.get(2) {
                    None => Some("DATA\r\n".to_owned()),
                    Some(hex) => Some(self.external(hex)),
                },
                "AUTH" => Some("REJECTED EXTERNAL\r\n".into()),
                "DATA" => Some(self.external(words.get(1).copied().unwrap_or(""))),
                "NEGOTIATE_UNIX_FD" => Some("AGREE_UNIX_FD\r\n".into()),
                "BEGIN" => {
                    self.conns.get_mut(&id).unwrap().authed = true;
                    None
                }
                "CANCEL" | "ERROR" => Some("REJECTED EXTERNAL\r\n".into()),
                _ => Some("ERROR \"unknown command\"\r\n".into()),
            };
            if let Some(a) = answer {
                self.enqueue(id, a.into_bytes(), vec![]);
            }
            if !self.conns.contains_key(&id) {
                return;
            }
        }
    }

    /// Empty data means "the uid the socket already proved".
    fn external(&self, hex: &str) -> String {
        let claimed: Vec<u8> = hex.as_bytes().chunks(2).map_while(|p| std::str::from_utf8(p).ok().and_then(|s| u8::from_str_radix(s, 16).ok())).collect();
        if hex.is_empty() || claimed == platform::euid().to_string().as_bytes() {
            format!("OK {}\r\n", self.router.guid)
        } else {
            "REJECTED EXTERNAL\r\n".into()
        }
    }

    fn frames(&mut self, id: usize) {
        loop {
            let Some(c) = self.conns.get_mut(&id) else { return };
            let Some(total) = Message::framed_length(&c.buf) else { return };
            if total > MAX_MESSAGE {
                return self.drop_conn(id, &format!("a message of {total} bytes"));
            }
            if c.buf.len() < total {
                return;
            }
            let frame: Vec<u8> = c.buf.drain(..total).collect();
            let raw: Vec<RawFd> = c.fds.iter().map(AsRawFd::as_raw_fd).collect();
            let mut msg = match Message::decode(&frame, &raw) {
                Ok(m) => m,
                Err(e) => return self.drop_conn(id, &format!("a message that does not parse ({e})")),
            };
            // Exactly the descriptors this message declared are its own; its
            // body names them, so it forwards with those and no copy beside.
            let declared = msg.declared_fds as usize;
            if declared > c.fds.len() {
                return self.drop_conn(id, "a message declaring descriptors that did not arrive");
            }
            let mine: Vec<OwnedFd> = c.fds.drain(..declared).collect();
            msg.fds.clear();
            let actions = self.router.route(id, msg);
            self.apply(actions, &mine);
        }
    }

    // MARK: writing

    /// Carry out the router's decisions. `fds` are the descriptors of the
    /// message being forwarded: each delivery sends its own copies.
    fn apply(&mut self, actions: Vec<Action>, fds: &[OwnedFd]) {
        for a in actions {
            match a {
                Action::Deliver(to, m) => {
                    if !self.conns.contains_key(&to) {
                        continue;
                    }
                    let Ok((bytes, raw)) = m.encode() else { continue };
                    // The encoded numbers are `fds`' own: copy each.
                    let copies: Option<Vec<OwnedFd>> = raw.iter().map(|r| fds.iter().find(|f| f.as_raw_fd() == *r).and_then(|f| f.try_clone().ok())).collect();
                    let Some(copies) = copies else { continue };
                    self.enqueue(to, bytes, copies);
                }
                Action::Close(id, why) => self.drop_conn(id, &why),
            }
        }
    }

    fn enqueue(&mut self, id: usize, bytes: Vec<u8>, fds: Vec<OwnedFd>) {
        let Some(c) = self.conns.get_mut(&id) else { return };
        c.queued += bytes.len();
        c.out.push_back(Outgoing { bytes, fds, at: 0 });
        if c.queued > self.queue_limit {
            let q = c.queued;
            return self.drop_conn(id, &format!("stopped reading ({q} bytes queued)"));
        }
        self.flush(id);
    }

    fn flush(&mut self, id: usize) {
        let Some(c) = self.conns.get_mut(&id) else { return };
        while let Some(head) = c.out.front_mut() {
            let rest = &head.bytes[head.at..];
            let r = if head.fds.is_empty() {
                (&c.stream).write(rest)
            } else {
                let raw: Vec<RawFd> = head.fds.iter().map(AsRawFd::as_raw_fd).collect();
                platform::sendmsg_fds(c.stream.as_fd(), rest, &raw)
            };
            match r {
                Ok(n) => {
                    // Sent once is sent: the rest of the bytes go plain.
                    head.fds.clear();
                    head.at += n;
                    c.queued -= n;
                    if head.at < head.bytes.len() {
                        return;
                    }
                    c.out.pop_front();
                }
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted) => return,
                Err(e) => return self.drop_conn(id, &format!("write: {}", words(&e))),
            }
        }
    }
}

fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}
