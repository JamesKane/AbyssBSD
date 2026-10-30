//! Portal in Rust (RUST.md R3): the brokerless answer to
//! xdg-desktop-portal (PHASE7 P7.2), ported from Portal.swift and
//! Service.swift beside it. No D-Bus, no broker, no flatpak: an app asks,
//! the person chooses in the Finder, and the app gets one descriptor.

mod request;
mod service;

pub use request::{png_size, picker_reply, screenshot_reply, GrabOutcome, OpenMode, PickerOutcome, PngSize, PortalRequest, PICKER_CANCELLED, PICKER_CHOSE, PNG_SIGNATURE};
pub use service::{choose_binary, read_picker_result, sibling_binary, PortalService};

#[cfg(test)]
mod tests;
