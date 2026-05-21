// SPDX-License-Identifier: BSD-2-Clause

//! A bounds-checked cursor over input bytes.
//!
//! Every read is fallible; none can panic or run past the end of the
//! buffer (`docs/design/wire-format.md` §4). Length arithmetic is checked
//! so it is correct on a 32-bit `usize` too (`DESIGN.md` §3.6).

use crate::error::WireError;

pub(crate) struct Decoder<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Decoder<'a> {
    pub(crate) fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    pub(crate) fn at_end(&self) -> bool {
        self.pos == self.buf.len()
    }

    /// Consume exactly `n` bytes, or fail without consuming any.
    pub(crate) fn take(&mut self, n: usize) -> Result<&'a [u8], WireError> {
        let end = self
            .pos
            .checked_add(n)
            .filter(|end| *end <= self.buf.len())
            .ok_or(WireError::Truncated)?;
        let slice = &self.buf[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    pub(crate) fn u8(&mut self) -> Result<u8, WireError> {
        Ok(self.take(1)?[0])
    }

    pub(crate) fn u16(&mut self) -> Result<u16, WireError> {
        let b = self.take(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }

    pub(crate) fn u32(&mut self) -> Result<u32, WireError> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub(crate) fn i64(&mut self) -> Result<i64, WireError> {
        let b = self.take(8)?;
        Ok(i64::from_le_bytes(b.try_into().expect("took 8 bytes")))
    }

    pub(crate) fn f64(&mut self) -> Result<f64, WireError> {
        let b = self.take(8)?;
        Ok(f64::from_le_bytes(b.try_into().expect("took 8 bytes")))
    }

    pub(crate) fn bool_byte(&mut self) -> Result<bool, WireError> {
        match self.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            other => Err(WireError::BadBool(other)),
        }
    }

    /// A `u32` length prefix, then that many raw bytes.
    pub(crate) fn blob(&mut self) -> Result<&'a [u8], WireError> {
        let len = self.u32()? as usize;
        self.take(len)
    }

    /// A `blob`, validated as UTF-8.
    pub(crate) fn string(&mut self) -> Result<String, WireError> {
        let bytes = self.blob()?;
        std::str::from_utf8(bytes)
            .map(str::to_owned)
            .map_err(|_| WireError::BadUtf8)
    }
}
