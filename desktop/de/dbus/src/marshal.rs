//! Marshalling and unmarshalling (Marshal.swift).
//!
//! **Every value is aligned to its natural boundary, measured from the
//! start of the message**: a header's fields and a body are marshalled into
//! separate buffers but share one origin, so both halves carry it rather
//! than trusting the buffer's length. Getting that wrong produces bytes our
//! own reader accepts and every real bus rejects.
//!
//! Little-endian on the write side (declared `l`, which the spec allows);
//! the read side honours whatever the peer declared.

use crate::value::{alignment_of, split_signature, Value};
use crate::Error;
use std::os::fd::RawFd;

/// The deepest a value may nest, arrays, structs, dict entries and variants
/// together: the specification's 64. Swift has no limit, so a message of
/// nested variants runs its stack out.
pub const MAX_DEPTH: usize = 64;

// MARK: writing

#[derive(Default)]
pub struct Marshaller {
    pub bytes: Vec<u8>,
    /// How many bytes precede this buffer in the message, for alignment.
    origin: usize,
    /// Descriptors collected while marshalling, to travel over SCM_RIGHTS.
    pub fds: Vec<RawFd>,
}

impl Marshaller {
    pub fn new(origin: usize) -> Marshaller {
        Marshaller { origin, ..Marshaller::default() }
    }

    pub fn align(&mut self, n: usize) {
        while !(self.origin + self.bytes.len()).is_multiple_of(n) {
            self.bytes.push(0);
        }
    }

    pub fn byte(&mut self, v: u8) {
        self.bytes.push(v);
    }

    pub fn u16(&mut self, v: u16) {
        self.align(2);
        self.bytes.extend(v.to_le_bytes());
    }

    pub fn u32(&mut self, v: u32) {
        self.align(4);
        self.bytes.extend(v.to_le_bytes());
    }

    pub fn u64(&mut self, v: u64) {
        self.align(8);
        self.bytes.extend(v.to_le_bytes());
    }

    /// A string: u32 length, the UTF-8, then a NUL that is *not* counted.
    pub fn string(&mut self, s: &str) -> Result<(), Error> {
        self.u32(u32::try_from(s.len()).map_err(|_| Error::new("a string longer than 4 GiB"))?);
        self.bytes.extend(s.as_bytes());
        self.bytes.push(0);
        Ok(())
    }

    /// A signature: a *byte* length, the text, then a NUL. Swift traps on
    /// one longer than 255; this refuses it.
    pub fn signature(&mut self, s: &str) -> Result<(), Error> {
        let n = u8::try_from(s.len()).map_err(|_| Error::new(format!("a signature of {} bytes (the most is 255)", s.len())))?;
        self.bytes.push(n);
        self.bytes.extend(s.as_bytes());
        self.bytes.push(0);
        Ok(())
    }

    pub fn value(&mut self, v: &Value) -> Result<(), Error> {
        match v {
            Value::Byte(b) => self.byte(*b),
            Value::Bool(b) => self.u32((*b).into()),
            Value::UInt16(n) => self.u16(*n),
            Value::Int32(n) => self.u32(*n as u32),
            Value::UInt32(n) => self.u32(*n),
            Value::UInt64(n) => self.u64(*n),
            // Its bit pattern, so it inherits `t`'s alignment.
            Value::Double(d) => self.u64(d.to_bits()),
            Value::String(s) | Value::ObjectPath(s) => self.string(s)?,
            Value::Signature(s) => self.signature(s)?,
            Value::UnixFd(fd) => {
                // The wire carries an INDEX; the descriptor rides out of band.
                self.u32(self.fds.len() as u32);
                self.fds.push(*fd);
            }
            Value::Array(elem, items) => {
                // The length does NOT include the padding between it and the
                // first element, so align before measuring. And an item must
                // be what the signature says, or the reader misreads it.
                self.align(4);
                let length_at = self.bytes.len();
                self.bytes.extend([0; 4]);
                self.align(alignment_of(elem));
                let start = self.bytes.len();
                for item in items {
                    if item.signature() != *elem {
                        return Err(Error::new(format!("an array of {elem} holds a {}", item.signature())));
                    }
                    self.value(item)?;
                }
                let length = u32::try_from(self.bytes.len() - start).map_err(|_| Error::new("an array longer than 4 GiB"))?;
                self.bytes[length_at..length_at + 4].copy_from_slice(&length.to_le_bytes());
            }
            Value::Struct(items) => {
                self.align(8);
                for item in items {
                    self.value(item)?;
                }
            }
            Value::DictEntry(k, v) => {
                self.align(8);
                self.value(k)?;
                self.value(v)?;
            }
            Value::Variant(inner) => {
                self.signature(&inner.signature())?;
                self.value(inner)?;
            }
        }
        Ok(())
    }
}

// MARK: reading

pub struct Unmarshaller<'a> {
    bytes: &'a [u8],
    pos: usize,
    origin: usize,
    pub little_endian: bool,
    /// Descriptors that arrived with the message; `h` indexes into these.
    pub fds: &'a [RawFd],
    depth: usize,
}

impl<'a> Unmarshaller<'a> {
    /// A reader over `bytes`, which start `origin` bytes into the message.
    pub fn new(bytes: &'a [u8], origin: usize, little_endian: bool, fds: &'a [RawFd]) -> Unmarshaller<'a> {
        Unmarshaller { bytes, pos: 0, origin, little_endian, fds, depth: 0 }
    }

    pub fn offset(&self) -> usize {
        self.pos
    }

    pub fn remaining(&self) -> usize {
        self.bytes.len() - self.pos
    }

    pub fn align(&mut self, n: usize) -> Result<(), Error> {
        while !(self.origin + self.pos).is_multiple_of(n) {
            if self.pos >= self.bytes.len() {
                return Err(Error::new("truncated padding"));
            }
            self.pos += 1;
        }
        Ok(())
    }

    fn take<const N: usize>(&mut self, what: &str) -> Result<[u8; N], Error> {
        let b = self.bytes.get(self.pos..self.pos + N).ok_or_else(|| Error::new(format!("truncated {what}")))?;
        self.pos += N;
        let mut a: [u8; N] = b.try_into().unwrap();
        if self.little_endian {
            a.reverse();
        }
        Ok(a) // big-endian order now
    }

    pub fn byte(&mut self) -> Result<u8, Error> {
        Ok(self.take::<1>("byte")?[0])
    }

    pub fn u16(&mut self) -> Result<u16, Error> {
        self.align(2)?;
        Ok(u16::from_be_bytes(self.take("uint16")?))
    }

    pub fn u32(&mut self) -> Result<u32, Error> {
        self.align(4)?;
        Ok(u32::from_be_bytes(self.take("uint32")?))
    }

    pub fn u64(&mut self) -> Result<u64, Error> {
        self.align(8)?;
        Ok(u64::from_be_bytes(self.take("uint64")?))
    }

    /// `n` bytes of text and the NUL after them, as lenient UTF-8.
    fn text(&mut self, n: usize, what: &str) -> Result<String, Error> {
        let b = self.bytes.get(self.pos..).filter(|b| b.len() > n).ok_or_else(|| Error::new(format!("truncated {what}")))?;
        let s = String::from_utf8_lossy(&b[..n]).into_owned();
        self.pos += n + 1; // and the NUL
        Ok(s)
    }

    pub fn string(&mut self) -> Result<String, Error> {
        let n = self.u32()? as usize;
        self.text(n, "string")
    }

    pub fn signature(&mut self) -> Result<String, Error> {
        let n = self.byte()? as usize;
        self.text(n, "signature")
    }

    /// One complete type named by `sig`.
    pub fn value(&mut self, sig: &str) -> Result<Value, Error> {
        let Some(c) = sig.chars().next() else { return Err(Error::new("empty signature")) };
        if matches!(c, 'a' | '(' | '{' | 'v') {
            if self.depth == MAX_DEPTH {
                return Err(Error::new(format!("values nested deeper than {MAX_DEPTH}")));
            }
            self.depth += 1;
            let v = self.container(c, sig);
            self.depth -= 1;
            return v;
        }
        if sig.len() != c.len_utf8() {
            return Err(Error::new(format!("\"{sig}\" is not one type")));
        }
        Ok(match c {
            'y' => Value::Byte(self.byte()?),
            'b' => Value::Bool(self.u32()? != 0),
            'q' => Value::UInt16(self.u16()?),
            'i' => Value::Int32(self.u32()? as i32),
            'u' => Value::UInt32(self.u32()?),
            't' => Value::UInt64(self.u64()?),
            'd' => Value::Double(f64::from_bits(self.u64()?)),
            's' => Value::String(self.string()?),
            'o' => Value::ObjectPath(self.string()?),
            'g' => Value::Signature(self.signature()?),
            'h' => {
                let i = self.u32()? as usize;
                Value::UnixFd(*self.fds.get(i).ok_or_else(|| Error::new(format!("fd index {i} out of range")))?)
            }
            c => return Err(Error::new(format!("unsupported type '{c}'"))),
        })
    }

    fn container(&mut self, c: char, sig: &str) -> Result<Value, Error> {
        // The whole of `sig` must be one complete type.
        if split_signature(sig)?.len() != 1 {
            return Err(Error::new(format!("\"{sig}\" is not one type")));
        }
        match c {
            'v' => {
                let inner = self.signature()?;
                Ok(Value::Variant(Box::new(self.value(&inner)?)))
            }
            'a' => {
                let elem = &sig[1..];
                let length = self.u32()? as usize;
                self.align(alignment_of(elem))?;
                let end = self.pos + length;
                if end > self.bytes.len() {
                    return Err(Error::new("array runs past the message"));
                }
                let mut items = vec![];
                while self.pos < end {
                    items.push(self.value(elem)?);
                }
                if self.pos != end {
                    return Err(Error::new("array overran its declared length"));
                }
                Ok(Value::Array(elem.to_owned(), items))
            }
            '(' => {
                self.align(8)?;
                let items = split_signature(&sig[1..sig.len() - 1])?.into_iter().map(|p| self.value(p)).collect::<Result<_, _>>()?;
                Ok(Value::Struct(items))
            }
            _ => {
                self.align(8)?;
                let parts = split_signature(&sig[1..sig.len() - 1])?;
                Ok(Value::DictEntry(Box::new(self.value(parts[0])?), Box::new(self.value(parts[1])?)))
            }
        }
    }
}
