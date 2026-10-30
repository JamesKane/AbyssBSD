//! org.freedesktop.portal.FileChooser, the rules (Portal.swift, PHASE8
//! P8.2).
//!
//! Pure: given a sender, a token and an options dictionary, where the
//! Request lives, what the picker is asked for, and what goes back in the
//! Response. The interface is somebody else's, and on disk to be read
//! (/usr/share/dbus-1/interfaces/org.freedesktop.portal.{FileChooser,
//! Request}.xml). Two things in it govern this file:
//!
//!   1. **The answer is a URI, not a descriptor.** `OpenFile`'s Response
//!      carries `uris` and nothing else that names the file; there is no
//!      `h` in it, in any version. So this bridge's job ends at a name, and
//!      the descriptor `abyss-portal` opened stops here (§6.6).
//!   2. **The client computes the handle path before it calls**, from its
//!      own unique name and its own `handle_token`, so it can subscribe to
//!      the Response first. Derive it any other way and a correct client
//!      subscribes to a path nothing is emitted on, and hangs.

use current_ipc::Msg;
use dbus::Value;

/// The `response` code in a `Request::Response` signal.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PortalResponse {
    Success = 0,
    Cancelled = 1,
    Other = 2,
}

/// Which chooser was asked for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChooserKind {
    Open,
    Save,
}

// MARK: the Request object's path

pub const REQUEST_PREFIX: &str = "/org/freedesktop/portal/desktop/request";

/// A valid object-path element, `[A-Za-z0-9_]+`: a token with a `/` would
/// move the Request elsewhere in the tree, one with a `-` makes a path a
/// strict client refuses.
pub fn is_valid_element(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

/// The caller's unique name as a path element, `:1.42` → `1_42`: exactly
/// the spec's transformation, which the client performs on its own name.
pub fn sender_element(sender: &str) -> Option<String> {
    let s = sender.strip_prefix(':').unwrap_or(sender).replace('.', "_");
    is_valid_element(&s).then_some(s)
}

/// The full path, or None if either part is unusable.
pub fn request_path(sender: &str, token: &str) -> Option<String> {
    let who = sender_element(sender)?;
    is_valid_element(token).then(|| format!("{REQUEST_PREFIX}/{who}/{token}"))
}

// MARK: file:// URIs

/// Percent-encode a path into a `file://` URI, **per UTF-8 byte**: the
/// unreserved characters and `/` pass, everything else is `%XX`. A superset
/// of what `g_filename_to_uri` escapes, which is always safe to decode.
pub fn file_uri(path: &str) -> String {
    let mut out = String::from("file://");
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// The inverse, so a test checks the round trip rather than trusting the
/// encoder's idea of what it made.
pub fn file_uri_path(uri: &str) -> Option<String> {
    let src = uri.strip_prefix("file://")?.as_bytes();
    let mut bytes = vec![];
    let mut i = 0;
    while i < src.len() {
        if src[i] == b'%' {
            let hex = std::str::from_utf8(src.get(i + 1..i + 3)?).ok()?;
            bytes.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            bytes.push(src[i]);
            i += 1;
        }
    }
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

// MARK: the options vardict

/// The subset of the chooser's options this bridge acts on. The rest
/// (`filters`, `choices`, `accept_label`, `modal`, `current_filter`) is
/// **parsed and ignored**, which is not the same as unsupported: the whole
/// `a{sv}` must decode or the call fails.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ChooserOptions {
    pub handle_token: Option<String>,
    pub current_folder: Option<String>,
    pub current_name: Option<String>,
    pub multiple: bool,
    pub directory: bool,
    /// Keys seen and not acted on, logged, so "the picker ignored my
    /// filter" is answerable from the journal.
    pub ignored: Vec<String>,
}

impl ChooserOptions {
    /// Read an `a{sv}`. A value of an unexpected shape is skipped, not
    /// rejected: failing a client's file dialog for its own bug helps nobody.
    pub fn from(options: &Value) -> ChooserOptions {
        let mut o = ChooserOptions::default();
        let Value::Array(_, entries) = options else { return o };
        for e in entries {
            let Value::DictEntry(k, v) = e else { continue };
            let (Value::String(key), Value::Variant(v)) = (&**k, &**v) else { continue };
            match (key.as_str(), &**v) {
                ("handle_token", Value::String(s)) => o.handle_token = Some(s.clone()),
                ("current_folder", v) => o.current_folder = path_from_byte_array(v),
                ("current_name", Value::String(s)) if !s.is_empty() => o.current_name = Some(s.clone()),
                ("multiple", Value::Bool(b)) => o.multiple = *b,
                ("directory", Value::Bool(b)) => o.directory = *b,
                ("handle_token" | "current_name" | "multiple" | "directory", _) => {}
                (other, _) => o.ignored.push(other.to_owned()),
            }
        }
        o
    }
}

/// `current_folder` is `ay`, "expected to be terminated by a nul byte": the
/// NUL comes off, or the picker is handed a path ending in one. Only an
/// absolute path is forwarded: a relative one resolves against a directory
/// the app should not get to point the picker at.
pub(crate) fn path_from_byte_array(v: &Value) -> Option<String> {
    let Value::Array(sig, items) = v else { return None };
    if sig != "y" {
        return None;
    }
    let mut bytes: Vec<u8> = items.iter().map(|i| if let Value::Byte(b) = i { Some(*b) } else { None }).collect::<Option<_>>()?;
    while bytes.last() == Some(&0) {
        bytes.pop();
    }
    let s = String::from_utf8_lossy(&bytes).into_owned();
    s.starts_with('/').then_some(s)
}

// MARK: translating to abyss-portal

/// The CurrentIPC request this D-Bus call becomes. Nothing from `options`
/// can name a file to open: `current_name` is a save dialog's suggestion,
/// and `abyss-portal` sanitises it again; the confused-deputy rule is
/// enforced there, by the type, and this bridge is not trusted with it.
pub fn portal_call_message(kind: ChooserKind, options: &ChooserOptions) -> Msg {
    let mut m = Msg::new();
    match kind {
        ChooserKind::Open => m.set_string("method", "file.open"),
        ChooserKind::Save => {
            m.set_string("method", "file.save");
            if let Some(n) = &options.current_name {
                m.set_string("name", n);
            }
        }
    }
    if let Some(d) = &options.current_folder {
        m.set_string("dir", d);
    }
    m
}

/// What `abyss-portal` said, as the Response's two arguments. 0 chose, 1
/// declined, 2 anything else: a client that reads a cancel as an error
/// shows a failure every time somebody changes their mind.
pub fn chooser_response(reply: &Msg) -> (PortalResponse, Value) {
    let empty = Value::options(vec![]);
    if reply.bool("ok") != Some(true) {
        let code = if reply.string("error") == Some("cancelled") { PortalResponse::Cancelled } else { PortalResponse::Other };
        return (code, empty);
    }
    // `ok` with no absolute path is a broken portal, not a success with an
    // empty list: the client would silently open nothing.
    match reply.string("path").filter(|p| p.starts_with('/')) {
        Some(p) => (PortalResponse::Success, chooser_results(&[p])),
        None => (PortalResponse::Other, empty),
    }
}

/// The results vardict: `uris`, and only `uris`.
pub fn chooser_results(paths: &[&str]) -> Value {
    Value::options(vec![("uris", Value::Array("s".into(), paths.iter().map(|p| Value::String(file_uri(p))).collect()))])
}
