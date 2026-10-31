//! ext-idle-notify-v1, the client side (IdleNotify.swift, P16.3): told when
//! nobody has touched the seat for a while, and when somebody does again.
//! v1's notification honours inhibitors (a video playing), so the session's
//! policy and the displays' sleep share one idea of idle (HANDOFF §2.86).

use crate::display::Display;
use abyss_sys::wlc::{ext_idle_notification_v1 as note, ext_idle_notifier_v1, Obj};
use std::rc::Rc;

pub struct IdleNotification {
    display: Rc<Display>,
    notification: Obj,
    pub timeout_ms: u32,
}

impl IdleNotification {
    /// None without the notifier or a seat.
    pub fn new(display: &Rc<Display>, timeout_ms: u32, on_idle: impl Fn() + 'static, on_resume: impl Fn() + 'static) -> Option<IdleNotification> {
        let (n, seat) = {
            let g = display.globals.borrow();
            (g.idle_notifier?, g.seat?)
        };
        let notification = ext_idle_notifier_v1::get_idle_notification(n, timeout_ms, seat)?;
        note::listen(notification, move |e| match e {
            note::Event::Idled {} => on_idle(),
            note::Event::Resumed {} => on_resume(),
        });
        display.flush();
        Some(IdleNotification { display: display.clone(), notification, timeout_ms })
    }
}

impl Drop for IdleNotification {
    fn drop(&mut self) {
        note::destroy(self.notification);
        self.display.flush()
    }
}
