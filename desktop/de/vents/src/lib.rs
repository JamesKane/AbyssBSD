//! Vents in Rust (RUST.md R3): the machine read through FreeBSD's own
//! facilities (sysctl not sysfs, OSS not ALSA, devd not udev), ported from
//! the Swift beside it.
//!
//! The rule throughout: **when a facility isn't there, say so, don't invent
//! a reading.** A desktop with no sound card hides its volume item rather
//! than showing a confident 0%, so every accessor is optional, and the
//! menu bar decides what to draw from what answered. Every parser is a pure
//! function of captured text, tested on any machine.

pub mod devd;
pub mod hardware;
pub mod network;
pub mod processes;
pub mod sound;
pub mod wifi;

pub use devd::{Devd, Event, EventKind};
pub use hardware::{kenv, sysctl, Battery, Mixer, VolumeLevel};
pub use processes::{ProcessTable, Row};

/// std's io::Error words, without its " (os error N)": strerror's.
pub(crate) fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}
