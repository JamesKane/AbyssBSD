//! The service (Service.swift): run the picker, open what the user chose,
//! hand back the descriptor; relay a notification; capture the screen.

use crate::request::{picker_reply, png_size, screenshot_reply, GrabOutcome, OpenMode, PickerOutcome, PortalRequest};
use current_ipc::Msg;
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::fd::OwnedFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::ExitStatusExt;
use std::process::Command;

pub struct PortalService {
    /// The picker: `$ABYSS_PICKER`, else the AquaDemo beside this binary.
    pub picker_binary: String,
    /// The capture helper (`abyssgrab`): a separate process, so the portal
    /// answers `screenshot` without ever becoming a Wayland client (§6.1).
    pub grabber_binary: String,
    /// The runtime directory for the picker's result file and the capture,
    /// or None for `current_ipc`'s (a test passes its own).
    pub runtime_dir: Option<String>,
    pub journal: Vec<String>,
}

/// The binary to run: what the caller said, else the environment's, else
/// the sibling.
pub fn choose_binary(explicit: Option<&str>, from_env: Option<&str>, sibling: Option<String>, bare: &str) -> String {
    explicit
        .or(from_env.filter(|v| !v.is_empty()))
        .map(str::to_owned)
        .or(sibling)
        .unwrap_or_else(|| bare.to_owned())
}

/// `name` beside the path this program was run as. **Not the resolved
/// executable**: the harness's bin directory links into both builds, and
/// the siblings are there (anchor needed the same).
pub fn sibling_binary(name: &str) -> Option<String> {
    let argv0 = std::env::args().next().filter(|a| a.contains('/'));
    let p = match argv0 {
        Some(a) if a.starts_with('/') => a,
        Some(a) => format!("{}/{a}", std::env::current_dir().ok()?.display()),
        None => abyss_sys::proc::self_executable()?,
    };
    p.rfind('/').map(|i| format!("{}/{name}", &p[..i]))
}

/// The picker's result file, read the portal's way (P7.1's contract): one
/// absolute path, or nothing. The portal opens what this returns.
pub fn read_picker_result(path: &str) -> Option<String> {
    let mut buf = [0u8; 4096];
    let n = File::open(path).ok()?.read(&mut buf).ok()?;
    let s = String::from_utf8_lossy(&buf[..n]);
    let s = s.trim_end_matches(['\n', '\r']);
    (!s.is_empty() && s.starts_with('/')).then(|| s.to_owned())
}

/// What a finished child said: its status and whether a signal ended it,
/// as `ap_run_and_wait` reports them; Err with strerror's words when it
/// could not run at all.
fn run_and_wait(argv: &[String], env: &BTreeMap<String, String>) -> Result<(i32, bool), String> {
    let status = Command::new(&argv[0]).args(&argv[1..]).env_clear().envs(env).status().map_err(|e| words(&e))?;
    Ok(match (status.code(), status.signal()) {
        (Some(c), _) => (c, false),
        (None, Some(s)) => (s, true),
        _ => (-1, false),
    })
}

fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}

fn environment() -> BTreeMap<String, String> {
    std::env::vars_os().map(|(k, v)| (k.to_string_lossy().into_owned(), v.to_string_lossy().into_owned())).collect()
}

impl PortalService {
    /// `$ABYSS_PICKER` and `$ABYSS_GRABBER` override; otherwise the
    /// siblings, resolved once.
    pub fn new(picker: Option<&str>, grabber: Option<&str>) -> PortalService {
        let env = |k: &str| std::env::var(k).ok();
        PortalService {
            picker_binary: choose_binary(picker, env("ABYSS_PICKER").as_deref(), sibling_binary("AquaDemo"), "AquaDemo"),
            grabber_binary: choose_binary(grabber, env("ABYSS_GRABBER").as_deref(), sibling_binary("abyssgrab"), "abyssgrab"),
            runtime_dir: None,
            journal: vec![],
        }
    }

    fn log(&mut self, msg: String) {
        eprintln!("portal: {msg}");
        self.journal.push(msg);
    }

    fn runtime(&self) -> Option<String> {
        self.runtime_dir.clone().or_else(|| current_ipc::runtime_dir().ok())
    }

    /// Answer one request: the reply, and when the user chose a file, **an
    /// open descriptor** to attach and then drop.
    pub fn handle(&mut self, request: &PortalRequest) -> (Msg, Option<OwnedFd>) {
        match request {
            PortalRequest::OpenFile { start_dir } => self.choose(start_dir.as_deref(), None, OpenMode::Read),
            PortalRequest::SaveFile { start_dir, suggested_name } => self.choose(start_dir.as_deref(), suggested_name.as_deref(), OpenMode::Write),
            PortalRequest::Notify { summary, body, timeout } => (self.relay_notify(summary, body.as_deref(), *timeout), None),
            PortalRequest::Screenshot => self.capture(),
            PortalRequest::Unknown(method) => {
                self.log(format!("unknown method '{method}'"));
                let mut reply = Msg::new();
                reply.set_bool("ok", false);
                reply.set_string("error", "unknown method");
                (reply, None)
            }
        }
    }

    /// Relay a notification to the shell's notify service: the portal is the
    /// only thing that talks to it, so a sandboxed app can post a toast
    /// without reaching, or impersonating, the shell.
    fn relay_notify(&mut self, summary: &str, body: Option<&str>, timeout: Option<u64>) -> Msg {
        let mut out = Msg::new();
        out.set_string("method", "notify");
        out.set_string("summary", summary);
        if let Some(b) = body {
            out.set_string("body", b);
        }
        if let Some(t) = timeout {
            out.set_u64("timeout", t);
        }
        let mut reply = Msg::new();
        let service = std::env::var("ABYSS_NOTIFY_SERVICE").unwrap_or_else(|_| "notify".into());
        match current_ipc::call(&service, &out) {
            Ok(answer) => {
                self.log(format!("relayed a notification: {summary}"));
                reply.set_bool("ok", answer.bool("ok").unwrap_or(false));
                if let Some(id) = answer.u64("id") {
                    reply.set_u64("id", id);
                }
            }
            Err(e) => {
                // No notification centre running is a normal state.
                self.log(format!("no notify service to relay to ({e})"));
                reply.set_bool("ok", false);
                reply.set_string("error", "no notification service");
            }
        }
        reply
    }

    fn choose(&mut self, start_dir: Option<&str>, name: Option<&str>, mode: OpenMode) -> (Msg, Option<OwnedFd>) {
        let outcome = self.run_picker(start_dir, name);
        let PickerOutcome::Chose(path) = &outcome else {
            let why = if outcome == PickerOutcome::Cancelled { "cancelled".to_owned() } else { format!("picker failed: {outcome:?}") };
            self.log(why);
            return (picker_reply(&outcome, mode), None);
        };
        // The portal opens the path THE USER CHOSE; nothing the requesting
        // app sent reaches this call.
        let mut o = OpenOptions::new();
        match mode {
            OpenMode::Read => o.read(true),
            OpenMode::Write => o.write(true).create(true).mode(0o600),
        };
        match o.open(path) {
            Ok(f) => {
                self.log(format!("handing over {path} ({})", if mode == OpenMode::Read { "read" } else { "write" }));
                (picker_reply(&outcome, mode), Some(f.into()))
            }
            Err(e) => {
                let why = words(&e);
                self.log(format!("cannot open {path}: {why}"));
                (picker_reply(&PickerOutcome::Failed(format!("cannot open the chosen file: {why}")), mode), None)
            }
        }
    }

    /// Capture the screen and hand back the PNG as a descriptor. **The image
    /// is unlinked the moment it is opened**: after this returns the
    /// descriptor is the only way to the bytes, for anyone.
    fn capture(&mut self) -> (Msg, Option<OwnedFd>) {
        let Some(runtime) = self.runtime() else { return (screenshot_reply(&GrabOutcome::Failed("no runtime directory".into())), None) };
        let path = format!("{runtime}/shot.{}.png", std::process::id());
        let _ = fs::remove_file(&path);
        // The helper needs this session's WAYLAND_DISPLAY, which the portal has.
        let (status, signalled) = match run_and_wait(&[self.grabber_binary.clone(), path.clone()], &environment()) {
            Ok(s) => s,
            Err(why) => {
                let _ = fs::remove_file(&path);
                self.log(format!("could not run the capture helper: {why}"));
                return (screenshot_reply(&GrabOutcome::Failed(format!("could not run the capture helper ({why})"))), None);
            }
        };
        // Open BEFORE unlinking, and unlink unconditionally.
        let file = File::open(&path).ok();
        let _ = fs::remove_file(&path);
        let mut file = file;
        let size = file.as_mut().and_then(|f| {
            let mut head = [0u8; 24];
            f.read_exact(&mut head).ok().and_then(|_| png_size(&head))
        });
        let outcome = GrabOutcome::from(status, signalled, size);
        let (GrabOutcome::Captured { width, height }, Some(mut f)) = (&outcome, file) else {
            self.log(format!("screenshot failed: {outcome:?}"));
            return (screenshot_reply(&outcome), None);
        };
        // The client reads from the start; the header probe moved the offset.
        let _ = f.seek(SeekFrom::Start(0));
        self.log(format!("handing over a {width}x{height} screenshot — as a descriptor with no name"));
        (screenshot_reply(&outcome), Some(f.into()))
    }

    /// Run the picker and wait. Blocking is right: a file dialog is modal,
    /// and the service answers one request at a time.
    pub fn run_picker(&mut self, start_dir: Option<&str>, suggested_name: Option<&str>) -> PickerOutcome {
        // A private result file, in the runtime directory (0700), not /tmp:
        // another user must not be able to plant a path for the portal.
        let Some(runtime) = self.runtime() else { return PickerOutcome::Failed("no runtime directory".into()) };
        let result = format!("{runtime}/pick.{}", std::process::id());
        let _ = fs::remove_file(&result);
        let mut env = environment();
        env.insert("AQUA_SCENE".into(), "finder".into());
        env.insert("ABYSS_FINDER_PICK".into(), result.clone());
        if let Some(d) = start_dir {
            env.insert("ABYSS_FINDER_DIR".into(), d.into());
        }
        if let Some(n) = suggested_name {
            env.insert("ABYSS_FINDER_SAVE_NAME".into(), n.into());
        }
        let outcome = match run_and_wait(std::slice::from_ref(&self.picker_binary), &env) {
            Ok((status, signalled)) => PickerOutcome::from(status, signalled, read_picker_result(&result)),
            Err(why) => PickerOutcome::Failed(format!("could not run the picker ({why})")),
        };
        let _ = fs::remove_file(&result);
        outcome
    }
}
