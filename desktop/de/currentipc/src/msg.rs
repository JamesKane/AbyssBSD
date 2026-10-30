//! A typed control-plane message and its wire format (Msg.swift).
//!
//! A message is a small set of named, typed fields, one of which may be a
//! file descriptor: handing over an shm or dmabuf handle with no pixel copies
//! is the reason the desktop has a control plane of its own. Descriptors do
//! not appear in the bytes; they travel as SCM_RIGHTS and the field records
//! their index in that array.
//!
//! ```text
//! msg    := magic "ABYM" | version u8 | count u16 | field*
//! field  := nameLen u16 | name UTF-8 | kind u8 | payload
//! payload: string  len u32 | UTF-8
//!          uint64  u64
//!          bool    u8 (0/1)
//!          bytes   len u32 | raw
//!          fd      index u8            (the fd itself rides in SCM_RIGHTS)
//! ```
//!
//! Integers are big-endian: a documented format, not a memory dump.

use std::fmt;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};

/// What went wrong in the control plane (CurrentError). Deliberately small:
/// a caller retries, reports, or gives up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The bytes are not a message we can read.
    Malformed(String),
    /// A frame bigger than [`Msg::MAX_FRAME`].
    TooLarge(usize),
    /// The peer hung up mid-message.
    Closed,
    /// A system call failed: errno, and what we tried.
    System(i32, String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Malformed(why) => write!(f, "malformed: {why}"),
            Error::TooLarge(n) => write!(f, "frame too large: {n} bytes"),
            Error::Closed => write!(f, "the peer closed the connection"),
            Error::System(e, what) => {
                write!(f, "{what}: {}", std::io::Error::from_raw_os_error(*e))
            }
        }
    }
}

impl std::error::Error for Error {}

impl Error {
    pub(crate) fn system(e: &std::io::Error, what: impl Into<String>) -> Error {
        Error::System(e.raw_os_error().unwrap_or(0), what.into())
    }
}

/// A field's value. `Fd` holds a descriptor number, not an index: the index
/// only exists on the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    String(String),
    UInt64(u64),
    Bool(bool),
    Bytes(Vec<u8>),
    Fd(RawFd),
}

const MAGIC: &[u8; 4] = b"ABYM";
const VERSION: u8 = 1;

const KIND_STRING: u8 = 1;
const KIND_UINT64: u8 = 2;
const KIND_BOOL: u8 = 3;
const KIND_BYTES: u8 = 4;
const KIND_FD: u8 = 5;

/// A typed IPC message: named fields, insertion-ordered so packing is
/// deterministic.
///
/// **Descriptor ownership.** [`set_fd`](Msg::set_fd) borrows: keep the
/// descriptor open until the message is sent. A received message owns the
/// descriptors that arrived with it: [`take_fd`](Msg::take_fd) hands one
/// over, and the rest close when the message is dropped (Swift's receiver
/// called `closeFDs()` for them).
#[derive(Debug, Default)]
pub struct Msg {
    fields: Vec<(String, Value)>,
    owned: Vec<OwnedFd>,
}

impl Msg {
    /// No frame bigger than this: a control message is a method name and a
    /// few scalars.
    pub const MAX_FRAME: usize = 1 << 20;
    /// At most this many descriptors per message (`AP_MAX_FDS`).
    pub const MAX_FDS: usize = 16;

    pub fn new() -> Msg {
        Msg::default()
    }

    /// The fields, in order.
    pub fn fields(&self) -> &[(String, Value)] {
        &self.fields
    }

    // MARK: building

    /// Set a field, replacing one of the same name in place, so packing
    /// stays stable.
    pub fn set(&mut self, name: &str, value: Value) {
        if let Some(f) = self.fields.iter_mut().find(|f| f.0 == name) {
            f.1 = value;
        } else {
            self.fields.push((name.to_owned(), value));
        }
    }

    pub fn set_string(&mut self, name: &str, value: &str) {
        self.set(name, Value::String(value.to_owned()))
    }
    pub fn set_u64(&mut self, name: &str, value: u64) {
        self.set(name, Value::UInt64(value))
    }
    pub fn set_bool(&mut self, name: &str, value: bool) {
        self.set(name, Value::Bool(value))
    }
    pub fn set_bytes(&mut self, name: &str, value: &[u8]) {
        self.set(name, Value::Bytes(value.to_vec()))
    }
    /// Attach a descriptor, borrowed: keep it open until the message is sent.
    pub fn set_fd(&mut self, name: &str, fd: RawFd) {
        self.set(name, Value::Fd(fd))
    }

    // MARK: reading
    //
    // A getter returns None when the field is absent *or* holds another type:
    // a caller that wanted a number and got a string has the same problem.

    pub fn has(&self, name: &str) -> bool {
        self.value(name).is_some()
    }
    pub fn value(&self, name: &str) -> Option<&Value> {
        self.fields.iter().find(|f| f.0 == name).map(|f| &f.1)
    }
    pub fn string(&self, name: &str) -> Option<&str> {
        match self.value(name) {
            Some(Value::String(s)) => Some(s),
            _ => None,
        }
    }
    pub fn u64(&self, name: &str) -> Option<u64> {
        match self.value(name) {
            Some(Value::UInt64(n)) => Some(*n),
            _ => None,
        }
    }
    pub fn bool(&self, name: &str) -> Option<bool> {
        match self.value(name) {
            Some(Value::Bool(b)) => Some(*b),
            _ => None,
        }
    }
    pub fn bytes(&self, name: &str) -> Option<&[u8]> {
        match self.value(name) {
            Some(Value::Bytes(b)) => Some(b),
            _ => None,
        }
    }
    /// Borrow an attached descriptor (still the message's).
    pub fn fd(&self, name: &str) -> Option<RawFd> {
        match self.value(name) {
            Some(Value::Fd(f)) => Some(*f),
            _ => None,
        }
    }

    /// Take a received descriptor out: the field goes, and the caller owns
    /// it. None for a field that is not a descriptor this message received.
    pub fn take_fd(&mut self, name: &str) -> Option<OwnedFd> {
        let i = self.fields.iter().position(|f| f.0 == name)?;
        let Value::Fd(raw) = self.fields[i].1 else { return None };
        let j = self.owned.iter().position(|o| o.as_raw_fd() == raw)?;
        self.fields.remove(i);
        Some(self.owned.swap_remove(j))
    }

    /// Close every received descriptor still attached, and drop their
    /// fields. Borrowed ones (set with `set_fd`) are only dropped.
    pub fn close_fds(&mut self) {
        self.owned.clear();
        self.fields.retain(|f| !matches!(f.1, Value::Fd(_)));
    }

    /// The descriptors attached, in field order: the order they go into
    /// SCM_RIGHTS, and so what the indices on the wire mean.
    pub fn attached_fds(&self) -> Vec<RawFd> {
        self.fields
            .iter()
            .filter_map(|f| if let Value::Fd(d) = f.1 { Some(d) } else { None })
            .collect()
    }

    // MARK: wire format

    /// The bytes; descriptors become indices ([`attached_fds`](Msg::attached_fds)
    /// are what go alongside).
    pub fn pack(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(64);
        out.extend_from_slice(MAGIC);
        out.push(VERSION);
        out.extend_from_slice(&(self.fields.len() as u16).to_be_bytes());
        let mut fd_index: u8 = 0;
        for (name, value) in &self.fields {
            out.extend_from_slice(&(name.len() as u16).to_be_bytes());
            out.extend_from_slice(name.as_bytes());
            match value {
                Value::String(s) => {
                    out.push(KIND_STRING);
                    out.extend_from_slice(&(s.len() as u32).to_be_bytes());
                    out.extend_from_slice(s.as_bytes());
                }
                Value::UInt64(n) => {
                    out.push(KIND_UINT64);
                    out.extend_from_slice(&n.to_be_bytes());
                }
                Value::Bool(b) => {
                    out.push(KIND_BOOL);
                    out.push(*b as u8);
                }
                Value::Bytes(b) => {
                    out.push(KIND_BYTES);
                    out.extend_from_slice(&(b.len() as u32).to_be_bytes());
                    out.extend_from_slice(b);
                }
                Value::Fd(_) => {
                    out.push(KIND_FD);
                    out.push(fd_index);
                    fd_index = fd_index.wrapping_add(1);
                }
            }
        }
        out
    }

    /// Parse bytes `pack` made. `fds` are the descriptors that arrived over
    /// SCM_RIGHTS, now the message's; an index with no descriptor is
    /// malformed, and on any error they all close.
    pub fn unpack(buf: &[u8], fds: Vec<OwnedFd>) -> Result<Msg, Error> {
        let mut r = Reader { b: buf, i: 0 };
        if r.take(4)? != MAGIC {
            return Err(Error::Malformed("bad magic".into()));
        }
        let v = r.u8()?;
        if v != VERSION {
            return Err(Error::Malformed(format!("unsupported version {v}")));
        }
        let count = r.u16()?;
        let raw: Vec<RawFd> = fds.iter().map(|f| f.as_raw_fd()).collect();
        let mut m = Msg { fields: Vec::new(), owned: fds };
        for _ in 0..count {
            let name_len = r.u16()? as usize;
            // Lenient, as Swift's String(decoding:): bad UTF-8 becomes
            // replacement characters, and a mojibake key just doesn't match.
            let name = String::from_utf8_lossy(r.take(name_len)?).into_owned();
            let kind = r.u8()?;
            let value = match kind {
                KIND_STRING => {
                    let n = r.u32()? as usize;
                    Value::String(String::from_utf8_lossy(r.take(n)?).into_owned())
                }
                KIND_UINT64 => Value::UInt64(r.u64()?),
                KIND_BOOL => Value::Bool(r.u8()? != 0),
                KIND_BYTES => {
                    let n = r.u32()? as usize;
                    Value::Bytes(r.take(n)?.to_vec())
                }
                KIND_FD => {
                    let idx = r.u8()? as usize;
                    let Some(&fd) = raw.get(idx) else {
                        return Err(Error::Malformed(format!(
                            "field '{name}' names fd #{idx}, only {} arrived",
                            raw.len()
                        )));
                    };
                    Value::Fd(fd)
                }
                _ => return Err(Error::Malformed(format!("unknown field kind for '{name}'"))),
            };
            m.set(&name, value);
        }
        Ok(m)
    }
}

/// A bounds-checked cursor: every read succeeds or errs, so a truncated or
/// hostile frame cannot walk off the end.
struct Reader<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], Error> {
        if self.i + n > self.b.len() {
            return Err(Error::Malformed(format!(
                "truncated: wanted {n} bytes at {} of {}",
                self.i,
                self.b.len()
            )));
        }
        let s = &self.b[self.i..self.i + n];
        self.i += n;
        Ok(s)
    }
    fn u8(&mut self) -> Result<u8, Error> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, Error> {
        Ok(u16::from_be_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> Result<u32, Error> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64, Error> {
        Ok(u64::from_be_bytes(self.take(8)?.try_into().unwrap()))
    }
}
