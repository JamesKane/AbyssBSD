//! GTK's menus as ADE's vocabulary in Rust (RUST.md R3; PHASE10 P10.6,
//! P10.9), ported from GtkMenus.swift and Bridge.swift beside it: the
//! translation, which is pure, and the bridge that serves it to the bar.

mod bridge;
pub mod gtkmenus;

pub use bridge::{app_name, service_name_for_jail_class, GtkMenuBridge, SERVICE_NAME};

#[cfg(test)]
mod tests;
