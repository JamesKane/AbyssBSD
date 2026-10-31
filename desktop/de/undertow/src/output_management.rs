//! wlr-output-management-v1, server side (OutputManagement.swift, PHASE14
//! P14.7b): what the Displays pane speaks, and wlr-randr and kanshi. A
//! client reads every output's modes, position and scale, and asks for a new
//! arrangement to be tested or applied.
//!
//! **Whole or not at all.** A configuration is checked (`problems`), then
//! every output's new state test-committed, and only when all pass is
//! anything committed. What was applied is written to displays.ini, which
//! undertow applies at start: the file is always what is on screen.

use crate::backend::log;
use crate::compositor::Compositor;
use crate::displays::{format_setting, problems, store_settings, DisplayLayout, DisplaySetting};
use abyss_sys::wlr::{self, globals, Listener, OutputConfig, OutputManager, OutputState};
use std::cell::Cell;

/// After a configuration is applied, with the new layout: the run loop
/// re-aims each output's scene and, for a new refresh rate, its metronome.
pub type AppliedHook = Box<dyn Fn(&DisplayLayout)>;

pub struct OutputManagement {
    manager: OutputManager,
    _listeners: Vec<Listener>,
    pub applied_count: Cell<u64>,
    pub refused_count: Cell<u64>,
}

impl Compositor {
    pub(crate) fn offer_output_management(&self) -> Option<OutputManagement> {
        let manager = globals::output_manager(self.session.display())?;
        let (w1, w2) = (self.me.clone(), self.me.clone());
        let listeners = [
            manager.on_apply(move |cfg| {
                if let Some(c) = w1.upgrade() {
                    c.handle_output_config(cfg, true)
                }
            }),
            manager.on_test(move |cfg| {
                if let Some(c) = w2.upgrade() {
                    c.handle_output_config(cfg, false)
                }
            }),
        ]
        .into_iter()
        .flatten()
        .collect();
        Some(OutputManagement { manager, _listeners: listeners, applied_count: Cell::new(0), refused_count: Cell::new(0) })
    }

    /// Tell every client what is true now: wlroots fills each head from its
    /// output; the position and scale are ours.
    pub fn publish_outputs(&self) {
        let om = self.output_management.borrow();
        let Some(om) = om.as_ref() else { return };
        let heads: Vec<(wlr::Output, i32, i32, f64)> = self.layout.borrow().displays.iter().filter_map(|d| self.session.output_named(&d.name).map(|o| (o, d.x, d.y, d.scale))).collect();
        om.manager.publish(&heads);
    }

    /// Who hears that a configuration was applied: the run loop.
    pub fn on_outputs_applied(&self, f: impl Fn(&DisplayLayout) + 'static) {
        *self.outputs_applied.borrow_mut() = Some(Box::new(f));
    }

    fn handle_output_config(&self, cfg: OutputConfig, apply: bool) {
        self.answer_output_config(cfg, apply);
        cfg.destroy();
    }

    fn answer_output_config(&self, cfg: OutputConfig, apply: bool) {
        let verb = if apply { "apply" } else { "test" };
        let refuse = |why: &str| {
            if let Some(om) = self.output_management.borrow().as_ref() {
                om.refused_count.set(om.refused_count.get() + 1)
            }
            log(&format!("output-config {verb} refused: {why}"));
            cfg.send_failed();
        };
        let heads = cfg.heads();
        let settings: Vec<DisplaySetting> = heads
            .iter()
            .filter_map(|h| {
                let a = h.ask();
                let o = a.output()?;
                Some(DisplaySetting { name: o.name(), enabled: a.enabled, mode_width: a.mode_width, mode_height: a.mode_height, refresh_milli_hz: a.refresh_mhz, x: a.x, y: a.y, scale: a.scale })
            })
            .collect();
        let mut why = problems(&settings);
        // A display the configuration leaves out is one it turns off.
        for d in &self.layout.borrow().displays {
            if !settings.iter().any(|s| s.name == d.name) {
                why.push(format!("{} is not in the configuration (turning a display off is not supported yet)", d.name));
            }
        }
        if !why.is_empty() {
            return refuse(&why.join("; "));
        }
        // Every output's new state passes a test commit before any is made.
        for h in &heads {
            if !h.try_state(false) {
                return refuse(&format!("{} refused that mode or scale", h.ask().output().map(|o| o.name()).unwrap_or_default()));
            }
        }
        if !apply {
            log(&format!("output-config test ok: {}", settings.iter().map(format_setting).collect::<Vec<_>>().join("; ")));
            return cfg.send_succeeded();
        }
        for h in &heads {
            // Tested a moment ago: a failure now is the backend's, and the
            // outputs already committed stay as they are, said, not hidden.
            if !h.try_state(true) {
                return refuse(&format!("{} failed to commit after its test passed", h.ask().output().map(|o| o.name()).unwrap_or_default()));
            }
        }
        // In the order it had: the main display stays the main one.
        let order: Vec<String> = self.layout.borrow().displays.iter().map(|d| d.name.clone()).collect();
        let boxes = order.iter().filter_map(|n| settings.iter().find(|s| s.name == *n).map(DisplaySetting::display_box)).collect();
        self.apply_layout(DisplayLayout { displays: boxes });
        if let Err(e) = store_settings(&settings, self.config_dir.as_deref()) {
            log(&format!("output-config: applied, but displays.ini could not be written: {e}"));
        }
        if let Some(om) = self.output_management.borrow().as_ref() {
            om.applied_count.set(om.applied_count.get() + 1)
        }
        log(&format!("output-config applied: {}", self.layout.borrow().summary()));
        if let Some(f) = &*self.outputs_applied.borrow() {
            f(&self.layout.borrow());
        }
        cfg.send_succeeded();
        self.publish_outputs();
    }
}

/// Put a saved setting on an output before the run starts (displays.ini).
/// A headless or nested output takes any mode; a real one is asked for a
/// custom mode, which DRM turns into a CVT timing.
pub fn commit_setting(s: &DisplaySetting, o: wlr::Output) -> bool {
    let mut st = OutputState::new();
    st.set_enabled(true);
    if s.mode_width != o.width() || s.mode_height != o.height() || (s.refresh_milli_hz != 0 && s.refresh_milli_hz != o.refresh()) {
        st.set_custom_mode(s.mode_width, s.mode_height, s.refresh_milli_hz);
    }
    st.set_scale(s.scale);
    o.commit(&st)
}
