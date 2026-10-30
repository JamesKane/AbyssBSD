//! The message (Message.swift): a fixed 12-byte prologue, an array of header
//! fields, padding to 8, then the body. Two subtleties, both silent when
//! wrong:
//!
//! 1. The body's declared length does not include the header, but the body
//!    is marshalled at an offset that does: its origin is the padded header
//!    length, not zero.
//! 2. `UNIX_FDS` (field 9) must be present and right whenever descriptors
//!    ride along, or the peer does not look for them.

use crate::marshal::{Marshaller, Unmarshaller};
use crate::value::{split_signature, Value};
use crate::Error;
use std::os::fd::RawFd;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MessageType {
    MethodCall = 1,
    MethodReturn = 2,
    Error = 3,
    Signal = 4,
}

impl MessageType {
    fn from_byte(b: u8) -> Option<MessageType> {
        Some(match b {
            1 => MessageType::MethodCall,
            2 => MessageType::MethodReturn,
            3 => MessageType::Error,
            4 => MessageType::Signal,
            _ => return None,
        })
    }
}

/// The header's flags byte.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Flags(pub u8);

impl Flags {
    pub const NO_REPLY_EXPECTED: Flags = Flags(1);
    pub const NO_AUTO_START: Flags = Flags(2);

    pub fn contains(self, f: Flags) -> bool {
        self.0 & f.0 == f.0
    }
}

impl std::ops::BitOr for Flags {
    type Output = Flags;
    fn bitor(self, o: Flags) -> Flags {
        Flags(self.0 | o.0)
    }
}

// Header field codes, from the specification.
const PATH: u8 = 1;
const INTERFACE: u8 = 2;
const MEMBER: u8 = 3;
const ERROR_NAME: u8 = 4;
const REPLY_SERIAL: u8 = 5;
const DESTINATION: u8 = 6;
const SENDER: u8 = 7;
const SIGNATURE: u8 = 8;
const UNIX_FDS: u8 = 9;

#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    pub kind: MessageType,
    pub flags: Flags,
    pub serial: u32,
    pub path: Option<String>,
    pub interface: Option<String>,
    pub member: Option<String>,
    pub error_name: Option<String>,
    pub reply_serial: Option<u32>,
    pub destination: Option<String>,
    pub sender: Option<String>,
    pub body: Vec<Value>,
    /// Descriptors to send beyond those the body's `h` values name. Empty
    /// on a decoded message, whose descriptors are in its body: so a decoded
    /// message encodes back to itself (Swift's carries every descriptor that
    /// arrived, and re-encoding it sends them twice; the bridge clears it).
    pub fds: Vec<RawFd>,
    /// On a decoded message, its `UNIX_FDS`: how many of the descriptors
    /// that arrived are this message's, the rest being the next one's. A
    /// forwarder consumes exactly this many (BACKLOG D.1).
    pub declared_fds: u32,
}

impl Message {
    pub fn new(kind: MessageType) -> Message {
        Message {
            kind,
            flags: Flags::default(),
            serial: 0,
            path: None,
            interface: None,
            member: None,
            error_name: None,
            reply_serial: None,
            destination: None,
            sender: None,
            body: vec![],
            fds: vec![],
            declared_fds: 0,
        }
    }

    pub fn signature(&self) -> String {
        self.body.iter().map(Value::signature).collect()
    }

    pub fn method_call(destination: &str, path: &str, interface: &str, member: &str, body: Vec<Value>) -> Message {
        Message {
            destination: Some(destination.into()),
            path: Some(path.into()),
            interface: Some(interface.into()),
            member: Some(member.into()),
            body,
            ..Message::new(MessageType::MethodCall)
        }
    }

    pub fn method_return(call: &Message, body: Vec<Value>) -> Message {
        Message { reply_serial: Some(call.serial), destination: call.sender.clone(), body, ..Message::new(MessageType::MethodReturn) }
    }

    pub fn error(call: &Message, name: &str, message: &str) -> Message {
        Message {
            error_name: Some(name.into()),
            reply_serial: Some(call.serial),
            destination: call.sender.clone(),
            body: vec![Value::String(message.into())],
            ..Message::new(MessageType::Error)
        }
    }

    /// A signal. **Pass `to` whenever it answers a particular client**: a
    /// broadcast reaches only clients that added a match rule, and one that
    /// expects to be addressed adds none, so never hears it (HANDOFF §2.40).
    pub fn signal(path: &str, interface: &str, member: &str, to: Option<&str>, body: Vec<Value>) -> Message {
        Message {
            path: Some(path.into()),
            interface: Some(interface.into()),
            member: Some(member.into()),
            destination: to.map(str::to_owned),
            body,
            ..Message::new(MessageType::Signal)
        }
    }

    // MARK: encoding

    /// The bytes, and the descriptors to send with them.
    pub fn encode(&self) -> Result<(Vec<u8>, Vec<RawFd>), Error> {
        // The body's origin is the padded header length, which depends on
        // whether UNIX_FDS is there, which depends on the body: so count the
        // body's descriptors first, then lay the header out once.
        let mut probe = Marshaller::new(0);
        for v in &self.body {
            probe.value(v)?;
        }
        let fd_count = self.fds.len() + probe.fds.len();
        let fields = self.fields(u32::try_from(fd_count).map_err(|_| Error::new("too many descriptors"))?)?;
        let body_origin = (16 + fields.len()).next_multiple_of(8);
        let mut body = Marshaller::new(body_origin);
        for v in &self.body {
            body.value(v)?;
        }
        let mut out = vec![b'l', self.kind as u8, self.flags.0, 1];
        out.extend(u32::try_from(body.bytes.len()).map_err(|_| Error::new("a body longer than 4 GiB"))?.to_le_bytes());
        out.extend(self.serial.to_le_bytes());
        out.extend((fields.len() as u32).to_le_bytes());
        out.extend(fields);
        out.resize(body_origin, 0);
        out.extend(body.bytes);
        let mut fds = self.fds.clone();
        fds.extend(body.fds);
        Ok((out, fds))
    }

    fn fields(&self, fd_count: u32) -> Result<Vec<u8>, Error> {
        // Fields start after the 12-byte prologue and the u32 array length.
        let mut m = Marshaller::new(16);
        let mut field = |code: u8, v: Value| {
            m.align(8);
            m.byte(code);
            m.value(&Value::Variant(Box::new(v)))
        };
        let s = |s: &Option<String>| s.clone().map(Value::String);
        if let Some(p) = &self.path {
            field(PATH, Value::ObjectPath(p.clone()))?;
        }
        for (code, v) in [(INTERFACE, s(&self.interface)), (MEMBER, s(&self.member)), (ERROR_NAME, s(&self.error_name))] {
            if let Some(v) = v {
                field(code, v)?;
            }
        }
        if let Some(r) = self.reply_serial {
            field(REPLY_SERIAL, Value::UInt32(r))?;
        }
        for (code, v) in [(DESTINATION, s(&self.destination)), (SENDER, s(&self.sender))] {
            if let Some(v) = v {
                field(code, v)?;
            }
        }
        if !self.body.is_empty() {
            field(SIGNATURE, Value::Signature(self.signature()))?;
        }
        if fd_count > 0 {
            field(UNIX_FDS, Value::UInt32(fd_count))?;
        }
        Ok(m.bytes)
    }

    // MARK: decoding

    /// How many bytes the message starting at `bytes` needs in total, or
    /// None while its 16-byte prologue has not arrived.
    pub fn framed_length(bytes: &[u8]) -> Option<usize> {
        let prologue: &[u8; 16] = bytes.get(..16)?.try_into().ok()?;
        let u32_at = |at: usize| {
            let b: [u8; 4] = prologue[at..at + 4].try_into().unwrap();
            (if prologue[0] == b'l' { u32::from_le_bytes(b) } else { u32::from_be_bytes(b) }) as usize
        };
        Some((16 + u32_at(12)).next_multiple_of(8) + u32_at(4))
    }

    pub fn decode(bytes: &[u8], fds: &[RawFd]) -> Result<Message, Error> {
        if bytes.len() < 16 {
            return Err(Error::new("message shorter than its prologue"));
        }
        let le = match bytes[0] {
            b'l' => true,
            b'B' => false,
            _ => return Err(Error::new("bad endianness byte")),
        };
        let kind = MessageType::from_byte(bytes[1]).ok_or_else(|| Error::new(format!("unknown message type {}", bytes[1])))?;
        let mut m = Message { flags: Flags(bytes[2]), ..Message::new(kind) };
        let mut head = Unmarshaller::new(&bytes[4..16], 4, le, fds);
        let body_len = head.u32()? as usize;
        m.serial = head.u32()?;
        let fields_len = head.u32()? as usize;

        let fields_end = 16 + fields_len;
        let Some(field_bytes) = bytes.get(16..fields_end) else { return Err(Error::new("header fields run past the message")) };
        let mut f = Unmarshaller::new(field_bytes, 16, le, fds);
        let mut body_signature = String::new();
        while f.remaining() > 0 {
            f.align(8)?;
            if f.remaining() == 0 {
                break;
            }
            let code = f.byte()?;
            let Value::Variant(inner) = f.value("v")? else { unreachable!() };
            // A field of the wrong type, or one we do not know, is ignored.
            match (code, *inner) {
                (PATH, Value::ObjectPath(s)) => m.path = Some(s),
                (INTERFACE, Value::String(s)) => m.interface = Some(s),
                (MEMBER, Value::String(s)) => m.member = Some(s),
                (ERROR_NAME, Value::String(s)) => m.error_name = Some(s),
                (REPLY_SERIAL, Value::UInt32(n)) => m.reply_serial = Some(n),
                (DESTINATION, Value::String(s)) => m.destination = Some(s),
                (SENDER, Value::String(s)) => m.sender = Some(s),
                (SIGNATURE, Value::Signature(s)) => body_signature = s,
                (UNIX_FDS, Value::UInt32(n)) => m.declared_fds = n,
                _ => {}
            }
        }

        let body_start = fields_end.next_multiple_of(8);
        let Some(body) = bytes.get(body_start..body_start + body_len) else { return Err(Error::new("body runs past the message")) };
        if body_len > 0 && !body_signature.is_empty() {
            let mut b = Unmarshaller::new(body, body_start, le, fds);
            for part in split_signature(&body_signature)? {
                m.body.push(b.value(part)?);
            }
        }
        Ok(m)
    }
}
