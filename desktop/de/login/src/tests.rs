//! LoginTests.swift (PHASE16 P16.1): the authenticator's decisions — who is
//! asking, how fast they may ask again, and that a password is never
//! written down. No root, no PAM, no socket: the checker and the account
//! table are handed in.

use crate::*;
use std::cell::Cell;
use std::rc::Rc;

const S: u64 = 1_000_000_000;

/// Accounts are a table and PAM is a compare; `calls` counts the compares.
fn auth(calls: Rc<Cell<u32>>) -> Authenticator {
    Authenticator::new(
        |uid| [(1001, "alice"), (1002, "bob")].iter().find(|(u, _)| *u == uid).map(|(_, n)| n.to_string()),
        move |user, pw| {
            calls.set(calls.get() + 1);
            let right = match user {
                "alice" => "correct-horse",
                "bob" => "battery-staple",
                _ => "",
            };
            if pw == right.as_bytes() { Check::Yes } else { Check::No("Authentication error".into()) }
        },
    )
}

fn ask(a: &mut Authenticator, uid: Option<u32>, pw: &str, at: u64) -> (Option<Verdict>, String) {
    let (reply, log) = a.handle(uid, &mut wire::request(pw.as_bytes()), at);
    (wire::decode(&reply), log)
}

#[test]
fn the_callers_own_password_is_accepted_and_another_accounts_is_not() {
    let mut a = auth(Rc::default());
    assert_eq!(ask(&mut a, Some(1001), "correct-horse", 0).0, Some(Verdict::Accepted));
    assert_eq!(ask(&mut a, Some(1001), "battery-staple", 0).0, Some(Verdict::Refused), "bob's password says nothing about alice: the uid decides whose is checked");
    assert_eq!(ask(&mut a, Some(1002), "battery-staple", 0).0, Some(Verdict::Accepted));
}

#[test]
fn a_caller_the_kernel_would_not_name_is_refused_outright() {
    let mut a = auth(Rc::default());
    let (reply, _) = a.handle(None, &mut wire::request(b"correct-horse"), 0);
    assert_eq!(reply.bool("ok"), Some(false));
    assert_eq!(wire::decode(&reply), None);
}

#[test]
fn two_typos_are_free_then_each_failure_doubles_the_wait() {
    let mut l = Limiter::default();
    l.failed(1, 0);
    assert_eq!(l.wait(1, 0), 0);
    l.failed(1, 0);
    assert_eq!(l.wait(1, 0), 0);
    l.failed(1, 0);
    assert_eq!(l.wait(1, 0), 2 * S);
    l.failed(1, 10 * S);
    assert_eq!(l.wait(1, 10 * S), 4 * S);
    for _ in 0..30 {
        l.failed(1, 0);
    }
    assert_eq!(l.wait(1, 0), Limiter::CAP_NS, "five minutes at most");
    assert_eq!(l.wait(2, 0), 0, "another uid is not held up");
    l.succeeded(1);
    assert_eq!(l.wait(1, 0), 0);
    assert_eq!(l.failures(1), 0);
}

#[test]
fn while_waiting_not_even_the_right_password_is_checked_and_pam_is_not_asked() {
    let calls: Rc<Cell<u32>> = Rc::default();
    let mut a = auth(calls.clone());
    for _ in 0..3 {
        ask(&mut a, Some(1001), "wrong", 0);
    }
    assert_eq!(calls.get(), 3);
    let (v, log) = ask(&mut a, Some(1001), "correct-horse", S);
    assert_eq!(v, Some(Verdict::Wait(1000)));
    assert_eq!(calls.get(), 3, "a caller made to wait must not get a free guess");
    assert!(log.contains("too soon"), "{log}");
    assert_eq!(ask(&mut a, Some(1001), "correct-horse", 2 * S).0, Some(Verdict::Accepted), "the wait over, the right one works");
}

#[test]
fn the_password_is_never_in_the_log() {
    let mut a = auth(Rc::default());
    for pw in ["correct-horse", "hunter2-wrong", "battery-staple"] {
        let (_, log) = ask(&mut a, Some(1001), pw, 0);
        assert!(!log.contains(pw), "logged: {log}");
    }
}

/// The request's copy is taken out to be checked: nothing of it is left in
/// the message once it has been answered.
#[test]
fn the_password_is_taken_out_of_the_request() {
    let mut a = auth(Rc::default());
    let mut m = wire::request(b"correct-horse");
    a.handle(Some(1001), &mut m, 0);
    assert!(!m.has("password"));
}

#[test]
fn an_account_that_does_not_exist_is_refused_and_an_unknown_method_is_an_error() {
    let mut a = auth(Rc::default());
    assert_eq!(ask(&mut a, Some(4242), "anything", 0).0, Some(Verdict::Refused));
    let mut m = Msg::new();
    m.set_string("method", "become-root");
    assert_eq!(a.handle(Some(1001), &mut m, 0).0.bool("ok"), Some(false));
}

#[test]
fn the_verdicts_survive_the_wire() {
    for v in [Verdict::Accepted, Verdict::Refused, Verdict::Wait(1500), Verdict::Unavailable("no PAM".into())] {
        assert_eq!(wire::decode(&wire::reply(&v)), Some(v));
    }
}

// MARK: power (P16.4a)

fn groups(g: &[&str]) -> Vec<String> {
    g.iter().map(|s| s.to_string()).collect()
}

fn may(a: PowerAction, uid: u32, g: &[&str]) -> bool {
    PowerPolicy::may(a, uid, &groups(g), 0, None)
}

#[test]
fn anyone_may_sleep_the_machine_and_only_administrators_restart_it() {
    assert!(may(PowerAction::Sleep, 1001, &[]), "sleep is anyone's, as on the Mac");
    assert!(!may(PowerAction::Restart, 1001, &["audio"]));
    assert!(!may(PowerAction::ShutDown, 1001, &["video", "audio"]));
    assert!(may(PowerAction::Restart, 1001, &["wheel"]));
    assert!(may(PowerAction::ShutDown, 1001, &["operator"]), "shutdown(8)'s own group");
    assert!(may(PowerAction::ShutDown, 0, &[]));
}

#[test]
fn each_action_runs_its_command() {
    let mut c = PowerCommands::default();
    assert_eq!(PowerPolicy::argv(PowerAction::Sleep, &c), groups(&["/usr/sbin/acpiconf", "-s", "3"]));
    assert_eq!(PowerPolicy::argv(PowerAction::Restart, &c), groups(&["/sbin/shutdown", "-r", "now"]));
    assert_eq!(PowerPolicy::argv(PowerAction::ShutDown, &c), groups(&["/sbin/shutdown", "-p", "now"]));
    c.acpiconf = "/tmp/stand-in".into();
    assert_eq!(PowerPolicy::argv(PowerAction::Sleep, &c)[0], "/tmp/stand-in");
}

#[test]
fn the_machines_buttons_are_roots_alone() {
    for a in [PowerAction::Lid, PowerAction::SleepKey, PowerAction::PowerKey] {
        assert!(may(a, 0, &[]));
        assert!(!may(a, 1001, &["wheel", "operator"]), "an administrator is not the hardware: {a:?}");
    }
    let c = PowerCommands::default();
    assert_eq!(PowerPolicy::argv(PowerAction::Lid, &c), groups(&["/usr/sbin/acpiconf", "-s", "3"]));
    assert_eq!(PowerPolicy::argv(PowerAction::PowerKey, &c), groups(&["/sbin/shutdown", "-p", "now"]), "the power key with nobody to ask: what the kernel would have done");
}

#[test]
fn every_action_has_its_wire_name() {
    for a in [PowerAction::Sleep, PowerAction::Restart, PowerAction::ShutDown, PowerAction::Lid, PowerAction::SleepKey, PowerAction::PowerKey] {
        assert_eq!(PowerAction::from_name(a.as_str()), Some(a));
    }
    assert_eq!(PowerAction::ShutDown.as_str(), "shut-down");
    assert_eq!(PowerAction::from_name("hibernate"), None);
}

// MARK: the login window (P16.5a)

fn login_request(user: &str, pw: &str) -> Msg {
    let mut m = wire::request(pw.as_bytes());
    m.set_string("method", "login");
    m.set_string("user", user);
    m
}

fn window_auth() -> Authenticator {
    Authenticator::new(|_| None, |user, pw| if (user == "ada" && pw == b"lovelace") || (user == "bob" && pw == b"b") { Check::Yes } else { Check::No("wrong".into()) })
}

fn uids(name: &str) -> Option<u32> {
    match name {
        "ada" => Some(1001),
        "bob" => Some(1002),
        _ => None,
    }
}

fn login(a: &mut Authenticator, greeter: bool, user: &str, pw: &str, now: u64) -> (Msg, String, Option<String>) {
    a.handle_login(greeter, &mut login_request(user, pw), now, &uids)
}

#[test]
fn only_the_login_window_may_ask_about_another_account() {
    let mut a = window_auth();
    let r = login(&mut a, false, "ada", "lovelace", 0);
    assert_eq!(r.0.bool("ok"), Some(false));
    assert_eq!(r.2, None);
    let g = login(&mut a, true, "ada", "lovelace", 0);
    assert_eq!(wire::decode(&g.0), Some(Verdict::Accepted));
    assert_eq!(g.2.as_deref(), Some("ada"), "the service starts ada's session");
}

#[test]
fn the_wait_is_per_account_asked_about_and_unknown_names_cost_the_same() {
    let mut a = window_auth();
    for k in 0..3 {
        login(&mut a, true, "ada", &format!("x{k}"), 0);
    }
    let held = login(&mut a, true, "ada", "lovelace", 1);
    assert!(matches!(wire::decode(&held.0), Some(Verdict::Wait(_))), "ada should wait: {}", held.1);
    assert_eq!(wire::decode(&login(&mut a, true, "bob", "b", 1).0), Some(Verdict::Accepted), "bob is not held up by guesses at ada");
    assert_eq!(wire::decode(&login(&mut a, true, "nobodyhere", "x", 1).0), Some(Verdict::Refused), "no such account looks like a wrong password");
    for _ in 0..2 {
        login(&mut a, true, "nobodyhere", "x", 1);
    }
    assert!(matches!(wire::decode(&login(&mut a, true, "nobodyhere", "x", 2).0), Some(Verdict::Wait(_))), "guessing at a name that is not an account must cost a wait too");
    assert!(!held.1.contains("lovelace"));
}

#[test]
fn the_window_offers_people_not_the_systems_accounts() {
    let e = |name, uid, gecos, shell| Entry { name, uid, gecos, shell };
    let all = [
        e("root", 0, "Charlie &", "/bin/sh"),
        e("_loginwindow", 1100, "", "/usr/sbin/nologin"),
        e("nobody", 65534, "Unprivileged user", "/usr/sbin/nologin"),
        e("daemon", 1, "", "/usr/sbin/nologin"),
        e("zed", 1003, "Zed Shaw,,,", "/bin/sh"),
        e("ada", 1001, "Ada Lovelace", "/bin/csh"),
        e("svc", 1004, "A service", "/usr/sbin/nologin"),
        e("bob", 1002, "", "/bin/sh"),
    ];
    let offered = accounts::offered(&all);
    assert_eq!(offered.iter().map(|a| a.name.as_str()).collect::<Vec<_>>(), ["ada", "bob", "zed"]);
    assert_eq!(offered[0].full_name, "Ada Lovelace");
    assert_eq!(offered[1].full_name, "bob", "no full name: the account name");
}

#[test]
fn accounts_groups_and_auto_login_from_their_files() {
    let passwd = "# comment\nroot:*:0:0:Charlie &:/root:/bin/sh\nada:*:1001:1001:Ada Lovelace:/home/ada:/bin/sh\n";
    assert_eq!(accounts::parse(passwd).iter().map(|a| a.uid).collect::<Vec<_>>(), [1001]);
    assert_eq!(accounts::members("wheel", "wheel:*:0:root,ada\nvideo:*:44:\n"), ["ada".to_owned(), "root".to_owned()].into());
    assert!(accounts::members("video", "video:*:44:\n").is_empty());
    assert_eq!(accounts::auto_login("abyss_desktop_enable=\"YES\"\n  abyss_desktop_user=\"ada\"\n").as_deref(), Some("ada"));
    assert_eq!(accounts::auto_login("abyss_desktop_enable=\"NO\"\nabyss_desktop_user=\"ada\"\n"), None, "the login window");
    assert_eq!(accounts::auto_login("abyss_desktop_enable=YES\n"), None);
}

#[test]
fn the_login_window_may_restart_and_shut_down() {
    let g = Some(1100);
    assert!(PowerPolicy::may(PowerAction::Restart, 1100, &[], 0, g));
    assert!(PowerPolicy::may(PowerAction::ShutDown, 1100, &[], 0, g));
    assert!(!PowerPolicy::may(PowerAction::Restart, 1101, &[], 0, g));
    assert!(!PowerPolicy::may(PowerAction::PowerKey, 1100, &[], 0, g), "not the hardware");
}

// MARK: sessions (P16.5b)

/// Only root may start a process as someone else; anyone else, only as
/// themselves, which is how a test runs the whole login flow unprivileged.
#[test]
fn only_root_spawns_as_another_account() {
    use abyss_sys::proc::{child_exit_events, poll, poll_fd, Child};
    if abyss_sys::platform::euid() == 0 {
        return; // as root, every account is ours to spawn as
    }
    let argv: Vec<String> = ["/bin/sh", "-c", "exit 0"].map(String::from).to_vec();
    let e = Child::spawn_as("root", &argv, &[], None).err().expect("as root, refused");
    assert_eq!(e.raw_os_error(), Some(libc::EPERM), "another account: refused before any fork");
    let e = Child::spawn_as(&format!("nosuchaccount{}", std::process::id()), &argv, &[], None).err().expect("refused");
    assert_eq!(e.raw_os_error(), Some(libc::ENOENT));
    let me = abyss_sys::users::by_uid(abyss_sys::platform::euid()).expect("who am I").name;
    let mut c = Child::spawn_as(&me, &argv, &[], None).expect("as oneself: allowed, nothing changed");
    let mut p = [poll_fd(c.fd(), child_exit_events())];
    assert_eq!(poll(&mut p, 5000).unwrap(), 1);
    c.reap();
    // **Reaped means reaped**: on FreeBSD, closing the process descriptor
    // alone left a zombie (HANDOFF §2.108). Nothing else here is our child.
    assert!(!abyss_sys::spawn::has_children(), "a reaped child is not left as a zombie");
}

/// One VT each (P16.6b): the greeter's is fixed; people get the lowest
/// free from 10, keep theirs, and give it back when they log out.
#[test]
fn each_session_has_its_own_vt() {
    let mut p = VTPlan::default();
    assert_eq!(VTPlan::GREETER, 9, "ttyv8: what /etc/ttys leaves for a display manager");
    assert_eq!(p.vt("ada"), Some(10));
    assert_eq!(p.vt("bob"), Some(11));
    assert_eq!(p.vt("ada"), Some(10), "ada keeps hers");
    p.release("ada");
    assert_eq!(p.vt("cy"), Some(10), "the lowest free");
    for n in ["d", "e", "f", "g", "h"] {
        p.vt(n);
    }
    assert_eq!(p.vt("z"), None, "every VT taken: none, not a shared one");
}
