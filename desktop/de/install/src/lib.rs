//! Install in Rust (RUST.md R2): the install as a value (PHASE5 P5.1),
//! ported from the Swift beside it.
//!
//! `SessionPlan`'s pattern pointed at a disk: an install is a **plan**, the
//! machine it runs on is an **inventory** gathered by somebody privileged,
//! the **refusals** are a function of the two, and a plan that passes them
//! compiles to the **steps** `abyss-install` runs without deciding anything.
//! Nothing here touches a disk, so every refusal is tested on Linux, where
//! `gpart` does not exist.

mod inventory;
pub mod keymaps;
mod plan;
mod safety;
mod steps;

pub use inventory::{Disk, DiskInventory, MachineIdentity};
pub use keymaps::Keymap;
pub use plan::{Account, Dataset, InstallPlan, BOOT_ENVIRONMENT_DATASETS, STANDARD_DATASETS};
pub use safety::{check, names_a_partition, problems, PlanRefusal};
pub use steps::{compile, fstab, loader_conf, rc_conf, render, Action, Step, POOL_CACHE_PATH};

#[cfg(test)]
mod tests;
