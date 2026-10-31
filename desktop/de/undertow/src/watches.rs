//! What the compositor follows while it runs: appearance.ini (P14.2: the
//! theme, which every frame is drawn in) and islands.ini (P13.7). A person
//! may change either with the pane or an editor, and nobody tells anybody:
//! the config directory is watched.

use crate::backend::log;
use crate::compositor::{frame_metrics, Compositor};
use aquadraw::theme::{announcement, role_announcements, Outcome};
use std::os::unix::io::AsRawFd;

/// The theme, said: a silent fallback is invisible to every test (§2.45).
pub fn announce_theme(o: &Outcome) {
    eprintln!("{}", announcement(o));
    if let Outcome::Loaded(t, _) = o {
        for l in role_announcements(&t.tokens) {
            eprintln!("{l}")
        }
    }
}

impl Compositor {
    /// Follow appearance.ini: a new theme bumps the generation, so the next
    /// frame redraws every window's frame in it.
    pub fn watch_appearance(&self) {
        if self.appearance_watch.borrow().is_some() {
            return;
        }
        let Ok(w) = pool_config::Watcher::new(self.config_dir.as_deref()) else { return };
        let me = self.me.clone();
        let Some(src) = self.session.event_loop().add_fd(w.as_raw_fd(), move || {
            let Some(c) = me.upgrade() else { return };
            if let Some((w, _)) = &*c.appearance_watch.borrow() {
                w.drain();
            }
            let outcome = {
                let mut runner = c.runner.borrow_mut();
                c.theme.borrow_mut().reload_if_changed(c.config_dir.as_deref(), runner.as_mut())
            };
            let Some(o) = outcome else { return };
            c.metrics.set(frame_metrics(&c.theme.borrow()));
            c.theme_reloads.set(c.theme_reloads.get() + 1);
            log(&format!("theme changed (#{})", c.theme_reloads.get()));
            announce_theme(&o);
        }) else {
            return;
        };
        *self.appearance_watch.borrow_mut() = Some((w, src));
    }

    /// Follow islands.ini, which the Islands pane writes and never says.
    pub fn watch_islands(&self) {
        if self.islands_watch.borrow().is_some() {
            return;
        }
        let Ok(w) = pool_config::Watcher::new(self.config_dir.as_deref()) else { return };
        let me = self.me.clone();
        let Some(src) = self.session.event_loop().add_fd(w.as_raw_fd(), move || {
            let Some(c) = me.upgrade() else { return };
            if let Some((w, _)) = &*c.islands_watch.borrow() {
                w.drain();
            }
            c.reload_islands();
        }) else {
            return;
        };
        *self.islands_watch.borrow_mut() = Some((w, src));
    }
}
