//! Wire.swift: the vocabulary as messages.
//!
//! Four methods, the `CurrentIPC` idiom of every other service (`method` in,
//! `ok` + `error` out):
//!
//! - `describe`: the whole vocabulary, menus and per command its verb, title,
//!   keys, arguments, a sentence of description and whether it can run now.
//! - `validate`: enablement only, for every command. What a menu asks as it
//!   opens.
//! - `activate`: run one verb with typed arguments, and get a **result**
//!   back: `ok` with an optional value, or `refused` with a reason.
//! - `subscribe`: keep the connection; `changed` is pushed down it when the
//!   vocabulary itself changes.
//!
//! `Msg` is flat and a menu is a tree, so a subtree travels as a packed `Msg`
//! in a bytes field (PHASE10 §4.4) and a list as a `Msg` whose fields are
//! named "0", "1", …. One parser, `Msg::unpack`, reads every level.

use crate::Error;
use current_ipc::{Msg, Value};
use menu_model::{Argument, ArgumentType, Command, CommandResult, Enablement, Key, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use std::collections::{BTreeMap, HashMap};

/// The prefix every menu service's name starts with.
pub const SERVICE_PREFIX: &str = "menus.";

/// The service name an application's menus are published under:
/// `menus.<app>.<pid>`. The pid keeps two Finders apart; the app name is
/// what a person types to `abyssmenu`. The name is lowercased and anything
/// but a letter or a digit becomes `-`, a character at a time (Swift: a
/// Character at a time, so a combining mark rides with its letter; RUST.md
/// §1, Swift's quirks).
pub fn service_name(app: &str, pid: i32) -> String {
    let slug: String = app.to_lowercase().chars().map(|c| if c.is_alphanumeric() { c } else { '-' }).collect();
    format!("{SERVICE_PREFIX}{slug}.{pid}")
}

fn malformed(why: &str) -> Error {
    Error::Ipc(current_ipc::Error::Malformed(why.to_owned()))
}

fn unpack(bytes: &[u8]) -> Result<Msg, Error> {
    Ok(Msg::unpack(bytes, Vec::new())?)
}

// MARK: lists and nesting

pub(crate) fn pack_list(items: impl IntoIterator<Item = Msg>) -> Vec<u8> {
    let mut m = Msg::new();
    for (i, item) in items.into_iter().enumerate() {
        m.set_bytes(&i.to_string(), &item.pack());
    }
    m.pack()
}

pub(crate) fn unpack_list(bytes: Option<&[u8]>) -> Result<Vec<Msg>, Error> {
    let Some(bytes) = bytes else { return Ok(Vec::new()) };
    let m = unpack(bytes)?;
    let mut out = Vec::new();
    while let Some(b) = m.bytes(&out.len().to_string()) {
        out.push(unpack(b)?);
    }
    Ok(out)
}

// MARK: key equivalents

pub(crate) fn encode_key(k: &KeyEquivalent) -> Msg {
    let mut m = Msg::new();
    m.set_u64("mods", u64::from(k.modifiers().0));
    m.set_string("key", &key_name(k.key()));
    m.set_string("display", &k.display()); // for a reader that will not parse keys
    m
}

pub(crate) fn decode_key(m: &Msg) -> Result<KeyEquivalent, Error> {
    let key = m.string("key").and_then(key_named).ok_or_else(|| malformed("key equivalent with no key"))?;
    Ok(KeyEquivalent::new(key, Modifiers(m.u64("mods").unwrap_or(0) as u8)))
}

pub fn key_name(k: Key) -> String {
    match k {
        Key::Character(c) => return format!("char:{c}"),
        Key::Backspace => "backspace",
        Key::ForwardDelete => "forward-delete",
        Key::Up => "up",
        Key::Down => "down",
        Key::Left => "left",
        Key::Right => "right",
        Key::Enter => "enter",
        Key::Escape => "escape",
        Key::Tab => "tab",
    }
    .to_owned()
}

/// `char:` and exactly one character (Swift: one Character, which may be
/// several).
pub fn key_named(s: &str) -> Option<Key> {
    if let Some(rest) = s.strip_prefix("char:") {
        let mut chars = rest.chars();
        return match (chars.next(), chars.next()) {
            (Some(c), None) => Some(Key::Character(c)),
            _ => None,
        };
    }
    Some(match s {
        "backspace" => Key::Backspace,
        "forward-delete" => Key::ForwardDelete,
        "up" => Key::Up,
        "down" => Key::Down,
        "left" => Key::Left,
        "right" => Key::Right,
        "enter" => Key::Enter,
        "escape" => Key::Escape,
        "tab" => Key::Tab,
        _ => return None,
    })
}

// MARK: commands and menus

pub(crate) fn encode_command(c: &Command, enablement: Option<&Enablement>) -> Msg {
    let mut m = Msg::new();
    m.set_string("kind", "command");
    m.set_string("verb", &c.verb);
    m.set_string("title", &c.title);
    m.set_string("summary", &c.summary);
    if c.writes {
        m.set_bool("writes", true);
    }
    if let Some(k) = &c.key {
        m.set_bytes("key", &encode_key(k).pack());
    }
    if !c.alternate_keys.is_empty() {
        m.set_bytes("alternates", &pack_list(c.alternate_keys.iter().map(encode_key)));
    }
    if !c.arguments.is_empty() {
        m.set_bytes(
            "arguments",
            &pack_list(c.arguments.iter().map(|a| {
                let mut am = Msg::new();
                am.set_string("name", &a.name);
                am.set_string("type", a.ty.as_str());
                am.set_string("summary", &a.summary);
                am
            })),
        );
    }
    if let Some(e) = enablement {
        set_enablement(e, &mut m);
    }
    m
}

fn set_enablement(e: &Enablement, m: &mut Msg) {
    match e {
        Enablement::Enabled => m.set_bool("enabled", true),
        Enablement::Disabled(why) => {
            m.set_bool("enabled", false);
            m.set_string("reason", why);
        }
    }
}

fn enablement(m: &Msg) -> Option<Enablement> {
    match m.bool("enabled")? {
        true => Some(Enablement::Enabled),
        false => Some(Enablement::Disabled(m.string("reason").unwrap_or("").to_owned())),
    }
}

pub(crate) fn decode_command(m: &Msg) -> Result<Command, Error> {
    let (Some(verb), Some(title)) = (m.string("verb"), m.string("title")) else {
        return Err(malformed("command with no verb or title"));
    };
    let key = m.bytes("key").map(|b| decode_key(&unpack(b)?)).transpose()?;
    let alternate_keys = unpack_list(m.bytes("alternates"))?.iter().map(decode_key).collect::<Result<_, _>>()?;
    let arguments = unpack_list(m.bytes("arguments"))?
        .iter()
        .map(|am| match (am.string("name"), am.string("type").and_then(ArgumentType::from_name)) {
            (Some(name), Some(ty)) => Ok(Argument::new(name, ty, am.string("summary").unwrap_or(""))),
            _ => Err(malformed("argument with no name or type")),
        })
        .collect::<Result<_, _>>()?;
    Ok(Command {
        verb: verb.to_owned(),
        title: title.to_owned(),
        key,
        alternate_keys,
        arguments,
        summary: m.string("summary").unwrap_or("").to_owned(),
        writes: m.bool("writes").unwrap_or(false),
    })
}

pub(crate) fn encode_menu(menu: &Menu, enablement: &dyn Fn(&Command) -> Option<Enablement>) -> Msg {
    let mut m = Msg::new();
    m.set_string("title", &menu.title);
    m.set_bytes(
        "items",
        &pack_list(menu.items.iter().map(|item| match item {
            MenuItem::Command(c) => encode_command(c, enablement(c).as_ref()),
            MenuItem::Separator => {
                let mut s = Msg::new();
                s.set_string("kind", "separator");
                s
            }
            MenuItem::Submenu(sub) => {
                let mut s = encode_menu(sub, enablement);
                s.set_string("kind", "submenu");
                s
            }
        })),
    );
    m
}

/// A menu, and the enablement that travelled with each of its commands.
pub(crate) fn decode_menu(m: &Msg, states: &mut HashMap<String, Enablement>) -> Result<Menu, Error> {
    let items = unpack_list(m.bytes("items"))?
        .iter()
        .map(|im| match im.string("kind") {
            Some("command") => {
                let c = decode_command(im)?;
                if let Some(e) = enablement(im) {
                    states.insert(c.verb.clone(), e);
                }
                Ok(MenuItem::Command(c))
            }
            Some("separator") => Ok(MenuItem::Separator),
            Some("submenu") => Ok(MenuItem::Submenu(decode_menu(im, states)?)),
            _ => Err(malformed("menu item of unknown kind")),
        })
        .collect::<Result<_, _>>()?;
    Ok(Menu { title: m.string("title").unwrap_or("").to_owned(), items })
}

// MARK: the four replies

/// `describe`'s reply body: the model, with each command's enablement.
pub fn describe_reply(model: &MenuBarModel, enablement: &dyn Fn(&Command) -> Enablement) -> Msg {
    describe_reply_with(model, &|c| Some(enablement(c)))
}

/// The same, for a reader that may not know a command's enablement (the
/// fixtures re-encode what they decoded).
pub fn describe_reply_with(model: &MenuBarModel, enablement: &dyn Fn(&Command) -> Option<Enablement>) -> Msg {
    let mut m = Msg::new();
    m.set_bool("ok", true);
    m.set_string("app", &model.app_name);
    m.set_bytes("menus", &pack_list(model.menus.iter().map(|menu| encode_menu(menu, enablement))));
    m
}

/// A model, and the enablement of each command that sent one.
pub type Described = (MenuBarModel, HashMap<String, Enablement>);

pub fn decode_describe(m: &Msg) -> Result<Described, Error> {
    check_ok(m)?;
    let mut states = HashMap::new();
    let menus = unpack_list(m.bytes("menus"))?.iter().map(|mm| decode_menu(mm, &mut states)).collect::<Result<_, _>>()?;
    Ok((MenuBarModel { app_name: m.string("app").unwrap_or("").to_owned(), menus }, states))
}

pub fn validate_reply(model: &MenuBarModel, enablement: &dyn Fn(&Command) -> Enablement) -> Msg {
    let mut m = Msg::new();
    m.set_bool("ok", true);
    m.set_bytes(
        "commands",
        &pack_list(model.commands().into_iter().map(|c| {
            let mut cm = Msg::new();
            cm.set_string("verb", &c.verb);
            set_enablement(&enablement(c), &mut cm);
            cm
        })),
    );
    m
}

pub fn decode_validate(m: &Msg) -> Result<HashMap<String, Enablement>, Error> {
    check_ok(m)?;
    let mut out = HashMap::new();
    for cm in unpack_list(m.bytes("commands"))? {
        if let (Some(v), Some(e)) = (cm.string("verb"), enablement(&cm)) {
            out.insert(v.to_owned(), e);
        }
    }
    Ok(out)
}

/// The arguments go in name order, byte by byte.
pub fn activate_request(verb: &str, arguments: &BTreeMap<String, String>) -> Msg {
    let mut m = Msg::new();
    m.set_string("method", "activate");
    m.set_string("verb", verb);
    if !arguments.is_empty() {
        let mut a = Msg::new();
        for (k, v) in arguments {
            a.set_string(k, v);
        }
        m.set_bytes("arguments", &a.pack());
    }
    m
}

/// The arguments an `activate` carried, as name → text. Every argument
/// travels as a string and is checked against its declared type by the
/// service ([`MenuService::check`](crate::MenuService::check)), so a script
/// writes `path=/tmp` and never has to know how the wire spells an integer.
pub fn arguments(request: &Msg) -> Result<BTreeMap<String, String>, Error> {
    let Some(b) = request.bytes("arguments") else { return Ok(BTreeMap::new()) };
    let mut out = BTreeMap::new();
    for (name, value) in unpack(b)?.fields() {
        let Value::String(s) = value else {
            return Err(malformed(&format!("argument {name} is not text")));
        };
        out.insert(name.clone(), s.clone());
    }
    Ok(out)
}

pub fn result_reply(r: &CommandResult) -> Msg {
    let mut m = Msg::new();
    match r {
        CommandResult::Ok(value) => {
            m.set_bool("ok", true);
            m.set_string("result", "ok");
            if let Some(v) = value {
                m.set_string("value", v);
            }
        }
        CommandResult::Refused(why) => {
            m.set_bool("ok", false);
            m.set_string("result", "refused");
            m.set_string("error", why);
        }
    }
    m
}

pub fn decode_result(m: &Msg) -> Result<CommandResult, Error> {
    match m.string("result") {
        Some("ok") => Ok(CommandResult::Ok(m.string("value").map(str::to_owned))),
        Some("refused") => Ok(CommandResult::Refused(m.string("error").unwrap_or("").to_owned())),
        // Not a result at all: the service could not run the method.
        _ => Err(Error::Service(m.string("error").unwrap_or("no result").to_owned())),
    }
}

pub fn error_reply(why: &str) -> Msg {
    let mut m = Msg::new();
    m.set_bool("ok", false);
    m.set_string("error", why);
    m
}

fn check_ok(m: &Msg) -> Result<(), Error> {
    if m.bool("ok") == Some(true) {
        return Ok(());
    }
    Err(Error::Service(m.string("error").unwrap_or("the service said no").to_owned()))
}
