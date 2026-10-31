//! Talking to the settings helper (SoundPane.swift's SettingsClient): read a
//! configured plan, send an apply and follow its events in the run loop,
//! and Wi-Fi's own reads. Every pane that changes the machine comes here.

use current_ipc::Msg;
use settings::{SettingsPlan, SettingsRefusal};
use settings_wire::{SettingsEvent, WifiKnown};
use std::cell::RefCell;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::rc::Rc;
use surface::Display;

pub fn service() -> String {
    std::env::var("ABYSS_SETTINGS_SERVICE").unwrap_or_else(|_| "settings".into())
}

fn refusal(s: &str) -> SettingsRefusal {
    SettingsRefusal { message: s.into() }
}

fn call(request: &Msg) -> Result<Msg, SettingsRefusal> {
    let reply = current_ipc::call(&service(), request).map_err(|_| refusal("the settings helper is not running on this machine"))?;
    if reply.bool("ok") != Some(true) {
        return Err(refusal(reply.string("error").unwrap_or("refused")));
    }
    Ok(reply)
}

/// The configured plan of `kind`, or the helper's reason there is none.
pub fn read(kind: &str, interface: Option<&str>) -> Result<SettingsPlan, SettingsRefusal> {
    let mut m = Msg::new();
    m.set_string("method", "read");
    m.set_string("kind", kind);
    if let Some(i) = interface {
        m.set_string("interface", i)
    }
    settings_wire::decode_plan(&call(&m)?)
}

/// A radio's wlan, and the networks wpa_supplicant.conf holds.
pub fn read_wifi(device: &str) -> Result<WifiKnown, SettingsRefusal> {
    let mut m = Msg::new();
    m.set_string("method", "read");
    m.set_string("kind", "wifi");
    m.set_string("wifi.device", device);
    Ok(settings_wire::decode_known(&call(&m)?))
}

/// Scan from a radio, as root. Blocking: a scan takes a second or two, and
/// the page has nothing to show until it is done.
pub fn scan_wifi(device: &str, interface: &str) -> Result<Vec<settings::WifiNetwork>, SettingsRefusal> {
    let mut m = Msg::new();
    m.set_string("method", "scan");
    m.set_string("wifi.device", device);
    m.set_string("wifi.interface", interface);
    Ok(settings_wire::decode_scan(&call(&m)?))
}

/// An apply's request.
pub fn apply_request(plan: &SettingsPlan) -> Msg {
    let mut m = Msg::new();
    m.set_string("method", "apply");
    settings_wire::encode_plan(plan, &mut m);
    m
}

/// What an apply came to, in words.
pub fn outcome(ok: bool, error: &str, skipped: &[String]) -> String {
    if !ok {
        return format!("Not applied: {error}");
    }
    match skipped.first() {
        Some(why) => format!("Saved, and not put into effect ({why})."),
        None => "Applied.".into(),
    }
}

/// An apply in flight: its events are followed in the display's loop.
/// `log` hears each step, `done` the outcome (ok, the words).
pub struct Apply {
    sock: UnixStream,
    skipped: RefCell<Vec<String>>,
}

impl Apply {
    /// Send `request`; None when the helper is not there.
    pub fn begin(display: &Rc<Display>, request: &Msg, log: impl Fn(&str) + 'static, done: impl Fn(bool, String) + 'static) -> Option<Rc<Apply>> {
        let sock = current_ipc::connect(&service()).ok()?;
        current_ipc::send(request, &sock).ok()?;
        let a = Rc::new(Apply { sock, skipped: RefCell::default() });
        let (fd, w, d) = (a.sock.as_raw_fd(), Rc::downgrade(&a), Rc::downgrade(display));
        display.add_fd(fd, move || {
            let Some(a) = w.upgrade() else { return };
            // A refusal is the `finished` it amounts to.
            let e = match current_ipc::receive(&a.sock) {
                Ok(m) => settings_wire::decode_event(&m).or_else(|| (m.bool("ok") == Some(false)).then(|| SettingsEvent::Finished { ok: false, error: m.string("error").unwrap_or("refused").into() })),
                Err(_) => Some(SettingsEvent::Finished { ok: false, error: "the settings helper hung up".into() }),
            };
            match e {
                Some(SettingsEvent::Starting { index, total, what }) => log(&format!("[{}/{total}] {what}", index + 1)),
                Some(SettingsEvent::Skipped { why, .. }) => {
                    log(&format!("skipped: {why}"));
                    a.skipped.borrow_mut().push(why)
                }
                Some(SettingsEvent::Failed { why, ignored, .. }) => log(&format!("{}: {why}", if ignored { "failed, and that is allowed" } else { "FAILED" })),
                Some(SettingsEvent::Finished { ok, error }) => {
                    if let Some(d) = d.upgrade() {
                        d.remove_fd(fd)
                    }
                    let said = outcome(ok, &error, &a.skipped.borrow());
                    done(ok, said)
                }
                Some(SettingsEvent::Ok { .. }) | None => {}
            }
        });
        Some(a)
    }
}

#[cfg(test)]
mod tests {
    use super::outcome;

    #[test]
    fn an_outcome_in_words() {
        assert_eq!(outcome(false, "no", &[]), "Not applied: no");
        assert_eq!(outcome(true, "", &["a test's helper".into()]), "Saved, and not put into effect (a test's helper).");
        assert_eq!(outcome(true, "", &[]), "Applied.");
    }
}
