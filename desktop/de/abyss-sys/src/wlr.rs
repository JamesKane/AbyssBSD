//! wlroots and libwayland-server, for undertow (RUST.md R4b), over
//! de/cwlroots: its listener trampoline, and tw-access.h's accessors for
//! what Swift read from wlroots' headers itself.
//!
//! **Handles are pointers wlroots owns.** An `Output`, `Surface` or
//! `Texture` is `Copy`, valid until wlroots destroys the object, and its
//! holders let go of it in the object's destroy signal: the rule undertow's
//! Swift keeps (HANDOFF §2.2, §2.35), which a handle cannot enforce, so it
//! is stated here. What Rust owns (`Display`, `OutputState`, `Listener`,
//! `Source`) is freed by `Drop`.

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::ptr::NonNull;

macro_rules! opaque {
    ($($c:ident),*) => { $( #[allow(non_camel_case_types)] #[repr(C)] pub struct $c { _p: [u8; 0] } )* };
}
opaque!(wl_display, wl_event_loop, wl_event_source, wlr_backend, wlr_session, wlr_renderer, wlr_allocator, wlr_output, wlr_output_mode, wlr_output_state, wlr_render_pass, wlr_buffer, wlr_texture, wlr_surface, wlr_input_device, wlr_drm_syncobj_timeline, tw_listener);

type Notify = extern "C" fn(*mut c_void, *mut c_void);
type FdFn = extern "C" fn(c_int, u32, *mut c_void) -> c_int;
type TimerFn = extern "C" fn(*mut c_void) -> c_int;
type SurfaceIter = extern "C" fn(*mut wlr_surface, c_int, c_int, *mut c_void);

/// tw-access.h's `struct tw_present`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Present {
    pub commit_seq: u32,
    pub presented: bool,
    /// Measured against real display hardware (`WLR_OUTPUT_PRESENT_HW_CLOCK`).
    pub hw_clock: bool,
    pub when_ns: u64,
}

/// How a rect or texture is blended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Blend {
    Premultiplied = 0,
    None = 1,
}

/// tw-access.h's `struct tw_rect`: a filled box, in buffer pixels.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RectDraw {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
    blend: i32,
}

impl RectDraw {
    pub fn new(x: i32, y: i32, width: i32, height: i32, (r, g, b, a): (f32, f32, f32, f32), blend: Blend) -> RectDraw {
        RectDraw { x, y, width, height, r, g, b, a, blend: blend as i32 }
    }
}

/// tw-access.h's `struct tw_texture_draw`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TextureDraw {
    texture: *mut wlr_texture,
    /// All zero: the whole texture.
    pub src: [f64; 4],
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    /// wl_output_transform.
    pub transform: i32,
    /// Below 0: none.
    pub alpha: f32,
    blend: i32,
    wait_timeline: *mut wlr_drm_syncobj_timeline,
    pub wait_point: u64,
}

impl TextureDraw {
    pub fn new(t: Texture, (x, y, width, height): (i32, i32, i32, i32)) -> TextureDraw {
        TextureDraw { texture: t.0.as_ptr(), src: [0.0; 4], x, y, width, height, transform: 0, alpha: -1.0, blend: Blend::Premultiplied as i32, wait_timeline: std::ptr::null_mut(), wait_point: 0 }
    }
    pub fn blend(mut self, b: Blend) -> TextureDraw {
        self.blend = b as i32;
        self
    }
    /// Wait for `point` on `timeline` before sampling (explicit sync).
    pub fn wait(mut self, timeline: Timeline, point: u64) -> TextureDraw {
        self.wait_timeline = timeline.0.as_ptr();
        self.wait_point = point;
        self
    }
}

unsafe extern "C" {
    fn wl_display_create() -> *mut wl_display;
    fn wl_display_destroy(d: *mut wl_display);
    fn wl_display_destroy_clients(d: *mut wl_display);
    fn wl_display_get_event_loop(d: *mut wl_display) -> *mut wl_event_loop;
    fn wl_display_flush_clients(d: *mut wl_display);
    fn wl_display_add_socket(d: *mut wl_display, name: *const c_char) -> c_int;
    fn wl_display_add_socket_auto(d: *mut wl_display) -> *const c_char;
    fn wl_event_loop_dispatch(l: *mut wl_event_loop, timeout: c_int) -> c_int;
    fn wl_event_loop_add_fd(l: *mut wl_event_loop, fd: c_int, mask: u32, f: FdFn, data: *mut c_void) -> *mut wl_event_source;
    fn wl_event_loop_add_timer(l: *mut wl_event_loop, f: TimerFn, data: *mut c_void) -> *mut wl_event_source;
    fn wl_event_source_timer_update(s: *mut wl_event_source, ms: c_int) -> c_int;
    fn wl_event_source_remove(s: *mut wl_event_source) -> c_int;

    fn tw_listener_free(l: *mut tw_listener);
    fn tw_log_silence();
    fn tw_log_verbose();
    fn tw_backend_on_new_output(o: *mut wlr_backend, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_backend_on_new_input(o: *mut wlr_backend, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_output_on_destroy(o: *mut wlr_output, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_output_on_present(o: *mut wlr_output, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_output_on_needs_frame(o: *mut wlr_output, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_output_on_frame(o: *mut wlr_output, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_output_name(o: *const wlr_output) -> *const c_char;
    fn tw_output_width(o: *const wlr_output) -> i32;
    fn tw_output_height(o: *const wlr_output) -> i32;
    fn tw_output_refresh(o: *const wlr_output) -> i32;
    fn tw_output_commit_seq(o: *const wlr_output) -> u32;
    fn tw_output_scale(o: *const wlr_output) -> f32;
    fn tw_output_transform(o: *const wlr_output) -> i32;
    fn tw_output_enabled(o: *const wlr_output) -> bool;
    fn tw_present_read(e: *const c_void, out: *mut Present);
    fn tw_output_state_new() -> *mut wlr_output_state;
    fn tw_output_state_free(s: *mut wlr_output_state);
    fn tw_output_state_buffer(s: *const wlr_output_state) -> *mut wlr_buffer;
    fn tw_pass_add_rect(p: *mut wlr_render_pass, r: *const RectDraw);
    fn tw_pass_add_texture(p: *mut wlr_render_pass, d: *const TextureDraw);
    fn tw_surface_width(s: *const wlr_surface) -> i32;
    fn tw_surface_height(s: *const wlr_surface) -> i32;
    fn tw_surface_seq(s: *const wlr_surface) -> u32;
    fn tw_surface_transform(s: *const wlr_surface) -> i32;
    fn tw_surface_source_box(s: *mut wlr_surface, out: *mut f64);

    fn wlr_headless_backend_create(l: *mut wl_event_loop) -> *mut wlr_backend;
    fn wlr_backend_autocreate(l: *mut wl_event_loop, session: *mut *mut wlr_session) -> *mut wlr_backend;
    fn wlr_backend_start(b: *mut wlr_backend) -> bool;
    fn wlr_backend_destroy(b: *mut wlr_backend);
    fn wlr_headless_add_output(b: *mut wlr_backend, w: u32, h: u32) -> *mut wlr_output;
    fn wlr_renderer_autocreate(b: *mut wlr_backend) -> *mut wlr_renderer;
    fn wlr_renderer_destroy(r: *mut wlr_renderer);
    fn wlr_allocator_autocreate(b: *mut wlr_backend, r: *mut wlr_renderer) -> *mut wlr_allocator;
    fn wlr_allocator_destroy(a: *mut wlr_allocator);
    fn wlr_session_change_vt(s: *mut wlr_session, vt: u32) -> bool;
    fn wlr_output_init_render(o: *mut wlr_output, a: *mut wlr_allocator, r: *mut wlr_renderer) -> bool;
    fn wlr_output_state_set_enabled(s: *mut wlr_output_state, on: bool);
    fn wlr_output_state_set_custom_mode(s: *mut wlr_output_state, w: i32, h: i32, refresh: i32);
    fn wlr_output_state_set_mode(s: *mut wlr_output_state, m: *mut wlr_output_mode);
    fn wlr_output_commit_state(o: *mut wlr_output, s: *const wlr_output_state) -> bool;
    fn wlr_output_create_global(o: *mut wlr_output, d: *mut wl_display);
    fn wlr_output_destroy(o: *mut wlr_output);
    fn wlr_output_set_name(o: *mut wlr_output, name: *const c_char);
    fn wlr_output_preferred_mode(o: *mut wlr_output) -> *mut wlr_output_mode;
    fn tw_output_backend_name(o: *mut wlr_output) -> *const c_char;
    fn wlr_output_begin_render_pass(o: *mut wlr_output, s: *mut wlr_output_state, opts: *mut c_void) -> *mut wlr_render_pass;
    fn wlr_render_pass_submit(p: *mut wlr_render_pass) -> bool;
    fn wlr_buffer_begin_data_ptr_access(b: *mut wlr_buffer, flags: u32, data: *mut *mut c_void, format: *mut u32, stride: *mut usize) -> bool;
    fn wlr_buffer_end_data_ptr_access(b: *mut wlr_buffer);
    fn wlr_texture_from_pixels(r: *mut wlr_renderer, fmt: u32, stride: u32, w: u32, h: u32, data: *const c_void) -> *mut wlr_texture;
    fn wlr_texture_destroy(t: *mut wlr_texture);
    fn wlr_surface_has_buffer(s: *mut wlr_surface) -> bool;
    fn wlr_surface_get_texture(s: *mut wlr_surface) -> *mut wlr_texture;
    fn wlr_surface_for_each_surface(s: *mut wlr_surface, f: SurfaceIter, data: *mut c_void);
    fn wlr_surface_send_enter(s: *mut wlr_surface, o: *mut wlr_output);
    fn wlr_surface_send_leave(s: *mut wlr_surface, o: *mut wlr_output);
    fn wlr_surface_set_preferred_buffer_scale(s: *mut wlr_surface, scale: i32);
    fn wlr_presentation_surface_textured_on_output(s: *mut wlr_surface, o: *mut wlr_output);
    fn wlr_output_transform_invert(t: c_int) -> c_int;
}

/// wlroots' own logging: silent, or everything.
pub fn log(verbose: bool) {
    unsafe {
        if verbose { tw_log_verbose() } else { tw_log_silence() }
    }
}

/// wl_output_transform's inverse.
pub fn transform_invert(t: i32) -> i32 {
    unsafe { wlr_output_transform_invert(t) }
}

macro_rules! handle {
    ($(#[$m:meta])* $name:ident, $c:ident) => {
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub struct $name(NonNull<$c>);
        impl $name {
            #[allow(dead_code)] // not every handle is made from a pointer yet
            fn from_raw(p: *mut $c) -> Option<$name> {
                NonNull::new(p).map($name)
            }
            /// The address, as an identity (a map key, a log line).
            pub fn addr(self) -> usize {
                self.0.as_ptr() as usize
            }
        }
    };
}

handle!(EventLoop, wl_event_loop);
handle!(Backend, wlr_backend);
handle!(
    /// What owns the VT and the device descriptors on DRM.
    Session,
    wlr_session
);
handle!(Renderer, wlr_renderer);
handle!(Allocator, wlr_allocator);
handle!(Output, wlr_output);
handle!(Mode, wlr_output_mode);
handle!(Buffer, wlr_buffer);
handle!(Texture, wlr_texture);
handle!(Surface, wlr_surface);
handle!(InputDevice, wlr_input_device);
handle!(Timeline, wlr_drm_syncobj_timeline);

// MARK: listeners

struct Slot {
    f: Box<dyn FnMut(*mut c_void)>,
    running: bool,
    orphaned: bool,
}

extern "C" fn trampoline(ctx: *mut c_void, data: *mut c_void) {
    let slot = ctx as *mut Slot;
    unsafe {
        (*slot).running = true;
        ((*slot).f)(data);
        (*slot).running = false;
        // Dropped from inside its own callback (an output's destroy
        // listener, letting go of the output): the closure was still
        // running, so it is freed now that it is done.
        if (*slot).orphaned {
            drop(Box::from_raw(slot));
        }
    }
}

/// One wl_signal listener, carrying a closure. Dropping it detaches it,
/// and may be done from inside its own callback.
pub struct Listener {
    raw: *mut tw_listener,
    slot: *mut Slot,
}

impl Listener {
    fn attach(f: Box<dyn FnMut(*mut c_void)>, hook: impl FnOnce(Notify, *mut c_void) -> *mut tw_listener) -> Option<Listener> {
        let slot = Box::into_raw(Box::new(Slot { f, running: false, orphaned: false }));
        let raw = hook(trampoline, slot as *mut c_void);
        if raw.is_null() {
            drop(unsafe { Box::from_raw(slot) });
            return None;
        }
        Some(Listener { raw, slot })
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        unsafe {
            tw_listener_free(self.raw);
            if (*self.slot).running {
                (*self.slot).orphaned = true;
            } else {
                drop(Box::from_raw(self.slot));
            }
        }
    }
}

// MARK: the display and its event loop

/// A wl_display, the server's. Destroyed on drop, which destroys every
/// global and client on it: drop what listens to them first.
pub struct Display(NonNull<wl_display>);

impl Display {
    pub fn create() -> Option<Display> {
        NonNull::new(unsafe { wl_display_create() }).map(Display)
    }
    pub fn event_loop(&self) -> EventLoop {
        EventLoop::from_raw(unsafe { wl_display_get_event_loop(self.0.as_ptr()) }).expect("a display has a loop")
    }
    pub fn flush_clients(&self) {
        unsafe { wl_display_flush_clients(self.0.as_ptr()) }
    }
    pub fn destroy_clients(&self) {
        unsafe { wl_display_destroy_clients(self.0.as_ptr()) }
    }
    /// Listen on `$XDG_RUNTIME_DIR/name`; false if it could not.
    pub fn add_socket(&self, name: &str) -> bool {
        let Ok(n) = CString::new(name) else { return false };
        unsafe { wl_display_add_socket(self.0.as_ptr(), n.as_ptr()) == 0 }
    }
    /// The first free `wayland-N`, or None.
    pub fn add_socket_auto(&self) -> Option<String> {
        let p = unsafe { wl_display_add_socket_auto(self.0.as_ptr()) };
        (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
    }
    pub fn raw(&self) -> *mut c_void {
        self.0.as_ptr() as *mut c_void
    }
}

impl Drop for Display {
    fn drop(&mut self) {
        unsafe { wl_display_destroy(self.0.as_ptr()) }
    }
}

pub const READABLE: u32 = 0x01;

/// An event source on the loop: a descriptor or a timer, removed on drop.
pub struct Source {
    raw: *mut wl_event_source,
    f: *mut Box<dyn FnMut()>,
}

extern "C" fn fd_ready(_fd: c_int, _mask: u32, data: *mut c_void) -> c_int {
    unsafe { (*(data as *mut Box<dyn FnMut()>))() };
    0
}

extern "C" fn timer_fired(data: *mut c_void) -> c_int {
    unsafe { (*(data as *mut Box<dyn FnMut()>))() };
    0
}

impl Source {
    /// Arm a timer to fire in `ms` (0 disarms it).
    pub fn arm(&self, ms: i32) {
        unsafe { wl_event_source_timer_update(self.raw, ms) };
    }
}

impl Drop for Source {
    fn drop(&mut self) {
        unsafe {
            wl_event_source_remove(self.raw);
            drop(Box::from_raw(self.f));
        }
    }
}

impl EventLoop {
    /// Dispatch, blocking at most `timeout_ms` (-1: indefinitely, 0: not at all).
    pub fn dispatch(self, timeout_ms: i32) {
        unsafe { wl_event_loop_dispatch(self.0.as_ptr(), timeout_ms) };
    }
    /// Call `f` whenever `fd` is readable.
    pub fn add_fd(self, fd: i32, f: impl FnMut() + 'static) -> Option<Source> {
        let f: *mut Box<dyn FnMut()> = Box::into_raw(Box::new(Box::new(f)));
        let raw = unsafe { wl_event_loop_add_fd(self.0.as_ptr(), fd, READABLE, fd_ready, f as *mut c_void) };
        Self::source(raw, f)
    }
    /// A timer, disarmed until `arm`.
    pub fn add_timer(self, f: impl FnMut() + 'static) -> Option<Source> {
        let f: *mut Box<dyn FnMut()> = Box::into_raw(Box::new(Box::new(f)));
        let raw = unsafe { wl_event_loop_add_timer(self.0.as_ptr(), timer_fired, f as *mut c_void) };
        Self::source(raw, f)
    }
    fn source(raw: *mut wl_event_source, f: *mut Box<dyn FnMut()>) -> Option<Source> {
        if raw.is_null() {
            drop(unsafe { Box::from_raw(f) });
            return None;
        }
        Some(Source { raw, f })
    }
}

// MARK: the backend

impl Backend {
    /// Outputs we invent, at sizes we choose.
    pub fn headless(l: EventLoop) -> Option<Backend> {
        Backend::from_raw(unsafe { wlr_headless_backend_create(l.0.as_ptr()) })
    }
    /// Whatever this machine is (DRM, nested Wayland, X11), and the session
    /// when the backend needed one.
    pub fn autocreate(l: EventLoop) -> Option<(Backend, Option<Session>)> {
        let mut s = std::ptr::null_mut();
        let b = Backend::from_raw(unsafe { wlr_backend_autocreate(l.0.as_ptr(), &mut s) })?;
        Some((b, Session::from_raw(s)))
    }
    pub fn start(self) -> bool {
        unsafe { wlr_backend_start(self.0.as_ptr()) }
    }
    pub fn destroy(self) {
        unsafe { wlr_backend_destroy(self.0.as_ptr()) }
    }
    /// A headless backend's new output; it is announced through `new_output`.
    pub fn headless_add_output(self, w: u32, h: u32) -> Option<Output> {
        Output::from_raw(unsafe { wlr_headless_add_output(self.0.as_ptr(), w, h) })
    }
    pub fn renderer(self) -> Option<Renderer> {
        Renderer::from_raw(unsafe { wlr_renderer_autocreate(self.0.as_ptr()) })
    }
    pub fn allocator(self, r: Renderer) -> Option<Allocator> {
        Allocator::from_raw(unsafe { wlr_allocator_autocreate(self.0.as_ptr(), r.0.as_ptr()) })
    }
    pub fn on_new_output(self, mut f: impl FnMut(Output) + 'static) -> Option<Listener> {
        let p = self.0.as_ptr();
        Listener::attach(Box::new(move |d| { if let Some(o) = Output::from_raw(d as *mut _) { f(o) } }), |n, c| unsafe { tw_backend_on_new_output(p, n, c) })
    }
    pub fn on_new_input(self, mut f: impl FnMut(InputDevice) + 'static) -> Option<Listener> {
        let p = self.0.as_ptr();
        Listener::attach(Box::new(move |d| { if let Some(i) = InputDevice::from_raw(d as *mut _) { f(i) } }), |n, c| unsafe { tw_backend_on_new_input(p, n, c) })
    }
}

impl Session {
    pub fn change_vt(self, vt: u32) -> bool {
        unsafe { wlr_session_change_vt(self.0.as_ptr(), vt) }
    }
}

impl Renderer {
    pub fn destroy(self) {
        unsafe { wlr_renderer_destroy(self.0.as_ptr()) }
    }
    /// A texture from `h` rows of `stride` bytes in DRM `format`.
    pub fn texture_from_pixels(self, format: u32, stride: u32, w: u32, h: u32, pixels: &[u8]) -> Option<Texture> {
        if (pixels.len() as u64) < stride as u64 * h as u64 {
            return None;
        }
        Texture::from_raw(unsafe { wlr_texture_from_pixels(self.0.as_ptr(), format, stride, w, h, pixels.as_ptr() as *const c_void) })
    }
}

impl Allocator {
    pub fn destroy(self) {
        unsafe { wlr_allocator_destroy(self.0.as_ptr()) }
    }
}

impl Texture {
    /// Only a texture undertow made (`texture_from_pixels`).
    pub fn destroy(self) {
        unsafe { wlr_texture_destroy(self.0.as_ptr()) }
    }
}

// MARK: outputs

/// A wlr_output_state, on the heap (Rust cannot size one).
pub struct OutputState(NonNull<wlr_output_state>);

impl OutputState {
    pub fn new() -> OutputState {
        OutputState(NonNull::new(unsafe { tw_output_state_new() }).expect("out of memory"))
    }
    pub fn set_enabled(&mut self, on: bool) {
        unsafe { wlr_output_state_set_enabled(self.0.as_ptr(), on) }
    }
    pub fn set_custom_mode(&mut self, w: i32, h: i32, refresh_mhz: i32) {
        unsafe { wlr_output_state_set_custom_mode(self.0.as_ptr(), w, h, refresh_mhz) }
    }
    pub fn set_mode(&mut self, m: Mode) {
        unsafe { wlr_output_state_set_mode(self.0.as_ptr(), m.0.as_ptr()) }
    }
    /// The buffer a render pass left here.
    pub fn buffer(&self) -> Option<Buffer> {
        Buffer::from_raw(unsafe { tw_output_state_buffer(self.0.as_ptr()) })
    }
}

impl Default for OutputState {
    fn default() -> OutputState {
        OutputState::new()
    }
}

impl Drop for OutputState {
    fn drop(&mut self) {
        unsafe { tw_output_state_free(self.0.as_ptr()) }
    }
}

/// A render pass into an output state's buffer: add to it, then submit.
pub struct RenderPass(NonNull<wlr_render_pass>);

impl RenderPass {
    pub fn add_rect(&mut self, r: &RectDraw) {
        unsafe { tw_pass_add_rect(self.0.as_ptr(), r) }
    }
    pub fn add_texture(&mut self, d: &TextureDraw) {
        unsafe { tw_pass_add_texture(self.0.as_ptr(), d) }
    }
    pub fn submit(self) -> bool {
        unsafe { wlr_render_pass_submit(self.0.as_ptr()) }
    }
}

impl Output {
    pub fn name(self) -> String {
        let p = unsafe { tw_output_name(self.0.as_ptr()) };
        if p.is_null() { String::new() } else { unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned() }
    }
    pub fn width(self) -> i32 {
        unsafe { tw_output_width(self.0.as_ptr()) }
    }
    pub fn height(self) -> i32 {
        unsafe { tw_output_height(self.0.as_ptr()) }
    }
    /// mHz; 0 with no mode.
    pub fn refresh(self) -> i32 {
        unsafe { tw_output_refresh(self.0.as_ptr()) }
    }
    pub fn commit_seq(self) -> u32 {
        unsafe { tw_output_commit_seq(self.0.as_ptr()) }
    }
    pub fn scale(self) -> f32 {
        unsafe { tw_output_scale(self.0.as_ptr()) }
    }
    pub fn transform(self) -> i32 {
        unsafe { tw_output_transform(self.0.as_ptr()) }
    }
    pub fn enabled(self) -> bool {
        unsafe { tw_output_enabled(self.0.as_ptr()) }
    }
    pub fn init_render(self, a: Allocator, r: Renderer) -> bool {
        unsafe { wlr_output_init_render(self.0.as_ptr(), a.0.as_ptr(), r.0.as_ptr()) }
    }
    pub fn commit(self, s: &OutputState) -> bool {
        unsafe { wlr_output_commit_state(self.0.as_ptr(), s.0.as_ptr()) }
    }
    /// Advertise it to clients as a wl_output.
    pub fn create_global(self, d: &Display) {
        unsafe { wlr_output_create_global(self.0.as_ptr(), d.0.as_ptr()) }
    }
    pub fn destroy(self) {
        unsafe { wlr_output_destroy(self.0.as_ptr()) }
    }
    pub fn set_name(self, name: &str) {
        if let Ok(n) = CString::new(name) {
            unsafe { wlr_output_set_name(self.0.as_ptr(), n.as_ptr()) }
        }
    }
    pub fn preferred_mode(self) -> Option<Mode> {
        Mode::from_raw(unsafe { wlr_output_preferred_mode(self.0.as_ptr()) })
    }
    /// Which backend it landed on: drm, nested-wayland, nested-x11, headless.
    pub fn backend_name(self) -> String {
        unsafe { CStr::from_ptr(tw_output_backend_name(self.0.as_ptr())) }.to_string_lossy().into_owned()
    }
    /// A pass into the buffer `state` will commit.
    pub fn begin_render_pass(self, state: &mut OutputState) -> Option<RenderPass> {
        NonNull::new(unsafe { wlr_output_begin_render_pass(self.0.as_ptr(), state.0.as_ptr(), std::ptr::null_mut()) }).map(RenderPass)
    }
    pub fn on_destroy(self, mut f: impl FnMut(Output) + 'static) -> Option<Listener> {
        let p = self.0.as_ptr();
        Listener::attach(Box::new(move |d| { if let Some(o) = Output::from_raw(d as *mut _) { f(o) } }), |n, c| unsafe { tw_output_on_destroy(p, n, c) })
    }
    pub fn on_present(self, mut f: impl FnMut(Present) + 'static) -> Option<Listener> {
        let p = self.0.as_ptr();
        Listener::attach(
            Box::new(move |d| {
                let mut e = Present::default();
                if !d.is_null() {
                    unsafe { tw_present_read(d, &mut e) };
                    f(e)
                }
            }),
            |n, c| unsafe { tw_output_on_present(p, n, c) },
        )
    }
    pub fn on_needs_frame(self, mut f: impl FnMut() + 'static) -> Option<Listener> {
        let p = self.0.as_ptr();
        Listener::attach(Box::new(move |_| f()), |n, c| unsafe { tw_output_on_needs_frame(p, n, c) })
    }
    pub fn on_frame(self, mut f: impl FnMut() + 'static) -> Option<Listener> {
        let p = self.0.as_ptr();
        Listener::attach(Box::new(move |_| f()), |n, c| unsafe { tw_output_on_frame(p, n, c) })
    }
}

impl Buffer {
    /// Read the buffer's first `rows` rows on the CPU: `f(bytes, DRM format,
    /// stride)`. None if it is not CPU-readable (not shm-backed).
    pub fn read<T>(self, rows: usize, f: impl FnOnce(&[u8], u32, usize) -> T) -> Option<T> {
        const READ: u32 = 1 << 0;
        let (mut data, mut fmt, mut stride) = (std::ptr::null_mut(), 0u32, 0usize);
        if !unsafe { wlr_buffer_begin_data_ptr_access(self.0.as_ptr(), READ, &mut data, &mut fmt, &mut stride) } || data.is_null() {
            return None;
        }
        let bytes = unsafe { std::slice::from_raw_parts(data as *const u8, stride * rows) };
        let out = f(bytes, fmt, stride);
        unsafe { wlr_buffer_end_data_ptr_access(self.0.as_ptr()) };
        Some(out)
    }
}

// MARK: surfaces

impl Surface {
    pub fn width(self) -> i32 {
        unsafe { tw_surface_width(self.0.as_ptr()) }
    }
    pub fn height(self) -> i32 {
        unsafe { tw_surface_height(self.0.as_ptr()) }
    }
    /// The committed state's sequence number: bumped by every commit.
    pub fn seq(self) -> u32 {
        unsafe { tw_surface_seq(self.0.as_ptr()) }
    }
    pub fn transform(self) -> i32 {
        unsafe { tw_surface_transform(self.0.as_ptr()) }
    }
    /// The part of the buffer shown: x, y, width, height.
    pub fn source_box(self) -> [f64; 4] {
        let mut b = [0.0; 4];
        unsafe { tw_surface_source_box(self.0.as_ptr(), b.as_mut_ptr()) };
        b
    }
    pub fn has_buffer(self) -> bool {
        unsafe { wlr_surface_has_buffer(self.0.as_ptr()) }
    }
    pub fn texture(self) -> Option<Texture> {
        Texture::from_raw(unsafe { wlr_surface_get_texture(self.0.as_ptr()) })
    }
    /// Each surface in the tree (subsurfaces included) with its offset.
    pub fn for_each_surface(self, mut f: impl FnMut(Surface, i32, i32)) {
        extern "C" fn each(s: *mut wlr_surface, sx: c_int, sy: c_int, data: *mut c_void) {
            let f = unsafe { &mut *(data as *mut &mut dyn FnMut(Surface, i32, i32)) };
            if let Some(s) = Surface::from_raw(s) {
                f(s, sx, sy)
            }
        }
        let mut dynf: &mut dyn FnMut(Surface, i32, i32) = &mut f;
        unsafe { wlr_surface_for_each_surface(self.0.as_ptr(), each, &mut dynf as *mut _ as *mut c_void) }
    }
    pub fn send_enter(self, o: Output) {
        unsafe { wlr_surface_send_enter(self.0.as_ptr(), o.0.as_ptr()) }
    }
    pub fn send_leave(self, o: Output) {
        unsafe { wlr_surface_send_leave(self.0.as_ptr(), o.0.as_ptr()) }
    }
    pub fn set_preferred_buffer_scale(self, scale: i32) {
        unsafe { wlr_surface_set_preferred_buffer_scale(self.0.as_ptr(), scale) }
    }
    /// Tell wp_presentation this surface was shown on `o`.
    pub fn textured_on_output(self, o: Output) {
        unsafe { wlr_presentation_surface_textured_on_output(self.0.as_ptr(), o.0.as_ptr()) }
    }
}

#[cfg(test)]
#[path = "wlr_tests.rs"]
mod tests;
