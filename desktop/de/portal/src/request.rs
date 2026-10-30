//! What an app may ask for, and what the answers mean (Portal.swift,
//! PHASE7 P7.2).
//!
//! An app asks the desktop to let the user pick a file. The portal runs the
//! **Finder** as the picker, **opens the chosen file itself**, and returns
//! the open descriptor over SCM_RIGHTS: the descriptor *is* the capability.
//! The portal is a trusted process with the user's whole filesystem; its
//! value is that it opens **only what the user picked**, so a sandboxed app
//! gains one capability per human decision.

use current_ipc::Msg;

/// What an app may ask for.
///
/// **The confused-deputy rule is enforced by this type** (PHASE7 §6.3):
/// there is no case and no field carrying "the path to open". A request can
/// suggest where the picker starts and what a new file might be called; it
/// cannot name the file that gets opened.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PortalRequest {
    OpenFile { start_dir: Option<String> },
    SaveFile { start_dir: Option<String>, suggested_name: Option<String> },
    /// A notification: a jailed app reaches the shell's toast only here.
    Notify { summary: String, body: Option<String>, timeout: Option<u64> },
    /// Capture the screen. **Carries nothing at all**: not what, not where,
    /// not what to call it; and the reply names no path either.
    Screenshot,
    Unknown(String),
}

impl PortalRequest {
    /// A control-plane message, parsed. Unknown methods are kept so the
    /// reply can name them.
    pub fn parse(msg: &Msg) -> PortalRequest {
        match msg.string("method").unwrap_or("") {
            "file.open" => PortalRequest::OpenFile { start_dir: sanitise(msg.string("dir")) },
            "file.save" => PortalRequest::SaveFile { start_dir: sanitise(msg.string("dir")), suggested_name: sanitise_name(msg.string("name")) },
            // An empty summary is not a notification: refused here.
            "notify" => match msg.string("summary").filter(|s| !s.is_empty()) {
                None => PortalRequest::Unknown("notify (no summary)".into()),
                Some(summary) => PortalRequest::Notify { summary: summary.into(), body: msg.string("body").map(str::to_owned), timeout: msg.u64("timeout") },
            },
            // Nothing is read out of the message, so nothing sent along survives.
            "screenshot" => PortalRequest::Screenshot,
            other => PortalRequest::Unknown(other.into()),
        }
    }
}

/// A start directory is an untrusted *hint*: only an absolute path is worth
/// passing on, since a relative one resolves against the portal's own.
pub(crate) fn sanitise(dir: Option<&str>) -> Option<String> {
    dir.filter(|d| d.starts_with('/') && !d.contains('\0')).map(str::to_owned)
}

/// A suggested name must be one path component: `../../.ssh/authorized_keys`
/// is a path, not a name.
pub(crate) fn sanitise_name(name: Option<&str>) -> Option<String> {
    name.filter(|n| !n.is_empty() && !n.contains('/') && !n.contains('\0') && *n != "." && *n != "..").map(str::to_owned)
}

/// The picker's exit codes, mirrored from FinderPicker so the portal links
/// no toolkit to know what 0 and 1 mean.
pub const PICKER_CHOSE: i32 = 0;
pub const PICKER_CANCELLED: i32 = 1;

/// What running the picker produced.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PickerOutcome {
    Chose(String),
    Cancelled,
    Failed(String),
}

impl PickerOutcome {
    /// The exit status *and* the result file, read together (§6.2): a crash
    /// and a decline both leave no result, and only the status tells them
    /// apart; exit 0 with nothing written is a broken picker, not a choice.
    pub fn from(status: i32, signalled: bool, result: Option<String>) -> PickerOutcome {
        if signalled {
            return PickerOutcome::Failed(format!("the picker was killed by signal {status}"));
        }
        match status {
            PICKER_CHOSE => result.map_or(PickerOutcome::Failed("the picker exited 0 but wrote no result".into()), PickerOutcome::Chose),
            PICKER_CANCELLED => PickerOutcome::Cancelled,
            s => PickerOutcome::Failed(format!("the picker exited {s}")),
        }
    }
}

/// What running the capture helper produced (P7.5): the same two signals.
/// A screenshot has no cancel; nobody was asked.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GrabOutcome {
    Captured { width: u32, height: u32 },
    Failed(String),
}

impl GrabOutcome {
    pub fn from(status: i32, signalled: bool, image: Option<PngSize>) -> GrabOutcome {
        if signalled {
            return GrabOutcome::Failed(format!("the capture helper was killed by signal {status}"));
        }
        if status != 0 {
            return GrabOutcome::Failed(format!("the capture helper exited {status}"));
        }
        // A capability is only as good as knowing what it is a capability to.
        match image {
            Some(i) => GrabOutcome::Captured { width: i.width, height: i.height },
            None => GrabOutcome::Failed("the capture helper exited 0 but wrote no readable PNG".into()),
        }
    }
}

/// A PNG's declared dimensions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PngSize {
    pub width: u32,
    pub height: u32,
}

pub const PNG_SIGNATURE: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Just enough PNG to answer "is this a PNG, and how big?": the signature,
/// then IHDR's length, its name, and width and height big-endian.
pub fn png_size(bytes: &[u8]) -> Option<PngSize> {
    if bytes.len() < 24 || bytes[..8] != PNG_SIGNATURE || &bytes[12..16] != b"IHDR" {
        return None;
    }
    let be32 = |at: usize| u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap());
    let (width, height) = (be32(16), be32(20));
    (width > 0 && height > 0).then_some(PngSize { width, height })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpenMode {
    /// file.open: O_RDONLY.
    Read,
    /// file.save: O_WRONLY|O_CREAT.
    Write,
}

/// The reply for a picker's outcome; the caller attaches the descriptor.
pub fn picker_reply(outcome: &PickerOutcome, mode: OpenMode) -> Msg {
    let mut reply = Msg::new();
    match outcome {
        PickerOutcome::Chose(path) => {
            reply.set_bool("ok", true);
            reply.set_string("path", path);
            reply.set_string("mode", if mode == OpenMode::Read { "r" } else { "w" });
        }
        PickerOutcome::Cancelled => {
            reply.set_bool("ok", false);
            reply.set_string("error", "cancelled");
        }
        PickerOutcome::Failed(why) => {
            reply.set_bool("ok", false);
            reply.set_string("error", why);
        }
    }
    reply
}

/// The reply for a capture. **No path**: a screenshot has no name the app
/// is entitled to, and its file is unlinked before the reply goes.
pub fn screenshot_reply(outcome: &GrabOutcome) -> Msg {
    let mut reply = Msg::new();
    match outcome {
        GrabOutcome::Captured { width, height } => {
            reply.set_bool("ok", true);
            reply.set_string("mode", "r");
            reply.set_u64("width", (*width).into());
            reply.set_u64("height", (*height).into());
        }
        GrabOutcome::Failed(why) => {
            reply.set_bool("ok", false);
            reply.set_string("error", why);
        }
    }
    reply
}
