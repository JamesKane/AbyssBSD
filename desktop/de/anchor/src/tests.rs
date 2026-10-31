//! AnchorTests.swift, ported: the supervisor's *decisions*, which are the
//! part that can be wrong quietly. Spawning and tearing down real processes
//! is proved live by abyss/tests/live-anchor.sh.

use super::*;
use std::collections::{BTreeMap, BTreeSet};

fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

// MARK: the restart policy

#[test]
fn a_flapping_component_is_eventually_abandoned() {
    let p = RestartPolicy { max_consecutive_failures: 3, healthy_run_seconds: 5.0 };
    assert_eq!(p.decide(0.1, 0), Decision::Restart(1));
    assert_eq!(p.decide(0.1, 1), Decision::Restart(2));
    assert_eq!(p.decide(0.1, 2), Decision::Restart(3));
    assert_eq!(p.decide(0.1, 3), Decision::GiveUp(4));
}

#[test]
fn a_healthy_run_clears_the_streak() {
    let p = RestartPolicy { max_consecutive_failures: 3, healthy_run_seconds: 5.0 };
    assert_eq!(p.decide(60.0, 3), Decision::Restart(1));
    assert_eq!(p.decide(5.0, 3), Decision::Restart(1), "exactly at the threshold counts as healthy");
    assert_eq!(p.decide(4.999, 3), Decision::GiveUp(4));
}

#[test]
fn zero_restarts_means_one_strike() {
    let p = RestartPolicy { max_consecutive_failures: 0, healthy_run_seconds: 5.0 };
    assert_eq!(p.decide(0.1, 0), Decision::GiveUp(1));
    assert_eq!(p.decide(3600.0, 0), Decision::GiveUp(1));
}

/// The policy matches `abyss/session.sh`, the thing it replaces.
#[test]
fn defaults_match_the_shell_supervisor_it_replaces() {
    let p = RestartPolicy::default();
    assert_eq!((p.max_consecutive_failures, p.healthy_run_seconds), (5, 5.0));
    assert_eq!(p.decide(0.0, 4), Decision::Restart(5));
    assert_eq!(p.decide(0.0, 5), Decision::GiveUp(6));
}

// MARK: a child's environment

#[test]
fn overrides_layer_over_the_inherited_environment() {
    let block = environment_block(&env(&[("PATH", "/bin"), ("HOME", "/home/build"), ("AQUA_SCENE", "old")]), &env(&[("AQUA_SCENE", "dock"), ("WAYLAND_DISPLAY", "wayland-1")]));
    assert_eq!(block, ["AQUA_SCENE=dock", "HOME=/home/build", "PATH=/bin", "WAYLAND_DISPLAY=wayland-1"], "sorted, so reproducible");
}

#[test]
fn an_empty_override_still_replaces() {
    assert_eq!(environment_block(&env(&[("A", "1")]), &env(&[("A", "")])), ["A="]);
}

#[test]
fn the_process_environment_is_readable() {
    assert!(current_environment().contains_key("PATH"), "a parser that produces nothing");
}

// MARK: command splitting

#[test]
fn command_splitting_is_whitespace_only() {
    assert_eq!(split_command("/usr/local/bin/sway"), ["/usr/local/bin/sway"]);
    assert_eq!(split_command("  /bin/sleep   300 "), ["/bin/sleep", "300"]);
    assert!(split_command("").is_empty());
    assert_eq!(split_command("/bin/echo \"a b\""), ["/bin/echo", "\"a", "b\""], "deliberately not a shell");
}

// MARK: component specs

#[test]
fn a_spec_carries_its_environment() {
    let mut spec = ComponentSpec::new("dock", vec!["/x/AquaDemo".into()]);
    spec.env.insert("AQUA_SCENE".into(), "dock".into());
    assert_eq!(spec.name, "dock");
    assert_eq!(spec.argv, ["/x/AquaDemo"]);
    assert_eq!(spec.env.get("AQUA_SCENE").map(String::as_str), Some("dock"));
    assert!(spec.requires.is_empty(), "a spec waits for nothing unless told");
}

#[test]
fn the_monotonic_clock_moves_forward() {
    let a = monotonic_seconds();
    std::thread::sleep(std::time::Duration::from_millis(20));
    let b = monotonic_seconds();
    assert!(b > a && b - a < 5.0);
}

// MARK: the default session (P8.4)

fn inputs() -> SessionInputs {
    SessionInputs::new("/opt/abyss/AquaDemo", "/opt/abyss", "/run/abyss", Some("abyss-0"))
}

fn plan_with(f: impl FnOnce(&mut SessionInputs)) -> SessionPlan {
    let mut i = inputs();
    f(&mut i);
    default_session(&i)
}

fn plan() -> SessionPlan {
    default_session(&inputs())
}

fn without(names: &[&str]) -> SessionPlan {
    plan_with(|i| i.without = names.iter().map(|n| (*n).to_owned()).collect::<BTreeSet<_>>())
}

fn mode(m: SessionMode) -> SessionPlan {
    plan_with(|i| i.mode = m)
}

fn names(p: &SessionPlan) -> Vec<&str> {
    p.components.iter().map(|c| c.name.as_str()).collect()
}

fn component<'a>(p: &'a SessionPlan, name: &str) -> Option<&'a ComponentSpec> {
    p.components.iter().find(|c| c.name == name)
}

fn e<'a>(c: Option<&'a ComponentSpec>, k: &str) -> Option<&'a str> {
    c.and_then(|c| c.env.get(k)).map(String::as_str)
}

#[test]
fn an_installer_session_runs_the_installer_and_not_a_shell() {
    let p = mode(SessionMode::Installer);
    let n = names(&p);
    assert_eq!(n.iter().filter(|n| **n == "desktop" || **n == "installer").collect::<Vec<_>>(), [&"desktop", &"installer"]);
    assert!(!n.contains(&"dock") && !n.contains(&"menubar"));
    assert_eq!(e(component(&p, "installer"), "AQUA_SCENE"), Some("installer"));
    assert_eq!(component(&p, "installer").unwrap().argv, ["/opt/abyss/AquaDemo"], "the same binary the desktop runs");
}

#[test]
fn an_installer_session_still_waits_for_the_compositor() {
    let p = plan_with(|i| {
        i.mode = SessionMode::Installer;
        i.compositor_socket = Some("/run/abyss/wayland-1".into());
    });
    for c in p.components.iter().filter(|c| c.name == "installer" || c.name == "desktop") {
        assert_eq!(c.requires, ["/run/abyss/wayland-1"], "{}", c.name);
    }
}

/// The menu bar, and only the menu bar, goes to the privileged socket.
#[test]
fn only_the_menu_bar_is_pointed_at_the_privileged_socket() {
    let p = plan_with(|i| {
        i.compositor_socket = Some("/run/x/abyss-0".into());
        i.menubar_display = Some("abyss-0-bar".into());
        i.menubar_socket = Some("/run/x/abyss-0-bar".into());
    });
    for c in &p.components {
        if c.name == "menubar" {
            assert_eq!(e(Some(c), "WAYLAND_DISPLAY"), Some("abyss-0-bar"));
            assert_eq!(e(Some(c), "ABYSS_APP_WAYLAND_DISPLAY"), Some("abyss-0"), "what the bar launches goes on the ordinary display (P10.8)");
            assert_eq!(c.requires, ["/run/x/abyss-0", "/run/x/abyss-0-bar"]);
        } else if c.env.contains_key("WAYLAND_DISPLAY") {
            assert_eq!(e(Some(c), "WAYLAND_DISPLAY"), Some("abyss-0"), "{} must not be handed the privileged socket", c.name);
        }
    }
    assert_eq!(e(component(&plan(), "menubar"), "WAYLAND_DISPLAY"), Some("abyss-0"));
}

#[test]
fn the_lock_screen_is_planned_on_the_privileged_display_and_not_started() {
    let p = plan_with(|i| i.menubar_display = Some("abyss-0-bar".into()));
    let lock = p.lock_screen.as_ref().unwrap();
    assert_eq!(lock.argv, ["/opt/abyss/AquaDemo"]);
    assert_eq!((e(Some(lock), "AQUA_SCENE"), e(Some(lock), "WAYLAND_DISPLAY")), (Some("lock"), Some("abyss-0-bar")));
    assert!(component(&p, "lock").is_none(), "not started with the session");
    assert_eq!(e(plan().lock_screen.as_ref(), "WAYLAND_DISPLAY"), Some("abyss-0"));
    assert!(mode(SessionMode::Installer).lock_screen.is_none());
    assert!(without(&["lock"]).lock_screen.is_none());
}

#[test]
fn the_idle_policy_is_a_desktop_component() {
    let p = plan_with(|i| i.compositor_socket = Some("/run/x/abyss-0".into()));
    let idle = component(&p, "idle").unwrap();
    assert_eq!(idle.argv, ["/opt/abyss/abyss-idle"]);
    assert_eq!(e(Some(idle), "WAYLAND_DISPLAY"), Some("abyss-0"));
    assert_eq!(idle.requires, ["/run/x/abyss-0"]);
    assert!(component(&mode(SessionMode::Installer), "idle").is_none());
    assert!(component(&without(&["idle"]), "idle").is_none());
}

#[test]
fn the_jail_keeper_is_a_desktop_component() {
    let p = plan_with(|i| i.compositor_socket = Some("/run/x/abyss-0".into()));
    let jails = component(&p, "jails").unwrap();
    assert_eq!(jails.argv, ["/opt/abyss/abyss-jail", "serve"]);
    assert_eq!(jails.requires, ["/run/x/abyss-0"]);
    for p in [mode(SessionMode::Installer), mode(SessionMode::Greeter), without(&["jails"])] {
        assert!(component(&p, "jails").is_none());
    }
}

#[test]
fn the_greeter_session_is_the_login_window_alone() {
    let p = mode(SessionMode::Greeter);
    assert_eq!(names(&p), ["loginwindow"]);
    assert_eq!(e(p.components.first(), "AQUA_SCENE"), Some("loginwindow"));
    assert!(p.lock_screen.is_none() && p.bus_address.is_none());
}

#[test]
fn the_setup_assistant_is_planned_only_until_it_is_done() {
    let p = |done: bool, m: SessionMode, w: &[&str]| {
        plan_with(|i| {
            i.first_run_done = done;
            i.mode = m;
            i.without = w.iter().map(|n| (*n).to_owned()).collect();
        })
    };
    let first = p(false, SessionMode::Desktop, &[]);
    assert_eq!(e(first.first_run.as_ref(), "AQUA_SCENE"), Some("setupassistant"));
    assert!(component(&first, "setup").is_none(), "not a component");
    assert!(p(true, SessionMode::Desktop, &[]).first_run.is_none());
    assert!(p(false, SessionMode::Greeter, &[]).first_run.is_none());
    assert!(p(false, SessionMode::Installer, &[]).first_run.is_none());
    assert!(p(false, SessionMode::Desktop, &["setup"]).first_run.is_none());
}

/// **The bus is first, and the order is the pass.**
#[test]
fn the_session_starts_in_the_order_its_dependencies_require() {
    assert_eq!(names(&plan()), ["bus", "portal", "bridge", "menus", "idle", "jails", "desktop", "menubar", "dock"]);
}

#[test]
fn the_menu_bridge_is_a_service_on_the_bridges_private_socket() {
    let p = plan();
    let m = component(&p, "menus").unwrap();
    assert_eq!(m.argv, ["/opt/abyss/abyss-dbus", "--menus"]);
    assert_eq!(m.requires, ["/run/abyss/dbus-services"]);
    assert_eq!(e(Some(m), "DBUS_SESSION_BUS_ADDRESS"), Some("unix:path=/run/abyss/dbus-services"));
    assert!(component(&without(&["bus"]), "menus").is_none());
}

#[test]
fn the_portal_service_waits_for_the_bridge_and_for_the_portal() {
    let p = plan();
    let bridge = component(&p, "bridge").unwrap();
    assert_eq!(bridge.requires, ["/run/abyss/dbus-services", "/run/abyss/portal.sock"]);
    assert_eq!(e(Some(bridge), "DBUS_SESSION_BUS_ADDRESS"), Some("unix:path=/run/abyss/dbus-services"));
    assert_eq!(component(&without(&["portal"]), "bridge").unwrap().requires, ["/run/abyss/dbus-services"]);
}

#[test]
fn the_session_names_its_own_bus_rather_than_asking_what_it_chose() {
    let p = plan();
    assert_eq!(p.bus_address.as_deref(), Some("unix:path=/run/abyss/bus"));
    assert_eq!(p.bus_address, Some(session_bus_address("/run/abyss")));
    assert_eq!(component(&p, "bus").unwrap().argv, ["/opt/abyss/abyss-dbus", "--endpoint", "--listen", "/run/abyss/bus", "--services", "/run/abyss/dbus-services"]);
}

/// **ADE's bridge, never `dbus-daemon`** (PRODUCT §5.6).
#[test]
fn the_bus_is_ades_bridge_and_never_dbus_daemon() {
    for m in [SessionMode::Desktop, SessionMode::Installer, SessionMode::Greeter] {
        let p = mode(m);
        let forbidden = ["dbus", "daemon"].join("-");
        assert!(!p.components.iter().any(|c| c.argv.join(" ").contains(&forbidden)), "{m:?}");
        assert!(!p.notes.iter().any(|n| n.contains(&forbidden)));
    }
    assert!(plan().bus_address.is_some());
}

#[test]
fn applications_are_told_to_use_the_portal_only_when_it_is_there() {
    assert_eq!(plan().application_environment(), env(&[("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/abyss/bus"), ("GTK_USE_PORTAL", "1")]));
    assert!(without(&["bus"]).application_environment().is_empty());
}

#[test]
fn dropping_the_bus_drops_the_bridge_and_explains_itself() {
    let p = without(&["bus"]);
    assert_eq!(names(&p), ["portal", "idle", "jails", "desktop", "menubar", "dock"]);
    assert_eq!(p.notes.len(), 1);
    assert!(p.notes[0].contains("bridge"), "{}", p.notes[0]);
}

#[test]
fn the_shell_waits_for_the_compositor_socket_when_its_path_is_known() {
    let p = plan_with(|i| i.compositor_socket = Some("/run/user/1000/abyss-0".into()));
    for name in ["desktop", "menubar", "dock"] {
        assert_eq!(component(&p, name).unwrap().requires, ["/run/user/1000/abyss-0"], "{name}");
    }
    assert!(component(&p, "portal").unwrap().requires.is_empty(), "services do not wait for it");
    assert!(component(&plan(), "dock").unwrap().requires.is_empty(), "no knowable path, no gate");
}

#[test]
fn every_component_is_told_where_the_session_lives() {
    for c in &plan_with(|i| i.compositor_socket = Some("/run/user/1000/abyss-0".into())).components {
        assert_eq!((e(Some(c), "ABYSS_RUNTIME_DIR"), e(Some(c), "WAYLAND_DISPLAY")), (Some("/run/abyss"), Some("abyss-0")), "{}", c.name);
    }
}

#[test]
fn the_shell_components_carry_their_scene_and_our_services_are_beside_the_binary() {
    let p = plan();
    for (name, scene) in [("desktop", "wallpaper"), ("menubar", "menubar"), ("dock", "dock")] {
        assert_eq!(e(component(&p, name), "AQUA_SCENE"), Some(scene));
    }
    assert_eq!(component(&p, "dock").unwrap().argv, ["/opt/abyss/AquaDemo"]);
    assert_eq!(component(&p, "portal").unwrap().argv, ["/opt/abyss/abyss-portal"]);
    assert_eq!(component(&p, "bridge").unwrap().argv, ["/opt/abyss/abyss-dbus"]);
    assert_eq!(names(&plan()).iter().rev().take(3).collect::<Vec<_>>(), [&"dock", &"menubar", &"desktop"]);
}

#[test]
fn the_bus_address_can_be_turned_back_into_a_socket_path() {
    assert_eq!(unix_socket_path("unix:path=/run/abyss/bus").as_deref(), Some("/run/abyss/bus"));
    assert_eq!(unix_socket_path("unix:path=/run/abyss/bus,guid=abc").as_deref(), Some("/run/abyss/bus"));
    assert_eq!(unix_socket_path("unix:abstract=/tmp/dbus-x"), None);
    assert_eq!(unix_socket_path("tcp:host=localhost,port=1234"), None);
}

// MARK: cursors (U.7b)

#[test]
fn the_session_names_abyss_and_puts_its_directory_first() {
    let c = cursor_environment("/run/s", &env(&[("HOME", "/home/p")]));
    assert_eq!(c["XCURSOR_THEME"], "Abyss");
    assert_eq!(c["XCURSOR_SIZE"], "24");
    assert_eq!(c["XCURSOR_PATH"], "/run/s/icons:/home/p/.local/share/icons:/home/p/.icons:/usr/local/share/icons:/usr/share/icons:/usr/share/pixmaps");
}

#[test]
fn a_persons_own_theme_and_size_are_kept_and_their_path_extended() {
    let c = cursor_environment("/run/s", &env(&[("XCURSOR_THEME", "Adwaita"), ("XCURSOR_SIZE", "48"), ("XCURSOR_PATH", "/opt/icons")]));
    assert!(!c.contains_key("XCURSOR_THEME") && !c.contains_key("XCURSOR_SIZE"), "theirs stands");
    assert_eq!(c["XCURSOR_PATH"], "/run/s/icons:/opt/icons");
}

#[test]
fn an_empty_variable_is_not_a_choice() {
    let c = cursor_environment("/r", &env(&[("XCURSOR_THEME", ""), ("XCURSOR_PATH", "")]));
    assert_eq!(c["XCURSOR_THEME"], "Abyss");
    assert_eq!(c["XCURSOR_PATH"], "/r/icons:/usr/local/share/icons:/usr/share/icons:/usr/share/pixmaps");
}
