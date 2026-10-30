//! What the default session *is*, as a value (Session.swift, P8.4): an
//! ordering and an environment, decisions a test reads without starting
//! six processes. In the order it has to start:
//!
//! ```text
//! bus       ADE's D-Bus bridge (abyss-dbus --endpoint, BACKLOG D.1), at
//!           sockets WE name, so the address is known before it exists
//! portal    abyss-portal (P7.1), our own portal, for our own apps
//! bridge    abyss-dbus (P8.2), the same portal, for everyone else's
//! desktop   the wallpaper and its icons
//! menubar   the menu bar
//! dock      the Dock
//! ```
//!
//! **The bus is first, not just early**: `DBUS_SESSION_BUS_ADDRESS` has to
//! be in the shell's environment, because the shell launches applications.

use crate::policy::ComponentSpec;
use std::collections::{BTreeMap, BTreeSet};

/// What kind of session this is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionMode {
    /// Wallpaper, menu bar, Dock: the desktop.
    Desktop,
    /// Wallpaper and the installer, and nothing else: the medium runs the
    /// real desktop's supervisor, with one application instead of a shell.
    Installer,
    /// The login window and nothing else (P16.5b).
    Greeter,
}

impl SessionMode {
    pub fn from_name(s: &str) -> Option<SessionMode> {
        Some(match s {
            "desktop" => SessionMode::Desktop,
            "installer" => SessionMode::Installer,
            "greeter" => SessionMode::Greeter,
            _ => return None,
        })
    }
}

/// The session as a plan: what to run, in what order, what to export first.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionPlan {
    /// Everything to supervise, already ordered.
    pub components: Vec<ComponentSpec>,
    /// `DBUS_SESSION_BUS_ADDRESS`, or None when this session has no bus.
    pub bus_address: Option<String>,
    /// Things to say out loud: a service asked for that could not be built.
    pub notes: Vec<String>,
    /// The lock screen (P16.2c): started when asked, on the privileged
    /// display, restarted if it dies while the session is locked.
    pub lock_screen: Option<ComponentSpec>,
    /// The Setup Assistant (P16.7): once, after bring-up, at a first login.
    pub first_run: Option<ComponentSpec>,
}

impl SessionPlan {
    /// Exported to every child: what applications the session starts need.
    /// `GTK_USE_PORTAL=1` while the bridge answers the file chooser (P15.3).
    pub fn application_environment(&self) -> BTreeMap<String, String> {
        let mut env = BTreeMap::new();
        if let Some(a) = &self.bus_address {
            env.insert("DBUS_SESSION_BUS_ADDRESS".to_owned(), a.clone());
        }
        if self.components.iter().any(|c| c.name == "bridge") {
            env.insert("GTK_USE_PORTAL".to_owned(), "1".to_owned());
        }
        env
    }
}

/// Where this session's own bus listens. **We name it**: an address only
/// knowable after the bridge starts would change when it restarts.
pub fn session_bus_address(runtime_dir: &str) -> String {
    format!("unix:path={runtime_dir}/bus")
}

/// Where ADE's own services meet the bridge (BACKLOG D.1): private.
pub fn bridge_services_address(runtime_dir: &str) -> String {
    format!("unix:path={runtime_dir}/dbus-services")
}

/// The socket path inside a `unix:path=…` address, or None for another
/// kind (`tcp:`, `unix:abstract=`) no connect(2) probe here understands.
pub fn unix_socket_path(address: &str) -> Option<String> {
    let rest = address.strip_prefix("unix:path=")?;
    Some(rest.split(',').next().unwrap_or("").to_owned())
}

/// What `default_session` needs to know, every path an argument, so a test
/// asks what a session *would* be on a machine it is not running on.
#[derive(Clone, Debug)]
pub struct SessionInputs {
    /// The AquaDemo-shaped binary the shell components run.
    pub shell_binary: String,
    /// Where abyss-portal and abyss-dbus live (normally beside anchor).
    pub service_directory: String,
    /// The session's `ABYSS_RUNTIME_DIR`; every socket lands here.
    pub runtime_dir: String,
    /// `WAYLAND_DISPLAY` for the components, if known.
    pub display: Option<String>,
    /// The compositor's socket, when knowable: the shell waits for it.
    pub compositor_socket: Option<String>,
    /// The compositor's privileged socket (P10.3): the menu bar's alone.
    pub menubar_display: Option<String>,
    pub menubar_socket: Option<String>,
    pub mode: SessionMode,
    pub first_run_done: bool,
    /// Names to leave out (`bus`, `portal`, `bridge`, `menus`, `desktop`, …).
    pub without: BTreeSet<String>,
}

impl SessionInputs {
    pub fn new(shell_binary: &str, service_directory: &str, runtime_dir: &str, display: Option<&str>) -> SessionInputs {
        SessionInputs {
            shell_binary: shell_binary.into(),
            service_directory: service_directory.into(),
            runtime_dir: runtime_dir.into(),
            display: display.map(str::to_owned),
            compositor_socket: None,
            menubar_display: None,
            menubar_socket: None,
            mode: SessionMode::Desktop,
            first_run_done: true,
            without: BTreeSet::new(),
        }
    }
}

fn s(v: &str) -> String {
    v.to_owned()
}

/// Build the default session. Pure: it resolves nothing, spawns nothing and
/// reads no environment.
pub fn default_session(i: &SessionInputs) -> SessionPlan {
    let mut without = i.without.clone();
    // The login window's session serves nobody: no bus, no portal, no bridge.
    if i.mode == SessionMode::Greeter {
        without.extend(["bus", "portal", "bridge", "menus"].map(s));
    }
    let left_out = |n: &str| without.contains(n);
    let desktop = i.mode == SessionMode::Desktop;
    let (dir, svc) = (&i.runtime_dir, &i.service_directory);
    let mut components = vec![];
    let mut notes = vec![];
    let mut bus_address = None;

    let mut shared = BTreeMap::new();
    if let Some(d) = &i.display {
        shared.insert(s("WAYLAND_DISPLAY"), d.clone());
    }
    shared.insert(s("ABYSS_RUNTIME_DIR"), dir.clone());
    let spec = |name: &str, argv: Vec<String>, env: BTreeMap<String, String>, requires: Vec<String>| ComponentSpec { name: s(name), argv, env, requires };
    let with = |pairs: &[(&str, &str)]| {
        let mut e = shared.clone();
        e.extend(pairs.iter().map(|(k, v)| (s(k), s(v))));
        e
    };
    let wait_compositor = || i.compositor_socket.iter().cloned().collect::<Vec<_>>();

    let bus_socket = format!("{dir}/bus");
    let portal_socket = format!("{dir}/portal.sock");
    let services_socket = format!("{dir}/dbus-services");
    let services_address = bridge_services_address(dir);

    // bus: ADE's bridge, ours, so always there.
    if !left_out("bus") {
        bus_address = Some(session_bus_address(dir));
        let argv = vec![format!("{svc}/abyss-dbus"), s("--endpoint"), s("--listen"), bus_socket.clone(), s("--services"), services_socket.clone()];
        components.push(spec("bus", argv, shared.clone(), vec![]));
    }
    if !left_out("portal") {
        components.push(spec("portal", vec![format!("{svc}/abyss-portal")], shared.clone(), vec![]));
    }
    // bridge: it cannot own the portal's name on a bus that is not
    // listening, and answering means reaching abyss-portal.
    if !left_out("bridge") {
        if bus_address.is_some() {
            let mut needs = vec![services_socket.clone()];
            if !left_out("portal") {
                needs.push(portal_socket);
            }
            components.push(spec("bridge", vec![format!("{svc}/abyss-dbus")], with(&[("DBUS_SESSION_BUS_ADDRESS", &services_address)]), needs));
        } else {
            notes.push(s("the bus was left out, so the D-Bus bridge's portal is not started either — there is no endpoint for it to serve on."));
        }
    }
    // menus: GTK's menus, bridged into the bar (P10.6).
    if !left_out("menus") && bus_address.is_some() {
        components.push(spec("menus", vec![format!("{svc}/abyss-dbus"), s("--menus")], with(&[("DBUS_SESSION_BUS_ADDRESS", &services_address)]), vec![services_socket.clone()]));
    }
    // idle: the idle policy (P16.3), a client of the ordinary socket.
    if desktop && !left_out("idle") {
        components.push(spec("idle", vec![format!("{svc}/abyss-idle")], with(&[("ABYSS_APP_BINARY", &i.shell_binary)]), wait_compositor()));
    }
    // jails: confinement's session half (P18.5).
    if desktop && !left_out("jails") {
        components.push(spec("jails", vec![format!("{svc}/abyss-jail"), s("serve")], shared.clone(), wait_compositor()));
    }
    // lock: planned, not started.
    let lock_screen = (desktop && !left_out("lock")).then(|| {
        let mut env = with(&[("AQUA_SCENE", "lock"), ("ABYSS_APP_BINARY", &i.shell_binary)]);
        if let Some(bar) = &i.menubar_display {
            env.insert(s("WAYLAND_DISPLAY"), bar.clone());
        }
        spec("lock", vec![i.shell_binary.clone()], env, vec![])
    });
    // The shell, in stacking order.
    let scenes: &[(&str, &str)] = match i.mode {
        SessionMode::Installer => &[("desktop", "wallpaper"), ("installer", "installer")],
        SessionMode::Greeter => &[("loginwindow", "loginwindow")],
        SessionMode::Desktop => &[("desktop", "wallpaper"), ("menubar", "menubar"), ("dock", "dock")],
    };
    for (name, scene) in scenes.iter().filter(|(n, _)| !left_out(n)) {
        let mut env = with(&[("AQUA_SCENE", scene), ("ABYSS_APP_BINARY", &i.shell_binary)]);
        let mut needs = wait_compositor();
        if *name == "menubar"
            && let Some(bar) = &i.menubar_display
        {
            // The bar is privileged; what it launches must not be (P10.8).
            if let Some(d) = env.get("WAYLAND_DISPLAY").cloned() {
                env.insert(s("ABYSS_APP_WAYLAND_DISPLAY"), d);
            }
            env.insert(s("WAYLAND_DISPLAY"), bar.clone());
            needs.extend(i.menubar_socket.iter().cloned());
        }
        components.push(spec(name, vec![i.shell_binary.clone()], env, needs));
    }
    let first_run = (desktop && !i.first_run_done && !left_out("setup"))
        .then(|| spec("setup", vec![i.shell_binary.clone()], with(&[("AQUA_SCENE", "setupassistant"), ("ABYSS_APP_BINARY", &i.shell_binary)]), wait_compositor()));
    SessionPlan { components, bus_address, notes, lock_screen, first_run }
}

/// The XCursor theme the session writes and names (U.7b).
pub const SESSION_CURSOR_THEME: &str = "Abyss";

/// What every process is told about cursors: our theme, its size, and a
/// search path that finds it first. **A person's own choice stands**: a
/// non-empty `XCURSOR_THEME` or `XCURSOR_SIZE` is kept; the path is always
/// extended, ours first.
pub fn cursor_environment(runtime_dir: &str, environment: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    let get = |k: &str| environment.get(k).filter(|v| !v.is_empty());
    let mut out = BTreeMap::new();
    if get("XCURSOR_THEME").is_none() {
        out.insert(s("XCURSOR_THEME"), s(SESSION_CURSOR_THEME));
    }
    if get("XCURSOR_SIZE").is_none() {
        out.insert(s("XCURSOR_SIZE"), s("24"));
    }
    let home = environment.get("HOME").map_or("", String::as_str);
    let mut defaults: Vec<String> = if home.is_empty() { vec![] } else { vec![format!("{home}/.local/share/icons"), format!("{home}/.icons")] };
    defaults.extend(["/usr/local/share/icons", "/usr/share/icons", "/usr/share/pixmaps"].map(s));
    let rest = get("XCURSOR_PATH").cloned().unwrap_or_else(|| defaults.join(":"));
    out.insert(s("XCURSOR_PATH"), format!("{runtime_dir}/icons:{rest}"));
    out
}
