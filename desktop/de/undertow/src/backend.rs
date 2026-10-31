//! The wlroots bridge (Backend.swift, PHASE6.md P6.2): a `wlr_output`
//! wearing the `Output` trait the metronome already drives.
//!
//! wlroots owns the plumbing: backends, buffer allocation, the renderer.
//! **We own the scene, the scheduler and the present path** (DESKTOP.md §2).
//! A wlroots compositor is normally written to render when the output asks,
//! in its `frame` handler. Undertow does not: the metronome decides when a
//! frame happens, and the output executes it and reports back through
//! `present`.
//!
//! **Single-threaded, and P6.5 measured why that is enough.** The event loop
//! is serviced from inside the metronome's wait (`wait_until`), only in the
//! slack before the deadline, with a reserve: what mattered was not which
//! thread dispatches but where in the frame it happens.
//!
//! Swift's classes become shared state here: the listeners hold the session
//! weakly and its hooks are kept apart, so a hook may call back into the
//! session while wlroots is still inside the signal that ran it.

use crate::metronome::since;
use crate::output::{Flip, Output};
use abyss_sys::mono;
use abyss_sys::wlr::{self, Backend, Blend, Display, EventLoop, InputDevice, Listener, OutputState, Present, RectDraw, RenderPass, Session, Source};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::fmt;
use std::io::Write as _;
use std::rc::{Rc, Weak};

pub fn log(s: &str) {
    eprintln!("undertow: {s}");
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BackendError {
    NoDisplay,
    NoBackend,
    NoRenderer,
    NoAllocator,
    NoOutput,
    RenderInitFailed,
    ModeRejected,
    NoGlobals(String),
    /// Could not bind a Wayland socket: its own case, because folding it
    /// into NoDisplay sent people to look at the compositor when the problem
    /// was the environment.
    NoSocket,
    /// A socket name asked for is in use: someone else's session, or ours.
    SocketTaken(String),
    /// The privileged socket (PHASE10 P10.3): path, errno.
    PrivilegedSocket(String, i32),
}

impl fmt::Display for BackendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BackendError::PrivilegedSocket(path, e) => write!(f, "could not listen on the privileged socket {path}: {}", std::io::Error::from_raw_os_error(*e).kind_text()),
            BackendError::NoDisplay => f.write_str("could not create a wl_display"),
            BackendError::NoBackend => f.write_str("could not create a wlroots backend"),
            BackendError::NoRenderer => f.write_str("could not create a wlroots renderer"),
            BackendError::NoAllocator => f.write_str("could not create a wlroots allocator"),
            BackendError::NoOutput => f.write_str("the backend produced no output"),
            BackendError::RenderInitFailed => f.write_str("wlr_output_init_render failed"),
            BackendError::ModeRejected => f.write_str("the output rejected its mode"),
            BackendError::NoGlobals(what) => write!(f, "could not create the {what} global"),
            BackendError::NoSocket => f.write_str("could not bind a Wayland socket — is XDG_RUNTIME_DIR set? (FreeBSD has no pam_xdg, so nothing sets it: HANDOFF §2.31)"),
            BackendError::SocketTaken(name) => write!(f, "could not bind the Wayland socket '{name}' — something is already using it (is a session already running?)"),
        }
    }
}

/// strerror's text, as Swift's message carried it.
trait KindText {
    fn kind_text(&self) -> String;
}

impl KindText for std::io::Error {
    fn kind_text(&self) -> String {
        let s = self.to_string();
        // "No such file or directory (os error 2)": strerror is the part before.
        s.rsplit_once(" (os error").map_or(s.clone(), |(t, _)| t.to_owned())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HeadlessSize {
    pub width: i32,
    pub height: i32,
}

impl HeadlessSize {
    pub fn new(width: i32, height: i32) -> HeadlessSize {
        HeadlessSize { width, height }
    }
}

/// Which backend to run on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    /// Outputs we invent, at sizes we choose, one per size (P14.7a):
    /// deterministic, CPU-readable, and all the build VM can do.
    Headless { sizes: Vec<HeadlessSize>, refresh_mhz: i32 },
    /// Whatever this machine is: DRM/KMS on metal, a nested Wayland window,
    /// X11 under one. wlroots decides, as every wlroots compositor lets it.
    Auto,
}

type Hook = Option<Box<dyn FnMut(wlr::Output)>>;

#[derive(Default)]
struct Hooks {
    removed: Hook,
    added: Hook,
}

struct State {
    kind: Kind,
    renderer: wlr::Renderer,
    allocator: wlr::Allocator,
    backend: Backend,
    display: Weak<Display>,
    /// Outputs the backend announced, in arrival order, that still exist.
    outputs: Vec<wlr::Output>,
    destroy_listeners: HashMap<usize, Listener>,
    /// Set once the outputs found at start are configured; after that an
    /// output is configured as it arrives.
    started: bool,
    lost: u64,
    returned: u64,
    startup_inputs: Vec<InputDevice>,
    /// The stand-in VT (tests): what the headless outputs were, and what is
    /// coming back.
    stand_in_away: Vec<(String, HeadlessSize)>,
    stand_in_returning: Vec<(String, HeadlessSize)>,
    stand_in_buffer: Vec<u8>,
}

/// The compositor's wlroots session: display, backend, renderer, allocator.
///
/// Torn down in the documented order (HANDOFF §2.2, §2.35): the listeners
/// before the objects they listen to, then the display. The backend,
/// renderer and allocator are left to the process's exit, as Swift leaves
/// them: destroying the backend destroys outputs that a `WlrootsOutput`
/// may still be listening to.
pub struct WlrootsSession {
    state: Rc<RefCell<State>>,
    hooks: Rc<RefCell<Hooks>>,
    display: Rc<Display>,
    event_loop: EventLoop,
    session: Option<Session>,
    new_output: Option<Listener>,
    startup_input: RefCell<Option<Listener>>,
    stand_in_vt: Option<Source>,
}

impl WlrootsSession {
    pub fn headless(outputs: usize, width: i32, height: i32, refresh_mhz: i32, verbose: bool) -> Result<WlrootsSession, BackendError> {
        WlrootsSession::new(Kind::Headless { sizes: vec![HeadlessSize::new(width, height); outputs], refresh_mhz }, verbose)
    }

    pub fn new(kind: Kind, verbose: bool) -> Result<WlrootsSession, BackendError> {
        wlr::log(verbose);
        let display = Rc::new(Display::create().ok_or(BackendError::NoDisplay)?);
        let event_loop = display.event_loop();
        let (backend, session) = match &kind {
            Kind::Headless { .. } => (Backend::headless(event_loop).ok_or(BackendError::NoBackend)?, None),
            // A multi-backend and, for DRM, a session that owns the VT and
            // the device descriptors: both kept.
            Kind::Auto => Backend::autocreate(event_loop).ok_or(BackendError::NoBackend)?,
        };
        // **Software rendering for headless only.** A GPU's buffers are not
        // CPU-readable, which would make capture impossible and the two
        // machines' difference invisible until it failed. On a real backend
        // the pin would be wrong. WLR_RENDERER from the environment wins.
        // Asked for directly, where Swift sets WLR_RENDERER: the environment
        // is not written while other threads may read it (a test's clients).
        let renderer = match kind {
            Kind::Headless { .. } => backend.renderer_preferring_pixman(),
            Kind::Auto => backend.renderer(),
        }
        .ok_or(BackendError::NoRenderer)?;
        let allocator = backend.allocator(renderer).ok_or(BackendError::NoAllocator)?;
        let state = Rc::new(RefCell::new(State {
            kind: kind.clone(),
            renderer,
            allocator,
            backend,
            display: Rc::downgrade(&display),
            outputs: vec![],
            destroy_listeners: HashMap::new(),
            started: false,
            lost: 0,
            returned: 0,
            startup_inputs: vec![],
            stand_in_away: vec![],
            stand_in_returning: vec![],
            stand_in_buffer: vec![],
        }));
        let hooks: Rc<RefCell<Hooks>> = Rc::default();

        // Outputs as the backend announces them: registered before it
        // starts, or the announcements arrive with nobody listening.
        let (w, h) = (Rc::downgrade(&state), Rc::downgrade(&hooks));
        let new_output = backend.on_new_output(move |o| {
            if let (Some(s), Some(h)) = (w.upgrade(), h.upgrade()) {
                adopt(&s, &h, o)
            }
        });
        // **And inputs, for the same reason** (PHASE4 §5.11): libinput
        // announces every device present at start from inside the backend's
        // start, before Seat exists. Without this the first metal boot had a
        // dead keyboard.
        let w = Rc::downgrade(&state);
        let startup_input = backend.on_new_input(move |d| {
            if let Some(s) = w.upgrade() {
                s.borrow_mut().startup_inputs.push(d)
            }
        });
        let me = WlrootsSession { state, hooks, display, event_loop, session, new_output, startup_input: RefCell::new(startup_input), stand_in_vt: None };

        // From here a failure drops `me`, which unhooks the listeners before
        // the display goes: destroying it with them hooked aborted in
        // wlr_backend_finish on the 2013 Mac Pro before the error was said.
        if !backend.start() {
            return Err(BackendError::NoBackend);
        }
        if let Kind::Headless { sizes, .. } = &kind {
            for sz in sizes {
                backend.headless_add_output(sz.width as u32, sz.height as u32);
            }
        } else {
            // A real backend announces its own outputs, and may take a moment
            // (DRM enumerates connectors, nested Wayland round-trips).
            for _ in 0..50 {
                if !me.state.borrow().outputs.is_empty() {
                    break;
                }
                me.display.flush_clients();
                me.event_loop.dispatch(20);
            }
        }
        let outputs = me.state.borrow().outputs.clone();
        if outputs.is_empty() {
            return Err(BackendError::NoOutput);
        }
        // A renderer, a mode and a global for each: until this commit lands
        // an output has no buffers to draw into.
        for (i, o) in outputs.into_iter().enumerate() {
            configure(&me.state.borrow(), o, i, None)?;
        }
        me.state.borrow_mut().started = true;
        Ok(me)
    }

    pub fn display(&self) -> &Display {
        &self.display
    }
    pub fn event_loop(&self) -> EventLoop {
        self.event_loop
    }
    pub fn renderer(&self) -> wlr::Renderer {
        self.state.borrow().renderer
    }
    pub fn backend(&self) -> Backend {
        self.state.borrow().backend
    }
    pub fn kind(&self) -> Kind {
        self.state.borrow().kind.clone()
    }
    pub fn outputs(&self) -> Vec<wlr::Output> {
        self.state.borrow().outputs.clone()
    }
    pub fn outputs_lost(&self) -> u64 {
        self.state.borrow().lost
    }
    pub fn outputs_returned(&self) -> u64 {
        self.state.borrow().returned
    }

    /// **Outputs come and go while we run** (P16, found on metal): wlroots
    /// 0.20 destroys every DRM output when the session is paused (a VT
    /// switch) and announces new ones when it is back; a monitor unplugged
    /// and plugged in is the same pair. `removed` runs inside the output's
    /// destroy, **before** wlroots finishes it: every holder lets go there.
    /// `added` runs once a late output is configured and has its global.
    pub fn on_output_removed(&self, f: impl FnMut(wlr::Output) + 'static) {
        self.hooks.borrow_mut().removed = Some(Box::new(f));
    }
    pub fn on_output_added(&self, f: impl FnMut(wlr::Output) + 'static) {
        self.hooks.borrow_mut().added = Some(Box::new(f));
    }

    /// The devices announced before Seat existed, handed over once; from
    /// then on Seat's own listener sees every device.
    pub fn take_startup_inputs(&self) -> Vec<InputDevice> {
        self.startup_input.borrow_mut().take();
        std::mem::take(&mut self.state.borrow_mut().startup_inputs)
    }

    /// `--stand-in-vt FIFO`: a line `away` does to the headless outputs
    /// what wlroots does to DRM ones when the VT is switched away (destroys
    /// them all), and `back` announces them again by the same names.
    /// Headless only: a real session has a real VT.
    pub fn add_stand_in_vt(&mut self, fifo: &str) -> bool {
        if !matches!(self.state.borrow().kind, Kind::Headless { .. }) || self.stand_in_vt.is_some() {
            return false;
        }
        use std::os::unix::fs::OpenOptionsExt;
        use std::os::unix::io::AsRawFd;
        // Read-write: never sees EOF between writers.
        let Ok(file) = std::fs::OpenOptions::new().read(true).write(true).custom_flags(libc::O_NONBLOCK).open(fifo) else { return false };
        let fd = file.as_raw_fd();
        let w = Rc::downgrade(&self.state);
        // The file lives in the closure, and so as long as the source.
        let Some(src) = self.event_loop.add_fd(fd, move || {
            if let Some(s) = w.upgrade() {
                read_stand_in_vt(&s, &file)
            }
        }) else {
            return false;
        };
        self.stand_in_vt = Some(src);
        true
    }

    /// Switch to virtual terminal `vt`. False with no session to ask
    /// (headless, or nested), which is how the key is left to the client.
    pub fn change_vt(&self, vt: u32) -> bool {
        self.session.is_some_and(|s| s.change_vt(vt))
    }

    pub fn output_named(&self, name: &str) -> Option<wlr::Output> {
        self.state.borrow().outputs.iter().copied().find(|o| o.name() == name)
    }

    pub fn dispatch_pending(&self) {
        self.event_loop.dispatch(0)
    }
    /// Dispatch, blocking at most `timeout_ms` (-1: indefinitely).
    pub fn dispatch(&self, timeout_ms: i32) {
        self.event_loop.dispatch(timeout_ms)
    }
}

impl Drop for WlrootsSession {
    fn drop(&mut self) {
        self.startup_input.borrow_mut().take();
        self.new_output.take();
        // Before the display goes: a destroy listener firing into a session
        // mid-teardown is §2.35 again.
        self.state.borrow_mut().destroy_listeners.clear();
        self.stand_in_vt.take();
        // The display itself goes when the last Rc does, which is here
        // unless someone kept one.
    }
}

/// A renderer, a mode and a global, for an output found at start and for
/// one that arrives later.
fn configure(s: &State, out: wlr::Output, index: usize, size: Option<HeadlessSize>) -> Result<(), BackendError> {
    if !out.init_render(s.allocator, s.renderer) {
        return Err(BackendError::RenderInitFailed);
    }
    let mut st = OutputState::new();
    st.set_enabled(true);
    match &s.kind {
        Kind::Headless { sizes, refresh_mhz } => {
            let sz = size.unwrap_or(sizes[index.min(sizes.len() - 1)]);
            st.set_custom_mode(sz.width, sz.height, *refresh_mhz);
        }
        // **The display's own preferred mode**: a panel has a native
        // resolution and a rate it was built for. A connector with no modes
        // has nothing to set, and the commit still enables it.
        Kind::Auto => {
            if let Some(m) = out.preferred_mode() {
                st.set_mode(m);
            }
        }
    }
    if !out.commit(&st) {
        return Err(BackendError::ModeRejected);
    }
    // **Advertise it to clients.** Without the global a client asking what
    // displays there are is told none: screencopy and per-output scale
    // break, and ordinary windows never notice.
    if let Some(d) = s.display.upgrade() {
        out.create_global(&d);
    }
    Ok(())
}

fn adopt(state: &Rc<RefCell<State>>, hooks: &Rc<RefCell<Hooks>>, out: wlr::Output) {
    let (w, h) = (Rc::downgrade(state), Rc::downgrade(hooks));
    let l = out.on_destroy(move |o| {
        if let (Some(s), Some(h)) = (w.upgrade(), h.upgrade()) {
            lose(&s, &h, o)
        }
    });
    let mut s = state.borrow_mut();
    s.outputs.push(out);
    if let Some(l) = l {
        s.destroy_listeners.insert(out.addr(), l);
    }
    if !s.started {
        return;
    }
    // The stand-in VT's way back: the same name and size as before, as a
    // DRM connector has when its session resumes.
    let mut size = None;
    if !s.stand_in_returning.is_empty() {
        let (name, sz) = s.stand_in_returning.remove(0);
        out.set_name(&name);
        size = Some(sz);
    }
    let index = s.outputs.len() - 1;
    if let Err(e) = configure(&s, out, index, size) {
        log(&format!("output {} arrived and could not be configured: {e}", out.name()));
        return;
    }
    s.returned += 1;
    drop(s);
    let hook = hooks.borrow_mut().added.take();
    if let Some(mut f) = hook {
        f(out);
        hooks.borrow_mut().added.get_or_insert(f);
    }
}

/// An output going away, inside wlroots' destroy signal, which allows a
/// listener to remove itself.
fn lose(state: &Rc<RefCell<State>>, hooks: &Rc<RefCell<Hooks>>, out: wlr::Output) {
    state.borrow_mut().lost += 1;
    let hook = hooks.borrow_mut().removed.take();
    if let Some(mut f) = hook {
        f(out);
        hooks.borrow_mut().removed.get_or_insert(f);
    }
    let l = {
        let mut s = state.borrow_mut();
        s.outputs.retain(|o| *o != out);
        s.destroy_listeners.remove(&out.addr())
    };
    // This listener, dropped from inside its own callback.
    drop(l);
}

fn read_stand_in_vt(state: &Rc<RefCell<State>>, mut file: &std::fs::File) {
    use std::io::Read;
    let mut buf = [0u8; 256];
    let n = file.read(&mut buf).unwrap_or(0);
    if n == 0 {
        return;
    }
    state.borrow_mut().stand_in_buffer.extend_from_slice(&buf[..n]);
    loop {
        let line = {
            let mut s = state.borrow_mut();
            let Some(nl) = s.stand_in_buffer.iter().position(|&b| b == b'\n') else { return };
            let line: Vec<u8> = s.stand_in_buffer.drain(..=nl).collect();
            String::from_utf8_lossy(&line[..nl]).into_owned()
        };
        match line.as_str() {
            "away" => {
                let outs = {
                    let mut s = state.borrow_mut();
                    if !s.stand_in_away.is_empty() {
                        continue;
                    }
                    let outs = s.outputs.clone();
                    s.stand_in_away = outs.iter().map(|o| (o.name(), HeadlessSize::new(o.width(), o.height()))).collect();
                    outs
                };
                log("stand-in VT: away — every output destroyed, as DRM's are");
                for o in outs {
                    o.destroy();
                }
            }
            "back" => {
                log("stand-in VT: back — the outputs announced again");
                let (backend, sizes) = {
                    let mut s = state.borrow_mut();
                    s.stand_in_returning = std::mem::take(&mut s.stand_in_away);
                    (s.backend, s.stand_in_returning.iter().map(|r| r.1).collect::<Vec<_>>())
                };
                for sz in sizes {
                    backend.headless_add_output(sz.width as u32, sz.height as u32);
                }
            }
            _ => {}
        }
    }
}

// MARK: an output

/// What draws an output's frame: the scene and the cursor over it. Shared
/// with the compositor, so behind a RefCell; one call per frame through it.
pub trait Painter {
    fn render(&mut self, pass: &mut RenderPass, out: wlr::Output, background: (f32, f32, f32, f32));
    /// Tell wp_presentation which surfaces this frame showed, before commit.
    fn mark_presented(&mut self, out: wlr::Output);
    /// Latch the freshest client state now (a capture's, not a frame's).
    fn latch_now(&mut self, now: u64);
    /// Set, the next frame draws, changed or not. A flag rather than a
    /// call, because wlroots raises it (`needs_frame`) from inside commits
    /// and dispatches, where the painter may be borrowed.
    fn dirty(&self) -> Rc<Cell<bool>>;
}

#[derive(Default)]
struct Shared {
    /// Present events, bounded: dropped, never grown.
    ring: std::collections::VecDeque<Present>,
    deliveries: u64,
    late_1ms: u64,
    late_half_period: u64,
    worst_ns: u64,
    period_hint_ns: u64,
}

const RING: usize = 16;

/// A `wlr_output` driven by the metronome. **Detached while the VT is
/// away** (or the monitor unplugged): wlroots has destroyed it, and this,
/// which the scene, metronome and loop all hold, waits for one of the same
/// name to come back (`attach`).
pub struct WlrootsOutput {
    output: Option<wlr::Output>,
    /// The connector's name, which outlives any one wlr_output for it.
    pub name: String,
    last_width: i32,
    last_height: i32,
    event_loop: EventLoop,
    shared: Rc<RefCell<Shared>>,
    present: Option<Listener>,
    needs_frame: Option<Listener>,
    /// The painter's dirty flag, set by `needs_frame`: screencopy waits on a
    /// frame, and with present-on-damage a still screen would never send one.
    dirty: Rc<Cell<bool>>,
    /// commit_seq → (the vblank aimed at, when the commit returned).
    targets: [(u32, u64, u64); RING],
    target_slot: usize,
    pub commits_made: u64,
    pub commits_refused: u64,
    /// Refused commits not yet reported by `poll_flip`, as their targets.
    refused: std::collections::VecDeque<u64>,
    frame_colour: f32,
    painter: Option<Rc<RefCell<dyn Painter>>>,
    /// Behind the windows: Jaguar blue, so a capture is obviously ours and an
    /// empty output obviously empty.
    pub background: (f32, f32, f32, f32),
    grid_epoch: u64,
    pub saw_hardware_clock: bool,
    asleep: bool,
}

impl WlrootsOutput {
    pub fn new(output: wlr::Output, session: &WlrootsSession) -> WlrootsOutput {
        let mut o = WlrootsOutput {
            output: Some(output),
            name: output.name(),
            last_width: output.width(),
            last_height: output.height(),
            event_loop: session.event_loop(),
            shared: Rc::default(),
            present: None,
            needs_frame: None,
            dirty: Rc::default(),
            targets: [(0, 0, 0); RING],
            target_slot: 0,
            commits_made: 0,
            commits_refused: 0,
            refused: std::collections::VecDeque::with_capacity(RING),
            frame_colour: 0.0,
            painter: None,
            background: (0.24, 0.40, 0.63, 1.0),
            grid_epoch: 0,
            saw_hardware_clock: false,
            asleep: false,
        };
        // Refresh in mHz; a headless output with no mode reports 0, and 60 Hz
        // is the honest guess: the predictor measures the truth anyway.
        let mhz = output.refresh();
        o.shared.borrow_mut().period_hint_ns = if mhz > 0 { 1_000_000_000_000 / mhz as u64 } else { 16_666_666 };
        o.listen(output);
        o
    }

    pub fn is_bound_to(&self, o: wlr::Output) -> bool {
        self.output == Some(o)
    }
    pub fn attached(&self) -> bool {
        self.output.is_some()
    }
    pub fn output(&self) -> Option<wlr::Output> {
        self.output
    }
    pub fn width(&self) -> i32 {
        self.output.map_or(self.last_width, |o| o.width())
    }
    pub fn height(&self) -> i32 {
        self.output.map_or(self.last_height, |o| o.height())
    }
    pub fn asleep(&self) -> bool {
        self.asleep
    }
    pub fn deliveries(&self) -> (u64, u64, u64, u64) {
        let s = self.shared.borrow();
        (s.deliveries, s.late_1ms, s.late_half_period, s.worst_ns)
    }

    /// Its output is being destroyed (inside wlroots' destroy signal): let
    /// go of it, and of flips it will never report.
    pub fn detach(&mut self) {
        self.present = None;
        self.needs_frame = None;
        self.output = None;
        self.refused.clear();
        self.shared.borrow_mut().ring.clear();
    }

    /// One of the same name is back: draw on it. Asleep when it went, it
    /// goes back to sleep: a new output starts enabled.
    pub fn attach(&mut self, o: wlr::Output) {
        self.output = Some(o);
        self.last_width = o.width();
        self.last_height = o.height();
        self.grid_epoch = 0;
        self.listen(o);
        self.invalidate(); // a new output shows nothing until drawn
        self.refresh_period();
        if self.asleep {
            self.asleep = false;
            self.set_asleep(true);
        }
    }

    /// What draws this output (the scene and cursor): set once at start.
    pub fn set_painter(&mut self, p: Rc<RefCell<dyn Painter>>) {
        self.dirty = p.borrow().dirty();
        self.painter = Some(p);
        if let Some(o) = self.output {
            let dirty = self.dirty.clone();
            self.needs_frame = o.on_needs_frame(move || dirty.set(true));
        }
    }

    fn invalidate(&self) {
        self.dirty.set(true)
    }

    fn listen(&mut self, output: wlr::Output) {
        let dirty = self.dirty.clone();
        self.needs_frame = output.on_needs_frame(move || dirty.set(true));
        let shared = Rc::downgrade(&self.shared);
        self.present = output.on_present(move |e| {
            let Some(s) = shared.upgrade() else { return };
            let mut s = s.borrow_mut();
            if s.ring.len() < RING {
                s.ring.push_back(e);
            }
            // How long after the flip we heard of it (PHASE4 §5.13): wlroots
            // keeps the output "flip pending" until this is read, so a late
            // delivery refuses the next commit however early it comes.
            if e.hw_clock {
                let ns = since(e.when_ns, mono::now());
                s.deliveries += 1;
                if ns > 1_000_000 {
                    s.late_1ms += 1;
                }
                if ns > s.period_hint_ns / 2 {
                    s.late_half_period += 1;
                }
                s.worst_ns = s.worst_ns.max(ns);
            }
        });
    }

    /// Read the refresh rate again, after a mode change: whether the period
    /// changed.
    pub fn refresh_period(&mut self) -> bool {
        let Some(o) = self.output else { return false };
        let mhz = o.refresh();
        let mut s = self.shared.borrow_mut();
        let p = if mhz > 0 { 1_000_000_000_000 / mhz as u64 } else { s.period_hint_ns };
        let changed = p != s.period_hint_ns;
        s.period_hint_ns = p;
        changed
    }

    /// Off while the displays sleep (U.9): on metal that is the CRTC, and
    /// the monitor goes to standby. Nothing is drawn until it wakes.
    pub fn set_asleep(&mut self, on: bool) {
        if on == self.asleep {
            return;
        }
        let mut st = OutputState::new();
        st.set_enabled(!on);
        if let Some(o) = self.output
            && !o.commit(&st)
        {
            log(&format!("{}: could not turn {}", self.name, if on { "off" } else { "on" }));
        }
        self.asleep = on;
        if !on {
            self.invalidate(); // awake: the screen is blank until drawn
        }
    }

    pub fn backend_name(&self) -> String {
        self.output.map_or_else(|| "gone".into(), |o| o.backend_name())
    }

    /// Give a backend with no hardware clock an honest vblank grid. A
    /// headless output presents the instant it is committed, so its
    /// "vblank" is our own commit time, and feeding that back to the
    /// predictor closes a loop with no external reference: measured
    /// drifting from 16.7 ms to 11.9 ms over 120 frames. Without
    /// `WLR_OUTPUT_PRESENT_HW_CLOCK` we snap to the nominal grid.
    fn snap_to_grid(&mut self, e: &Present) -> u64 {
        let period = self.shared.borrow().period_hint_ns;
        if e.hw_clock || period == 0 {
            return e.when_ns;
        }
        if self.grid_epoch == 0 {
            self.grid_epoch = e.when_ns;
            return e.when_ns;
        }
        if e.when_ns <= self.grid_epoch {
            return self.grid_epoch;
        }
        let k = (since(self.grid_epoch, e.when_ns) + period / 2) / period;
        self.grid_epoch + k * period
    }

    fn draw(&mut self, pass: &mut RenderPass, o: wlr::Output) {
        if let Some(p) = &self.painter {
            p.borrow_mut().render(pass, o, self.background);
        } else {
            // No scene: P6.2's test pattern, an animated rect: enough to
            // prove buffers are allocated, drawn, committed and presented.
            self.frame_colour += 0.013;
            if self.frame_colour > 1.0 {
                self.frame_colour -= 1.0;
            }
            let c = self.frame_colour;
            pass.add_rect(&RectDraw::new(0, 0, o.width(), o.height(), (c, 0.25, 1.0 - c, 1.0), Blend::None));
        }
    }

    /// Render one frame and write it out as a binary PPM: no image library
    /// for a pixel probe (HANDOFF §2.26). It captures **the output's own
    /// swapchain buffer**, the one it is about to present: a buffer of our
    /// own was refused by the renderer, which knows its formats better.
    pub fn capture_ppm(&mut self, path: &str) -> bool {
        let Some(o) = self.output else { return fail("the output is gone (VT away, or unplugged)") };
        let mut st = OutputState::new();
        let Some(mut pass) = o.begin_render_pass(&mut st) else { return fail("the output refused a render pass") };
        if let Some(p) = &self.painter {
            // **Latch now, not the last frame's list**: its textures belong
            // to buffers a client may have replaced since, and drawing a
            // freed texture aborted undertow in pixman.
            p.borrow_mut().latch_now(mono::now());
        }
        self.draw_capture(&mut pass, o);
        if !pass.submit() {
            return fail("the render pass failed");
        }
        let Some(buffer) = st.buffer() else { return fail("the render pass left no buffer to read") };
        let (w, h) = (o.width() as usize, o.height() as usize);
        let written = buffer.read(h, |bytes, _, stride| write_ppm(path, bytes, w, h, stride));
        match written {
            None => fail("the output's buffer is not CPU-readable (not shm-backed?)"),
            Some(false) => fail(&format!("could not write {path}")),
            Some(true) => true,
        }
    }

    fn draw_capture(&mut self, pass: &mut RenderPass, o: wlr::Output) {
        match &self.painter {
            Some(p) => p.borrow_mut().render(pass, o, self.background),
            None => self.draw(pass, o),
        }
    }
}

/// A capture that fails silently is worse than none: say which step.
fn fail(why: &str) -> bool {
    eprintln!("undertow: capture failed — {why}");
    false
}

/// Binary PPM from XRGB8888 little-endian (B, G, R, X in memory).
fn write_ppm(path: &str, px: &[u8], w: usize, h: usize, stride: usize) -> bool {
    let mut out = format!("P6\n{w} {h}\n255\n").into_bytes();
    out.reserve(w * h * 3);
    for row in 0..h {
        for p in px[row * stride..row * stride + w * 4].as_chunks::<4>().0 {
            out.extend_from_slice(&[p[2], p[1], p[0]]);
        }
    }
    std::fs::File::create(path).and_then(|mut f| f.write_all(&out)).is_ok()
}

impl Output for WlrootsOutput {
    fn period_hint_ns(&self) -> u64 {
        self.shared.borrow().period_hint_ns
    }

    /// Render and commit a frame. Fire-and-forget: the commit queues the
    /// flip, and `present` reports back later.
    fn submit(&mut self, target: u64, _now: u64) {
        if self.asleep {
            return;
        }
        let Some(o) = self.output else { return };
        let mut st = OutputState::new();
        let Some(mut pass) = o.begin_render_pass(&mut st) else { return };
        self.draw(&mut pass, o);
        if let Some(p) = &self.painter {
            p.borrow_mut().mark_presented(o);
        }
        pass.submit();
        if !o.commit(&st) {
            // Refused: on DRM most often "a page-flip is already pending". A
            // frame lost here never produces a present event, so nothing else
            // counts it; and it was never shown, so the next frame draws.
            self.commits_refused += 1;
            self.invalidate();
            if self.refused.len() < RING {
                self.refused.push_back(target);
            }
            return;
        }
        self.commits_made += 1;
        // What this commit aimed at, and when it returned: what the flip's
        // `done` means (PHASE4 §5.11).
        self.targets[self.target_slot] = (o.commit_seq(), target, mono::now());
        self.target_slot = (self.target_slot + 1) % RING;
    }

    fn poll_flip(&mut self) -> Option<Flip> {
        // **No dispatch here, deliberately**: this runs after the deadline,
        // the worst place to service clients (P6.5). Present events are
        // collected in `wait_until`; this only drains them.
        if let Some(target) = self.refused.pop_front() {
            return Some(Flip { target, vblank: target, done: mono::now(), missed: true, refused: true });
        }
        let e = self.shared.borrow_mut().ring.pop_front()?;
        if e.hw_clock {
            self.saw_hardware_clock = true;
        }
        // **`done` is when the commit returned, not when the frame lit up**:
        // the present's time made every on-time frame on DRM report the whole
        // margin as commit latency, a loop that ratchets (PHASE4 §5.11).
        let (mut target, mut done) = (e.when_ns, e.when_ns);
        for t in self.targets.iter().filter(|t| t.0 == e.commit_seq) {
            target = t.1;
            done = t.2;
        }
        let vblank = self.snap_to_grid(&e);
        // **Late means a later vblank, not a later nanosecond** (PHASE4
        // §5.12): a hardware timestamp lands a few µs either side of its
        // estimate, and every one after it was a false miss.
        let period = self.shared.borrow().period_hint_ns;
        let late = if period > 0 { vblank > target + period / 2 } else { vblank > target };
        Some(Flip { target, vblank, done, missed: e.presented && late, refused: false })
    }

    /// Wait for the deadline **while servicing wlroots**: a plain sleep
    /// would leave the loop unserviced, no present would arrive, and the
    /// compositor would look hung while dutifully committing frames.
    fn wait_until(&mut self, deadline_ns: u64) {
        // Stop servicing clients this long before the deadline and just
        // sleep: a dispatch pass is bounded by the clients' buffers, not the
        // time left, so the last one could overrun onto the frame.
        const RESERVE_NS: u64 = 500_000;
        loop {
            let now = mono::now();
            if now >= deadline_ns {
                return;
            }
            let remaining = deadline_ns - now;
            if remaining <= RESERVE_NS {
                mono::sleep_until(deadline_ns);
                return;
            }
            // Bounded, non-blocking passes with a clock check between each.
            self.event_loop.dispatch(0);
            if mono::now() >= deadline_ns - RESERVE_NS {
                continue;
            }
            // Nothing pending: block for the remainder, **and wake before
            // the reserve, never after it** (PHASE4 §5.13): round down, and
            // leave a sixteenth for the timer's slop.
            let slop = remaining / 16;
            let ms = (remaining - RESERVE_NS - slop.min(remaining - RESERVE_NS)) / 1_000_000;
            if ms == 0 {
                mono::sleep_until(deadline_ns - RESERVE_NS);
                continue;
            }
            self.event_loop.dispatch(ms.min(1000) as i32);
        }
    }
}

#[cfg(test)]
#[path = "backend_tests.rs"]
mod tests;
