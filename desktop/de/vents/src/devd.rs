//! devd(8): how a FreeBSD desktop learns about hotplug, power and media
//! without udev or acpid (Devd.swift).
//!
//! devd publishes newline-delimited events on `/var/run/devd.pipe`; a
//! client connects and reads. The first byte is the event's type:
//!
//! ```text
//! +ugen0.2 at ...          a device attached
//! -ugen0.2 at ...          a device detached
//! !system=DEVFS ...        a notify, carrying key=value fields
//! ?  at ...                a device with no matching driver
//! ```

use std::io::{self, Read};
use std::os::fd::{AsFd, BorrowedFd};
use std::os::unix::net::UnixStream;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EventKind {
    /// `!`: key=value fields.
    Notify,
    /// `+`: a device arrived.
    Attach,
    /// `-`: a device went away.
    Detach,
    /// `?`: no driver claimed it.
    Nomatch,
    Unknown,
}

/// One line from devd.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Event {
    pub kind: EventKind,
    /// The line without its type byte and line ending.
    pub raw: String,
    /// `key=value` pairs; notify events only.
    pub fields: Vec<(String, String)>,
}

impl Event {
    /// A line, with any CR and LF at its end dropped (to Swift a CRLF is one
    /// Character that is neither, and stays).
    pub fn new(line: &str) -> Event {
        let s = line.trim_end_matches(['\n', '\r']);
        let kind = match s.chars().next() {
            Some('!') => EventKind::Notify,
            Some('+') => EventKind::Attach,
            Some('-') => EventKind::Detach,
            Some('?') => EventKind::Nomatch,
            _ => EventKind::Unknown,
        };
        let raw = if kind == EventKind::Unknown { s.to_owned() } else { s[1..].to_owned() };
        let fields = if kind == EventKind::Notify { parse_fields(&raw) } else { vec![] };
        Event { kind, raw, fields }
    }

    /// The device of an attach or detach: the first word.
    pub fn device(&self) -> Option<&str> {
        match self.kind {
            EventKind::Attach | EventKind::Detach => self.raw.split([' ', '\t']).find(|w| !w.is_empty()),
            _ => None,
        }
    }

    /// A notify field.
    pub fn value(&self, key: &str) -> Option<&str> {
        self.fields.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }

    /// One readable line, for logs.
    pub fn summary(&self) -> String {
        match self.kind {
            EventKind::Attach => format!("attach {}", self.device().unwrap_or("?")),
            EventKind::Detach => format!("detach {}", self.device().unwrap_or("?")),
            EventKind::Notify => format!("notify {}", self.raw),
            EventKind::Nomatch => format!("nomatch {}", self.raw),
            EventKind::Unknown => format!("event {}", self.raw),
        }
    }
}

/// `key=value` pairs, honouring the double quotes devd puts around values
/// with spaces in them (`CDB="00 00 00 "`): splitting on whitespace alone
/// chops that value up and loses the field. Real devd output looks so.
pub(crate) fn parse_fields(s: &str) -> Vec<(String, String)> {
    let mut out = vec![];
    let (mut key, mut value) = (String::new(), String::new());
    let (mut in_value, mut quoted) = (false, false);
    let mut flush = |key: &mut String, value: &mut String, in_value: &mut bool| {
        if !key.is_empty() {
            out.push((std::mem::take(key), std::mem::take(value)));
        }
        key.clear();
        value.clear();
        *in_value = false;
    };
    for c in s.chars() {
        if quoted {
            if c == '"' {
                quoted = false;
            } else {
                value.push(c);
            }
            continue;
        }
        match c {
            '=' if !in_value => in_value = true,
            '"' if in_value && value.is_empty() => quoted = true,
            ' ' | '\t' => flush(&mut key, &mut value, &mut in_value),
            c if in_value => value.push(c),
            c => key.push(c),
        }
    }
    flush(&mut key, &mut value, &mut in_value);
    out
}

/// A connection to devd's event socket. Its descriptor is pollable, so
/// hotplug folds into a component's run loop: no thread, no polling.
pub struct Devd {
    stream: UnixStream,
    pending: Vec<u8>,
}

impl Devd {
    /// The stream socket devd publishes on.
    pub const DEFAULT_PATH: &str = "/var/run/devd.pipe";

    /// Connect, or None when devd isn't running (or isn't a thing, as on
    /// Linux): the caller then has no hotplug, rather than an error.
    pub fn connect(path: &str) -> Option<Devd> {
        let stream = UnixStream::connect(path).ok()?;
        stream.set_nonblocking(true).ok()?;
        Some(Devd { stream, pending: vec![] })
    }

    pub fn fd(&self) -> BorrowedFd<'_> {
        self.stream.as_fd()
    }

    /// Whatever devd has queued, as complete events. A partial line is held
    /// back, as bytes, until its newline arrives: devd writes whole events,
    /// but a stream socket may split one (and a character) across two
    /// reads, and half an event parsed as a whole one is a silent lie.
    pub fn read(&mut self) -> Vec<Event> {
        let mut buf = vec![0u8; 64 * 1024];
        match self.stream.read(&mut buf) {
            Ok(n) if n > 0 => self.pending.extend_from_slice(&buf[..n]),
            Err(e) if e.kind() != io::ErrorKind::WouldBlock => return vec![],
            _ => return vec![],
        }
        let mut events = vec![];
        while let Some(nl) = self.pending.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.pending.drain(..=nl).collect();
            let text = String::from_utf8_lossy(&line[..nl]);
            if !text.is_empty() {
                events.push(Event::new(&text));
            }
        }
        events
    }
}
