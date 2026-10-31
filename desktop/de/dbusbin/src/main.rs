//! abyss-dbus: the desktop's portal, on ADE's D-Bus bridge (PHASE8 P8.2),
//! ported from main.swift beside it.
//!
//!   abyss-dbus [--portal SERVICE] [--seconds N] [--once]
//!              [--bus ADDRESS --jail NAME [--jaild SOCKET]]
//!   abyss-dbus --menus [--class CLASS] [--bus ADDRESS]
//!   abyss-dbus --endpoint --listen PATH --services PATH
//!
//! `--endpoint` is the bridge itself (BACKLOG D.1, PRODUCT §5.6):
//! applications connect at `--listen` (what DBUS_SESSION_BUS_ADDRESS
//! names), ADE's services (this program's portal and menu modes) at
//! `--services`, and messages go between the two kinds, never within one.
//! There is no bus: no application reaches another through it.
//!
//! The portal owns `org.freedesktop.portal.Desktop` and answers the file
//! chooser by asking `abyss-portal`: the same Finder our own apps get. With
//! `--jail` it is a jail's portal (PHASE18 P18.4), and a chosen file is
//! granted into the jail by abyss-jaild and answered by its path there.
//!
//! A **legacy adapter and nothing more**: nothing on the frame path knows
//! it exists, and if it dies the desktop carries on without a file dialog
//! for foreign apps (PHASE8 §6.3).

use dbus::Connection;
use dbusbridge::{Endpoint, PeerKind};
use dbusmenus::GtkMenuBridge;
use dbusportal::{PortalService, PortalSettings};
use std::process::{exit, Command, Stdio};
use std::time::{Duration, Instant};

fn die(s: &str) -> ! {
    eprintln!("abyss-dbus: {s}");
    exit(1)
}

/// `name` beside the path this program was run as: the harness's bin
/// directory links into both builds, and the siblings are there.
fn sibling(name: &str) -> Option<String> {
    let a0 = std::env::args().next().filter(|a| a.contains('/'))?;
    let p = if a0.starts_with('/') { a0 } else { format!("{}/{a0}", std::env::current_dir().ok()?.display()) };
    p.rfind('/').map(|i| format!("{}/{name}", &p[..i]))
}

/// `abyss-theme palette`, beside this binary: what it printed.
fn run_palette() -> Option<String> {
    let tool = sibling("abyss-theme").filter(|t| abyss_sys::spawn::executable(t))?;
    let out = Command::new(tool).arg("palette").stdin(Stdio::null()).stderr(Stdio::inherit()).output().ok()?;
    (!out.stdout.is_empty()).then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

fn palette_name(text: &str) -> &str {
    text.lines().find_map(|l| l.strip_prefix("name = ")).unwrap_or("?")
}

#[derive(Default)]
struct Args {
    portal: Option<String>,
    seconds: f64,
    once: bool,
    menus: bool,
    class: Option<String>,
    endpoint: bool,
    listen: Option<String>,
    services: Option<String>,
    bus: Option<String>,
    jail: Option<String>,
    jaild: Option<String>,
}

fn parse() -> Args {
    let mut a = Args::default();
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        let mut value = |what: &str| it.next().unwrap_or_else(|| die(&format!("{arg} needs {what}")));
        match arg.as_str() {
            "--portal" => a.portal = Some(value("a service name")),
            "--seconds" => a.seconds = value("a number").parse().unwrap_or_else(|_| die("--seconds needs a number")),
            "--once" => a.once = true,
            "--menus" => a.menus = true,
            // With --menus: a jail class's menu bridge (PHASE18), on that
            // jail's bridge (--bus), serving menus-dbus-CLASS to the bar.
            "--class" => a.class = Some(value("a jail class")),
            "--endpoint" => a.endpoint = true,
            "--listen" => a.listen = Some(value("a socket path")),
            "--services" => a.services = Some(value("a socket path")),
            "--bus" => a.bus = Some(value("an address")),
            "--jail" => a.jail = Some(value("a jail's name")),
            "--jaild" => a.jaild = Some(value("a socket path")),
            "-h" | "--help" => {
                println!("usage: abyss-dbus [--portal SERVICE] [--seconds N] [--once] [--bus ADDRESS --jail NAME [--jaild SOCKET]] | --menus");
                exit(0)
            }
            other => die(&format!("unknown option '{other}'")),
        }
    }
    a
}

fn main() {
    let a = parse();

    if a.endpoint {
        let (Some(listen), Some(services)) = (a.listen, a.services) else { die("--endpoint needs --listen and --services") };
        let mut bridge = Endpoint::new(|s| eprintln!("{s}"));
        if let Err(e) = bridge.listen(&services, PeerKind::Service).and_then(|_| bridge.listen(&listen, PeerKind::Application)) {
            die(&format!("cannot listen: {e}"));
        }
        println!("ready (endpoint: applications at {listen}, ADE's services at {services})");
        bridge.run(&mut || true);
        bridge.shutdown();
        return;
    }

    let conn = Connection::connect(a.bus.as_deref())
        .unwrap_or_else(|e| die(&format!("cannot reach ADE's D-Bus bridge: {e} (is DBUS_SESSION_BUS_ADDRESS set, and is `abyss-dbus --endpoint` running?)")));

    if a.menus {
        let service = a.class.as_deref().map_or(dbusmenus::SERVICE_NAME.to_owned(), dbusmenus::service_name_for_jail_class);
        let mut bridge = GtkMenuBridge::new(conn, &service).unwrap_or_else(|e| die(&format!("cannot serve {service}: {e}")));
        // What it watches and what it pushes (P10.9), for the log a test reads.
        bridge.log = Box::new(|s| println!("menus-dbus: {s}"));
        println!("ready (menus: {service})");
        loop {
            if let Err(e) = bridge.step(1000) {
                die(&format!("the bus connection failed: {e}"));
            }
        }
    }

    let mut service = PortalService::new(conn, a.portal.as_deref());
    if let Some(jail) = a.jail {
        let socket = a.jaild.unwrap_or_else(|| jaild::wire::DEFAULT_SOCKET.into());
        eprintln!("abyss-dbus: the portal of {jail}: chosen files are granted into it");
        service.grant = Some(Box::new(move |path, fd| match jaild::client::grant(&jail, path, fd, &socket) {
            Ok((inside, _)) => Some(inside),
            Err(e) => {
                eprintln!("abyss-dbus: {jail}: {e}");
                None
            }
        }));
    }
    // What a foreign toolkit is told (P11.10): the loaded theme's palette,
    // or Aqua's, and said so.
    match run_palette().and_then(|t| Some((PortalSettings::from_palette(&t)?, t))) {
        Some((s, text)) => {
            service.settings = s;
            eprintln!("abyss-dbus: settings from the theme's palette ({})", palette_name(&text));
        }
        None => eprintln!("abyss-dbus: no theme palette (abyss-theme not found or failed) — telling toolkits Aqua's"),
    }
    if let Err(e) = service.attach() {
        die(&e.to_string());
    }
    // stdout, so a supervisor or a test can wait for the name.
    println!("ready");

    // **Follow the theme** (P14.2): the config directory, drained on every
    // pass (at least every 200 ms), and the palette asked again when
    // anything in it changed; `update` says SettingChanged for what differs.
    let appearance = pool_config::Watcher::new(None).ok();
    let deadline = (a.seconds > 0.0).then(|| Instant::now() + Duration::from_secs_f64(a.seconds));
    while deadline.is_none_or(|d| Instant::now() < d) {
        if let Err(e) = service.step(200) {
            die(&format!("the bus connection failed: {e}"));
        }
        if appearance.as_ref().is_some_and(|w| w.drain())
            && let Some((s, text)) = run_palette().and_then(|t| Some((PortalSettings::from_palette(&t)?, t)))
        {
            let n = service.update(s);
            if n > 0 {
                eprintln!("abyss-dbus: the theme changed ({}) — {n} setting{} changed", palette_name(&text), if n == 1 { "" } else { "s" });
            }
        }
        if a.once && service.served > 0 {
            break;
        }
    }
    println!("done served={}", service.served);
}
