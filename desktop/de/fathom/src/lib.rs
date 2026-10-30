//! Fathom in Rust (RUST.md R2): what this machine is, as a value (PHASE12
//! P12.1), ported from Probe.swift and Report.swift beside it.
//!
//! **Everything here is a pure function over captured text.** Nothing runs a
//! command, opens a device or reads a sysctl: a caller gathers, these
//! interpret. So every probe is tested on a machine that has none of the
//! hardware, which is most of them.
//!
//! **And a probe with no positive control measures nothing** (§2.37): every
//! parser is written against the build VM's *absent* case first.

mod probe;
mod report;

pub use probe::{
    needs_pcie_hotplug_disabled, probe_audio, probe_battery, probe_boot_method, probe_cpu, probe_gpu, probe_machine, probe_memory,
    probe_modules, probe_network, probe_wifi, ProbeResult, ProbeStatus,
};
pub use report::{ascii_only, probe_disks, probe_frame_contract, render_text, report_filename, Counts, DiskFact, FathomReport};

#[cfg(test)]
mod tests;
