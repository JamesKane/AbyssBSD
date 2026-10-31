//! What every Aqua surface in a process shares: the fonts and draw-list
//! runner, and the theme, followed as the person changes it (P14.2).

use aquadraw::runner::Runner;
use aquadraw::theme::{announcement, role_announcements, Outcome, Theme};
use std::cell::RefCell;
use std::os::fd::AsRawFd;
use std::rc::Rc;
use surface::Display;

pub struct Toolkit {
    pub runner: RefCell<Runner>,
    pub theme: RefCell<Theme>,
    config_dir: Option<String>,
    watch: RefCell<Option<pool_config::Watcher>>,
}

/// Say which theme loaded, or that it fell back, and each font role.
pub fn announce(o: &Outcome) {
    eprintln!("{}", announcement(o));
    if let Outcome::Loaded(t, _) = o {
        for l in role_announcements(&t.tokens) {
            eprintln!("{l}")
        }
    }
}

impl Toolkit {
    /// The fonts at `scale`, and the chosen theme, announced. None without
    /// fonts.
    pub fn new(scale: i32, config_dir: Option<String>) -> Option<Rc<Toolkit>> {
        let mut runner = aquadraw::scene::runner(scale)?;
        let mut theme = Theme::default();
        announce(&theme.load_current(config_dir.as_deref(), Some(&mut runner)));
        Some(Rc::new(Toolkit { runner: RefCell::new(runner), theme: RefCell::new(theme), config_dir, watch: RefCell::new(None) }))
    }

    /// **Follow the theme a person chooses while this runs** (P14.2): one
    /// watch on the config directory, in the display's loop; a change to
    /// appearance.ini reloads, says so, and every surface draws again.
    pub fn follow_appearance(self: &Rc<Toolkit>, display: &Rc<Display>) {
        let Ok(w) = pool_config::Watcher::new(self.config_dir.as_deref()) else { return };
        let fd = w.as_raw_fd();
        *self.watch.borrow_mut() = Some(w);
        let (me, d) = (Rc::downgrade(self), Rc::downgrade(display));
        display.add_fd(fd, move || {
            let (Some(tk), Some(d)) = (me.upgrade(), d.upgrade()) else { return };
            if let Some(w) = &*tk.watch.borrow() {
                w.drain();
            }
            let outcome = tk.theme.borrow_mut().reload_if_changed(tk.config_dir.as_deref(), Some(&mut tk.runner.borrow_mut()));
            if let Some(o) = outcome {
                announce(&o);
                d.set_everything_needs_display()
            }
        });
    }
}
