//! The desktop's portal on D-Bus in Rust (RUST.md R3; PHASE8 P8.2, P8.3),
//! ported from Portal.swift, Settings.swift and Service.swift beside it:
//! the FileChooser's rules and the Settings table, both pure, and the
//! service that answers them over a connection to ADE's bridge.

pub mod portal;
pub mod service;
pub mod settings;

pub use portal::{chooser_response, chooser_results, file_uri, file_uri_path, portal_call_message, request_path, sender_element, ChooserKind, ChooserOptions, PortalResponse};
pub use service::{next_component, Grant, PortalService, BUS_NAME, OBJECT_PATH};
pub use settings::PortalSettings;

#[cfg(test)]
mod tests;
