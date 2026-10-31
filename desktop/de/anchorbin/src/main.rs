//! anchor: the AbyssBSD session supervisor (Rust; the Swift is main.swift
//! beside it, and the logic is the `anchor` crate).
//!
//! Starts a compositor (or attaches to a running one), brings the shell up
//! against it, keeps the components alive, and tears the session down as a
//! unit:
//!
//! ```text
//! anchor [options]
//!   --compositor CMD     start CMD as the compositor (absolute path); without
//!                        it, attach to $WAYLAND_DISPLAY
//!   --display NAME       the Wayland socket for the components
//!   --menubar-display N  the compositor's privileged socket, the bar's
//!   --component NAME=CMD supervise CMD as NAME (repeatable); without any,
//!                        the default session
//!   --without NAME       drop one of the default components (repeatable)
//!   --binary PATH        the shell binary (default: $ABYSS_APP_BINARY, else
//!                        AquaDemo beside us)
//!   --runtime-dir DIR    where the control socket lives ($ABYSS_RUNTIME_DIR)
//!   --mode MODE          desktop, installer or greeter
//!   --max-restarts N     consecutive failures tolerated per component (5)
//! ```
//!
//! **The environment is a value**, not `setenv`: what the session exports
//! (the runtime directory, the cursors, the bus) is handed to every child
//! the supervisor starts, and to the ones started here.

use anchor::{cursor_environment, current_environment, default_session, split_command, ComponentSpec, ControlSocket, RestartPolicy, SessionInputs, SessionMode, Supervisor, SESSION_CURSOR_THEME};
use std::collections::{BTreeMap, BTreeSet};
use std::process::exit;

fn fail(msg: &str) -> ! {
    eprintln!("anchor: {msg}");
    exit(2)
}

/// The directory this binary was run from, so the default components find
/// AquaDemo and the services beside it without a PATH search. **As invoked,
/// not resolved**: $ABYSS_BIN_DIR may be a directory of links, and the
/// siblings are there, not beside the file a link points to. Run by bare name (from `$PATH`),
/// the executable's own path.
fn self_directory() -> Option<String> {
    let argv0 = std::env::args().next().filter(|a| a.contains('/'));
    let p = match argv0 {
        Some(a) if a.starts_with('/') => a,
        Some(a) => format!("{}/{a}", std::env::current_dir().ok()?.display()),
        None => abyss_sys::proc::self_executable()?,
    };
    p.rfind('/').map(|i| p[..i].to_owned())
}

fn env(k: &str) -> Option<String> {
    std::env::var(k).ok().filter(|v| !v.is_empty())
}

const USAGE: &str = "usage: anchor [--compositor CMD] [--display NAME] [--menubar-display NAME]
              [--component NAME=CMD]
              [--without NAME] [--binary PATH] [--runtime-dir DIR]
              [--max-restarts N]
the default session: bus, portal, bridge, desktop, menubar, dock
control it with: abyssctl status | abyssctl quit
";

fn main() {
    let mut compositor_cmd: Option<String> = None;
    let mut display = env("WAYLAND_DISPLAY");
    let mut menubar_display: Option<String> = None;
    let mut explicit: Vec<(String, String)> = vec![];
    let mut mode = SessionMode::Desktop;
    let mut without = BTreeSet::new();
    let mut binary = env("ABYSS_APP_BINARY");
    let mut runtime_dir = env("ABYSS_RUNTIME_DIR");
    let mut max_restarts = 5;

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let a = args[i].clone();
        let mut next = |what: &str| -> String {
            i += 1;
            args.get(i).cloned().unwrap_or_else(|| fail(&format!("{a} needs {what}")))
        };
        match a.as_str() {
            "--compositor" => compositor_cmd = Some(next("a command")),
            "--display" => display = Some(next("a socket name")),
            "--menubar-display" => menubar_display = Some(next("a socket name")),
            "--binary" => binary = Some(next("a path")),
            "--runtime-dir" => runtime_dir = Some(next("a directory")),
            "--max-restarts" => max_restarts = next("a number").parse::<u32>().unwrap_or_else(|_| fail("--max-restarts wants a number")),
            "--mode" => {
                let m = next("desktop, installer or greeter");
                mode = SessionMode::from_name(&m).unwrap_or_else(|| fail(&format!("--mode is desktop, installer or greeter, not '{m}'")));
            }
            "--without" => {
                without.insert(next("a component name"));
            }
            "--component" => {
                let spec = next("NAME=COMMAND");
                match spec.split_once('=') {
                    Some((name, cmd)) if !name.is_empty() => explicit.push((name.to_owned(), cmd.to_owned())),
                    _ => fail(&format!("--component wants NAME=COMMAND, got '{spec}'")),
                }
            }
            "-h" | "--help" => {
                print!("{USAGE}");
                exit(0);
            }
            _ => fail(&format!("unknown option '{a}'")),
        }
        i += 1;
    }

    // What the session exports: one `current` namespace for the whole
    // session, so every component's sockets and anchor's own land together.
    let mut session_env: BTreeMap<String, String> = BTreeMap::new();
    let runtime = match &runtime_dir {
        Some(dir) => {
            session_env.insert("ABYSS_RUNTIME_DIR".into(), dir.clone());
            current_ipc::ensure_private_dir(dir).map(|_| dir.clone())
        }
        None => current_ipc::runtime_dir(),
    };
    let self_dir = self_directory();
    let beside = |name: &str| format!("{}/{name}", self_dir.as_deref().unwrap_or("."));

    // **Our cursors, for the toolkits that draw their own (U.7b)**: written
    // into the runtime directory from the theme as it is at login, and named
    // for every child. A missing abyss-theme costs a fallback cursor only.
    if let Ok(dir) = &runtime {
        let theme = beside("abyss-theme");
        if abyss_sys::spawn::executable(&theme) {
            let r = spawn::run(&[theme.as_str(), "cursors", &format!("{dir}/icons"), SESSION_CURSOR_THEME]);
            if r.exit_code() != Some(0) {
                eprintln!("anchor: could not write the cursor theme: {}", r.stderr_text());
            }
        }
        let mine = current_environment();
        let ask: BTreeMap<String, String> = ["XCURSOR_THEME", "XCURSOR_SIZE", "XCURSOR_PATH", "HOME"].iter().filter_map(|k| mine.get(*k).map(|v| ((*k).to_owned(), v.clone()))).collect();
        session_env.extend(cursor_environment(dir, &ask));
    }

    // **Every installed port as an application (P15.1)**: bundles in
    // ~/Applications, regenerated at every login, detached.
    let appgen = beside("abyss-appgen");
    if abyss_sys::spawn::executable(&appgen)
        && let Some(home) = env("HOME")
    {
        spawn::detached(&[appgen.as_str(), "--to", &format!("{home}/Applications")], &session_env);
    }

    // The shell binary, resolved once, here, so no child searches $PATH.
    let shell_binary = binary.unwrap_or_else(|| match &self_dir {
        Some(d) => format!("{d}/AquaDemo"),
        None => fail("cannot find my own directory — pass --binary or set ABYSS_APP_BINARY"),
    });

    let mut specs: Vec<ComponentSpec> = vec![];
    let (mut lock, mut first_run) = (None, None);
    if explicit.is_empty() {
        if !abyss_sys::spawn::executable(&shell_binary) {
            fail(&format!("no shell binary at {shell_binary} (build it, or pass --binary)"));
        }
        let Ok(dir) = &runtime else { fail("no runtime directory — pass --runtime-dir or set ABYSS_RUNTIME_DIR") };
        // A bare WAYLAND_DISPLAY is a name under $XDG_RUNTIME_DIR, an
        // absolute one the path itself; unknowable means no gate, not a guess.
        let socket_path = |d: &str| if d.starts_with('/') { Some(d.to_owned()) } else { env("XDG_RUNTIME_DIR").map(|x| format!("{x}/{d}")) };
        let mut inputs = SessionInputs::new(&shell_binary, self_dir.as_deref().unwrap_or("."), dir, display.as_deref());
        inputs.compositor_socket = display.as_deref().and_then(socket_path);
        inputs.menubar_display = menubar_display.clone();
        inputs.menubar_socket = menubar_display.as_deref().and_then(socket_path);
        inputs.mode = mode;
        inputs.first_run_done = pool_config::SetupState::done(None);
        inputs.without = without.clone();
        let plan = default_session(&inputs);
        // Exported to every child, including what the shell launches later:
        // the whole reason the bus comes first.
        session_env.extend(plan.application_environment());
        for note in &plan.notes {
            eprintln!("anchor: {note}");
        }
        specs = plan.components;
        lock = plan.lock_screen;
        first_run = plan.first_run;
    } else {
        for (name, cmd) in explicit.iter().filter(|(n, _)| !without.contains(n)) {
            let argv = split_command(cmd);
            if argv.is_empty() {
                fail(&format!("component '{name}' has an empty command"));
            }
            let mut spec = ComponentSpec::new(name, argv);
            if let Some(d) = &display {
                spec.env.insert("WAYLAND_DISPLAY".into(), d.clone());
            }
            specs.push(spec);
        }
    }
    if specs.is_empty() {
        fail("nothing to supervise");
    }

    let compositor = match &compositor_cmd {
        Some(cmd) => {
            let argv = split_command(cmd);
            if argv.is_empty() {
                fail("--compositor has an empty command");
            }
            Some(ComponentSpec::new("compositor", argv))
        }
        None if display.is_none() => fail("no --compositor and no $WAYLAND_DISPLAY — nothing to run against"),
        None => None,
    };

    let mut environment = current_environment();
    environment.extend(session_env);
    let control = match &runtime {
        Ok(dir) if runtime_dir.is_some() => ControlSocket::At(format!("{dir}/anchor.sock")),
        _ => ControlSocket::Default,
    };
    let policy = RestartPolicy { max_consecutive_failures: max_restarts, ..RestartPolicy::default() };
    let mut supervisor = Supervisor::new(compositor, specs, lock, first_run, policy, environment, control);
    exit(supervisor.run());
}
