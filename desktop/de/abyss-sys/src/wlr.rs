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
opaque!(wlr_xdg_decoration_manager_v1, wlr_xdg_toplevel_decoration_v1);
opaque!(wlr_session_lock_manager_v1, wlr_session_lock_v1, wlr_session_lock_surface_v1);
opaque!(wlr_text_input_manager_v3, wlr_input_method_manager_v2, wlr_text_input_v3, wlr_input_method_v2, wlr_input_method_keyboard_grab_v2, wlr_input_popup_surface_v2);
opaque!(wlr_relative_pointer_manager_v1, wlr_pointer_constraints_v1, wlr_pointer_constraint_v1);
opaque!(wlr_pointer, wlr_keyboard, wlr_drag_icon, wlr_cursor_shape_manager_v1, wlr_virtual_pointer_manager_v1, wlr_virtual_keyboard_manager_v1);
opaque!(wlr_output_manager_v1, wlr_output_configuration_v1, wlr_output_configuration_head_v1, wlr_idle_inhibit_manager_v1, wlr_idle_inhibitor_v1, wlr_idle_notifier_v1, wlr_seat);

/// tw-access.h's `struct tw_motion`: a relative motion.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Motion {
    pub time_msec: u32,
    pub dx: f64,
    pub dy: f64,
    pub unaccel_dx: f64,
    pub unaccel_dy: f64,
}

/// A button or key: when, which, and whether pressed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Press {
    pub time_msec: u32,
    pub code: u32,
    pub pressed: bool,
}

/// tw-access.h's `struct tw_head_ask`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct HeadAsk {
    output: *mut wlr_output,
    pub enabled: bool,
    pub mode_width: i32,
    pub mode_height: i32,
    pub refresh_mhz: i32,
    pub x: i32,
    pub y: i32,
    pub scale: f64,
}

impl HeadAsk {
    pub fn output(&self) -> Option<Output> {
        Output::from_raw(self.output)
    }
}
opaque!(wlr_compositor, wlr_xdg_shell, wlr_xdg_toplevel, wlr_xdg_popup, wlr_layer_shell_v1, wlr_layer_surface_v1, wlr_foreign_toplevel_manager_v1, wlr_foreign_toplevel_handle_v1, wlr_xdg_activation_v1, wlr_output_layout);

/// tw-access.h's `struct tw_layer_request`: what a layer surface asks for.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LayerRequestRaw {
    pub anchor: u32,
    pub desired_width: u32,
    pub desired_height: u32,
    pub margin_top: i32,
    pub margin_right: i32,
    pub margin_bottom: i32,
    pub margin_left: i32,
    pub exclusive_zone: i32,
}

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
    fn wlr_pixman_renderer_create() -> *mut wlr_renderer;
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

    fn tw_compositor_on_new_surface(o: *mut wlr_compositor, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_surface_on_map(o: *mut wlr_surface, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_surface_on_unmap(o: *mut wlr_surface, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_surface_on_commit(o: *mut wlr_surface, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_surface_on_destroy(o: *mut wlr_surface, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_shell_on_new_toplevel(o: *mut wlr_xdg_shell, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_shell_on_new_popup(o: *mut wlr_xdg_shell, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_toplevel_on_destroy(o: *mut wlr_xdg_toplevel, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_toplevel_on_request_move(o: *mut wlr_xdg_toplevel, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_toplevel_on_request_resize(o: *mut wlr_xdg_toplevel, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_toplevel_on_request_maximize(o: *mut wlr_xdg_toplevel, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_toplevel_on_request_minimize(o: *mut wlr_xdg_toplevel, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_toplevel_on_request_fullscreen(o: *mut wlr_xdg_toplevel, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_toplevel_on_set_title(o: *mut wlr_xdg_toplevel, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_toplevel_on_set_app_id(o: *mut wlr_xdg_toplevel, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_popup_on_destroy(o: *mut wlr_xdg_popup, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_layer_shell_v1_on_new_surface(o: *mut wlr_layer_shell_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_layer_surface_v1_on_destroy(o: *mut wlr_layer_surface_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_foreign_toplevel_handle_v1_on_request_activate(o: *mut wlr_foreign_toplevel_handle_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_foreign_toplevel_handle_v1_on_request_close(o: *mut wlr_foreign_toplevel_handle_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_foreign_toplevel_handle_v1_on_request_minimize(o: *mut wlr_foreign_toplevel_handle_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_foreign_toplevel_handle_v1_on_request_maximize(o: *mut wlr_foreign_toplevel_handle_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_decoration_manager_v1_on_new_toplevel_decoration(o: *mut wlr_xdg_decoration_manager_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_xdg_toplevel_decoration_v1_on_destroy(o: *mut wlr_xdg_toplevel_decoration_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_decoration_toplevel(d: *const wlr_xdg_toplevel_decoration_v1) -> *mut wlr_xdg_toplevel;
    fn tw_decoration_server_side(d: *mut wlr_xdg_toplevel_decoration_v1);
    fn wlr_xdg_decoration_manager_v1_create(d: *mut wl_display) -> *mut wlr_xdg_decoration_manager_v1;
    fn tw_session_lock_manager_v1_on_new_lock(o: *mut wlr_session_lock_manager_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_session_lock_v1_on_new_surface(o: *mut wlr_session_lock_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_session_lock_v1_on_unlock(o: *mut wlr_session_lock_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_session_lock_v1_on_destroy(o: *mut wlr_session_lock_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_session_lock_surface_v1_on_destroy(o: *mut wlr_session_lock_surface_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_session_lock_manager_global(m: *const wlr_session_lock_manager_v1) -> *const c_void;
    fn tw_lock_surface_surface(s: *const wlr_session_lock_surface_v1) -> *mut wlr_surface;
    fn tw_lock_surface_output(s: *const wlr_session_lock_surface_v1) -> *mut wlr_output;
    fn tw_text_input_manager_v3_on_new_text_input(o: *mut wlr_text_input_manager_v3, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_input_method_manager_v2_on_new_input_method(o: *mut wlr_input_method_manager_v2, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_text_input_v3_on_enable(o: *mut wlr_text_input_v3, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_text_input_v3_on_commit(o: *mut wlr_text_input_v3, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_text_input_v3_on_disable(o: *mut wlr_text_input_v3, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_text_input_v3_on_destroy(o: *mut wlr_text_input_v3, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_input_method_v2_on_commit(o: *mut wlr_input_method_v2, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_input_method_v2_on_grab_keyboard(o: *mut wlr_input_method_v2, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_input_method_v2_on_new_popup_surface(o: *mut wlr_input_method_v2, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_input_method_v2_on_destroy(o: *mut wlr_input_method_v2, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_input_method_keyboard_grab_v2_on_destroy(o: *mut wlr_input_method_keyboard_grab_v2, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_input_popup_surface_v2_on_destroy(o: *mut wlr_input_popup_surface_v2, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_seat_on_keyboard_focus_change(o: *mut wlr_seat, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_keyboard_focus_new_surface(e: *const c_void) -> *mut wlr_surface;
    fn tw_text_input_focused(t: *const wlr_text_input_v3) -> *mut wlr_surface;
    fn tw_text_input_enabled(t: *const wlr_text_input_v3) -> bool;
    fn tw_text_input_same_client(t: *const wlr_text_input_v3, s: *mut wlr_surface) -> bool;
    fn tw_text_input_cursor(t: *const wlr_text_input_v3, out: *mut i32);
    fn tw_text_input_send_state(t: *mut wlr_text_input_v3, im: *mut wlr_input_method_v2);
    fn tw_input_method_relay(im: *mut wlr_input_method_v2, t: *mut wlr_text_input_v3, pre: *mut usize, com: *mut usize);
    fn tw_text_input_clear_preedit(t: *mut wlr_text_input_v3);
    fn tw_keyboard_from_method(k: *mut wlr_keyboard, im: *const wlr_input_method_v2) -> bool;
    fn tw_grab_send_modifiers(g: *mut wlr_input_method_keyboard_grab_v2, k: *mut wlr_keyboard);
    fn tw_input_popup_surface(p: *const wlr_input_popup_surface_v2) -> *mut wlr_surface;
    fn tw_input_popup_send_rectangle(p: *mut wlr_input_popup_surface_v2, r: *const i32);
    fn wlr_text_input_manager_v3_create(d: *mut wl_display) -> *mut wlr_text_input_manager_v3;
    fn wlr_input_method_manager_v2_create(d: *mut wl_display) -> *mut wlr_input_method_manager_v2;
    fn wlr_text_input_v3_send_enter(t: *mut wlr_text_input_v3, s: *mut wlr_surface);
    fn wlr_text_input_v3_send_leave(t: *mut wlr_text_input_v3);
    fn wlr_input_method_v2_send_activate(im: *mut wlr_input_method_v2);
    fn wlr_input_method_v2_send_deactivate(im: *mut wlr_input_method_v2);
    fn wlr_input_method_v2_send_done(im: *mut wlr_input_method_v2);
    fn wlr_input_method_v2_send_unavailable(im: *mut wlr_input_method_v2);
    fn wlr_input_method_keyboard_grab_v2_set_keyboard(g: *mut wlr_input_method_keyboard_grab_v2, k: *mut wlr_keyboard);
    fn wlr_input_method_keyboard_grab_v2_send_key(g: *mut wlr_input_method_keyboard_grab_v2, time: u32, key: u32, state: u32);
    fn tw_pointer_constraints_v1_on_new_constraint(o: *mut wlr_pointer_constraints_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_pointer_constraint_v1_on_set_region(o: *mut wlr_pointer_constraint_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_pointer_constraint_v1_on_destroy(o: *mut wlr_pointer_constraint_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_seat_pointer_focused(s: *const wlr_seat, sx: *mut f64, sy: *mut f64) -> *mut wlr_surface;
    fn tw_relative_motion(m: *mut wlr_relative_pointer_manager_v1, s: *mut wlr_seat, t: u32, dx: f64, dy: f64, udx: f64, udy: f64);
    fn tw_constraint_locked(c: *const wlr_pointer_constraint_v1) -> bool;
    fn tw_constraint_surface(c: *const wlr_pointer_constraint_v1) -> *mut wlr_surface;
    fn tw_constraint_contains(c: *mut wlr_pointer_constraint_v1, x: f64, y: f64) -> bool;
    fn tw_constraint_nearest(c: *mut wlr_pointer_constraint_v1, x: f64, y: f64, nx: *mut f64, ny: *mut f64) -> bool;
    fn tw_constraint_hint(c: *const wlr_pointer_constraint_v1, x: *mut f64, y: *mut f64) -> bool;
    fn wlr_relative_pointer_manager_v1_create(d: *mut wl_display) -> *mut wlr_relative_pointer_manager_v1;
    fn wlr_pointer_constraints_v1_create(d: *mut wl_display) -> *mut wlr_pointer_constraints_v1;
    fn wlr_pointer_constraints_v1_constraint_for_surface(m: *mut wlr_pointer_constraints_v1, s: *mut wlr_surface, seat: *mut wlr_seat) -> *mut wlr_pointer_constraint_v1;
    fn wlr_pointer_constraint_v1_send_activated(c: *mut wlr_pointer_constraint_v1);
    fn wlr_pointer_constraint_v1_send_deactivated(c: *mut wlr_pointer_constraint_v1);
    fn tw_seat_on_request_set_selection(o: *mut wlr_seat, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_seat_on_request_set_primary_selection(o: *mut wlr_seat, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_seat_on_request_start_drag(o: *mut wlr_seat, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_seat_on_start_drag(o: *mut wlr_seat, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_seat_on_request_set_cursor(o: *mut wlr_seat, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_seat_on_pointer_focus_change(o: *mut wlr_seat, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_cursor_shape_manager_v1_on_request_set_shape(o: *mut wlr_cursor_shape_manager_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_virtual_pointer_manager_v1_on_new_virtual_pointer(o: *mut wlr_virtual_pointer_manager_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_virtual_keyboard_manager_v1_on_new_virtual_keyboard(o: *mut wlr_virtual_keyboard_manager_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_pointer_on_motion(o: *mut wlr_pointer, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_pointer_on_motion_absolute(o: *mut wlr_pointer, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_pointer_on_button(o: *mut wlr_pointer, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_pointer_on_axis(o: *mut wlr_pointer, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_keyboard_on_key(o: *mut wlr_keyboard, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_keyboard_on_modifiers(o: *mut wlr_keyboard, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_input_device_on_destroy(o: *mut wlr_input_device, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_drag_icon_on_destroy(o: *mut wlr_drag_icon, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_pointer_motion_read(e: *const c_void, out: *mut Motion);
    fn tw_pointer_motion_absolute_read(e: *const c_void, t: *mut u32, x: *mut f64, y: *mut f64);
    fn tw_pointer_button_read(e: *const c_void, t: *mut u32, b: *mut u32, p: *mut u32);
    fn tw_seat_pointer_axis(s: *mut wlr_seat, e: *const c_void);
    fn tw_keyboard_key_read(e: *const c_void, t: *mut u32, k: *mut u32, p: *mut u32);
    fn tw_input_device_kind(d: *const wlr_input_device) -> c_int;
    fn tw_input_device_pointer(d: *mut wlr_input_device) -> *mut wlr_pointer;
    fn tw_input_device_keyboard(d: *mut wlr_input_device) -> *mut wlr_keyboard;
    fn tw_pointer_device(p: *mut wlr_pointer) -> *mut wlr_input_device;
    fn tw_keyboard_device(k: *mut wlr_keyboard) -> *mut wlr_input_device;
    fn tw_input_device_name(d: *const wlr_input_device) -> *const c_char;
    fn tw_virtual_pointer_from_event(e: *const c_void) -> *mut wlr_pointer;
    fn tw_virtual_keyboard_keyboard(v: *mut c_void) -> *mut wlr_keyboard;
    fn tw_seat_keyboard_enter(s: *mut wlr_seat, sf: *mut wlr_surface) -> bool;
    fn tw_seat_keyboard_modifiers(s: *mut wlr_seat, k: *mut wlr_keyboard);
    fn tw_seat_keyboard_focused(s: *const wlr_seat) -> *mut wlr_surface;
    fn tw_seat_pointer_focused_client(s: *const wlr_seat) -> *const c_void;
    fn tw_seat_break_grabs(s: *mut wlr_seat, lock: *mut wlr_surface) -> c_int;
    fn tw_seat_accept_selection(s: *mut wlr_seat, e: *const c_void, primary: bool);
    fn tw_seat_accept_drag(s: *mut wlr_seat, e: *const c_void) -> bool;
    fn tw_drag_icon(d: *const c_void) -> *mut wlr_drag_icon;
    fn tw_drag_icon_surface(i: *const wlr_drag_icon) -> *mut wlr_surface;
    fn tw_set_cursor_read(e: *const c_void, s: *mut *mut wlr_surface, hx: *mut i32, hy: *mut i32) -> *const c_void;
    fn tw_set_shape_read(e: *const c_void, client: *mut *const c_void) -> *const c_char;
    fn tw_pointer_focus_changed(e: *const c_void) -> bool;
    fn tw_surface_offset(s: *const wlr_surface, dx: *mut i32, dy: *mut i32);
    fn tw_keyboard_give_keymap(k: *mut wlr_keyboard, layout: *const c_char, variant: *const c_char) -> c_int;
    fn tw_keyboard_set_layout(k: *mut wlr_keyboard, layout: *const c_char, variant: *const c_char) -> bool;
    fn tw_keymap_compiles(layout: *const c_char, variant: *const c_char) -> bool;
    fn tw_keyboard_layout_name(k: *const wlr_keyboard) -> *const c_char;
    fn tw_keyboard_modifiers(k: *mut wlr_keyboard) -> u32;
    fn tw_keyboard_syms(k: *mut wlr_keyboard, code: u32, out: *mut u32, max: usize) -> usize;
    fn tw_keysym_from_name(name: *const c_char) -> u32;
    fn tw_stand_in_keyboard_create() -> *mut wlr_keyboard;
    fn tw_stand_in_keyboard_key(k: *mut wlr_keyboard, code: u32, pressed: bool, time: u32);
    fn wlr_seat_create(d: *mut wl_display, name: *const c_char) -> *mut wlr_seat;
    fn wlr_seat_set_capabilities(s: *mut wlr_seat, caps: u32);
    fn wlr_seat_set_keyboard(s: *mut wlr_seat, k: *mut wlr_keyboard);
    fn wlr_seat_keyboard_notify_clear_focus(s: *mut wlr_seat);
    fn wlr_seat_keyboard_notify_key(s: *mut wlr_seat, time: u32, key: u32, state: u32);
    fn wlr_seat_pointer_notify_enter(s: *mut wlr_seat, sf: *mut wlr_surface, sx: f64, sy: f64);
    fn wlr_seat_pointer_notify_motion(s: *mut wlr_seat, time: u32, sx: f64, sy: f64);
    fn wlr_seat_pointer_notify_button(s: *mut wlr_seat, time: u32, button: u32, state: u32) -> u32;
    fn wlr_seat_pointer_notify_frame(s: *mut wlr_seat);
    fn wlr_seat_pointer_clear_focus(s: *mut wlr_seat);
    fn wlr_seat_pointer_warp(s: *mut wlr_seat, sx: f64, sy: f64);
    fn wlr_surface_surface_at(s: *mut wlr_surface, sx: f64, sy: f64, sub_x: *mut f64, sub_y: *mut f64) -> *mut wlr_surface;
    fn wlr_virtual_pointer_manager_v1_create(d: *mut wl_display) -> *mut wlr_virtual_pointer_manager_v1;
    fn wlr_virtual_keyboard_manager_v1_create(d: *mut wl_display) -> *mut wlr_virtual_keyboard_manager_v1;
    fn wlr_cursor_shape_manager_v1_create(d: *mut wl_display, version: u32) -> *mut wlr_cursor_shape_manager_v1;
    fn wlr_primary_selection_v1_device_manager_create(d: *mut wl_display) -> *mut c_void;
    fn tw_output_manager_v1_on_apply(o: *mut wlr_output_manager_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_output_manager_v1_on_test(o: *mut wlr_output_manager_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_idle_inhibit_manager_v1_on_new_inhibitor(o: *mut wlr_idle_inhibit_manager_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_idle_inhibitor_v1_on_destroy(o: *mut wlr_idle_inhibitor_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;
    fn tw_head_read(h: *const wlr_output_configuration_head_v1, out: *mut HeadAsk);
    fn tw_head_try(h: *mut wlr_output_configuration_head_v1, commit: bool) -> bool;
    fn tw_output_manager_publish(m: *mut wlr_output_manager_v1, outputs: *mut *mut wlr_output, x: *const i32, y: *const i32, scale: *const f64, n: usize);
    fn tw_output_state_set_scale(s: *mut wlr_output_state, scale: f64);
    fn tw_output_config_heads(c: *mut wlr_output_configuration_v1, out: *mut *mut wlr_output_configuration_head_v1, max: usize) -> usize;
    fn tw_idle_inhibitor_surface(i: *const wlr_idle_inhibitor_v1) -> *mut wlr_surface;
    fn wlr_output_manager_v1_create(d: *mut wl_display) -> *mut wlr_output_manager_v1;
    fn wlr_output_configuration_v1_send_succeeded(c: *mut wlr_output_configuration_v1);
    fn wlr_output_configuration_v1_send_failed(c: *mut wlr_output_configuration_v1);
    fn wlr_output_configuration_v1_destroy(c: *mut wlr_output_configuration_v1);
    fn wlr_idle_inhibit_v1_create(d: *mut wl_display) -> *mut wlr_idle_inhibit_manager_v1;
    fn wlr_idle_notifier_v1_create(d: *mut wl_display) -> *mut wlr_idle_notifier_v1;
    fn wlr_idle_notifier_v1_notify_activity(n: *mut wlr_idle_notifier_v1, s: *mut wlr_seat);
    fn wlr_idle_notifier_v1_set_inhibited(n: *mut wlr_idle_notifier_v1, on: bool);
    fn wlr_surface_get_root_surface(s: *mut wlr_surface) -> *mut wlr_surface;
    fn wlr_fractional_scale_v1_notify_scale(s: *mut wlr_surface, scale: f64);
    fn tw_syncobj_unsupported(r: *const wlr_renderer, b: *const wlr_backend) -> c_int;
    fn tw_syncobj_create(d: *mut wl_display, r: *mut wlr_renderer) -> bool;
    fn tw_syncobj_arm_release(s: *mut wlr_surface) -> bool;
    fn tw_syncobj_acquire(s: *mut wlr_surface, t: *mut *mut wlr_drm_syncobj_timeline, point: *mut u64) -> bool;
    fn wlr_session_lock_manager_v1_create(d: *mut wl_display) -> *mut wlr_session_lock_manager_v1;
    fn wlr_session_lock_v1_destroy(l: *mut wlr_session_lock_v1);
    fn wlr_session_lock_v1_send_locked(l: *mut wlr_session_lock_v1);
    fn wlr_session_lock_surface_v1_configure(s: *mut wlr_session_lock_surface_v1, w: u32, h: u32) -> u32;
    fn tw_xdg_activation_v1_on_request_activate(o: *mut wlr_xdg_activation_v1, f: Notify, ctx: *mut c_void) -> *mut tw_listener;

    fn tw_surface_committed_buffer(s: *const wlr_surface) -> bool;
    fn tw_surface_frame_done_tree(s: *mut wlr_surface);
    fn tw_surface_client_pid(s: *mut wlr_surface) -> c_int;
    fn tw_xdg_toplevel_surface(t: *const wlr_xdg_toplevel) -> *mut wlr_surface;
    fn tw_xdg_toplevel_app_id(t: *const wlr_xdg_toplevel) -> *const c_char;
    fn tw_xdg_toplevel_title(t: *const wlr_xdg_toplevel) -> *const c_char;
    fn tw_xdg_toplevel_initial_commit(t: *const wlr_xdg_toplevel) -> bool;
    fn tw_xdg_toplevel_initialized(t: *const wlr_xdg_toplevel) -> bool;
    fn tw_xdg_toplevel_requested(t: *const wlr_xdg_toplevel) -> u32;
    fn tw_xdg_toplevel_geometry(t: *const wlr_xdg_toplevel, out: *mut i32);
    fn tw_xdg_resize_edges(e: *const c_void) -> u32;
    fn tw_xdg_toplevel_offer_capabilities(t: *mut wlr_xdg_toplevel);
    fn tw_xdg_popup_surface(p: *const wlr_xdg_popup) -> *mut wlr_surface;
    fn tw_xdg_popup_parent(p: *const wlr_xdg_popup) -> *mut wlr_surface;
    fn tw_xdg_popup_initial_commit(p: *const wlr_xdg_popup) -> bool;
    fn tw_xdg_popup_geometry(p: *const wlr_xdg_popup, out: *mut i32);
    fn tw_xdg_popup_unconstrain(p: *mut wlr_xdg_popup, x: i32, y: i32, w: i32, h: i32);
    fn tw_layer_surface(l: *const wlr_layer_surface_v1) -> *mut wlr_surface;
    fn tw_layer_namespace(l: *const wlr_layer_surface_v1) -> *const c_char;
    fn tw_layer_layer(l: *const wlr_layer_surface_v1) -> u32;
    fn tw_layer_keyboard_interactive(l: *const wlr_layer_surface_v1) -> u32;
    fn tw_layer_request_read(l: *const wlr_layer_surface_v1, out: *mut LayerRequestRaw);
    fn tw_layer_output(l: *const wlr_layer_surface_v1) -> *mut wlr_output;
    fn tw_layer_set_output(l: *mut wlr_layer_surface_v1, o: *mut wlr_output);
    fn tw_foreign_event_flag(e: *const c_void, maximize: c_int) -> bool;
    fn tw_activation_surface(e: *const c_void) -> *mut wlr_surface;

    fn wlr_compositor_create(d: *mut wl_display, version: u32, r: *mut wlr_renderer) -> *mut wlr_compositor;
    fn wlr_subcompositor_create(d: *mut wl_display) -> *mut c_void;
    fn wlr_data_device_manager_create(d: *mut wl_display) -> *mut c_void;
    fn wlr_viewporter_create(d: *mut wl_display) -> *mut c_void;
    fn wlr_fractional_scale_manager_v1_create(d: *mut wl_display, version: u32) -> *mut c_void;
    fn wlr_shm_create_with_renderer(d: *mut wl_display, version: u32, r: *mut wlr_renderer) -> *mut c_void;
    fn wlr_presentation_create(d: *mut wl_display, b: *mut wlr_backend, version: u32) -> *mut c_void;
    fn wlr_linux_dmabuf_v1_create_with_renderer(d: *mut wl_display, version: u32, r: *mut wlr_renderer) -> *mut c_void;
    fn wlr_xdg_shell_create(d: *mut wl_display, version: u32) -> *mut wlr_xdg_shell;
    fn wlr_layer_shell_v1_create(d: *mut wl_display, version: u32) -> *mut wlr_layer_shell_v1;
    fn wlr_foreign_toplevel_manager_v1_create(d: *mut wl_display) -> *mut wlr_foreign_toplevel_manager_v1;
    fn wlr_screencopy_manager_v1_create(d: *mut wl_display) -> *mut c_void;
    fn wlr_xdg_activation_v1_create(d: *mut wl_display) -> *mut wlr_xdg_activation_v1;
    fn wlr_output_layout_create(d: *mut wl_display) -> *mut wlr_output_layout;
    fn wlr_output_layout_add(l: *mut wlr_output_layout, o: *mut wlr_output, x: c_int, y: c_int) -> *mut c_void;
    fn wlr_xdg_output_manager_v1_create(d: *mut wl_display, l: *mut wlr_output_layout) -> *mut c_void;

    fn wlr_xdg_toplevel_set_size(t: *mut wlr_xdg_toplevel, w: i32, h: i32) -> u32;
    fn wlr_xdg_toplevel_set_bounds(t: *mut wlr_xdg_toplevel, w: i32, h: i32) -> u32;
    fn wlr_xdg_toplevel_set_maximized(t: *mut wlr_xdg_toplevel, on: bool) -> u32;
    fn wlr_xdg_toplevel_set_fullscreen(t: *mut wlr_xdg_toplevel, on: bool) -> u32;
    fn wlr_xdg_toplevel_set_activated(t: *mut wlr_xdg_toplevel, on: bool) -> u32;
    fn wlr_xdg_toplevel_set_suspended(t: *mut wlr_xdg_toplevel, on: bool) -> u32;
    fn wlr_xdg_toplevel_send_close(t: *mut wlr_xdg_toplevel);
    fn wlr_layer_surface_v1_configure(l: *mut wlr_layer_surface_v1, w: u32, h: u32) -> u32;
    fn wlr_foreign_toplevel_handle_v1_create(m: *mut wlr_foreign_toplevel_manager_v1) -> *mut wlr_foreign_toplevel_handle_v1;
    fn wlr_foreign_toplevel_handle_v1_destroy(h: *mut wlr_foreign_toplevel_handle_v1);
    fn wlr_foreign_toplevel_handle_v1_set_title(h: *mut wlr_foreign_toplevel_handle_v1, s: *const c_char);
    fn wlr_foreign_toplevel_handle_v1_set_app_id(h: *mut wlr_foreign_toplevel_handle_v1, s: *const c_char);
    fn wlr_foreign_toplevel_handle_v1_set_minimized(h: *mut wlr_foreign_toplevel_handle_v1, on: bool);
    fn wlr_foreign_toplevel_handle_v1_set_maximized(h: *mut wlr_foreign_toplevel_handle_v1, on: bool);
    fn wlr_foreign_toplevel_handle_v1_set_activated(h: *mut wlr_foreign_toplevel_handle_v1, on: bool);
}

fn text(p: *const c_char) -> Option<String> {
    (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

fn cstr(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

/// A typed listener on one of tw-access.h's signals: `f` gets the signal's
/// data turned into what it carries.
macro_rules! signal {
    ($(#[$m:meta])* $name:ident, $hook:ident, $c:ident, || ) => {
        $(#[$m])*
        pub fn $name(self, mut f: impl FnMut() + 'static) -> Option<Listener> {
            let p = self.0.as_ptr();
            Listener::attach(Box::new(move |_| f()), |n, c| unsafe { $hook(p as *mut $c, n, c) })
        }
    };
    ($(#[$m:meta])* $name:ident, $hook:ident, $c:ident, |$d:ident| -> $t:ty $conv:block) => {
        $(#[$m])*
        pub fn $name(self, mut f: impl FnMut($t) + 'static) -> Option<Listener> {
            let p = self.0.as_ptr();
            Listener::attach(Box::new(move |$d: *mut c_void| { if !$d.is_null() { f($conv) } }), |n, c| unsafe { $hook(p as *mut $c, n, c) })
        }
    };
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
handle!(Compositor, wlr_compositor);
handle!(XdgShell, wlr_xdg_shell);
handle!(XdgToplevel, wlr_xdg_toplevel);
handle!(XdgPopup, wlr_xdg_popup);
handle!(LayerShell, wlr_layer_shell_v1);
handle!(LayerSurface, wlr_layer_surface_v1);
handle!(ForeignManager, wlr_foreign_toplevel_manager_v1);
handle!(ForeignHandle, wlr_foreign_toplevel_handle_v1);
handle!(Activation, wlr_xdg_activation_v1);
handle!(OutputLayout, wlr_output_layout);
handle!(DecorationManager, wlr_xdg_decoration_manager_v1);
handle!(Decoration, wlr_xdg_toplevel_decoration_v1);
handle!(LockManager, wlr_session_lock_manager_v1);
handle!(Lock, wlr_session_lock_v1);
handle!(LockSurface, wlr_session_lock_surface_v1);
handle!(OutputManager, wlr_output_manager_v1);
handle!(Pointer, wlr_pointer);
handle!(RelativePointerManager, wlr_relative_pointer_manager_v1);
handle!(TextInputManager, wlr_text_input_manager_v3);
handle!(InputMethodManager, wlr_input_method_manager_v2);
handle!(TextInput, wlr_text_input_v3);
handle!(InputMethod, wlr_input_method_v2);
handle!(KeyboardGrab, wlr_input_method_keyboard_grab_v2);
handle!(InputPopup, wlr_input_popup_surface_v2);
handle!(ConstraintManager, wlr_pointer_constraints_v1);
handle!(Constraint, wlr_pointer_constraint_v1);
handle!(Keyboard, wlr_keyboard);
handle!(DragIcon, wlr_drag_icon);
handle!(CursorShapeManager, wlr_cursor_shape_manager_v1);
handle!(VirtualPointerManager, wlr_virtual_pointer_manager_v1);
handle!(VirtualKeyboardManager, wlr_virtual_keyboard_manager_v1);
handle!(
    /// A configuration a client asked to test or apply. Answer it, then
    /// `destroy` it.
    OutputConfig,
    wlr_output_configuration_v1
);
handle!(ConfigHead, wlr_output_configuration_head_v1);
handle!(IdleInhibitManager, wlr_idle_inhibit_manager_v1);
handle!(IdleInhibitor, wlr_idle_inhibitor_v1);
handle!(IdleNotifier, wlr_idle_notifier_v1);
handle!(
    /// A wlr_seat (the seat's own, R4e).
    Seat,
    wlr_seat
);

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
    /// Pixman, unless `$WLR_RENDERER` names another: what a headless run
    /// needs (CPU-readable buffers), chosen without writing the environment,
    /// which another thread may be reading.
    pub fn renderer_preferring_pixman(self) -> Option<Renderer> {
        if std::env::var_os("WLR_RENDERER").is_some() {
            return self.renderer();
        }
        Renderer::from_raw(unsafe { wlr_pixman_renderer_create() })
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
    pub fn set_scale(&mut self, scale: f64) {
        unsafe { tw_output_state_set_scale(self.0.as_ptr(), scale) }
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

impl Surface {
    signal!(on_map, tw_surface_on_map, wlr_surface, ||);
    signal!(on_unmap, tw_surface_on_unmap, wlr_surface, ||);
    signal!(on_commit, tw_surface_on_commit, wlr_surface, ||);
    signal!(on_destroy, tw_surface_on_destroy, wlr_surface, ||);
    /// The surface of its tree under a point in its coordinates (honouring
    /// each surface's input region), and the point in that surface's.
    pub fn surface_at(self, x: f64, y: f64) -> Option<(Surface, f64, f64)> {
        let (mut sx, mut sy) = (0.0, 0.0);
        Surface::from_raw(unsafe { wlr_surface_surface_at(self.0.as_ptr(), x, y, &mut sx, &mut sy) }).map(|s| (s, sx, sy))
    }
    /// This commit's attach offset.
    pub fn offset(self) -> (i32, i32) {
        let (mut dx, mut dy) = (0, 0);
        unsafe { tw_surface_offset(self.0.as_ptr(), &mut dx, &mut dy) };
        (dx, dy)
    }
    /// The root of the tree it is in (itself, unless a subsurface).
    pub fn root(self) -> Surface {
        Surface::from_raw(unsafe { wlr_surface_get_root_surface(self.0.as_ptr()) }).unwrap_or(self)
    }
    /// fractional-scale-v1's preferred scale (U.8); sent only on a change.
    pub fn notify_fractional_scale(self, scale: f64) {
        unsafe { wlr_fractional_scale_v1_notify_scale(self.0.as_ptr(), scale) }
    }
    /// A new buffer with an acquire point: arm its release (U.3b).
    pub fn arm_release(self) -> bool {
        unsafe { tw_syncobj_arm_release(self.0.as_ptr()) }
    }
    /// Its acquire point, for the renderer to wait on.
    pub fn acquire_point(self) -> Option<(Timeline, u64)> {
        let (mut t, mut p) = (std::ptr::null_mut(), 0u64);
        unsafe { tw_syncobj_acquire(self.0.as_ptr(), &mut t, &mut p) }.then(|| (Timeline::from_raw(t), p)).and_then(|(t, p)| t.map(|t| (t, p)))
    }
    /// Whether the commit just made attached a buffer.
    pub fn committed_buffer(self) -> bool {
        unsafe { tw_surface_committed_buffer(self.0.as_ptr()) }
    }
    /// Frame-done, now, to it **and every subsurface under it**: a
    /// subsurface asks for its own callbacks, and one never answered draws
    /// once and waits for ever.
    pub fn frame_done_tree(self) {
        unsafe { tw_surface_frame_done_tree(self.0.as_ptr()) }
    }
    /// The pid of the client that owns it, if the kernel says.
    pub fn client_pid(self) -> Option<i32> {
        let p = unsafe { tw_surface_client_pid(self.0.as_ptr()) };
        (p > 0).then_some(p)
    }
}

/// The globals a compositor offers, each made once on the display.
pub mod globals {
    use super::*;

    /// wl_compositor, which makes client buffers into textures on commit.
    pub fn compositor(d: &Display, version: u32, r: Renderer) -> Option<Compositor> {
        Compositor::from_raw(unsafe { wlr_compositor_create(d.0.as_ptr(), version, r.0.as_ptr()) })
    }
    pub fn subcompositor(d: &Display) -> bool {
        !unsafe { wlr_subcompositor_create(d.0.as_ptr()) }.is_null()
    }
    pub fn data_device_manager(d: &Display) -> bool {
        !unsafe { wlr_data_device_manager_create(d.0.as_ptr()) }.is_null()
    }
    pub fn viewporter(d: &Display) -> bool {
        !unsafe { wlr_viewporter_create(d.0.as_ptr()) }.is_null()
    }
    pub fn fractional_scale(d: &Display, version: u32) -> bool {
        !unsafe { wlr_fractional_scale_manager_v1_create(d.0.as_ptr(), version) }.is_null()
    }
    pub fn shm(d: &Display, version: u32, r: Renderer) -> bool {
        !unsafe { wlr_shm_create_with_renderer(d.0.as_ptr(), version, r.0.as_ptr()) }.is_null()
    }
    pub fn presentation(d: &Display, b: Backend, version: u32) -> bool {
        !unsafe { wlr_presentation_create(d.0.as_ptr(), b.0.as_ptr(), version) }.is_null()
    }
    /// None when the renderer imports no dma-bufs (pixman).
    pub fn linux_dmabuf(d: &Display, version: u32, r: Renderer) -> bool {
        !unsafe { wlr_linux_dmabuf_v1_create_with_renderer(d.0.as_ptr(), version, r.0.as_ptr()) }.is_null()
    }
    pub fn xdg_shell(d: &Display, version: u32) -> Option<XdgShell> {
        XdgShell::from_raw(unsafe { wlr_xdg_shell_create(d.0.as_ptr(), version) })
    }
    pub fn layer_shell(d: &Display, version: u32) -> Option<LayerShell> {
        LayerShell::from_raw(unsafe { wlr_layer_shell_v1_create(d.0.as_ptr(), version) })
    }
    pub fn foreign_toplevel_manager(d: &Display) -> Option<ForeignManager> {
        ForeignManager::from_raw(unsafe { wlr_foreign_toplevel_manager_v1_create(d.0.as_ptr()) })
    }
    pub fn screencopy(d: &Display) -> bool {
        !unsafe { wlr_screencopy_manager_v1_create(d.0.as_ptr()) }.is_null()
    }
    pub fn xdg_activation(d: &Display) -> Option<Activation> {
        Activation::from_raw(unsafe { wlr_xdg_activation_v1_create(d.0.as_ptr()) })
    }
    pub fn output_layout(d: &Display) -> Option<OutputLayout> {
        OutputLayout::from_raw(unsafe { wlr_output_layout_create(d.0.as_ptr()) })
    }
    pub fn xdg_decoration_manager(d: &Display) -> Option<DecorationManager> {
        DecorationManager::from_raw(unsafe { wlr_xdg_decoration_manager_v1_create(d.0.as_ptr()) })
    }
    /// ext-session-lock-v1 (P16.2).
    pub fn session_lock_manager(d: &Display) -> Option<LockManager> {
        LockManager::from_raw(unsafe { wlr_session_lock_manager_v1_create(d.0.as_ptr()) })
    }
    /// linux-drm-syncobj-v1 (U.3b), where both halves can be kept:
    /// Err says why not ("the renderer…", "the backend…", "the render node…").
    pub fn explicit_sync(d: &Display, r: Renderer, b: Backend) -> Result<(), &'static str> {
        match unsafe { tw_syncobj_unsupported(r.0.as_ptr(), b.0.as_ptr()) } {
            1 => return Err("this renderer takes no timeline waits (pixman?); GPU clients use implicit sync"),
            2 => return Err("this backend's output commits take no timelines"),
            _ => {}
        }
        if unsafe { tw_syncobj_create(d.0.as_ptr(), r.0.as_ptr()) } { Ok(()) } else { Err("the render node refused a syncobj manager") }
    }
    pub fn text_input_manager(d: &Display) -> Option<TextInputManager> {
        TextInputManager::from_raw(unsafe { wlr_text_input_manager_v3_create(d.0.as_ptr()) })
    }
    pub fn input_method_manager(d: &Display) -> Option<InputMethodManager> {
        InputMethodManager::from_raw(unsafe { wlr_input_method_manager_v2_create(d.0.as_ptr()) })
    }
    pub fn relative_pointer_manager(d: &Display) -> Option<RelativePointerManager> {
        RelativePointerManager::from_raw(unsafe { wlr_relative_pointer_manager_v1_create(d.0.as_ptr()) })
    }
    pub fn pointer_constraints(d: &Display) -> Option<ConstraintManager> {
        ConstraintManager::from_raw(unsafe { wlr_pointer_constraints_v1_create(d.0.as_ptr()) })
    }
    pub fn seat(d: &Display, name: &str) -> Option<Seat> {
        Seat::from_raw(unsafe { wlr_seat_create(d.0.as_ptr(), cstr(name).as_ptr()) })
    }
    pub fn virtual_pointer_manager(d: &Display) -> Option<VirtualPointerManager> {
        VirtualPointerManager::from_raw(unsafe { wlr_virtual_pointer_manager_v1_create(d.0.as_ptr()) })
    }
    pub fn virtual_keyboard_manager(d: &Display) -> Option<VirtualKeyboardManager> {
        VirtualKeyboardManager::from_raw(unsafe { wlr_virtual_keyboard_manager_v1_create(d.0.as_ptr()) })
    }
    pub fn cursor_shape_manager(d: &Display, version: u32) -> Option<CursorShapeManager> {
        CursorShapeManager::from_raw(unsafe { wlr_cursor_shape_manager_v1_create(d.0.as_ptr(), version) })
    }
    pub fn primary_selection(d: &Display) -> bool {
        !unsafe { wlr_primary_selection_v1_device_manager_create(d.0.as_ptr()) }.is_null()
    }
    pub fn output_manager(d: &Display) -> Option<OutputManager> {
        OutputManager::from_raw(unsafe { wlr_output_manager_v1_create(d.0.as_ptr()) })
    }
    pub fn idle_inhibit(d: &Display) -> Option<IdleInhibitManager> {
        IdleInhibitManager::from_raw(unsafe { wlr_idle_inhibit_v1_create(d.0.as_ptr()) })
    }
    pub fn idle_notifier(d: &Display) -> Option<IdleNotifier> {
        IdleNotifier::from_raw(unsafe { wlr_idle_notifier_v1_create(d.0.as_ptr()) })
    }
    pub fn xdg_output_manager(d: &Display, l: OutputLayout) -> bool {
        !unsafe { wlr_xdg_output_manager_v1_create(d.0.as_ptr(), l.0.as_ptr()) }.is_null()
    }
}

impl Compositor {
    signal!(on_new_surface, tw_compositor_on_new_surface, wlr_compositor, ||);
    signal!(
        /// The same signal, with the surface it made.
        on_new_surface_with, tw_compositor_on_new_surface, wlr_compositor, |d| -> Surface { Surface(NonNull::new(d as *mut wlr_surface).unwrap()) });
}

impl OutputLayout {
    pub fn add(self, o: Output, x: i32, y: i32) {
        unsafe { wlr_output_layout_add(self.0.as_ptr(), o.0.as_ptr(), x, y) };
    }
}

impl XdgShell {
    signal!(on_new_toplevel, tw_xdg_shell_on_new_toplevel, wlr_xdg_shell, |d| -> XdgToplevel { XdgToplevel(NonNull::new(d as *mut wlr_xdg_toplevel).unwrap()) });
    signal!(on_new_popup, tw_xdg_shell_on_new_popup, wlr_xdg_shell, |d| -> XdgPopup { XdgPopup(NonNull::new(d as *mut wlr_xdg_popup).unwrap()) });
}

/// What a toplevel asked for before or since its last configure.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Requested {
    pub maximized: bool,
    pub minimized: bool,
    pub fullscreen: bool,
}

impl XdgToplevel {
    signal!(on_destroy, tw_xdg_toplevel_on_destroy, wlr_xdg_toplevel, ||);
    signal!(on_request_move, tw_xdg_toplevel_on_request_move, wlr_xdg_toplevel, ||);
    signal!(
        /// The edges to resize from (wlr_edges).
        on_request_resize, tw_xdg_toplevel_on_request_resize, wlr_xdg_toplevel, |d| -> u32 { unsafe { tw_xdg_resize_edges(d) } });
    signal!(on_request_maximize, tw_xdg_toplevel_on_request_maximize, wlr_xdg_toplevel, ||);
    signal!(on_request_minimize, tw_xdg_toplevel_on_request_minimize, wlr_xdg_toplevel, ||);
    signal!(on_request_fullscreen, tw_xdg_toplevel_on_request_fullscreen, wlr_xdg_toplevel, ||);
    signal!(on_set_title, tw_xdg_toplevel_on_set_title, wlr_xdg_toplevel, ||);
    signal!(on_set_app_id, tw_xdg_toplevel_on_set_app_id, wlr_xdg_toplevel, ||);

    pub fn surface(self) -> Surface {
        Surface::from_raw(unsafe { tw_xdg_toplevel_surface(self.0.as_ptr()) }).expect("a toplevel has a surface")
    }
    pub fn app_id(self) -> Option<String> {
        text(unsafe { tw_xdg_toplevel_app_id(self.0.as_ptr()) })
    }
    pub fn title(self) -> Option<String> {
        text(unsafe { tw_xdg_toplevel_title(self.0.as_ptr()) })
    }
    /// The client's first commit, which must be answered with a configure.
    pub fn initial_commit(self) -> bool {
        unsafe { tw_xdg_toplevel_initial_commit(self.0.as_ptr()) }
    }
    /// Past its first commit: a configure may be scheduled now.
    pub fn initialized(self) -> bool {
        unsafe { tw_xdg_toplevel_initialized(self.0.as_ptr()) }
    }
    pub fn requested(self) -> Requested {
        let r = unsafe { tw_xdg_toplevel_requested(self.0.as_ptr()) };
        Requested { maximized: r & 1 != 0, minimized: r & 2 != 0, fullscreen: r & 4 != 0 }
    }
    /// The window geometry's offset in its surface.
    pub fn geometry_offset(self) -> (i32, i32) {
        let mut g = [0i32; 2];
        unsafe { tw_xdg_toplevel_geometry(self.0.as_ptr(), g.as_mut_ptr()) };
        (g[0], g[1])
    }
    pub fn set_size(self, w: i32, h: i32) {
        unsafe { wlr_xdg_toplevel_set_size(self.0.as_ptr(), w, h) };
    }
    pub fn set_bounds(self, w: i32, h: i32) {
        unsafe { wlr_xdg_toplevel_set_bounds(self.0.as_ptr(), w, h) };
    }
    pub fn set_maximized(self, on: bool) {
        unsafe { wlr_xdg_toplevel_set_maximized(self.0.as_ptr(), on) };
    }
    pub fn set_fullscreen(self, on: bool) {
        unsafe { wlr_xdg_toplevel_set_fullscreen(self.0.as_ptr(), on) };
    }
    pub fn set_activated(self, on: bool) {
        unsafe { wlr_xdg_toplevel_set_activated(self.0.as_ptr(), on) };
    }
    pub fn set_suspended(self, on: bool) {
        unsafe { wlr_xdg_toplevel_set_suspended(self.0.as_ptr(), on) };
    }
    pub fn send_close(self) {
        unsafe { wlr_xdg_toplevel_send_close(self.0.as_ptr()) }
    }
    /// Maximize, fullscreen and minimize: what undertow does if asked (not
    /// the window menu, which it does not draw).
    pub fn offer_capabilities(self) {
        unsafe { tw_xdg_toplevel_offer_capabilities(self.0.as_ptr()) }
    }
}

impl XdgPopup {
    signal!(on_destroy, tw_xdg_popup_on_destroy, wlr_xdg_popup, ||);
    pub fn surface(self) -> Surface {
        Surface::from_raw(unsafe { tw_xdg_popup_surface(self.0.as_ptr()) }).expect("a popup has a surface")
    }
    pub fn parent(self) -> Option<Surface> {
        Surface::from_raw(unsafe { tw_xdg_popup_parent(self.0.as_ptr()) })
    }
    pub fn initial_commit(self) -> bool {
        unsafe { tw_xdg_popup_initial_commit(self.0.as_ptr()) }
    }
    /// Its position (relative to its parent's window geometry), and its own
    /// geometry's offset in its surface.
    pub fn geometry(self) -> ((i32, i32), (i32, i32)) {
        let mut g = [0i32; 4];
        unsafe { tw_xdg_popup_geometry(self.0.as_ptr(), g.as_mut_ptr()) };
        ((g[0], g[1]), (g[2], g[3]))
    }
    /// Keep it inside `box`, in its root's coordinates.
    pub fn unconstrain(self, x: i32, y: i32, w: i32, h: i32) {
        unsafe { tw_xdg_popup_unconstrain(self.0.as_ptr(), x, y, w, h) }
    }
}

impl LayerShell {
    signal!(on_new_surface, tw_layer_shell_v1_on_new_surface, wlr_layer_shell_v1, |d| -> LayerSurface { LayerSurface(NonNull::new(d as *mut wlr_layer_surface_v1).unwrap()) });
}

impl LayerSurface {
    signal!(on_destroy, tw_layer_surface_v1_on_destroy, wlr_layer_surface_v1, ||);
    pub fn surface(self) -> Surface {
        Surface::from_raw(unsafe { tw_layer_surface(self.0.as_ptr()) }).expect("a layer surface has a surface")
    }
    pub fn namespace(self) -> String {
        text(unsafe { tw_layer_namespace(self.0.as_ptr()) }).unwrap_or_default()
    }
    /// 0 background, 1 bottom, 2 top, 3 overlay: the paint order.
    pub fn layer(self) -> u32 {
        unsafe { tw_layer_layer(self.0.as_ptr()) }
    }
    /// 0 none, 1 exclusive, 2 on demand.
    pub fn keyboard_interactive(self) -> u32 {
        unsafe { tw_layer_keyboard_interactive(self.0.as_ptr()) }
    }
    pub fn request(self) -> LayerRequestRaw {
        let mut r = LayerRequestRaw::default();
        unsafe { tw_layer_request_read(self.0.as_ptr(), &mut r) };
        r
    }
    pub fn output(self) -> Option<Output> {
        Output::from_raw(unsafe { tw_layer_output(self.0.as_ptr()) })
    }
    pub fn set_output(self, o: Option<Output>) {
        unsafe { tw_layer_set_output(self.0.as_ptr(), o.map_or(std::ptr::null_mut(), |o| o.0.as_ptr())) }
    }
    pub fn configure(self, w: u32, h: u32) {
        unsafe { wlr_layer_surface_v1_configure(self.0.as_ptr(), w, h) };
    }
}

impl ForeignManager {
    pub fn create_handle(self) -> Option<ForeignHandle> {
        ForeignHandle::from_raw(unsafe { wlr_foreign_toplevel_handle_v1_create(self.0.as_ptr()) })
    }
}

impl ForeignHandle {
    signal!(on_request_activate, tw_foreign_toplevel_handle_v1_on_request_activate, wlr_foreign_toplevel_handle_v1, ||);
    signal!(on_request_close, tw_foreign_toplevel_handle_v1_on_request_close, wlr_foreign_toplevel_handle_v1, ||);
    signal!(on_request_minimize, tw_foreign_toplevel_handle_v1_on_request_minimize, wlr_foreign_toplevel_handle_v1, |d| -> bool { unsafe { tw_foreign_event_flag(d, 0) } });
    signal!(on_request_maximize, tw_foreign_toplevel_handle_v1_on_request_maximize, wlr_foreign_toplevel_handle_v1, |d| -> bool { unsafe { tw_foreign_event_flag(d, 1) } });
    pub fn destroy(self) {
        unsafe { wlr_foreign_toplevel_handle_v1_destroy(self.0.as_ptr()) }
    }
    pub fn set_title(self, s: &str) {
        let c = cstr(s);
        unsafe { wlr_foreign_toplevel_handle_v1_set_title(self.0.as_ptr(), c.as_ptr()) }
    }
    pub fn set_app_id(self, s: &str) {
        let c = cstr(s);
        unsafe { wlr_foreign_toplevel_handle_v1_set_app_id(self.0.as_ptr(), c.as_ptr()) }
    }
    pub fn set_minimized(self, on: bool) {
        unsafe { wlr_foreign_toplevel_handle_v1_set_minimized(self.0.as_ptr(), on) }
    }
    pub fn set_maximized(self, on: bool) {
        unsafe { wlr_foreign_toplevel_handle_v1_set_maximized(self.0.as_ptr(), on) }
    }
    pub fn set_activated(self, on: bool) {
        unsafe { wlr_foreign_toplevel_handle_v1_set_activated(self.0.as_ptr(), on) }
    }
}

impl DecorationManager {
    signal!(on_new_toplevel_decoration, tw_xdg_decoration_manager_v1_on_new_toplevel_decoration, wlr_xdg_decoration_manager_v1, |d| -> Decoration { Decoration(NonNull::new(d as *mut wlr_xdg_toplevel_decoration_v1).unwrap()) });
}

impl Decoration {
    signal!(on_destroy, tw_xdg_toplevel_decoration_v1_on_destroy, wlr_xdg_toplevel_decoration_v1, ||);
    pub fn toplevel(self) -> Option<XdgToplevel> {
        XdgToplevel::from_raw(unsafe { tw_decoration_toplevel(self.0.as_ptr()) })
    }
    /// We draw the frame: always (P9.6).
    pub fn set_server_side(self) {
        unsafe { tw_decoration_server_side(self.0.as_ptr()) }
    }
}

impl LockManager {
    signal!(on_new_lock, tw_session_lock_manager_v1_on_new_lock, wlr_session_lock_manager_v1, |d| -> Lock { Lock(NonNull::new(d as *mut wlr_session_lock_v1).unwrap()) });
    /// Its wl_global, for `Menus::restrict_to_privileged`.
    pub fn global(self) -> *const c_void {
        unsafe { tw_session_lock_manager_global(self.0.as_ptr()) }
    }
}

impl Lock {
    signal!(on_new_surface, tw_session_lock_v1_on_new_surface, wlr_session_lock_v1, |d| -> LockSurface { LockSurface(NonNull::new(d as *mut wlr_session_lock_surface_v1).unwrap()) });
    signal!(on_unlock, tw_session_lock_v1_on_unlock, wlr_session_lock_v1, ||);
    signal!(on_destroy, tw_session_lock_v1_on_destroy, wlr_session_lock_v1, ||);
    /// Refuse it: the client is told `finished`.
    pub fn destroy(self) {
        unsafe { wlr_session_lock_v1_destroy(self.0.as_ptr()) }
    }
    pub fn send_locked(self) {
        unsafe { wlr_session_lock_v1_send_locked(self.0.as_ptr()) }
    }
}

impl LockSurface {
    signal!(on_destroy, tw_session_lock_surface_v1_on_destroy, wlr_session_lock_surface_v1, ||);
    pub fn surface(self) -> Surface {
        Surface::from_raw(unsafe { tw_lock_surface_surface(self.0.as_ptr()) }).expect("a lock surface has a surface")
    }
    pub fn output(self) -> Option<Output> {
        Output::from_raw(unsafe { tw_lock_surface_output(self.0.as_ptr()) })
    }
    pub fn configure(self, w: u32, h: u32) {
        unsafe { wlr_session_lock_surface_v1_configure(self.0.as_ptr(), w, h) };
    }
}

/// A client, as an identity only (`wlr_seat_client`): who asked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SeatClient(*const c_void);

/// The cursor a client asked for (wl_pointer.set_cursor).
#[derive(Clone, Copy, Debug)]
pub struct CursorRequest {
    pub client: SeatClient,
    pub surface: Option<Surface>,
    pub hot_x: i32,
    pub hot_y: i32,
}

/// The seat's capabilities (wl_seat.capability).
pub const CAP_POINTER: u32 = 1;
pub const CAP_KEYBOARD: u32 = 2;

impl Seat {
    signal!(
        /// A client set the clipboard: accepted (wlroots checks the serial).
        on_request_set_selection, tw_seat_on_request_set_selection, wlr_seat, |d| -> SelectionRequest { SelectionRequest(d) });
    signal!(on_request_set_primary_selection, tw_seat_on_request_set_primary_selection, wlr_seat, |d| -> SelectionRequest { SelectionRequest(d) });
    signal!(on_request_start_drag, tw_seat_on_request_start_drag, wlr_seat, |d| -> DragRequest { DragRequest(d) });
    signal!(
        /// A drag began: its icon, if it has one.
        on_start_drag, tw_seat_on_start_drag, wlr_seat, |d| -> Option<DragIcon> { DragIcon::from_raw(unsafe { tw_drag_icon(d) }) });
    signal!(on_request_set_cursor, tw_seat_on_request_set_cursor, wlr_seat, |d| -> CursorRequest {
        let (mut s, mut hx, mut hy) = (std::ptr::null_mut(), 0, 0);
        let client = SeatClient(unsafe { tw_set_cursor_read(d, &mut s, &mut hx, &mut hy) });
        CursorRequest { client, surface: Surface::from_raw(s), hot_x: hx, hot_y: hy }
    });
    signal!(
        /// The pointer went to another surface (true), or stayed (false).
        on_pointer_focus_change, tw_seat_on_pointer_focus_change, wlr_seat, |d| -> bool { unsafe { tw_pointer_focus_changed(d) } });

    pub fn set_capabilities(self, caps: u32) {
        unsafe { wlr_seat_set_capabilities(self.0.as_ptr(), caps) }
    }
    /// The one active keyboard: its keymap is what clients are told.
    pub fn set_keyboard(self, k: Keyboard) {
        unsafe { wlr_seat_set_keyboard(self.0.as_ptr(), k.0.as_ptr()) }
    }
    /// Keyboard focus to `s`; false if there is no keyboard yet.
    pub fn keyboard_enter(self, s: Surface) -> bool {
        unsafe { tw_seat_keyboard_enter(self.0.as_ptr(), s.0.as_ptr()) }
    }
    pub fn keyboard_clear_focus(self) {
        unsafe { wlr_seat_keyboard_notify_clear_focus(self.0.as_ptr()) }
    }
    pub fn keyboard_key(self, time_msec: u32, keycode: u32, pressed: bool) {
        unsafe { wlr_seat_keyboard_notify_key(self.0.as_ptr(), time_msec, keycode, pressed as u32) }
    }
    pub fn keyboard_modifiers(self, k: Keyboard) {
        unsafe { tw_seat_keyboard_modifiers(self.0.as_ptr(), k.0.as_ptr()) }
    }
    pub fn keyboard_focused(self) -> Option<Surface> {
        Surface::from_raw(unsafe { tw_seat_keyboard_focused(self.0.as_ptr()) })
    }
    pub fn pointer_focused_client(self) -> SeatClient {
        SeatClient(unsafe { tw_seat_pointer_focused_client(self.0.as_ptr()) })
    }
    pub fn pointer_enter(self, s: Surface, sx: f64, sy: f64) {
        unsafe { wlr_seat_pointer_notify_enter(self.0.as_ptr(), s.0.as_ptr(), sx, sy) }
    }
    pub fn pointer_motion(self, time_msec: u32, sx: f64, sy: f64) {
        unsafe { wlr_seat_pointer_notify_motion(self.0.as_ptr(), time_msec, sx, sy) }
    }
    pub fn pointer_button(self, time_msec: u32, button: u32, pressed: bool) -> u32 {
        unsafe { wlr_seat_pointer_notify_button(self.0.as_ptr(), time_msec, button, pressed as u32) }
    }
    pub fn pointer_frame(self) {
        unsafe { wlr_seat_pointer_notify_frame(self.0.as_ptr()) }
    }
    pub fn pointer_clear_focus(self) {
        unsafe { wlr_seat_pointer_clear_focus(self.0.as_ptr()) }
    }
    pub fn pointer_warp(self, sx: f64, sy: f64) {
        unsafe { wlr_seat_pointer_warp(self.0.as_ptr(), sx, sy) }
    }
    /// An axis event from a pointer, passed on whole, and its frame.
    pub fn pointer_axis(self, e: AxisEvent) {
        unsafe { tw_seat_pointer_axis(self.0.as_ptr(), e.0) }
    }
    /// **No grab survives a lock**: end any keyboard grab (the keys then go
    /// to `lock_surface`) and pointer grab. How many were ended.
    pub fn break_grabs(self, lock_surface: Option<Surface>) -> u32 {
        unsafe { tw_seat_break_grabs(self.0.as_ptr(), lock_surface.map_or(std::ptr::null_mut(), |s| s.0.as_ptr())) as u32 }
    }
    pub fn accept_selection(self, r: SelectionRequest, primary: bool) {
        unsafe { tw_seat_accept_selection(self.0.as_ptr(), r.0, primary) }
    }
    /// Start it if its serial is a real press; else destroy its source.
    pub fn accept_drag(self, r: DragRequest) -> bool {
        unsafe { tw_seat_accept_drag(self.0.as_ptr(), r.0) }
    }
}

impl Seat {
    /// The surface with the pointer, and where in it the pointer is.
    pub fn pointer_focused(self) -> Option<(Surface, f64, f64)> {
        let (mut x, mut y) = (0.0, 0.0);
        Surface::from_raw(unsafe { tw_seat_pointer_focused(self.0.as_ptr(), &mut x, &mut y) }).map(|s| (s, x, y))
    }
}

impl Seat {
    signal!(
        /// The keyboard went to another surface (or none).
        on_keyboard_focus_change, tw_seat_on_keyboard_focus_change, wlr_seat, |d| -> Option<Surface> { Surface::from_raw(unsafe { tw_keyboard_focus_new_surface(d) }) });
}

impl TextInputManager {
    signal!(on_new_text_input, tw_text_input_manager_v3_on_new_text_input, wlr_text_input_manager_v3, |d| -> TextInput { TextInput(NonNull::new(d as *mut wlr_text_input_v3).unwrap()) });
}

impl InputMethodManager {
    signal!(on_new_input_method, tw_input_method_manager_v2_on_new_input_method, wlr_input_method_manager_v2, |d| -> InputMethod { InputMethod(NonNull::new(d as *mut wlr_input_method_v2).unwrap()) });
}

impl TextInput {
    // wlroots 0.20 emits these with NULL data: the closure knows which.
    signal!(on_enable, tw_text_input_v3_on_enable, wlr_text_input_v3, ||);
    signal!(on_commit, tw_text_input_v3_on_commit, wlr_text_input_v3, ||);
    signal!(on_disable, tw_text_input_v3_on_disable, wlr_text_input_v3, ||);
    signal!(on_destroy, tw_text_input_v3_on_destroy, wlr_text_input_v3, ||);
    pub fn focused_surface(self) -> Option<Surface> {
        Surface::from_raw(unsafe { tw_text_input_focused(self.0.as_ptr()) })
    }
    pub fn enabled(self) -> bool {
        unsafe { tw_text_input_enabled(self.0.as_ptr()) }
    }
    pub fn same_client(self, s: Surface) -> bool {
        unsafe { tw_text_input_same_client(self.0.as_ptr(), s.0.as_ptr()) }
    }
    /// The text cursor's rectangle, in its surface: x, y, width, height.
    pub fn cursor(self) -> [i32; 4] {
        let mut r = [0; 4];
        unsafe { tw_text_input_cursor(self.0.as_ptr(), r.as_mut_ptr()) };
        r
    }
    pub fn send_enter(self, s: Surface) {
        unsafe { wlr_text_input_v3_send_enter(self.0.as_ptr(), s.0.as_ptr()) }
    }
    pub fn send_leave(self) {
        unsafe { wlr_text_input_v3_send_leave(self.0.as_ptr()) }
    }
    /// Its state to the method, then done.
    pub fn send_state_to(self, im: InputMethod) {
        unsafe { tw_text_input_send_state(self.0.as_ptr(), im.0.as_ptr()) }
    }
    pub fn clear_preedit(self) {
        unsafe { tw_text_input_clear_preedit(self.0.as_ptr()) }
    }
}

impl InputMethod {
    signal!(on_commit, tw_input_method_v2_on_commit, wlr_input_method_v2, ||);
    signal!(on_grab_keyboard, tw_input_method_v2_on_grab_keyboard, wlr_input_method_v2, |d| -> KeyboardGrab { KeyboardGrab(NonNull::new(d as *mut wlr_input_method_keyboard_grab_v2).unwrap()) });
    signal!(on_new_popup_surface, tw_input_method_v2_on_new_popup_surface, wlr_input_method_v2, |d| -> InputPopup { InputPopup(NonNull::new(d as *mut wlr_input_popup_surface_v2).unwrap()) });
    signal!(on_destroy, tw_input_method_v2_on_destroy, wlr_input_method_v2, ||);
    pub fn send_activate(self) {
        unsafe { wlr_input_method_v2_send_activate(self.0.as_ptr()) }
    }
    pub fn send_deactivate(self) {
        unsafe { wlr_input_method_v2_send_deactivate(self.0.as_ptr()) }
    }
    pub fn send_done(self) {
        unsafe { wlr_input_method_v2_send_done(self.0.as_ptr()) }
    }
    /// One per seat: a second is told it is unavailable.
    pub fn send_unavailable(self) {
        unsafe { wlr_input_method_v2_send_unavailable(self.0.as_ptr()) }
    }
    /// Its commit to the field: preedit and commit sizes, never the text.
    pub fn relay_to(self, ti: TextInput) -> (usize, usize) {
        let (mut p, mut c) = (0, 0);
        unsafe { tw_input_method_relay(self.0.as_ptr(), ti.0.as_ptr(), &mut p, &mut c) };
        (p, c)
    }
    /// Whether `k` is its own virtual keyboard.
    pub fn owns_keyboard(self, k: Keyboard) -> bool {
        unsafe { tw_keyboard_from_method(k.0.as_ptr(), self.0.as_ptr()) }
    }
}

impl KeyboardGrab {
    signal!(on_destroy, tw_input_method_keyboard_grab_v2_on_destroy, wlr_input_method_keyboard_grab_v2, ||);
    pub fn set_keyboard(self, k: Keyboard) {
        unsafe { wlr_input_method_keyboard_grab_v2_set_keyboard(self.0.as_ptr(), k.0.as_ptr()) }
    }
    pub fn send_key(self, k: Keyboard, e: Press) {
        unsafe {
            wlr_input_method_keyboard_grab_v2_set_keyboard(self.0.as_ptr(), k.0.as_ptr());
            wlr_input_method_keyboard_grab_v2_send_key(self.0.as_ptr(), e.time_msec, e.code, e.pressed as u32);
        }
    }
    pub fn send_modifiers(self, k: Keyboard) {
        unsafe { tw_grab_send_modifiers(self.0.as_ptr(), k.0.as_ptr()) }
    }
}

impl InputPopup {
    signal!(on_destroy, tw_input_popup_surface_v2_on_destroy, wlr_input_popup_surface_v2, ||);
    pub fn surface(self) -> Option<Surface> {
        Surface::from_raw(unsafe { tw_input_popup_surface(self.0.as_ptr()) })
    }
    /// Where the field's text cursor is, in its surface.
    pub fn send_rectangle(self, r: [i32; 4]) {
        unsafe { tw_input_popup_send_rectangle(self.0.as_ptr(), r.as_ptr()) }
    }
}

impl RelativePointerManager {
    /// A motion as a delta, accelerated and not, to whoever has the pointer.
    pub fn send(self, seat: Seat, time_msec: u32, d: (f64, f64), unaccel: (f64, f64)) {
        unsafe { tw_relative_motion(self.0.as_ptr(), seat.0.as_ptr(), time_msec, d.0, d.1, unaccel.0, unaccel.1) }
    }
}

impl ConstraintManager {
    signal!(on_new_constraint, tw_pointer_constraints_v1_on_new_constraint, wlr_pointer_constraints_v1, |d| -> Constraint { Constraint(NonNull::new(d as *mut wlr_pointer_constraint_v1).unwrap()) });
    pub fn for_surface(self, s: Surface, seat: Seat) -> Option<Constraint> {
        Constraint::from_raw(unsafe { wlr_pointer_constraints_v1_constraint_for_surface(self.0.as_ptr(), s.0.as_ptr(), seat.0.as_ptr()) })
    }
}

impl Constraint {
    signal!(on_set_region, tw_pointer_constraint_v1_on_set_region, wlr_pointer_constraint_v1, ||);
    signal!(on_destroy, tw_pointer_constraint_v1_on_destroy, wlr_pointer_constraint_v1, ||);
    /// Locked (not confined): the pointer does not move at all.
    pub fn locked(self) -> bool {
        unsafe { tw_constraint_locked(self.0.as_ptr()) }
    }
    pub fn surface(self) -> Option<Surface> {
        Surface::from_raw(unsafe { tw_constraint_surface(self.0.as_ptr()) })
    }
    pub fn contains(self, x: f64, y: f64) -> bool {
        unsafe { tw_constraint_contains(self.0.as_ptr(), x, y) }
    }
    /// The region's nearest point; None if it is empty.
    pub fn nearest(self, x: f64, y: f64) -> Option<(f64, f64)> {
        let (mut nx, mut ny) = (0.0, 0.0);
        unsafe { tw_constraint_nearest(self.0.as_ptr(), x, y, &mut nx, &mut ny) }.then_some((nx, ny))
    }
    /// A lock's cursor hint: where the client drew its own cursor.
    pub fn hint(self) -> Option<(f64, f64)> {
        let (mut x, mut y) = (0.0, 0.0);
        unsafe { tw_constraint_hint(self.0.as_ptr(), &mut x, &mut y) }.then_some((x, y))
    }
    pub fn send_activated(self) {
        unsafe { wlr_pointer_constraint_v1_send_activated(self.0.as_ptr()) }
    }
    /// May destroy it (a oneshot constraint).
    pub fn send_deactivated(self) {
        unsafe { wlr_pointer_constraint_v1_send_deactivated(self.0.as_ptr()) }
    }
}

/// An event only valid inside the signal that carried it.
#[derive(Clone, Copy, Debug)]
pub struct SelectionRequest(*mut c_void);
#[derive(Clone, Copy, Debug)]
pub struct DragRequest(*mut c_void);
#[derive(Clone, Copy, Debug)]
pub struct AxisEvent(*mut c_void);

impl DragIcon {
    signal!(on_destroy, tw_drag_icon_on_destroy, wlr_drag_icon, ||);
    pub fn surface(self) -> Option<Surface> {
        Surface::from_raw(unsafe { tw_drag_icon_surface(self.0.as_ptr()) })
    }
}

impl CursorShapeManager {
    signal!(
        /// A shape by name, if for the pointer, and who asked.
        on_request_set_shape, tw_cursor_shape_manager_v1_on_request_set_shape, wlr_cursor_shape_manager_v1, |d| -> (Option<String>, SeatClient) {
            let mut c = std::ptr::null();
            let name = text(unsafe { tw_set_shape_read(d, &mut c) });
            (name, SeatClient(c))
        });
}

impl VirtualPointerManager {
    signal!(on_new_virtual_pointer, tw_virtual_pointer_manager_v1_on_new_virtual_pointer, wlr_virtual_pointer_manager_v1, |d| -> Option<Pointer> { Pointer::from_raw(unsafe { tw_virtual_pointer_from_event(d) }) });
}

impl VirtualKeyboardManager {
    signal!(on_new_virtual_keyboard, tw_virtual_keyboard_manager_v1_on_new_virtual_keyboard, wlr_virtual_keyboard_manager_v1, |d| -> Option<Keyboard> { Keyboard::from_raw(unsafe { tw_virtual_keyboard_keyboard(d) }) });
}

/// What a device is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeviceKind {
    Pointer(Pointer),
    Keyboard(Keyboard),
    Other,
}

impl InputDevice {
    signal!(on_destroy, tw_input_device_on_destroy, wlr_input_device, ||);
    pub fn kind(self) -> DeviceKind {
        let p = self.0.as_ptr();
        match unsafe { tw_input_device_kind(p) } {
            1 => Pointer::from_raw(unsafe { tw_input_device_pointer(p) }).map_or(DeviceKind::Other, DeviceKind::Pointer),
            2 => Keyboard::from_raw(unsafe { tw_input_device_keyboard(p) }).map_or(DeviceKind::Other, DeviceKind::Keyboard),
            _ => DeviceKind::Other,
        }
    }
    pub fn name(self) -> String {
        text(unsafe { tw_input_device_name(self.0.as_ptr()) }).unwrap_or_default()
    }
}

impl Pointer {
    signal!(on_motion, tw_pointer_on_motion, wlr_pointer, |d| -> Motion { let mut m = Motion::default(); unsafe { tw_pointer_motion_read(d, &mut m) }; m });
    signal!(
        /// x and y in 0…1 across the layout, and the time.
        on_motion_absolute, tw_pointer_on_motion_absolute, wlr_pointer, |d| -> (f64, f64, u32) {
            let (mut t, mut x, mut y) = (0, 0.0, 0.0);
            unsafe { tw_pointer_motion_absolute_read(d, &mut t, &mut x, &mut y) };
            (x, y, t)
        });
    signal!(on_button, tw_pointer_on_button, wlr_pointer, |d| -> Press {
        let (mut t, mut b, mut p) = (0, 0, 0);
        unsafe { tw_pointer_button_read(d, &mut t, &mut b, &mut p) };
        Press { time_msec: t, code: b, pressed: p != 0 }
    });
    signal!(on_axis, tw_pointer_on_axis, wlr_pointer, |d| -> AxisEvent { AxisEvent(d) });
    pub fn device(self) -> InputDevice {
        InputDevice::from_raw(unsafe { tw_pointer_device(self.0.as_ptr()) }).expect("a pointer is a device")
    }
}

/// What giving a keyboard a keymap did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeymapGiven {
    Given,
    /// It came with one: a backend that chose one knows better.
    HadOne,
    /// Nothing compiled (are the xkeyboard-config layouts installed?).
    NoneCompiled,
    Refused,
}

impl Keyboard {
    signal!(on_key, tw_keyboard_on_key, wlr_keyboard, |d| -> Press {
        let (mut t, mut k, mut p) = (0, 0, 0);
        unsafe { tw_keyboard_key_read(d, &mut t, &mut k, &mut p) };
        Press { time_msec: t, code: k, pressed: p != 0 }
    });
    signal!(on_modifiers, tw_keyboard_on_modifiers, wlr_keyboard, ||);
    pub fn device(self) -> InputDevice {
        InputDevice::from_raw(unsafe { tw_keyboard_device(self.0.as_ptr()) }).expect("a keyboard is a device")
    }
    /// A keyboard with no keymap of its own, fed by a test (T.2).
    pub fn stand_in() -> Option<Keyboard> {
        Keyboard::from_raw(unsafe { tw_stand_in_keyboard_create() })
    }
    pub fn stand_in_key(self, keycode: u32, pressed: bool, time_msec: u32) {
        unsafe { tw_stand_in_keyboard_key(self.0.as_ptr(), keycode, pressed, time_msec) }
    }
    /// Compile `layout` (None: xkbcommon's default, which honours
    /// XKB_DEFAULT_*) for a keyboard that has no keymap.
    pub fn give_keymap(self, layout: Option<(&str, &str)>) -> KeymapGiven {
        let (l, v) = layout.map_or((CString::default(), CString::default()), |(l, v)| (cstr(l), cstr(v)));
        match unsafe { tw_keyboard_give_keymap(self.0.as_ptr(), l.as_ptr(), v.as_ptr()) } {
            1 => KeymapGiven::Given,
            0 => KeymapGiven::HadOne,
            -1 => KeymapGiven::NoneCompiled,
            _ => KeymapGiven::Refused,
        }
    }
    pub fn set_layout(self, layout: &str, variant: &str) -> bool {
        unsafe { tw_keyboard_set_layout(self.0.as_ptr(), cstr(layout).as_ptr(), cstr(variant).as_ptr()) }
    }
    pub fn layout_name(self) -> Option<String> {
        text(unsafe { tw_keyboard_layout_name(self.0.as_ptr()) })
    }
    /// wlr_keyboard_get_modifiers: WLR_MODIFIER_* bits.
    pub fn modifiers(self) -> u32 {
        unsafe { tw_keyboard_modifiers(self.0.as_ptr()) }
    }
    /// The key's symbols: translated with the modifiers, then the raw ones.
    pub fn syms(self, keycode: u32) -> Vec<u32> {
        let mut out = [0u32; 16];
        let n = unsafe { tw_keyboard_syms(self.0.as_ptr(), keycode, out.as_mut_ptr(), out.len()) };
        out[..n].to_vec()
    }
}

/// Whether an XKB layout compiles.
pub fn keymap_compiles(layout: &str, variant: &str) -> bool {
    unsafe { tw_keymap_compiles(cstr(layout).as_ptr(), cstr(variant).as_ptr()) }
}

pub fn keysym_from_name(name: &str) -> Option<u32> {
    let k = unsafe { tw_keysym_from_name(cstr(name).as_ptr()) };
    (k != 0).then_some(k)
}

impl OutputManager {
    signal!(on_apply, tw_output_manager_v1_on_apply, wlr_output_manager_v1, |d| -> OutputConfig { OutputConfig(NonNull::new(d as *mut wlr_output_configuration_v1).unwrap()) });
    signal!(on_test, tw_output_manager_v1_on_test, wlr_output_manager_v1, |d| -> OutputConfig { OutputConfig(NonNull::new(d as *mut wlr_output_configuration_v1).unwrap()) });
    /// Tell every client what is true now: each output at its place and scale.
    pub fn publish(self, heads: &[(Output, i32, i32, f64)]) {
        let mut outs: Vec<*mut wlr_output> = heads.iter().map(|h| h.0.0.as_ptr()).collect();
        let xs: Vec<i32> = heads.iter().map(|h| h.1).collect();
        let ys: Vec<i32> = heads.iter().map(|h| h.2).collect();
        let ss: Vec<f64> = heads.iter().map(|h| h.3).collect();
        unsafe { tw_output_manager_publish(self.0.as_ptr(), outs.as_mut_ptr(), xs.as_ptr(), ys.as_ptr(), ss.as_ptr(), heads.len()) }
    }
}

impl OutputConfig {
    pub fn heads(self) -> Vec<ConfigHead> {
        let mut v = vec![std::ptr::null_mut(); 32];
        let n = unsafe { tw_output_config_heads(self.0.as_ptr(), v.as_mut_ptr(), v.len()) }.min(32);
        v[..n].iter().filter_map(|p| ConfigHead::from_raw(*p)).collect()
    }
    pub fn send_succeeded(self) {
        unsafe { wlr_output_configuration_v1_send_succeeded(self.0.as_ptr()) }
    }
    pub fn send_failed(self) {
        unsafe { wlr_output_configuration_v1_send_failed(self.0.as_ptr()) }
    }
    pub fn destroy(self) {
        unsafe { wlr_output_configuration_v1_destroy(self.0.as_ptr()) }
    }
}

impl ConfigHead {
    pub fn ask(self) -> HeadAsk {
        let mut a = HeadAsk { output: std::ptr::null_mut(), enabled: false, mode_width: 0, mode_height: 0, refresh_mhz: 0, x: 0, y: 0, scale: 1.0 };
        unsafe { tw_head_read(self.0.as_ptr(), &mut a) };
        a
    }
    /// Its state applied to its output: tested, or committed.
    pub fn try_state(self, commit: bool) -> bool {
        unsafe { tw_head_try(self.0.as_ptr(), commit) }
    }
}

impl IdleInhibitManager {
    signal!(on_new_inhibitor, tw_idle_inhibit_manager_v1_on_new_inhibitor, wlr_idle_inhibit_manager_v1, |d| -> IdleInhibitor { IdleInhibitor(NonNull::new(d as *mut wlr_idle_inhibitor_v1).unwrap()) });
}

impl IdleInhibitor {
    signal!(on_destroy, tw_idle_inhibitor_v1_on_destroy, wlr_idle_inhibitor_v1, ||);
    pub fn surface(self) -> Option<Surface> {
        Surface::from_raw(unsafe { tw_idle_inhibitor_surface(self.0.as_ptr()) })
    }
}

impl IdleNotifier {
    pub fn notify_activity(self, seat: Seat) {
        unsafe { wlr_idle_notifier_v1_notify_activity(self.0.as_ptr(), seat.0.as_ptr()) }
    }
    pub fn set_inhibited(self, on: bool) {
        unsafe { wlr_idle_notifier_v1_set_inhibited(self.0.as_ptr(), on) }
    }
}

impl Activation {
    signal!(
        /// The surface a client asks to raise (its own, with a token).
        on_request_activate, tw_xdg_activation_v1_on_request_activate, wlr_xdg_activation_v1, |d| -> Option<Surface> { Surface::from_raw(unsafe { tw_activation_surface(d) }) });
}

/// The menu protocols undertow implements itself (cwlroots.h's "Menus",
/// de/cwlroots/menus.c; PHASE10 P10.3): the plumbing is C, and what it
/// means is the compositor's, through `MenuHooks`.
pub mod menus {
    use super::*;

    opaque!(tw_menus, wl_resource, wl_client, wl_global, wlr_security_context_manager_v1);

    type SetAddress = extern "C" fn(*mut c_void, *mut wlr_surface, *const c_char);
    type Bound = extern "C" fn(*mut c_void, *mut wl_resource);
    type GtkProps = extern "C" fn(*mut c_void, *mut wlr_surface, *const c_char, *const c_char, *const c_char, *const c_char, *const c_char, *const c_char);
    type Str = extern "C" fn(*mut c_void, *const c_char);
    type OnSurface = extern "C" fn(*mut c_void, *mut wlr_surface);
    type WindowAt = extern "C" fn(*mut c_void, i32, i32, *mut i32, *mut *mut c_char, *mut *mut c_char) -> c_int;
    type SwitchIsland = extern "C" fn(*mut c_void, *const c_char, u32);
    type Activate = extern "C" fn(*mut c_void, u32);
    type ShoalCommand = extern "C" fn(*mut c_void, *const c_char, u32);

    /// cwlroots.h's `struct tw_menu_hooks`, in its order.
    #[repr(C)]
    struct RawHooks {
        ctx: *mut c_void,
        set_address: SetAddress,
        menubar_bound: Bound,
        set_gtk_properties: GtkProps,
        force_quit: Str,
        lower: OnSurface,
        window_at: WindowAt,
        list_islands: Bound,
        switch_island: SwitchIsland,
        activate_window: Activate,
        shoal_command: ShoalCommand,
    }

    unsafe extern "C" {
        fn tw_menus_create(d: *mut wl_display, h: *const RawHooks) -> *mut tw_menus;
        fn tw_menus_destroy(m: *mut tw_menus);
        fn tw_privileged_socket_add(m: *mut tw_menus, path: *const c_char) -> c_int;
        fn tw_menus_add_privileged_global(m: *mut tw_menus, g: *const wl_global);
        fn tw_menus_enable_jails(m: *mut tw_menus) -> *mut wlr_security_context_manager_v1;
        fn tw_client_jail(m: *mut tw_menus, c: *mut wl_client, engine: *mut *const c_char, app: *mut *const c_char, instance: *mut *const c_char) -> bool;
        fn tw_surface_client(s: *mut wlr_surface) -> *mut wl_client;
        fn tw_menubar_send_focused(r: *mut wl_resource, kind: u32, address: *const c_char, app: *const c_char, jail: *const c_char);
        fn tw_menubar_send_focused_all(m: *mut tw_menus, kind: u32, address: *const c_char, app: *const c_char, jail: *const c_char);
        fn tw_menubar_count(m: *mut tw_menus) -> c_int;
        fn tw_menubar_send_island(r: *mut wl_resource, display: *const c_char, island: u32, name: *const c_char, count: u32, main: u32);
        fn tw_menubar_send_island_all(m: *mut tw_menus, display: *const c_char, island: u32, name: *const c_char, count: u32, main: u32);
        fn tw_menubar_send_window(r: *mut wl_resource, id: u32, display: *const c_char, island: u32, app: *const c_char, title: *const c_char);
        fn tw_menubar_send_window_pid(r: *mut wl_resource, id: u32, pid: c_int);
        fn tw_menubar_send_islands_done(r: *mut wl_resource, names: *const c_char);
        fn tw_menubar_send_shoal(r: *mut wl_resource, display: *const c_char, island: u32, index: u32, name: *const c_char, open: u32);
        fn tw_gtk_set_global_menus(m: *mut tw_menus, on: bool);
    }

    /// What GTK says about a window's menus (gtk_surface1, P10.6).
    #[derive(Clone, Debug, Default, PartialEq, Eq)]
    pub struct GtkProperties {
        pub application_id: String,
        pub app_menu_path: String,
        pub menubar_path: String,
        pub window_object_path: String,
        pub application_object_path: String,
        pub unique_bus_name: String,
    }

    /// A topmost window, as `window_at` answers it: its box, frame included.
    pub struct WindowAtAnswer {
        pub x: i32,
        pub y: i32,
        pub width: i32,
        pub height: i32,
        pub app_id: String,
        pub title: String,
    }

    /// What the menus' requests mean: the compositor's.
    pub trait MenuHooks {
        /// A client set (or, with "", cleared) the menu address of one of
        /// its own surfaces.
        fn set_address(&self, surface: Surface, address: &str);
        /// A privileged client bound abyss_menubar_v1: send it the state.
        fn menubar_bound(&self, bar: Menubar);
        fn set_gtk_properties(&self, surface: Surface, p: GtkProperties);
        /// The menu bar asked to force-quit an application (v2, P10.8).
        fn force_quit(&self, app_id: &str);
        /// A toolkit window's own depth gadget (abyss_window_manager_v1).
        fn lower(&self, surface: Surface);
        /// The topmost window at (x, y), for Grab (P15.6).
        fn window_at(&self, x: i32, y: i32) -> Option<WindowAtAnswer>;
        /// The bar's island menu (v3): answer with `send_window` for each
        /// window, then `send_islands_done`.
        fn list_islands(&self, bar: Menubar);
        fn switch_island(&self, display: &str, island: u32);
        fn activate_window(&self, id: u32);
        /// Shoals (v4): one of the bar's verbs.
        fn shoal_command(&self, verb: &str, arg: u32);
    }

    /// A bound abyss_menubar_v1.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub struct Menubar(NonNull<wl_resource>);

    fn s(p: *const c_char) -> String {
        text(p).unwrap_or_default()
    }

    fn hooks<'a>(ctx: *mut c_void) -> &'a dyn MenuHooks {
        unsafe { &**(ctx as *const Box<dyn MenuHooks>) }
    }

    extern "C" fn set_address(ctx: *mut c_void, surface: *mut wlr_surface, address: *const c_char) {
        if let Some(sf) = Surface::from_raw(surface) {
            hooks(ctx).set_address(sf, &s(address))
        }
    }
    extern "C" fn menubar_bound(ctx: *mut c_void, r: *mut wl_resource) {
        if let Some(r) = NonNull::new(r) {
            hooks(ctx).menubar_bound(Menubar(r))
        }
    }
    extern "C" fn set_gtk_properties(ctx: *mut c_void, surface: *mut wlr_surface, app: *const c_char, app_menu: *const c_char, menubar: *const c_char, window: *const c_char, app_path: *const c_char, bus: *const c_char) {
        if let Some(sf) = Surface::from_raw(surface) {
            hooks(ctx).set_gtk_properties(sf, GtkProperties { application_id: s(app), app_menu_path: s(app_menu), menubar_path: s(menubar), window_object_path: s(window), application_object_path: s(app_path), unique_bus_name: s(bus) })
        }
    }
    extern "C" fn force_quit(ctx: *mut c_void, app: *const c_char) {
        hooks(ctx).force_quit(&s(app))
    }
    extern "C" fn lower(ctx: *mut c_void, surface: *mut wlr_surface) {
        if let Some(sf) = Surface::from_raw(surface) {
            hooks(ctx).lower(sf)
        }
    }
    extern "C" fn window_at(ctx: *mut c_void, x: i32, y: i32, b: *mut i32, app: *mut *mut c_char, title: *mut *mut c_char) -> c_int {
        let Some(w) = hooks(ctx).window_at(x, y) else { return 0 };
        if b.is_null() {
            return 0;
        }
        // malloc'd, for the C to free.
        let dup = |t: &str| unsafe { libc::strdup(cstr(t).as_ptr()) };
        unsafe {
            *b = w.x;
            *b.add(1) = w.y;
            *b.add(2) = w.width;
            *b.add(3) = w.height;
            if !app.is_null() {
                *app = dup(&w.app_id);
            }
            if !title.is_null() {
                *title = dup(&w.title);
            }
        }
        1
    }
    extern "C" fn list_islands(ctx: *mut c_void, r: *mut wl_resource) {
        if let Some(r) = NonNull::new(r) {
            hooks(ctx).list_islands(Menubar(r))
        }
    }
    extern "C" fn switch_island(ctx: *mut c_void, display: *const c_char, island: u32) {
        hooks(ctx).switch_island(&s(display), island)
    }
    extern "C" fn activate_window(ctx: *mut c_void, id: u32) {
        hooks(ctx).activate_window(id)
    }
    extern "C" fn shoal_command(ctx: *mut c_void, verb: *const c_char, arg: u32) {
        hooks(ctx).shoal_command(&s(verb), arg)
    }

    /// The menu globals on a display, and the hooks they call. Destroyed on
    /// drop, before the display.
    pub struct Menus {
        raw: NonNull<tw_menus>,
        hooks: *mut Box<dyn MenuHooks>,
    }

    impl Menus {
        pub fn create(d: &Display, h: impl MenuHooks + 'static) -> Option<Menus> {
            let hooks: *mut Box<dyn MenuHooks> = Box::into_raw(Box::new(Box::new(h)));
            let raw = RawHooks {
                ctx: hooks as *mut c_void,
                set_address,
                menubar_bound,
                set_gtk_properties,
                force_quit,
                lower,
                window_at,
                list_islands,
                switch_island,
                activate_window,
                shoal_command,
            };
            match NonNull::new(unsafe { tw_menus_create(d.0.as_ptr(), &raw) }) {
                Some(raw) => Some(Menus { raw, hooks }),
                None => {
                    drop(unsafe { Box::from_raw(hooks) });
                    None
                }
            }
        }
        /// Listen on `path` (absolute) for privileged clients: they, and
        /// only they, see abyss_menubar_v1. Err(errno).
        pub fn add_privileged_socket(&self, path: &str) -> Result<(), i32> {
            let rc = unsafe { tw_privileged_socket_add(self.raw.as_ptr(), cstr(path).as_ptr()) };
            if rc == 0 { Ok(()) } else { Err(-rc) }
        }
        /// Offer a global (its address, as wlroots gives it) to the
        /// privileged socket's clients only (P16.2c).
        pub fn restrict_to_privileged(&self, global: *const c_void) {
            unsafe { tw_menus_add_privileged_global(self.raw.as_ptr(), global as *const wl_global) }
        }
        /// Jailed clients (P18.3) see an allowlist. False with no
        /// security-context manager.
        pub fn enable_jails(&self) -> bool {
            !unsafe { tw_menus_enable_jails(self.raw.as_ptr()) }.is_null()
        }
        /// The security context `surface`'s client came in through:
        /// engine, app id, instance ("-" where unset).
        pub fn jail(&self, surface: Surface) -> Option<(String, String, String)> {
            let c = unsafe { tw_surface_client(surface.0.as_ptr()) };
            if c.is_null() {
                return None;
            }
            let (mut e, mut a, mut i) = (std::ptr::null(), std::ptr::null(), std::ptr::null());
            if !unsafe { tw_client_jail(self.raw.as_ptr(), c, &mut e, &mut a, &mut i) } {
                return None;
            }
            let t = |p| text(p).unwrap_or_else(|| "-".into());
            Some((t(e), t(a), t(i)))
        }
        pub fn send_focused_all(&self, kind: u32, address: &str, app_id: &str, jail: &str) {
            unsafe { tw_menubar_send_focused_all(self.raw.as_ptr(), kind, cstr(address).as_ptr(), cstr(app_id).as_ptr(), cstr(jail).as_ptr()) }
        }
        pub fn send_island_all(&self, display: &str, island: u32, name: &str, count: u32, main: bool) {
            unsafe { tw_menubar_send_island_all(self.raw.as_ptr(), cstr(display).as_ptr(), island, cstr(name).as_ptr(), count, main as u32) }
        }
        pub fn menubar_count(&self) -> usize {
            unsafe { tw_menubar_count(self.raw.as_ptr()) }.max(0) as usize
        }
        /// GTK stops drawing its own menubar only when this is on (§6.5).
        pub fn advertise_global_menus_to_gtk(&self, on: bool) {
            unsafe { tw_gtk_set_global_menus(self.raw.as_ptr(), on) }
        }
    }

    impl Drop for Menus {
        fn drop(&mut self) {
            unsafe {
                tw_menus_destroy(self.raw.as_ptr());
                drop(Box::from_raw(self.hooks));
            }
        }
    }

    impl Menubar {
        pub fn send_focused(self, kind: u32, address: &str, app_id: &str, jail: &str) {
            unsafe { tw_menubar_send_focused(self.0.as_ptr(), kind, cstr(address).as_ptr(), cstr(app_id).as_ptr(), cstr(jail).as_ptr()) }
        }
        pub fn send_island(self, display: &str, island: u32, name: &str, count: u32, main: bool) {
            unsafe { tw_menubar_send_island(self.0.as_ptr(), cstr(display).as_ptr(), island, cstr(name).as_ptr(), count, main as u32) }
        }
        pub fn send_window(self, id: u32, display: &str, island: u32, app_id: &str, title: &str, pid: Option<i32>) {
            unsafe {
                tw_menubar_send_window(self.0.as_ptr(), id, cstr(display).as_ptr(), island, cstr(app_id).as_ptr(), cstr(title).as_ptr());
                // v6: whose it is, as Force Quit finds it (P10.8).
                tw_menubar_send_window_pid(self.0.as_ptr(), id, pid.unwrap_or(-1));
            }
        }
        pub fn send_shoal(self, display: &str, island: u32, index: u32, name: &str, open: u32) {
            unsafe { tw_menubar_send_shoal(self.0.as_ptr(), cstr(display).as_ptr(), island, index, cstr(name).as_ptr(), open) }
        }
        /// The islands' names, tab-separated.
        pub fn send_islands_done(self, names: &str) {
            unsafe { tw_menubar_send_islands_done(self.0.as_ptr(), cstr(names).as_ptr()) }
        }
    }
}

#[cfg(test)]
#[path = "wlr_tests.rs"]
mod tests;
