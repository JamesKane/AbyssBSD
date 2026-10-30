//! A connection to ADE's bridge (Connection.swift): connect, authenticate,
//! say Hello, then call and be called.
//!
//! **Swift dispatches inside `call`**: a handler or a signal callback can run
//! while a caller is blocked waiting for its own reply. Here nothing runs
//! behind the caller's back: what arrives while a call waits is kept, and
//! the next `receive` hands it over, so the owner of the connection decides
//! what to do with every message, in order, on its own stack.

use crate::{parse_address, Error, Message, MessageType, Value};
use abyss_sys::platform;
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

pub const DRIVER: &str = "org.freedesktop.DBus";
pub const DRIVER_PATH: &str = "/org/freedesktop/DBus";

/// A message that arrived, and the descriptors that came with it: its body's
/// `h` values are these descriptors' numbers, valid while this lives.
#[derive(Debug)]
pub struct Received {
    pub message: Message,
    pub fds: Vec<OwnedFd>,
}

pub struct Connection {
    stream: UnixStream,
    /// What `Hello` said this connection is called: `:1.42`.
    pub unique_name: String,
    next_serial: u32,
    /// Bytes read and not yet a whole message.
    buf: Vec<u8>,
    /// Descriptors that arrived and no message has claimed yet.
    fds: VecDeque<OwnedFd>,
    /// Whole messages, read and not yet handed over.
    queued: VecDeque<Received>,
}

impl Connection {
    /// Connect to `address`, or to `$DBUS_SESSION_BUS_ADDRESS`.
    pub fn connect(address: Option<&str>) -> Result<Connection, Error> {
        let addr = match address {
            Some(a) => a.to_owned(),
            None => std::env::var("DBUS_SESSION_BUS_ADDRESS").map_err(|_| Error::new("no DBUS_SESSION_BUS_ADDRESS and no address given"))?,
        };
        let (path, abstract_) = parse_address(&addr).ok_or_else(|| Error::new(format!("unsupported bus address: {addr}")))?;
        let stream = open(&path, abstract_).map_err(|e| Error::new(format!("connect {path}: {}", words(&e))))?;
        platform::socket_nosigpipe(stream.as_fd());
        let mut c = Connection { stream, unique_name: String::new(), next_serial: 1, buf: vec![], fds: VecDeque::new(), queued: VecDeque::new() };
        c.authenticate()?;
        let reply = c.call(Message::method_call(DRIVER, DRIVER_PATH, DRIVER, "Hello", vec![]), 25_000)?;
        let Some(Value::String(name)) = reply.body.first() else { return Err(Error::new("Hello returned no name")) };
        c.unique_name = name.clone();
        Ok(c)
    }

    /// SASL EXTERNAL: a NUL byte, so the kernel can attach our credentials,
    /// then a small line protocol. Descriptor passing is not optional: the
    /// file chooser's answer cannot travel without it.
    fn authenticate(&mut self) -> Result<(), Error> {
        let hex: String = platform::euid().to_string().bytes().map(|b| format!("{b:02x}")).collect();
        self.write(b"\0")?;
        self.write(format!("AUTH EXTERNAL {hex}\r\n").as_bytes())?;
        let reply = self.read_line()?;
        if !reply.starts_with("OK") {
            return Err(Error::new(format!("authentication refused: {reply}")));
        }
        self.write(b"NEGOTIATE_UNIX_FD\r\n")?;
        let fd_reply = self.read_line()?;
        if !fd_reply.starts_with("AGREE_UNIX_FD") {
            return Err(Error::new(format!("the bus will not pass descriptors ({fd_reply}); a portal cannot work without them")));
        }
        self.write(b"BEGIN\r\n")
    }

    fn write(&mut self, bytes: &[u8]) -> Result<(), Error> {
        self.stream.write_all(bytes).map_err(|e| Error::new(format!("write: {}", words(&e))))
    }

    fn read_line(&mut self) -> Result<String, Error> {
        let mut out = vec![];
        let mut c = [0u8];
        // A byte at a time: what follows the line is the bus's, not ours.
        while out.len() < 16384 {
            match self.stream.read(&mut c) {
                Ok(1) => out.push(c[0]),
                Ok(_) => return Err(Error::new("the bus closed the connection during authentication")),
                Err(e) => return Err(Error::new(format!("read: {}", words(&e)))),
            }
            if out.ends_with(b"\r\n") {
                break;
            }
        }
        while out.last().is_some_and(|&b| b == b'\n' || b == b'\r') {
            out.pop();
        }
        Ok(String::from_utf8_lossy(&out).into_owned())
    }

    // MARK: the driver

    /// Ask for a well-known name: the reply code, 1 being primary owner.
    pub fn request_name(&mut self, name: &str, flags: u32) -> Result<u32, Error> {
        let r = self.call(Message::method_call(DRIVER, DRIVER_PATH, DRIVER, "RequestName", vec![Value::String(name.into()), Value::UInt32(flags)]), 25_000)?;
        match r.body.first() {
            Some(Value::UInt32(code)) => Ok(*code),
            _ => Err(Error::new("RequestName returned nothing")),
        }
    }

    /// Subscribe to what a rule matches. **Before** the call that provokes
    /// the signal: a broadcast reaches only those who already asked.
    pub fn add_match(&mut self, rule: &str) -> Result<(), Error> {
        self.call(Message::method_call(DRIVER, DRIVER_PATH, DRIVER, "AddMatch", vec![Value::String(rule.into())]), 25_000).map(drop)
    }

    /// Stop: the same rule, word for word.
    pub fn remove_match(&mut self, rule: &str) -> Result<(), Error> {
        self.call(Message::method_call(DRIVER, DRIVER_PATH, DRIVER, "RemoveMatch", vec![Value::String(rule.into())]), 25_000).map(drop)
    }

    // MARK: sending

    /// Send, numbering the message if it has no serial: the serial it went
    /// with.
    pub fn send(&mut self, mut message: Message) -> Result<u32, Error> {
        if message.serial == 0 {
            message.serial = self.next_serial;
            self.next_serial = self.next_serial.wrapping_add(1).max(1);
        }
        let (bytes, fds) = message.encode()?;
        if fds.is_empty() {
            self.write(&bytes)?;
        } else {
            // The descriptors ride with the first byte; whatever sendmsg did
            // not take goes as plain bytes after it.
            let n = platform::sendmsg_fds(self.stream.as_fd(), &bytes, &fds).map_err(|e| Error::new(format!("sendmsg with fds: {}", words(&e))))?;
            self.write(&bytes[n..])?;
        }
        Ok(message.serial)
    }

    /// Answer `call` with `reply`, unless the caller said it expects none.
    pub fn reply(&mut self, call: &Message, reply: Message) -> Result<(), Error> {
        if call.flags.contains(crate::Flags::NO_REPLY_EXPECTED) {
            return Ok(());
        }
        self.send(reply).map(drop)
    }

    /// Refuse a method nobody here answers, so the caller is not left
    /// waiting for ever.
    pub fn unknown_method(&mut self, call: &Message) -> Result<(), Error> {
        let text = format!("no such method: {}.{}", call.interface.as_deref().unwrap_or("?"), call.member.as_deref().unwrap_or("?"));
        self.reply(call, Message::error(call, "org.freedesktop.DBus.Error.UnknownMethod", &text))
    }

    /// Send a method call and block until its reply. Whatever else arrives
    /// meanwhile is kept for `receive`. An error reply is an `Err` with its
    /// name and text. Descriptors in a reply are closed with it: nothing
    /// ADE calls answers with one.
    pub fn call(&mut self, message: Message, timeout_ms: u64) -> Result<Message, Error> {
        let member = message.member.clone().unwrap_or_else(|| "?".into());
        let serial = self.send(Message { serial: 0, ..message })?;
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        loop {
            if let Some(i) = self.queued.iter().position(|r| r.message.reply_serial == Some(serial) && matches!(r.message.kind, MessageType::MethodReturn | MessageType::Error)) {
                let reply = self.queued.remove(i).unwrap().message;
                if reply.kind == MessageType::Error {
                    let text = match reply.body.first() {
                        Some(Value::String(s)) => s.as_str(),
                        _ => "",
                    };
                    return Err(Error::new(format!("{}: {text}", reply.error_name.as_deref().unwrap_or("error"))));
                }
                return Ok(reply);
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(Error::new(format!("timed out waiting for a reply to {member}")));
            }
            self.fill(left.as_millis().min(100) as i32)?;
        }
    }

    // MARK: receiving

    /// Whether messages are waiting already: poll with no timeout if so.
    pub fn has_queued(&self) -> bool {
        !self.queued.is_empty()
    }

    /// Everything that has arrived, waiting up to `timeout_ms` (negative is
    /// for ever) if nothing has. Replies whose caller stopped waiting are
    /// dropped here.
    pub fn receive(&mut self, timeout_ms: i32) -> Result<Vec<Received>, Error> {
        if self.queued.is_empty() {
            self.fill(timeout_ms)?;
        }
        Ok(self
            .queued
            .drain(..)
            .filter(|r| !matches!(r.message.kind, MessageType::MethodReturn | MessageType::Error))
            .collect())
    }

    /// One read, if anything comes within `timeout_ms`, and every whole
    /// message in it queued.
    fn fill(&mut self, timeout_ms: i32) -> Result<(), Error> {
        let mut p = [abyss_sys::proc::poll_fd(self.stream.as_raw_fd(), libc::POLLIN)];
        match abyss_sys::proc::poll(&mut p, timeout_ms) {
            Ok(0) => return Ok(()),
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => return Ok(()),
            Err(e) => return Err(Error::new(format!("poll: {}", words(&e)))),
        }
        let mut chunk = vec![0u8; 65536];
        let (n, fds) = match platform::recvmsg_fds(self.stream.as_fd(), &mut chunk) {
            Ok(r) => r,
            Err(e) if matches!(e.kind(), std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock) => return Ok(()),
            Err(e) => return Err(Error::new(format!("read: {}", words(&e)))),
        };
        if n == 0 {
            return Err(Error::new("the bus closed the connection"));
        }
        self.buf.extend_from_slice(&chunk[..n]);
        self.fds.extend(fds);
        while let Some(total) = Message::framed_length(&self.buf) {
            if self.buf.len() < total {
                break;
            }
            let frame: Vec<u8> = self.buf.drain(..total).collect();
            let raw: Vec<RawFd> = self.fds.iter().map(AsRawFd::as_raw_fd).collect();
            let message = Message::decode(&frame, &raw)?;
            // Exactly the descriptors this message declared are its own.
            let mine = (message.declared_fds as usize).min(self.fds.len());
            let fds = self.fds.drain(..mine).collect();
            self.queued.push_back(Received { message, fds });
        }
        Ok(())
    }
}

impl AsFd for Connection {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.stream.as_fd()
    }
}

impl AsRawFd for Connection {
    fn as_raw_fd(&self) -> RawFd {
        self.stream.as_raw_fd()
    }
}

#[cfg(target_os = "linux")]
fn open(path: &str, abstract_: bool) -> std::io::Result<UnixStream> {
    use std::os::linux::net::SocketAddrExt;
    if abstract_ {
        let a = std::os::unix::net::SocketAddr::from_abstract_name(path.as_bytes())?;
        return UnixStream::connect_addr(&a);
    }
    UnixStream::connect(path)
}

#[cfg(not(target_os = "linux"))]
fn open(path: &str, abstract_: bool) -> std::io::Result<UnixStream> {
    if abstract_ {
        // The abstract namespace is Linux's alone.
        return Err(std::io::Error::from(std::io::ErrorKind::Unsupported));
    }
    UnixStream::connect(path)
}

/// An io::Error as strerror says it, without Rust's "(os error N)".
pub(crate) fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}
