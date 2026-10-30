//! sysctl, kenv, the OSS mixer and the battery (Hardware.swift).

use abyss_sys::vents as sys;
use std::os::fd::{AsFd, OwnedFd};

/// The kernel environment: **a different namespace from sysctl**, and the
/// only place the machine says what it is (`smbios.system.*`).
pub mod kenv {
    use super::sys;

    /// Whether this platform has one at all (false on Linux).
    pub fn is_supported() -> bool {
        sys::sysctl_supported()
    }

    /// A variable, or None if it is not set.
    pub fn string(name: &str) -> Option<String> {
        sys::kenv_read(name)
    }

    /// What this machine calls itself: maker and product, trimmed, the
    /// quotes `kenv` reports stripped; None when either is missing, since
    /// half an identity is none.
    pub fn machine() -> Option<(String, String)> {
        let mk = unquote(&string("smbios.system.maker")?);
        let pr = unquote(&string("smbios.system.product")?);
        (!mk.is_empty() && !pr.is_empty()).then_some((mk, pr))
    }

    /// `kenv` renders values in quotes; the value does not hold them.
    pub fn unquote(s: &str) -> String {
        let v = s.trim_matches(' ');
        let v = if v.len() >= 2 && v.starts_with('"') && v.ends_with('"') { &v[1..v.len() - 1] } else { v };
        v.to_owned()
    }
}

pub mod sysctl {
    use super::sys;

    /// Whether this platform answers sysctl at all (false on Linux).
    pub fn is_supported() -> bool {
        sys::sysctl_supported()
    }

    /// A sysctl's bytes, or None if it doesn't exist.
    pub fn raw(name: &str) -> Option<Vec<u8>> {
        sys::sysctl_read(name)
    }

    /// A string sysctl (`kern.ostype`), without its trailing NUL.
    pub fn string(name: &str) -> Option<String> {
        let mut b = raw(name)?;
        if b.last() == Some(&0) {
            b.pop();
        }
        Some(String::from_utf8_lossy(&b).into_owned())
    }

    /// An integer sysctl: 4 or 8 native-endian bytes.
    pub fn int(name: &str) -> Option<i64> {
        int_of(&raw(name)?)
    }

    pub(crate) fn int_of(b: &[u8]) -> Option<i64> {
        match b.len() {
            4 => Some(i32::from_ne_bytes(b.try_into().ok()?) as i64),
            8 => Some(i64::from_ne_bytes(b.try_into().ok()?)),
            // Present but not a number: not ours to guess.
            _ => None,
        }
    }

    /// A best-effort readable value, for a caller that doesn't know the type.
    pub fn display(name: &str) -> Option<String> {
        Some(display_of(&raw(name)?))
    }

    /// **Printable bytes win over the integer reading**: a sysctl is
    /// untyped, and `kern.ostype` is `"FreeBSD\0"`, exactly eight bytes,
    /// which reads as a perfectly plausible Int64.
    pub fn display_of(bytes: &[u8]) -> String {
        let body = bytes.strip_suffix(&[0]).unwrap_or(bytes);
        let printable = body.iter().all(|&b| b == b'\t' || b == b'\n' || (0x20..0x7f).contains(&b));
        if !body.is_empty() && printable {
            return String::from_utf8_lossy(body).trim_end_matches(['\n', ' ']).to_owned();
        }
        match int_of(bytes) {
            Some(n) => n.to_string(),
            None => format!("<{} bytes>", bytes.len()),
        }
    }
}

/// OSS packs a stereo level into one int: low byte left, next byte right,
/// each 0...100.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VolumeLevel {
    pub left: u8,
    pub right: u8,
}

impl VolumeLevel {
    /// Clamped: an out-of-range level must not wrap into the other channel.
    pub fn new(left: u8, right: u8) -> VolumeLevel {
        VolumeLevel { left: left.min(100), right: right.min(100) }
    }

    pub fn both(v: u8) -> VolumeLevel {
        VolumeLevel::new(v, v)
    }

    /// Only the low two bytes are the master level.
    pub fn from_encoded(encoded: i32) -> VolumeLevel {
        VolumeLevel::new((encoded & 0xff) as u8, ((encoded >> 8) & 0xff) as u8)
    }

    pub fn encoded(self) -> i32 {
        self.left as i32 | (self.right as i32) << 8
    }

    /// One number for a UI that shows a single bar.
    pub fn mono(self) -> u8 {
        self.left
    }
}

/// An open OSS mixer device.
pub struct Mixer(OwnedFd);

impl Mixer {
    /// Open `path`, or `/dev/mixer` then `/dev/mixer0`; the error when there
    /// is none, which is the normal answer without a sound card, and always
    /// on Linux.
    pub fn open(path: Option<&str>) -> std::io::Result<Mixer> {
        sys::mixer_open(path).map(Mixer)
    }

    pub fn level(&self) -> Option<VolumeLevel> {
        sys::mixer_get_volume(self.0.as_fd()).map(VolumeLevel::from_encoded)
    }

    /// Set the level; what the kernel applied, which a card need not match.
    pub fn set_level(&self, want: VolumeLevel) -> Option<VolumeLevel> {
        sys::mixer_set_volume(self.0.as_fd(), want.encoded()).map(VolumeLevel::from_encoded)
    }
}

/// The battery, through ACPI's sysctls.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Battery {
    /// 0...100; None while the kernel says -1, which it does until it knows.
    pub percent: Option<i64>,
    pub minutes_remaining: Option<i64>,
    /// `hw.acpi.battery.state` bit 1 is discharging.
    pub is_charging: bool,
}

impl Battery {
    /// None on a machine with none: a desktop, or a VM. The item is then
    /// absent, which is honest.
    pub fn read() -> Option<Battery> {
        let life = sysctl::int("hw.acpi.battery.life")?;
        let time = sysctl::int("hw.acpi.battery.time");
        let state = sysctl::int("hw.acpi.battery.state").unwrap_or(0);
        Some(Battery { percent: (life >= 0).then_some(life), minutes_remaining: time.filter(|&t| t >= 0), is_charging: state & 0x2 == 0 })
    }

    /// What the menu bar shows: "84%", or "—" before the kernel knows.
    pub fn label(&self) -> String {
        self.percent.map_or("—".into(), |p| format!("{p}%"))
    }
}
