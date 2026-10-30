//! Jails in Rust (RUST.md R2): what a jail contains, as data, and the plan a
//! root daemon performs (PHASE18 P18.1), ported from JailClass.swift and
//! JailPlan.swift beside it. Pure, so tested on Linux, where there are no
//! jails; `jaild`, which performs a plan, is R3.

mod class;
mod plan;

pub use class::{known_devices, JailClass, Network, APPS_SECTION, BASE_SYSTEM, DEFAULT_BUDGET};
pub use plan::{under, JailDir, JailLayout, JailMount, JailPlan, JailUser, MountKind};

#[cfg(test)]
mod tests;
