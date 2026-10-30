//! The sound devices, their controls, and who is playing, without
//! privilege (Sound.swift, PHASE14 P14.6): /dev/sndstat's nvlist for the
//! devices and channels, libmixer for the controls, `hw.snd.default_unit`
//! for which device `/dev/dsp` means. On Linux there is no OSS, and every
//! read says no devices rather than reaching for ALSA.

use crate::hardware::sysctl;
use abyss_sys::vents as sys;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Channel {
    /// `dsp0.virtual_play.1`
    pub name: String,
    /// Who has it open, or None when nobody does.
    pub pid: Option<i32>,
    pub command: String,
    pub left: i64,
    pub right: i64,
}

impl Channel {
    pub fn is_playback(&self) -> bool {
        self.name.contains("play")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Device {
    pub unit: i64,
    /// `pcm0`
    pub name: String,
    pub description: String,
    pub devnode: String,
    pub playback: bool,
    pub recording: bool,
    /// A device a user-space server (virtual_oss) added.
    pub from_user: bool,
    pub channels: Vec<Channel>,
}

impl Device {
    /// Channels someone has open for playback: the applications playing,
    /// with the volume each set for itself.
    pub fn playing(&self) -> Vec<&Channel> {
        self.channels.iter().filter(|c| c.pid.is_some() && c.is_playback()).collect()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Control {
    /// `vol`, `pcm`, `rec` …
    pub name: String,
    pub left: i64,
    pub right: i64,
    pub muted: bool,
    pub recordable: bool,
}

impl Control {
    /// One number for a slider: the louder side.
    pub fn level(&self) -> i64 {
        self.left.max(self.right)
    }
}

/// Every device, in the kernel's order; empty where there are none.
pub fn devices() -> Vec<Device> {
    parse_sndstat(&sys::sndstat_read().unwrap_or_default())
}

/// The unit `/dev/dsp` means, or None.
pub fn default_unit() -> Option<i64> {
    sysctl::int("hw.snd.default_unit")
}

/// A device's controls; empty when it has no mixer.
pub fn controls(unit: i64) -> Vec<Control> {
    parse_controls(&i32::try_from(unit).ok().and_then(sys::mixer_describe).unwrap_or_default())
}

/// Set a control's level, both sides: None, or why not in errno's words.
pub fn set(unit: i64, control: &str, left: i64, right: i64) -> Option<String> {
    let (Ok(u), Ok(l), Ok(r)) = (i32::try_from(unit), i32::try_from(left), i32::try_from(right)) else { return Some("Invalid argument".into()) };
    sys::mixer_set(u, control, l, r).err().map(|e| crate::words(&e))
}

pub fn set_muted(unit: i64, control: &str, muted: bool) -> Option<String> {
    let Ok(u) = i32::try_from(unit) else { return Some("Invalid argument".into()) };
    sys::mixer_mute(u, control, muted).err().map(|e| crate::words(&e))
}

// MARK: parsers (pure)

/// cvents' flattening of sndstat: `dev` lines, each with its `chan` lines.
/// A device with no sound(4) unit (a user-space one) is not a pcm.
pub fn parse_sndstat(text: &str) -> Vec<Device> {
    let mut devices: Vec<(Vec<&str>, Vec<Channel>)> = vec![];
    let mut by_unit: Vec<(i64, usize)> = vec![];
    for line in text.split('\n').filter(|l| !l.is_empty()) {
        let f: Vec<&str> = line.split('\t').collect();
        if f[0] == "dev" && f.len() >= 8 {
            if let Ok(u) = f[1].parse::<i64>() {
                by_unit.retain(|(x, _)| *x != u);
                by_unit.push((u, devices.len()));
            }
            devices.push((f, vec![]));
        } else if f[0] == "chan"
            && f.len() >= 7
            && let Ok(u) = f[1].parse::<i64>()
            && let Some(&(_, i)) = by_unit.iter().find(|(x, _)| *x == u)
        {
            let pid = f[3].parse::<i32>().unwrap_or(-1);
            devices[i].1.push(Channel {
                name: f[2].to_owned(),
                pid: (pid >= 0).then_some(pid),
                command: if pid < 0 { String::new() } else { f[4].to_owned() },
                left: f[5].parse().unwrap_or(0),
                right: f[6].parse().unwrap_or(0),
            });
        }
    }
    devices
        .into_iter()
        .filter_map(|(f, channels)| {
            let unit = f[1].parse::<i64>().ok().filter(|&u| u >= 0)?;
            Some(Device {
                unit,
                name: f[2].into(),
                description: f[3].into(),
                devnode: f[4].into(),
                playback: f[5] == "1",
                recording: f[6] == "1",
                from_user: f[7] == "1",
                channels,
            })
        })
        .collect()
}

/// cvents' `ctl` lines: name, left, right, muted, recordable.
pub fn parse_controls(text: &str) -> Vec<Control> {
    text.split('\n')
        .filter_map(|line| {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() < 6 || f[0] != "ctl" {
                return None;
            }
            Some(Control { name: f[1].into(), left: f[2].parse().ok()?, right: f[3].parse().ok()?, muted: f[4] == "1", recordable: f[5] == "1" })
        })
        .collect()
}
