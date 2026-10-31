//! linux-drm-syncobj-v1 (ExplicitSync.swift, BACKLOG U.3b).
//!
//! A GPU client's buffer is ready when the GPU says so, not when it is
//! committed. Explicit sync says it out loud: an ACQUIRE point (do not read
//! before this is signalled) and a RELEASE point (signal when done). Two
//! halves, as wlr_scene has them: the scene hands each texture's acquire
//! point to the renderer as a wait, and a commit bringing a new buffer arms
//! its release.
//!
//! Offered only where both halves can be kept: pixman keeps neither, so a
//! software run offers none and says so. Advertising it anyway would be
//! §2.58 again, a global with nothing behind it.

use crate::backend::log;
use crate::compositor::Compositor;
use abyss_sys::wlr::{globals, Compositor as WlrCompositor, Listener, Surface};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;

#[derive(Default)]
pub struct ExplicitSync {
    pub offered: bool,
    surfaces: RefCell<HashMap<Surface, Vec<Listener>>>,
    /// Release points armed, one per new buffer from a client using it: the
    /// test's positive control.
    pub releases_armed: Cell<u64>,
}

impl Compositor {
    pub(crate) fn offer_explicit_sync(&self, comp: WlrCompositor) -> Option<Listener> {
        if let Err(why) = globals::explicit_sync(self.session.display(), self.session.renderer(), self.session.backend()) {
            log(&format!("linux-drm-syncobj not offered — {why}"));
            return None;
        }
        log("linux-drm-syncobj offered — the scene waits on acquire points and arms release points");
        let w = self.me.clone();
        comp.on_new_surface_with(move |s| {
            if let Some(c) = w.upgrade() {
                c.track_sync(s)
            }
        })
    }

    fn track_sync(&self, s: Surface) {
        let (w1, w2) = (self.me.clone(), self.me.clone());
        let ls: Vec<Listener> = [
            s.on_commit(move || {
                if let Some(c) = w1.upgrade()
                    && s.arm_release()
                {
                    let r = &c.explicit_sync.borrow().releases_armed;
                    r.set(r.get() + 1);
                }
            }),
            s.on_destroy(move || {
                if let Some(c) = w2.upgrade() {
                    // Both listeners dropped from inside one (§2.82).
                    let gone = c.explicit_sync.borrow().surfaces.borrow_mut().remove(&s);
                    drop(gone);
                }
            }),
        ]
        .into_iter()
        .flatten()
        .collect();
        self.explicit_sync.borrow().surfaces.borrow_mut().insert(s, ls);
    }
}
