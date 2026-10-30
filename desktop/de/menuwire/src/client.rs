//! Client.swift: asking an application what it can do.
//!
//! The first consumer of the vocabulary is `abyssmenu`, which cannot draw a
//! menu at all; the menu bar (P10.4) is the second. Both go through this.

use crate::{wire, Described, Error};
use current_ipc::{connect, connect_path, receive, runtime_dir, send, Msg};
use menu_model::{CommandResult, Enablement};
use std::collections::{BTreeMap, HashMap};
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// How long an application gets to answer. **A menu bar must never wait
/// for ever on somebody else's program**: the portal half of abyss-dbus
/// blocks behind a dialog, an application can hang. So every call is
/// bounded, and a slow answer is an error the bar survives (P10.6).
pub const TIMEOUT: Duration = Duration::from_secs(2);

fn call(service: &str, request: &Msg) -> Result<Msg, Error> {
    let s = connect(service)?;
    let _ = s.set_read_timeout(Some(TIMEOUT));
    let _ = s.set_write_timeout(Some(TIMEOUT));
    send(request, &s)?;
    Ok(receive(&s)?)
}

/// `target`: for a service that answers for more than one application (the
/// GTK bridge), which one (PHASE10 P10.6). Our own applications ignore it.
fn request(method: &str, target: Option<&str>) -> Msg {
    let mut m = Msg::new();
    m.set_string("method", method);
    if let Some(t) = target {
        m.set_string("target", t);
    }
    m
}

pub fn describe(service: &str, target: Option<&str>) -> Result<Described, Error> {
    wire::decode_describe(&call(service, &request("describe", target))?)
}

pub fn validate(service: &str, target: Option<&str>) -> Result<HashMap<String, Enablement>, Error> {
    wire::decode_validate(&call(service, &request("validate", target))?)
}

pub fn activate(
    service: &str,
    verb: &str,
    arguments: &BTreeMap<String, String>,
    target: Option<&str>,
) -> Result<CommandResult, Error> {
    let mut m = wire::activate_request(verb, arguments);
    if let Some(t) = target {
        m.set_string("target", t);
    }
    wire::decode_result(&call(service, &m)?)
}

/// Ask to be told when `service`'s vocabulary changes. Returns the held
/// connection: it becomes readable with a `changed` message each time, and
/// with EOF when the application goes. `target` names the application, for
/// a service that answers for many (the D-Bus bridge, P10.9).
pub fn subscribe(service: &str, target: Option<&str>) -> Result<UnixStream, Error> {
    let s = connect(service)?;
    // Bounded like every call; the held connection is only ever read when
    // poll says it is readable, so the timeout costs nothing later.
    let _ = s.set_read_timeout(Some(TIMEOUT));
    send(&request("subscribe", target), &s)?;
    let reply = receive(&s)?;
    if reply.bool("ok") != Some(true) {
        return Err(Error::Service(reply.string("error").unwrap_or("subscribe refused").to_owned()));
    }
    Ok(s)
}

/// Every menu service in the runtime directory that answers a connection: a
/// socket left behind by a crash is not an application.
pub fn services() -> Vec<String> {
    runtime_dir().map(|d| services_in(&d)).unwrap_or_default()
}

/// The same, in an explicit directory.
pub fn services_in(dir: &str) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut names: Vec<String> = entries
        .filter_map(|e| {
            let file = e.ok()?.file_name().to_string_lossy().into_owned();
            let name = file.strip_suffix(".sock")?;
            name.starts_with(wire::SERVICE_PREFIX).then(|| name.to_owned())
        })
        .filter(|name| connect_path(&format!("{dir}/{name}.sock")).is_ok())
        .collect();
    names.sort();
    names
}

/// A service from what a person types: its full name, or an application
/// name (`finder`) that exactly one live service carries.
pub fn resolve(name: &str) -> Result<String, Error> {
    resolve_in(&runtime_dir()?, name)
}

/// The same, in an explicit directory.
pub fn resolve_in(dir: &str, name: &str) -> Result<String, Error> {
    let live = services_in(dir);
    if live.iter().any(|s| s == name) {
        return Ok(name.to_owned());
    }
    let full = wire::service_name(name, 0);
    let slug = &full[..full.len() - 1]; // "menus.finder."
    let mut matches: Vec<String> = live.into_iter().filter(|s| s.starts_with(slug)).collect();
    match matches.len() {
        1 => Ok(matches.remove(0)),
        0 => Err(Error::NoSuchApplication(name.to_owned())),
        _ => Err(Error::Ambiguous(name.to_owned(), matches)),
    }
}
