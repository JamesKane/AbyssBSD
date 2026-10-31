//! Undertow in Rust (RUST.md R4): ADE's compositor, ported from the Swift
//! beside it. So far its pure core (R4a): the metronome and the flight
//! recorder, and the rules that decide where windows go. The wlroots half
//! comes over a grown `cwlroots` (RUST.md §6.4).

pub mod backend;
pub mod displays;
pub mod frame;
pub mod geometry;
pub mod idle;
pub mod keys;
pub mod metronome;
pub mod output;
pub mod places;
pub mod recorder;
pub mod shoals;
pub mod switch_latency;
pub mod synthetic;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod geometry_tests;
#[cfg(test)]
mod displays_tests;

pub use geometry::{clamp_cursor, ebb_arrange, hit, place_layer, snap_rect, snap_zone, EbbItem, EbbScope, IslandSlide, LayerAnchor, LayerRequest, Rect, SnapZone};
pub use metronome::{Conductor, Config, LatchMargin, Metronome, Plan, VblankPredictor};
pub use output::{display_hz, recorder_capacity, run_is_unbounded, Flip, FrameSink, FrameStats, Output};
pub use recorder::{FlightRecorder, FrameRecord};
pub use switch_latency::SwitchLatencies;
