//! Just enough HTTP/1.1 for the model wire (HTTP.swift, PHASE18 P18.7).
//!
//! `abyss-model` speaks OpenAI-compatible chat completions **over a unix
//! socket**, so any OpenAI client (and `curl --unix-socket`) can use it, and
//! calls llama.cpp's `llama-server` over a unix socket or loopback TCP. One
//! request per connection, `Content-Length` bodies, no chunking, no
//! keep-alive: the agent is one client asking one thing at a time, and a
//! parser this small is one that can be read.

use crate::json::Json;
use std::fmt;
use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::time::Duration;

pub const MAX_HEAD: usize = 64 << 10;
pub const MAX_BODY: usize = 32 << 20;

/// Why an HTTP exchange did not happen, in words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure(pub String);

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Failure {}

fn fail<T>(why: impl Into<String>) -> Result<T, Failure> {
    Err(Failure(why.into()))
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers.iter().rev().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        header(&self.headers, name)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub reason: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn json(status: u16, reason: &str, json: &Json) -> Response {
        Response { status, reason: reason.into(), headers: vec![("Content-Type".into(), "application/json".into())], body: json.text().into_bytes() }
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        header(&self.headers, name)
    }

    /// The bytes on the wire: its own length, and `Connection: close`.
    pub fn bytes(&self) -> Vec<u8> {
        let mut head = format!("HTTP/1.1 {} {}\r\n", self.status, self.reason);
        for (k, v) in &self.headers {
            if !k.eq_ignore_ascii_case("content-length") && !k.eq_ignore_ascii_case("connection") {
                head += &format!("{k}: {v}\r\n");
            }
        }
        head += &format!("Content-Length: {}\r\nConnection: close\r\n\r\n", self.body.len());
        let mut out = head.into_bytes();
        out.extend_from_slice(&self.body);
        out
    }
}

/// Where the head ends (just past "\r\n\r\n"), if it has.
fn head_end(b: &[u8]) -> Option<usize> {
    b.windows(4).position(|w| w == b"\r\n\r\n").map(|i| i + 4)
}

/// A head's start line and its headers.
fn lines(head: &[u8]) -> (String, Vec<(String, String)>) {
    let text = String::from_utf8_lossy(head);
    let mut rows = text.split("\r\n").filter(|r| !r.is_empty());
    let start = rows.next().unwrap_or("").to_owned();
    let headers = rows.filter_map(|r| r.split_once(':').map(|(k, v)| (k.to_owned(), v.trim_start_matches(' ').to_owned()))).collect();
    (start, headers)
}

/// A complete request from `bytes`, or None while more are needed.
pub fn request(bytes: &[u8]) -> Result<Option<Request>, Failure> {
    let Some(end) = head_end(bytes) else {
        return if bytes.len() > MAX_HEAD { fail(format!("a request head over {MAX_HEAD} bytes")) } else { Ok(None) };
    };
    let (start, headers) = lines(&bytes[..end]);
    let parts: Vec<&str> = start.split(' ').filter(|p| !p.is_empty()).collect();
    if parts.len() != 3 || !parts[2].starts_with("HTTP/1.") {
        return fail(format!("not an HTTP/1 request line: {start}"));
    }
    if header(&headers, "transfer-encoding").is_some() {
        return fail("chunked bodies are not accepted");
    }
    let length = match header(&headers, "content-length") {
        None => 0,
        Some(v) => match v.trim().parse::<usize>() {
            Ok(n) if n <= MAX_BODY => n,
            _ => return fail(format!("a body of {v} bytes")),
        },
    };
    if bytes.len() < end + length {
        return Ok(None);
    }
    Ok(Some(Request { method: parts[0].into(), path: parts[1].into(), headers, body: bytes[end..end + length].to_vec() }))
}

/// A complete response from `bytes`, read to EOF (`Connection: close`).
pub fn response(bytes: &[u8]) -> Result<Response, Failure> {
    let Some(end) = head_end(bytes) else { return fail("no response head") };
    let (start, headers) = lines(&bytes[..end]);
    let mut parts = start.splitn(3, ' ');
    let (version, status) = (parts.next().unwrap_or(""), parts.next().and_then(|s| s.parse::<u16>().ok()));
    let Some(status) = status.filter(|_| version.starts_with("HTTP/1.")) else {
        return fail(format!("not an HTTP/1 status line: {start}"));
    };
    let mut body = bytes[end..].to_vec();
    if let Some(l) = header(&headers, "content-length").and_then(|v| v.trim().parse::<usize>().ok())
        && l <= body.len()
    {
        body.truncate(l);
    }
    Ok(Response { status, reason: parts.next().unwrap_or("").into(), headers, body })
}

/// Read one request from a connection.
pub fn read_request(c: &mut impl Read) -> Result<Option<Request>, Failure> {
    let mut got = vec![];
    let mut buf = vec![0u8; 65536];
    loop {
        if let Some(r) = request(&got)? {
            return Ok(Some(r));
        }
        match c.read(&mut buf) {
            Ok(0) => return Ok(None),
            Ok(n) => got.extend_from_slice(&buf[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return fail(format!("read: {e}")),
        }
        if got.len() > MAX_HEAD + MAX_BODY {
            return fail(format!("more than {} bytes", MAX_HEAD + MAX_BODY));
        }
    }
}

pub fn send(r: &Response, c: &mut impl Write) -> Result<(), Failure> {
    c.write_all(&r.bytes()).map_err(|e| Failure(format!("write: {e}")))
}

// MARK: the client

/// Where a server is: loopback TCP, a unix socket (how `abyss-model` runs
/// `llama-server` itself, so a local model has no port at all), or TLS over
/// TCP, whose certificate must chain to a trusted CA (the system's, or
/// `cafile`) and name `host` (P18.12a).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Endpoint {
    Tcp { host: String, port: u16 },
    Unix(String),
    Tls { host: String, port: u16, cafile: Option<String> },
}

impl Endpoint {
    fn host_header(&self) -> String {
        match self {
            Endpoint::Tcp { host, port } => format!("{host}:{port}"),
            Endpoint::Tls { host, port: 443, .. } => host.clone(),
            Endpoint::Tls { host, port, .. } => format!("{host}:{port}"),
            Endpoint::Unix(_) => "localhost".into(),
        }
    }
}

/// A connected stream: unix, TCP, or TLS over TCP.
enum Stream {
    Unix(UnixStream),
    Tcp(TcpStream),
    // The TLS session first, so it is closed before the socket it runs on,
    // which is held for that and not read.
    Tls { tls: abyss_sys::tls::Tls, _socket: TcpStream },
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Stream::Unix(s) => s.read(buf),
            Stream::Tcp(s) => s.read(buf),
            Stream::Tls { tls, .. } => tls.read(buf),
        }
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            Stream::Unix(s) => s.write(buf),
            Stream::Tcp(s) => s.write(buf),
            Stream::Tls { tls, .. } => tls.write(buf),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// `address`: connect to this numeric address rather than resolving the
/// host again, the one a caller already checked (the fetch bridge, so a DNS
/// answer that changes between the check and the connection cannot slip in
/// a local address). The host still names the server for TLS and `Host:`.
fn open(to: &Endpoint, timeout: Duration, address: Option<&str>) -> Result<Stream, Failure> {
    let tcp = |host: &str, port: u16| -> Result<TcpStream, Failure> {
        let addrs: Vec<SocketAddr> = match address {
            Some(a) => vec![SocketAddr::new(a.parse::<IpAddr>().map_err(|_| Failure(format!("not an address: {a}")))?, port)],
            None => (host, port).to_socket_addrs().map_err(|_| Failure(format!("cannot resolve {host}")))?.collect(),
        };
        let first = addrs.first().ok_or_else(|| Failure(format!("cannot resolve {host}")))?;
        let s = TcpStream::connect(first).map_err(|e| Failure(format!("connect {host}:{port}: {}", words(&e))))?;
        let _ = s.set_read_timeout(Some(timeout));
        Ok(s)
    };
    Ok(match to {
        Endpoint::Tcp { host, port } => Stream::Tcp(tcp(host, *port)?),
        Endpoint::Tls { host, port, cafile } => {
            let s = tcp(host, *port)?;
            let t = abyss_sys::tls::Tls::open(s.as_fd(), host, cafile.as_deref()).map_err(Failure)?;
            Stream::Tls { tls: t, _socket: s }
        }
        Endpoint::Unix(path) => {
            let s = UnixStream::connect(path).map_err(|e| Failure(format!("connect {path}: {}", words(&e))))?;
            let _ = s.set_read_timeout(Some(timeout));
            Stream::Unix(s)
        }
    })
}

fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}

/// One request's options.
#[derive(Clone, Debug)]
pub struct Call<'a> {
    pub method: &'a str,
    pub path: &'a str,
    pub json: Option<&'a Json>,
    pub headers: &'a [(&'a str, &'a str)],
    /// "1.0" asks a web server for a body it ends by closing, never chunked
    /// (P18.12's fetch).
    pub version: &'a str,
    pub timeout: Duration,
    pub address: Option<&'a str>,
}

impl<'a> Call<'a> {
    pub fn new(method: &'a str, path: &'a str) -> Call<'a> {
        Call { method, path, json: None, headers: &[], version: "1.1", timeout: Duration::from_secs(600), address: None }
    }
}

/// One request to `to`, read to EOF.
pub fn call(to: &Endpoint, c: &Call<'_>) -> Result<Response, Failure> {
    let mut s = open(to, c.timeout, c.address)?;
    let body = c.json.map(|j| j.text().into_bytes()).unwrap_or_default();
    let mut head = format!("{} {} HTTP/{}\r\nHost: {}\r\n", c.method, c.path, c.version, to.host_header());
    if c.json.is_some() {
        head += "Content-Type: application/json\r\n";
    }
    for (k, v) in c.headers {
        head += &format!("{k}: {v}\r\n");
    }
    head += &format!("Content-Length: {}\r\nConnection: close\r\n\r\n", body.len());
    let mut out = head.into_bytes();
    out.extend_from_slice(&body);
    s.write_all(&out).map_err(|e| Failure(format!("write: {e}")))?;
    let mut got = vec![];
    let mut buf = vec![0u8; 65536];
    loop {
        match s.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => got.extend_from_slice(&buf[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return fail(format!("read: {e}")),
        }
        if got.len() > MAX_HEAD + MAX_BODY {
            return fail(format!("more than {} bytes", MAX_HEAD + MAX_BODY));
        }
    }
    response(&got)
}

// MARK: URLs (P18.12)

/// An http or https URL, as a person writes one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WebUrl {
    pub https: bool,
    pub host: String,
    pub port: u16,
    pub path: String,
}

impl WebUrl {
    pub fn parse(text: &str) -> Option<WebUrl> {
        let lower = text.to_ascii_lowercase();
        let (https, rest) = if lower.starts_with("https://") {
            (true, &text[8..])
        } else if lower.starts_with("http://") {
            (false, &text[7..])
        } else {
            return None;
        };
        let cut = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        let (hostport, mut p) = (&rest[..cut], rest[cut..].to_owned());
        if let Some(h) = p.find('#') {
            p.truncate(h);
        }
        let path = if p.is_empty() { "/".to_owned() } else if p.starts_with('?') { format!("/{p}") } else { p };
        // No userinfo: a host is a host.
        if hostport.contains('@') {
            return None;
        }
        let (host, port) = match hostport.split_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (hostport, None),
        };
        // ASCII: a host on the wire is (an international name travels as
        // punycode), and a letter that only looks like one is a homograph.
        // Swift took any Unicode letter.
        let host = host.to_ascii_lowercase();
        if host.is_empty() || !host.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-') {
            return None;
        }
        let port = match port {
            Some(p) => p.parse::<u16>().ok().filter(|n| *n > 0)?,
            None if https => 443,
            None => 80,
        };
        Some(WebUrl { https, host, port, path })
    }

    pub fn endpoint(&self) -> Endpoint {
        if self.https {
            Endpoint::Tls { host: self.host.clone(), port: self.port, cafile: None }
        } else {
            Endpoint::Tcp { host: self.host.clone(), port: self.port }
        }
    }

    pub fn text(&self) -> String {
        let default = if self.https { 443 } else { 80 };
        let port = if self.port == default { String::new() } else { format!(":{}", self.port) };
        format!("{}://{}{port}{}", if self.https { "https" } else { "http" }, self.host, self.path)
    }

    /// A redirect's Location, against this URL: absolute URLs and paths only.
    pub fn resolve(&self, location: &str) -> Option<WebUrl> {
        if let Some(u) = WebUrl::parse(location) {
            return Some(u);
        }
        location.starts_with('/').then(|| WebUrl { path: location.into(), ..self.clone() })
    }
}
