//! Anchor in Rust (RUST.md R3): the session supervisor's library, ported
//! from Policy.swift, Session.swift and Supervisor.swift beside it. The
//! decisions (the restart policy, the session as a plan) are pure and
//! tested without spawning; the supervisor is one poll loop over process
//! descriptors, proved live by `abyss/tests/live-anchor.sh`.

mod policy;
mod session;
mod supervisor;

pub use policy::{current_environment, environment_block, monotonic_seconds, split_command, ComponentSpec, Decision, RestartPolicy};
pub use session::{
    bridge_services_address, cursor_environment, default_session, session_bus_address, unix_socket_path, SessionInputs, SessionMode, SessionPlan,
    SESSION_CURSOR_THEME,
};
pub use supervisor::{ControlSocket, Supervisor};

#[cfg(test)]
mod tests;
