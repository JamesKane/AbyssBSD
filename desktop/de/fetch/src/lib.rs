//! The fetch bridge in Rust (Fetch.swift, PHASE18 P18.12b): an agent's only
//! way to the network.
//!
//! The agent's jail has no network at all. Its `fetch` tool asks this
//! bridge, run by the keeper outside the jail, which:
//!
//!   - reaches only hosts the person allowed this session (requester 3): a
//!     new host is answered "the person must be asked", and the answer
//!     comes on the keeper's side, never the agent's;
//!   - never reaches this computer's own services or private networks
//!     (loopback, RFC 1918, link-local): the agent must not be able to use
//!     the bridge to knock on the person's own doors;
//!   - follows a redirect only to a host that is allowed too;
//!   - gives back text: a page's words without its markup, cut to 16 KB;
//!   - says every request, permission and refusal in the transcript.

use model::http::{self, Call, Response, WebUrl};
use model::Json;
use std::collections::BTreeSet;
use std::net::{IpAddr, ToSocketAddrs};
use std::time::Duration;

pub const PAGE_LIMIT: usize = 16 << 10;

/// A page's words: markup, scripts and styles gone, entities read, space
/// folded. Plain text passes through.
pub fn page_text(body: &str, content_type: &str) -> String {
    if !content_type.to_ascii_lowercase().contains("html") {
        return cut(body);
    }
    const BREAKS: [&str; 16] = ["p", "/p", "br", "br/", "div", "/div", "li", "tr", "h1", "h2", "h3", "/h1", "/h2", "/h3", "title", "/title"];
    let (mut out, mut tag, mut in_tag, mut skipping) = (String::new(), String::new(), false, None::<String>);
    for ch in body.chars() {
        if in_tag {
            if ch == '>' {
                in_tag = false;
                let name = tag.to_lowercase().split([' ', '\n', '\t']).find(|w| !w.is_empty()).unwrap_or("").to_owned();
                match &skipping {
                    Some(s) => {
                        if name == format!("/{s}") {
                            skipping = None;
                        }
                    }
                    None if name == "script" || name == "style" => skipping = Some(name),
                    None if BREAKS.contains(&name.as_str()) => out.push('\n'),
                    None => {}
                }
                tag.clear();
            } else {
                tag.push(ch);
            }
            continue;
        }
        if ch == '<' {
            in_tag = true;
        } else if skipping.is_none() {
            out.push(ch);
        }
    }
    for (e, r) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
        out = out.replace(e, r);
    }
    let lines: Vec<String> = out.split('\n').map(|l| l.split([' ', '\t', '\r']).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ")).filter(|l| !l.is_empty()).collect();
    cut(&lines.join("\n"))
}

fn cut(s: &str) -> String {
    if s.len() <= PAGE_LIMIT {
        return s.to_owned();
    }
    String::from_utf8_lossy(&s.as_bytes()[..PAGE_LIMIT]).into_owned() + "\n(cut at 16 KB)"
}

/// Whether an address is this computer's or a private network's: the
/// bridge does not reach them. One it cannot read is refused too.
pub fn is_local(ip: &str) -> bool {
    match ip.parse::<IpAddr>() {
        Err(_) => true,
        Ok(IpAddr::V4(v)) => {
            let [a, b, ..] = v.octets();
            matches!((a, b), (127, _) | (10, _) | (0, _) | (169, 254) | (192, 168)) || (a == 172 && (16..=31).contains(&b)) || (a == 100 && (64..=127).contains(&b))
        }
        Ok(IpAddr::V6(v)) => {
            if let Some(m) = v.to_ipv4_mapped() {
                return is_local(&m.to_string());
            }
            let seg = v.segments()[0];
            v.is_loopback() || v.is_unspecified() || (seg & 0xffc0) == 0xfe80 || (seg & 0xfe00) == 0xfc00
        }
    }
}

/// The addresses a host resolves to, as text.
pub fn resolve(host: &str) -> Vec<String> {
    (host, 0).to_socket_addrs().map(|a| a.map(|s| s.ip().to_string()).collect()).unwrap_or_default()
}

/// What the bridge says to one fetch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Answer {
    Page { url: String, status: u16, text: String },
    /// The person must be asked about `host` first.
    Ask { host: String, url: String },
    Refused(String),
}

/// One GET of a URL, connecting to `address` (the one checked) when given.
pub type Get = Box<dyn FnMut(&WebUrl, Option<&str>) -> Result<Response, String>>;
pub type Log = Box<dyn FnMut(&str, Vec<(String, Json)>)>;
/// A host's addresses, as text.
pub type Resolve = Box<dyn Fn(&str) -> Vec<String>>;

/// The real GET: HTTP/1.0, so a body is ended by closing, never chunked.
pub fn web_get() -> Get {
    Box::new(|u, address| {
        let headers = [("User-Agent", "AbyssBSD agent"), ("Accept", "text/html, text/plain;q=0.9, */*;q=0.1")];
        let c = Call { headers: &headers, version: "1.0", timeout: Duration::from_secs(20), address, ..Call::new("GET", &u.path) };
        http::call(&u.endpoint(), &c).map_err(|e| e.0)
    })
}

pub struct FetchBridge {
    permitted: BTreeSet<String>,
    get: Get,
    resolve: Resolve,
    allow_local: bool,
    log: Log,
}

fn s(x: &str) -> Json {
    Json::String(x.into())
}

fn field(k: &str, v: Json) -> (String, Json) {
    (k.to_owned(), v)
}

impl FetchBridge {
    pub fn new(allow_local: bool, resolve: impl Fn(&str) -> Vec<String> + 'static, get: Get, log: Log) -> FetchBridge {
        FetchBridge { permitted: BTreeSet::new(), get, resolve: Box::new(resolve), allow_local, log }
    }

    /// The person's answer for `host` (the keeper's side). A no is not
    /// remembered: the host is asked about again.
    pub fn permit(&mut self, host: &str, allow: bool) {
        let h = host.to_ascii_lowercase();
        if allow {
            self.permitted.insert(h.clone());
        }
        (self.log)(if allow { "permitted" } else { "denied" }, vec![field("host", s(&h))]);
    }

    pub fn fetch(&mut self, text: &str) -> Answer {
        let Some(mut url) = WebUrl::parse(text) else { return self.refuse(&format!("not an http or https URL: {text}"), text) };
        for _ in 0..4 {
            // Resolved once, checked, and that address is the one connected
            // to: no second look-up for a rebinding DNS answer to change.
            let address = match self.check(&url.host) {
                Err(why) => return self.refuse(&why, &url.text()),
                Ok(a) => a,
            };
            if !self.permitted.contains(&url.host) {
                (self.log)("asked", vec![field("host", s(&url.host)), field("url", s(&url.text()))]);
                return Answer::Ask { host: url.host.clone(), url: url.text() };
            }
            let r = match (self.get)(&url, address.as_deref()) {
                Ok(r) => r,
                Err(e) => return self.refuse(&format!("{} did not answer: {e}", url.host), &url.text()),
            };
            if (300..=399).contains(&r.status)
                && let Some(loc) = r.header("location")
            {
                let Some(next) = url.resolve(loc) else { return self.refuse(&format!("a redirect to {loc}, which is not a URL"), &url.text()) };
                (self.log)("redirected", vec![field("from", s(&url.text())), field("to", s(&next.text()))]);
                url = next;
                continue;
            }
            let kind = r.header("content-type").unwrap_or("text/plain");
            let text = page_text(&String::from_utf8_lossy(&r.body), kind);
            (self.log)("fetched", vec![field("url", s(&url.text())), field("status", Json::Number(f64::from(r.status))), field("bytes", Json::Number(r.body.len() as f64))]);
            return Answer::Page { url: url.text(), status: r.status, text };
        }
        self.refuse("too many redirects", &url.text())
    }

    /// The host's addresses, every one checked; the first is the one to
    /// connect to. A test that allows local addresses resolves as usual.
    fn check(&self, host: &str) -> Result<Option<String>, String> {
        if self.allow_local {
            return Ok(None);
        }
        let ips = (self.resolve)(host);
        let Some(first) = ips.first() else { return Err(format!("{host} does not resolve")) };
        if let Some(ip) = ips.iter().find(|ip| is_local(ip)) {
            return Err(format!("{host} is this computer's or a private network's ({ip}): an agent does not reach those"));
        }
        Ok(Some(first.clone()))
    }

    fn refuse(&mut self, why: &str, url: &str) -> Answer {
        (self.log)("refused", vec![field("url", s(url)), field("reason", s(why))]);
        Answer::Refused(why.into())
    }
}

#[cfg(test)]
mod tests;
