//! The clipboard and drag and drop, client side (Clipboard.swift, P9.1,
//! P9.3), over core wayland's data device.
//!
//! The transfer is a pipe, and that is the part worth reading twice: a
//! selection is not data the compositor holds, it is a *promise by the
//! source client* to write bytes into a descriptor when somebody asks. A
//! paste is "make a pipe, hand the owner one end, read the other"; if the
//! owner has exited, the read just ends.

use crate::display::Display;
use abyss_sys::wlc::{wl_data_device as device, wl_data_device_manager as manager, wl_data_offer as offer, wl_data_source as source, Obj};
use std::cell::{Cell, RefCell};
use std::io::{Read, Write};
use std::rc::{Rc, Weak};

/// What a selection is offered as: a URI list, which another file manager
/// understands, and plain text, which everything else does.
pub mod mime {
    pub const TEXT: &str = "text/plain;charset=utf-8";
    pub const URI_LIST: &str = "text/uri-list";
    /// What we advertise, in preference order.
    pub const OFFERED: [&str; 2] = [URI_LIST, TEXT];
}

const COPY: u32 = 1;

type DropHook = Rc<dyn Fn(&str, &[u8], f64, f64)>;
type MotionHook = Rc<dyn Fn(f64, f64)>;
type LeaveHook = Rc<dyn Fn()>;
/// A source of ours and the bytes it answers with.
type Source = RefCell<Option<(Obj, Rc<Vec<u8>>)>>;

#[derive(Default)]
struct Drag {
    /// The offer the pointer carries over one of our surfaces, and its types.
    offer: Option<Obj>,
    types: Vec<String>,
    x: f64,
    y: f64,
    /// **Which of our surfaces it is over**: a drag is a grab, so pointer
    /// events stop for it; only `enter` names the surface.
    surface: Option<Obj>,
}

pub struct Clipboard {
    display: Weak<Display>,
    manager: Obj,
    device: Obj,
    /// The selection's offer, and the types it advertised.
    current: Cell<Option<Obj>>,
    offered: RefCell<Vec<String>>,
    /// Types of the newest offer, before `selection` or `enter` claims it.
    pending: RefCell<Vec<String>>,
    /// What we put on the clipboard, kept to answer `send`.
    owned: Source,
    /// A drag we started: apart from the clipboard's, since dragging must not
    /// replace what somebody copied.
    dragging: Source,
    drag: RefCell<Drag>,
    /// What this application will take from a drop; empty is nothing, and
    /// the cursor says so rather than a drop that does nothing.
    pub accepted_drag_types: RefCell<Vec<String>>,
    on_drop: RefCell<Option<DropHook>>,
    on_drag_motion: RefCell<Option<MotionHook>>,
    on_drag_leave: RefCell<Option<LeaveHook>>,
}

/// Write `bytes` to a source's descriptor, then close it: **closing is the
/// end of the message**; a reader waits for EOF.
fn send(fd: std::os::fd::OwnedFd, bytes: &[u8]) {
    let _ = std::fs::File::from(fd).write_all(bytes);
}

impl Clipboard {
    pub(crate) fn new(display: &Rc<Display>, manager: Obj, seat: Obj) -> Option<Rc<Clipboard>> {
        let d = manager::get_data_device(manager, seat)?;
        let c = Rc::new(Clipboard {
            display: Rc::downgrade(display),
            manager,
            device: d,
            current: Cell::new(None),
            offered: RefCell::default(),
            pending: RefCell::default(),
            owned: RefCell::new(None),
            dragging: RefCell::new(None),
            drag: RefCell::default(),
            accepted_drag_types: RefCell::default(),
            on_drop: RefCell::new(None),
            on_drag_motion: RefCell::new(None),
            on_drag_leave: RefCell::new(None),
        });
        let me = Rc::downgrade(&c);
        device::listen(d, move |e| {
            if let Some(c) = me.upgrade() {
                c.device_event(e)
            }
        });
        Some(c)
    }

    fn flush(&self) {
        if let Some(d) = self.display.upgrade() {
            d.flush()
        }
    }

    fn device_event(self: &Rc<Self>, e: device::Event) {
        use device::Event::*;
        match e {
            // A new offer: its types arrive next, on the offer itself.
            DataOffer { id: Some(o) } => {
                self.offered.borrow_mut().clear();
                self.pending.borrow_mut().clear();
                let me = Rc::downgrade(self);
                offer::listen(o, move |e| {
                    // One offer may become the selection or a drag; which is
                    // `selection`'s or `enter`'s to say, so record both.
                    if let (Some(c), offer::Event::Offer { mime_type }) = (me.upgrade(), e) {
                        c.offered.borrow_mut().push(mime_type.clone());
                        c.pending.borrow_mut().push(mime_type)
                    }
                });
            }
            // None is an empty clipboard: a state, not an error.
            Selection { id } => {
                if let Some(old) = self.current.get()
                    && Some(old) != id
                {
                    offer::destroy(old)
                }
                self.current.set(id);
                if id.is_none() {
                    self.offered.borrow_mut().clear()
                }
            }
            Enter { serial, surface, x, y, id } => {
                {
                    let mut d = self.drag.borrow_mut();
                    *d = Drag { offer: id, types: self.pending.borrow().clone(), x, y, surface };
                }
                self.motion(x, y);
                let Some(o) = id else { return };
                // **Accepting is what makes the source's cursor say yes**: on
                // enter, not on drop.
                let accepted = self.accepted_drag_types.borrow();
                let m = self.drag.borrow().types.iter().find(|t| accepted.contains(t)).cloned();
                offer::accept(o, serial, m.as_deref());
                // Copy, always: a move is the Finder's own cut, not the protocol's.
                offer::set_actions(o, COPY, COPY);
            }
            Motion { x, y, .. } => {
                {
                    let mut d = self.drag.borrow_mut();
                    (d.x, d.y) = (x, y);
                }
                self.motion(x, y)
            }
            Leave {} => self.release_drag(),
            Drop {} => self.complete_drop(),
            _ => {}
        }
    }

    fn motion(&self, x: f64, y: f64) {
        let f = self.on_drag_motion.borrow().clone();
        if let Some(f) = f {
            f(x, y)
        }
    }

    /// Whether the current selection is one we offered. **This is what stops
    /// a program deadlocking on its own clipboard**: reading it would ask this
    /// process, blocked on the read, for a `send` only its stopped event loop
    /// could deliver.
    pub fn owns_selection(&self) -> bool {
        self.owned.borrow().is_some()
    }

    /// Whether the clipboard holds one of `types`, without reading it: for a
    /// menu deciding whether Paste is enabled (P10.1).
    pub fn offers(&self, types: &[&str]) -> bool {
        self.owns_selection() || (self.current.get().is_some() && types.iter().any(|t| self.offered.borrow().iter().any(|o| o == t)))
    }

    /// Ask `o` for `mime`, and read it to the end. **Flush before reading,
    /// and drop our write end**: without the flush the source never hears
    /// the ask, without the drop the read never sees EOF.
    fn receive(&self, o: Obj, mime: &str) -> Option<Vec<u8>> {
        let (mut r, w) = std::io::pipe().ok()?;
        offer::receive(o, mime, std::os::fd::AsFd::as_fd(&w));
        self.flush();
        drop(w);
        let mut out = Vec::new();
        let _ = r.read_to_end(&mut out);
        Some(out)
    }

    /// What the clipboard holds, as the first of `types` it offers (else its
    /// first type). **Blocking, deliberately**: a menu command wants the
    /// bytes. None for our own selection: the caller already has those.
    pub fn read(&self, types: &[&str]) -> Option<(String, Vec<u8>)> {
        if self.owns_selection() {
            return None;
        }
        let o = self.current.get()?;
        let m = {
            let offered = self.offered.borrow();
            types.iter().map(|t| t.to_string()).find(|t| offered.contains(t)).or_else(|| offered.first().cloned())?
        };
        let bytes = self.receive(o, &m)?;
        Some((m, bytes))
    }

    pub fn read_text(&self) -> Option<String> {
        self.read(&mime::OFFERED).map(|(_, b)| String::from_utf8_lossy(&b).into_owned())
    }

    fn release_drag(&self) {
        let o = std::mem::take(&mut *self.drag.borrow_mut()).offer;
        if let Some(o) = o {
            offer::destroy(o)
        }
        let f = self.on_drag_leave.borrow().clone();
        if let Some(f) = f {
            f()
        }
    }

    fn complete_drop(&self) {
        let (o, types, x, y) = {
            let d = self.drag.borrow();
            (d.offer, d.types.clone(), d.x, d.y)
        };
        let cb = self.on_drop.borrow().clone();
        let accepted = self.accepted_drag_types.borrow().clone();
        let (Some(o), Some(cb), Some(m)) = (o, cb, types.into_iter().find(|t| accepted.contains(t))) else { return self.release_drag() };
        // **A drag that ends where it started is one process asking itself**,
        // the same deadlock as reading our own selection: the bytes are here.
        // The offer is still finished, so the source sees the drag complete.
        let ours = self.dragging.borrow().as_ref().map(|(_, b)| b.clone());
        let bytes = match ours {
            Some(b) => b.to_vec(),
            None => self.receive(o, &m).unwrap_or_default(),
        };
        // **`finish` after reading**: it tells the source the transfer is
        // done, and early it ends the drag mid-read.
        offer::finish(o);
        self.flush();
        cb(&m, &bytes, x, y);
        self.release_drag()
    }

    /// Which of our surfaces a drag is over, and where.
    pub fn drag_position(&self) -> (Option<Obj>, f64, f64) {
        let d = self.drag.borrow();
        (d.surface, d.x, d.y)
    }

    pub fn on_drop(&self, f: impl Fn(&str, &[u8], f64, f64) + 'static) {
        *self.on_drop.borrow_mut() = Some(Rc::new(f))
    }
    /// As a drag crosses us: for the highlight of where it would land.
    pub fn on_drag_motion(&self, f: impl Fn(f64, f64) + 'static) {
        *self.on_drag_motion.borrow_mut() = Some(Rc::new(f))
    }
    pub fn on_drag_leave(&self, f: impl Fn() + 'static) {
        *self.on_drag_leave.borrow_mut() = Some(Rc::new(f))
    }

    /// A data source offering `bytes` as `types`, answering every `send`,
    /// and forgetting itself from `slot` when cancelled or finished. **The
    /// slot is compared**: `cancelled` may come for a source already
    /// replaced, and clearing the current one would empty a clipboard
    /// somebody just set.
    fn source(self: &Rc<Self>, bytes: Vec<u8>, types: &[&str], slot: fn(&Clipboard) -> &Source) -> Option<Obj> {
        let s = manager::create_data_source(self.manager)?;
        let bytes = Rc::new(bytes);
        if let Some((old, _)) = slot(self).replace(Some((s, bytes.clone()))) {
            source::destroy(old)
        }
        let me = Rc::downgrade(self);
        source::listen(s, move |e| match e {
            // The same bytes under every type advertised.
            source::Event::Send { fd, .. } => send(fd, &bytes),
            source::Event::Cancelled {} | source::Event::DndFinished {} => {
                let Some(c) = me.upgrade() else { return };
                let mine = slot(&c).borrow().as_ref().is_some_and(|(o, _)| *o == s);
                if mine {
                    slot(&c).borrow_mut().take();
                    source::destroy(s)
                }
            }
            _ => {}
        });
        for t in types {
            source::offer(s, t)
        }
        Some(s)
    }

    /// Offer `bytes` to the desktop as `types`, quoting the last input's
    /// serial: wlroots checks it, which stops a client taking the clipboard
    /// off an input it never received.
    pub fn write(self: &Rc<Self>, bytes: Vec<u8>, types: &[&str]) -> bool {
        let Some(serial) = self.display.upgrade().map(|d| d.last_input_serial()) else { return false };
        let Some(s) = self.source(bytes, types, |c| &c.owned) else { return false };
        device::set_selection(self.device, Some(s), serial);
        self.flush();
        true
    }

    pub fn write_text(self: &Rc<Self>, s: &str) -> bool {
        self.write(s.as_bytes().to_vec(), &mime::OFFERED)
    }

    /// Begin dragging `bytes` from `origin`. The serial must be the pointer
    /// press that started it: wlroots checks, so a program cannot start a
    /// drag nobody began and harvest what the cursor passes over. No icon
    /// surface: the cursor is the feedback.
    pub fn start_drag(self: &Rc<Self>, bytes: Vec<u8>, origin: Obj, serial: u32, types: &[&str]) -> bool {
        let Some(s) = self.source(bytes, types, |c| &c.dragging) else { return false };
        source::set_actions(s, COPY);
        device::start_drag(self.device, Some(s), origin, None, serial);
        self.flush();
        true
    }
}

impl Drop for Clipboard {
    fn drop(&mut self) {
        for slot in [&self.owned, &self.dragging] {
            if let Some((s, _)) = slot.borrow_mut().take() {
                source::destroy(s)
            }
        }
        if let Some(o) = self.current.take() {
            offer::destroy(o)
        }
        device::destroy(self.device)
    }
}
