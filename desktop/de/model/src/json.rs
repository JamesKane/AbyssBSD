//! The one wire format's values (JSON.swift, PHASE18 P18.7).
//!
//! The model wire is OpenAI-compatible chat completions, which is JSON, and
//! the tree takes no dependency for it: this is the whole of it. Objects
//! keep their keys in order, so a transcript reads in the order it was
//! sent. Numbers are doubles, written without a fraction when they are
//! whole (token counts stay `42`, not `42.0`), and otherwise as Swift
//! writes them, so the two halves' transcripts are the same bytes.
//!
//! Parsing is RFC 8259's grammar. Swift's is looser where its `Double` and
//! `UInt32` parsers are: it takes `+1`, `01`, `.5`, `1.` and a `\u` escape
//! with a sign in it.

use std::fmt;

#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    // MARK: reading a value

    /// A key's value; the last, where the text gave it twice.
    pub fn get(&self, key: &str) -> Option<&Json> {
        let Json::Object(o) = self else { return None };
        o.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn at(&self, index: usize) -> Option<&Json> {
        let Json::Array(a) = self else { return None };
        a.get(index)
    }

    pub fn as_str(&self) -> Option<&str> {
        if let Json::String(s) = self { Some(s) } else { None }
    }

    pub fn as_f64(&self) -> Option<f64> {
        if let Json::Number(n) = self { Some(*n) } else { None }
    }

    /// A whole number small enough to be exact.
    pub fn as_int(&self) -> Option<i64> {
        self.as_f64().filter(|n| *n == n.round() && n.abs() < 9e15).map(|n| n as i64)
    }

    pub fn as_bool(&self) -> Option<bool> {
        if let Json::Bool(b) = self { Some(*b) } else { None }
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        if let Json::Array(a) = self { Some(a) } else { None }
    }

    /// A copy with `key` set: replaced in place if present, appended if not.
    pub fn setting(&self, key: &str, value: Json) -> Json {
        let Json::Object(o) = self else { return self.clone() };
        let mut o = o.clone();
        match o.iter_mut().find(|(k, _)| k == key) {
            Some(slot) => slot.1 = value,
            None => o.push((key.to_owned(), value)),
        }
        Json::Object(o)
    }

    // MARK: writing

    pub fn text(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut String) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Json::Number(n) => out.push_str(&number_text(*n)),
            Json::String(s) => quote(s, out),
            Json::Array(a) => {
                out.push('[');
                for (i, v) in a.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    v.write(out);
                }
                out.push(']');
            }
            Json::Object(o) => {
                out.push('{');
                for (i, (k, v)) in o.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    quote(k, out);
                    out.push(':');
                    v.write(out);
                }
                out.push('}');
            }
        }
    }

    // MARK: parsing

    /// Exactly one value, whitespace around it allowed. Nesting is limited,
    /// so a hostile body cannot exhaust the stack.
    pub fn parse(bytes: &[u8]) -> Result<Json, ParseError> {
        let mut p = Parser { b: bytes, i: 0 };
        p.ws();
        let v = p.value(0)?;
        p.ws();
        if p.i != bytes.len() {
            return Err(p.fail("text after the value"));
        }
        Ok(v)
    }
}

impl fmt::Display for Json {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.text())
    }
}

/// A number as the wire writes it: whole ones as integers, others as
/// Swift's `Double.description` does (shortest digits that read back;
/// exponential above 2^53 and below 1e-4, with a sign and two digits),
/// and what JSON cannot say as `null`.
fn number_text(n: f64) -> String {
    if n == n.round() && n.abs() < 9e15 {
        return (n as i64).to_string();
    }
    if !n.is_finite() {
        return "null".into();
    }
    let a = n.abs();
    if (1e-4..=9_007_199_254_740_992.0).contains(&a) {
        let d = format!("{n}");
        return if d.contains('.') { d } else { d + ".0" };
    }
    let e = format!("{n:e}"); // "1.5e-7", "1e16"
    let (mantissa, exp) = e.split_once('e').unwrap();
    let (sign, digits) = match exp.strip_prefix('-') {
        Some(d) => ('-', d),
        None => ('+', exp),
    };
    format!("{mantissa}e{sign}{digits:0>2}")
}

fn quote(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    pub offset: usize,
    pub why: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "JSON at byte {}: {}", self.offset, self.why)
    }
}

impl std::error::Error for ParseError {}

const MAX_DEPTH: usize = 128;

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn ws(&mut self) {
        while self.b.get(self.i).is_some_and(|c| matches!(c, b' ' | b'\n' | b'\r' | b'\t')) {
            self.i += 1;
        }
    }

    fn fail(&self, why: &str) -> ParseError {
        ParseError { offset: self.i, why: why.into() }
    }

    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }

    fn value(&mut self, depth: usize) -> Result<Json, ParseError> {
        if depth >= MAX_DEPTH {
            return Err(self.fail("nested too deep"));
        }
        match self.peek() {
            None => Err(self.fail("unexpected end")),
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => Ok(Json::String(self.string()?)),
            Some(b't') => self.word("true", Json::Bool(true)),
            Some(b'f') => self.word("false", Json::Bool(false)),
            Some(b'n') => self.word("null", Json::Null),
            Some(_) => Ok(Json::Number(self.number()?)),
        }
    }

    fn word(&mut self, w: &str, v: Json) -> Result<Json, ParseError> {
        if !self.b[self.i..].starts_with(w.as_bytes()) {
            return Err(self.fail(&format!("expected {w}")));
        }
        self.i += w.len();
        Ok(v)
    }

    fn object(&mut self, depth: usize) -> Result<Json, ParseError> {
        self.i += 1;
        self.ws();
        let mut out = vec![];
        if self.peek() == Some(b'}') {
            self.i += 1;
            return Ok(Json::Object(out));
        }
        loop {
            self.ws();
            if self.peek() != Some(b'"') {
                return Err(self.fail("expected a key"));
            }
            let k = self.string()?;
            self.ws();
            if self.peek() != Some(b':') {
                return Err(self.fail("expected ':'"));
            }
            self.i += 1;
            self.ws();
            out.push((k, self.value(depth + 1)?));
            self.ws();
            match self.peek() {
                None => return Err(self.fail("unexpected end in an object")),
                Some(b',') => self.i += 1,
                Some(b'}') => {
                    self.i += 1;
                    return Ok(Json::Object(out));
                }
                Some(_) => return Err(self.fail("expected ',' or '}'")),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Json, ParseError> {
        self.i += 1;
        self.ws();
        let mut out = vec![];
        if self.peek() == Some(b']') {
            self.i += 1;
            return Ok(Json::Array(out));
        }
        loop {
            self.ws();
            out.push(self.value(depth + 1)?);
            self.ws();
            match self.peek() {
                None => return Err(self.fail("unexpected end in an array")),
                Some(b',') => self.i += 1,
                Some(b']') => {
                    self.i += 1;
                    return Ok(Json::Array(out));
                }
                Some(_) => return Err(self.fail("expected ',' or ']'")),
            }
        }
    }

    /// Four hex digits, and only hex digits.
    fn hex4(&mut self) -> Result<u32, ParseError> {
        let h = self.b.get(self.i..self.i + 4).filter(|h| h.iter().all(u8::is_ascii_hexdigit)).ok_or_else(|| self.fail("bad \\u escape"))?;
        let v = u32::from_str_radix(std::str::from_utf8(h).unwrap(), 16).unwrap();
        self.i += 4;
        Ok(v)
    }

    fn string(&mut self) -> Result<String, ParseError> {
        self.i += 1;
        let mut out: Vec<u8> = vec![];
        loop {
            let Some(c) = self.peek() else { return Err(self.fail("unterminated string")) };
            if c == b'"' {
                self.i += 1;
                break;
            }
            if c < 0x20 {
                return Err(self.fail("a control character in a string"));
            }
            self.i += 1;
            if c != b'\\' {
                out.push(c);
                continue;
            }
            let Some(e) = self.peek() else { return Err(self.fail("unterminated escape")) };
            self.i += 1;
            match e {
                b'"' | b'\\' | b'/' => out.push(e),
                b'b' => out.push(0x08),
                b'f' => out.push(0x0c),
                b'n' => out.push(b'\n'),
                b'r' => out.push(b'\r'),
                b't' => out.push(b'\t'),
                b'u' => {
                    let mut v = self.hex4()?;
                    if (0xd800..0xdc00).contains(&v) {
                        // A surrogate pair.
                        if self.i + 6 > self.b.len() || &self.b[self.i..self.i + 2] != b"\\u" {
                            return Err(self.fail("a lone high surrogate"));
                        }
                        self.i += 2;
                        let lo = self.hex4()?;
                        if !(0xdc00..0xe000).contains(&lo) {
                            return Err(self.fail("a bad low surrogate"));
                        }
                        v = 0x10000 + ((v - 0xd800) << 10) + (lo - 0xdc00);
                    }
                    let ch = char::from_u32(v).ok_or_else(|| self.fail("not a character"))?;
                    out.extend(ch.encode_utf8(&mut [0; 4]).as_bytes());
                }
                _ => return Err(self.fail("unknown escape")),
            }
        }
        Ok(String::from_utf8_lossy(&out).into_owned())
    }

    /// RFC 8259's number: `-`? (`0` | [1-9][0-9]*) (`.` [0-9]+)? ([eE] [+-]? [0-9]+)?
    fn number(&mut self) -> Result<f64, ParseError> {
        let start = self.i;
        let digits = |p: &mut Self| {
            let s = p.i;
            while p.peek().is_some_and(|c| c.is_ascii_digit()) {
                p.i += 1;
            }
            p.i > s
        };
        let refuse = |p: &mut Self| {
            p.i = start;
            Err(p.fail("expected a value"))
        };
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        let int_start = self.i;
        if !digits(self) || (self.b[int_start] == b'0' && self.i - int_start > 1) {
            return refuse(self);
        }
        if self.peek() == Some(b'.') {
            self.i += 1;
            if !digits(self) {
                return refuse(self);
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.i += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.i += 1;
            }
            if !digits(self) {
                return refuse(self);
            }
        }
        Ok(std::str::from_utf8(&self.b[start..self.i]).unwrap().parse().unwrap())
    }
}
