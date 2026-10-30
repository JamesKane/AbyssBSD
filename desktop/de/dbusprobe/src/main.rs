//! dbusprobe: drive the DBus connection against a real bridge (PHASE8
//! P8.1), ported from main.swift beside it.
//!
//!   dbusprobe hello                  connect, authenticate, print our unique name
//!   dbusprobe serve <name> [seconds] own <name> and answer Ping/Echo until told
//!   dbusprobe portal-open <dir>      call FileChooser.OpenFile and await Response
//!   dbusprobe portal-save <dir> <n>  ... SaveFile, suggesting the name <n>
//!   dbusprobe portal-open-late <dir> ... but subscribe only AFTER the call
//!
//! The point of `serve` is that the CLIENT is GLib's `gdbus`: somebody
//! else's encoder. A marshaller tested only against its own parser
//! round-trips beautifully and is still wrong (HANDOFF §2.37).

use dbus::{Connection, Message, MessageType, Value};
use std::process::exit;
use std::time::{Duration, Instant};

fn die(s: &str) -> ! {
    eprintln!("dbusprobe: {s}");
    exit(1)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(mode) = args.first().map(String::as_str) else { die("usage: dbusprobe hello|serve <name> [seconds]") };
    let mut conn = Connection::connect(None).unwrap_or_else(|e| die(&e.to_string()));
    match mode {
        "hello" => println!("unique-name={}", conn.unique_name),
        "serve" => serve(&mut conn, &args),
        "portal-open" | "portal-save" | "portal-open-late" => portal(&mut conn, mode, &args),
        other => die(&format!("unknown mode '{other}'")),
    }
}

fn serve(conn: &mut Connection, args: &[String]) {
    let Some(name) = args.get(1) else { die("serve needs a bus name") };
    let seconds = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(5.0);
    // 1 is PRIMARY_OWNER: a portal that is not the primary owner is a
    // portal nobody calls.
    match conn.request_name(name, 0) {
        Ok(1) => {}
        Ok(code) => die(&format!("could not own {name}: RequestName returned {code}")),
        Err(e) => die(&e.to_string()),
    }
    println!("owning={name}");
    println!("ready");
    let deadline = Instant::now() + Duration::from_secs_f64(seconds);
    while Instant::now() < deadline {
        for r in conn.receive(200).unwrap_or_else(|e| die(&e.to_string())) {
            let call = r.message;
            if call.kind != MessageType::MethodCall {
                continue;
            }
            let reply = match (call.interface.as_deref(), call.member.as_deref()) {
                (Some("org.abyssbsd.Probe"), Some("Ping")) => Message::method_return(&call, vec![Value::String("pong".into())]),
                // Echo takes every type the portal API uses, so a real
                // client's encoder exercises our reader.
                (Some("org.abyssbsd.Probe"), Some("Echo")) => Message::method_return(&call, call.body.clone()),
                (Some("org.freedesktop.DBus.Introspectable"), Some("Introspect")) => Message::method_return(
                    &call,
                    vec![Value::String(
                        concat!(
                            r#"<node><interface name="org.abyssbsd.Probe">"#,
                            r#"<method name="Ping"><arg type="s" direction="out"/></method>"#,
                            r#"<method name="Echo"><arg type="v" direction="in"/>"#,
                            r#"<arg type="v" direction="out"/></method></interface></node>"#
                        )
                        .into(),
                    )],
                ),
                _ => {
                    let _ = conn.unknown_method(&call);
                    continue;
                }
            };
            // The descriptors of an echoed `h` live with `r` until this goes.
            let _ = conn.reply(&call, reply);
            drop(r.fds);
        }
    }
    println!("done");
}

/// The portal client, in two flavours, because the API has two ways to hang
/// and each is visible from only one.
///
/// `portal-open` / `portal-save` are the MODERN client: the Request path is
/// derived from the spec's words, subscribed to **before** the call, and the
/// handle given checked against it. `portal-open-late` is the OLD client
/// that `handle_token` was added to rescue: call first, subscribe to the
/// handle that came back, then wait. It hangs if the server emits
/// `Response` before its method return is on the wire.
fn portal(conn: &mut Connection, mode: &str, args: &[String]) {
    let Some(dir) = args.get(1) else { die(&format!("{mode} needs a directory")) };
    let late = mode == "portal-open-late";
    let save_name = (mode == "portal-save").then(|| args.get(2).cloned().unwrap_or_else(|| "Untitled.txt".into()));
    let token = "abyssprobe1";
    let who = conn.unique_name.trim_start_matches(':').replace('.', "_");
    let expected = format!("/org/freedesktop/portal/desktop/request/{who}/{token}");
    let rule = |path: &str| format!("type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{path}'");
    let fail = |e: dbus::Error| -> ! { die(&e.to_string()) };

    if !late {
        println!("expect-handle={expected}");
        // BEFORE the call: the whole point of the mode.
        conn.add_match(&rule(&expected)).unwrap_or_else(|e| fail(e));
        println!("subscribed");
    }
    // `current_folder` is `ay`, NUL-terminated: bytes, not a string. The old
    // client sends no token, and can watch only the handle it is given.
    let folder = Value::Array("y".into(), dir.bytes().chain([0]).map(Value::Byte).collect());
    let mut options = vec![];
    if !late {
        options.push(("handle_token", Value::String(token.into())));
    }
    options.push(("current_folder", folder));
    if let Some(n) = &save_name {
        options.push(("current_name", Value::String(n.clone())));
    }
    let member = if mode == "portal-save" { "SaveFile" } else { "OpenFile" };
    let call = Message::method_call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.FileChooser",
        member,
        vec![Value::String(String::new()), Value::String("Pick a file".into()), Value::options(options)],
    );
    let reply = conn.call(call, 25_000).unwrap_or_else(|e| fail(e));
    let Some(Value::ObjectPath(handle)) = reply.body.first() else { die("OpenFile returned no handle") };
    println!("handle={handle}");
    let watching = if late {
        conn.add_match(&rule(handle)).unwrap_or_else(|e| fail(e));
        println!("subscribed-after-the-call");
        handle.clone()
    } else {
        if *handle != expected {
            die(&format!("the handle we were given ({handle}) is not the one the spec says to expect ({expected}) — a client that pre-subscribed would hang"));
        }
        println!("handle-matches-prediction");
        expected
    };

    // The picker is a human interaction; wait a generous while for it.
    let until = Instant::now() + Duration::from_secs(90);
    loop {
        if Instant::now() >= until {
            die(&format!("no Response signal arrived on {watching} within 90s{}", if late { " — was it emitted before the method return reached us?" } else { "" }));
        }
        for r in conn.receive(200).unwrap_or_else(|e| fail(e)) {
            let m = &r.message;
            if m.kind != MessageType::Signal || m.interface.as_deref() != Some("org.freedesktop.portal.Request") || m.member.as_deref() != Some("Response") || m.path.as_deref() != Some(watching.as_str()) {
                continue;
            }
            let Some(Value::UInt32(code)) = m.body.first() else { continue };
            println!("response={code}");
            if let Some(Value::Array(_, entries)) = m.body.get(1) {
                for e in entries {
                    let Value::DictEntry(k, v) = e else { continue };
                    let (Value::String(k), Value::Variant(v)) = (&**k, &**v) else { continue };
                    if let (true, Value::Array(_, list)) = (k == "uris", &**v) {
                        for item in list {
                            if let Value::String(u) = item {
                                println!("uri={u}");
                            }
                        }
                    }
                }
            }
            exit(if *code == 0 { 0 } else { 2 });
        }
    }
}
