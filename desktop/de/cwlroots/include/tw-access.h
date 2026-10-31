/*
 * CWlroots for Rust (RUST.md R4b): what Swift's importer did for free.
 *
 * Swift reads wlroots' headers itself, so undertow touches struct fields and
 * static inlines directly. Rust declares only what it is told (§6.4: no
 * bindgen), and declaring wlroots' own structs by hand would break at every
 * release. So wlroots' types stay opaque to Rust, and this file is the rest:
 *
 *   - an accessor for each field undertow reads (`tw_output_width`);
 *   - a listener for each signal it hears (`tw_output_on_present`), so Rust
 *     never takes the address of a struct member;
 *   - wlroots structs Rust would have to fill or read (render options, the
 *     output state, event payloads) as structs of our own, below, whose
 *     layout is ours to keep.
 *
 * Plain wlroots functions over opaque pointers (`wlr_backend_start`) are
 * declared by Rust directly, as the client side's are. C decides nothing.
 */
#ifndef ABYSS_TW_ACCESS_H
#define ABYSS_TW_ACCESS_H

#include "cwlroots.h"

/* MARK: signals — each returns a listener for tw_listener_free, or NULL. */

#define TW_SIGNAL(type, sig) \
    struct tw_listener *tw_##type##_on_##sig(struct wlr_##type *o, tw_notify_fn fn, void *ctx);
TW_SIGNAL(backend, new_output)
TW_SIGNAL(backend, new_input)
TW_SIGNAL(output, destroy)
TW_SIGNAL(output, present)
TW_SIGNAL(output, needs_frame)
TW_SIGNAL(output, frame)
TW_SIGNAL(compositor, new_surface)
TW_SIGNAL(surface, map)
TW_SIGNAL(surface, unmap)
TW_SIGNAL(surface, commit)
TW_SIGNAL(surface, destroy)
TW_SIGNAL(xdg_shell, new_toplevel)
TW_SIGNAL(xdg_shell, new_popup)
TW_SIGNAL(xdg_toplevel, destroy)
TW_SIGNAL(xdg_toplevel, request_move)
TW_SIGNAL(xdg_toplevel, request_resize)
TW_SIGNAL(xdg_toplevel, request_maximize)
TW_SIGNAL(xdg_toplevel, request_minimize)
TW_SIGNAL(xdg_toplevel, request_fullscreen)
TW_SIGNAL(xdg_toplevel, set_title)
TW_SIGNAL(xdg_toplevel, set_app_id)
TW_SIGNAL(xdg_popup, destroy)
TW_SIGNAL(layer_shell_v1, new_surface)
TW_SIGNAL(layer_surface_v1, destroy)
TW_SIGNAL(foreign_toplevel_handle_v1, request_activate)
TW_SIGNAL(foreign_toplevel_handle_v1, request_close)
TW_SIGNAL(foreign_toplevel_handle_v1, request_minimize)
TW_SIGNAL(foreign_toplevel_handle_v1, request_maximize)
TW_SIGNAL(xdg_activation_v1, request_activate)
TW_SIGNAL(xdg_decoration_manager_v1, new_toplevel_decoration)
TW_SIGNAL(xdg_toplevel_decoration_v1, destroy)
TW_SIGNAL(session_lock_manager_v1, new_lock)
TW_SIGNAL(session_lock_v1, new_surface)
TW_SIGNAL(session_lock_v1, unlock)
TW_SIGNAL(session_lock_v1, destroy)
TW_SIGNAL(session_lock_surface_v1, destroy)
TW_SIGNAL(output_manager_v1, apply)
TW_SIGNAL(output_manager_v1, test)
TW_SIGNAL(idle_inhibit_manager_v1, new_inhibitor)
TW_SIGNAL(idle_inhibitor_v1, destroy)
TW_SIGNAL(seat, request_set_selection)
TW_SIGNAL(seat, request_set_primary_selection)
TW_SIGNAL(seat, request_start_drag)
TW_SIGNAL(seat, start_drag)
TW_SIGNAL(seat, request_set_cursor)
TW_SIGNAL(cursor_shape_manager_v1, request_set_shape)
TW_SIGNAL(virtual_pointer_manager_v1, new_virtual_pointer)
TW_SIGNAL(virtual_keyboard_manager_v1, new_virtual_keyboard)
TW_SIGNAL(pointer, motion)
TW_SIGNAL(pointer, motion_absolute)
TW_SIGNAL(pointer, button)
TW_SIGNAL(pointer, axis)
TW_SIGNAL(keyboard, key)
TW_SIGNAL(keyboard, modifiers)
TW_SIGNAL(input_device, destroy)
TW_SIGNAL(drag_icon, destroy)
TW_SIGNAL(pointer_constraints_v1, new_constraint)
TW_SIGNAL(pointer_constraint_v1, set_region)
TW_SIGNAL(pointer_constraint_v1, destroy)
TW_SIGNAL(text_input_manager_v3, new_text_input)
TW_SIGNAL(input_method_manager_v2, new_input_method)
TW_SIGNAL(text_input_v3, enable)
TW_SIGNAL(text_input_v3, commit)
TW_SIGNAL(text_input_v3, disable)
TW_SIGNAL(text_input_v3, destroy)
TW_SIGNAL(input_method_v2, commit)
TW_SIGNAL(input_method_v2, grab_keyboard)
TW_SIGNAL(input_method_v2, new_popup_surface)
TW_SIGNAL(input_method_v2, destroy)
TW_SIGNAL(input_method_keyboard_grab_v2, destroy)
TW_SIGNAL(input_popup_surface_v2, destroy)
#undef TW_SIGNAL
/* The seat's keyboard focus moved: the new surface (keyboard_state.events). */
struct tw_listener *tw_seat_on_keyboard_focus_change(struct wlr_seat *s, tw_notify_fn fn, void *ctx);
struct wlr_surface *tw_keyboard_focus_new_surface(const void *event);
/* The seat's pointer focus moved (pointer_state.events, not events). */
struct tw_listener *tw_seat_on_pointer_focus_change(struct wlr_seat *s, tw_notify_fn fn, void *ctx);

/* MARK: outputs */

const char *tw_output_name(const struct wlr_output *o);
int32_t tw_output_width(const struct wlr_output *o);
int32_t tw_output_height(const struct wlr_output *o);
/* mHz; 0 when the output has no mode. */
int32_t tw_output_refresh(const struct wlr_output *o);
uint32_t tw_output_commit_seq(const struct wlr_output *o);
float tw_output_scale(const struct wlr_output *o);
int32_t tw_output_transform(const struct wlr_output *o);
bool tw_output_enabled(const struct wlr_output *o);
/* Which backend it landed on: "drm", "nested-wayland", "nested-x11",
 * "headless" or "unknown". C, because a wlroots without X11 has no
 * wlr_output_is_x11 to call. */
const char *tw_output_backend_name(struct wlr_output *o);

/* `wlr_output_event_present`, as ours. */
struct tw_present {
    uint32_t commit_seq;
    bool presented;
    /* WLR_OUTPUT_PRESENT_HW_CLOCK: measured against real display hardware. */
    bool hw_clock;
    uint64_t when_ns;
};
void tw_present_read(const void *event, struct tw_present *out);

/* A wlr_output_state on the heap: Rust cannot size one. Initialised;
 * tw_output_state_free finishes and frees it. */
struct wlr_output_state *tw_output_state_new(void);
void tw_output_state_free(struct wlr_output_state *s);
/* The buffer a render pass left in the state, or NULL. */
struct wlr_buffer *tw_output_state_buffer(const struct wlr_output_state *s);

/* MARK: render passes */

/* wlr_render_rect_options. blend: 0 premultiplied, 1 none. */
struct tw_rect {
    int32_t x, y, width, height;
    float r, g, b, a;
    int32_t blend;
};
void tw_pass_add_rect(struct wlr_render_pass *pass, const struct tw_rect *r);

/* wlr_render_texture_options. A src_box of all zeroes is the whole
 * texture; alpha < 0 is none (opaque as drawn). */
struct tw_texture_draw {
    struct wlr_texture *texture;
    double src_x, src_y, src_width, src_height;
    int32_t x, y, width, height;
    int32_t transform;
    float alpha;
    int32_t blend;
    struct wlr_drm_syncobj_timeline *wait_timeline;
    uint64_t wait_point;
};
void tw_pass_add_texture(struct wlr_render_pass *pass, const struct tw_texture_draw *d);

/* MARK: surfaces */

int32_t tw_surface_width(const struct wlr_surface *s);
int32_t tw_surface_height(const struct wlr_surface *s);
uint32_t tw_surface_seq(const struct wlr_surface *s);
int32_t tw_surface_transform(const struct wlr_surface *s);
/* wlr_surface_get_buffer_source_box, into x, y, width, height. */
void tw_surface_source_box(struct wlr_surface *s, double out[4]);
/* Whether the commit just made attached a buffer (WLR_SURFACE_STATE_BUFFER). */
bool tw_surface_committed_buffer(const struct wlr_surface *s);
/* Frame-done, now, to `s` and every subsurface under it. */
void tw_surface_frame_done_tree(struct wlr_surface *s);
/* The client owning the surface, or NULL. */
struct wl_client *tw_surface_client(struct wlr_surface *s);
/* The pid of the client owning the surface, or -1. */
int tw_surface_client_pid(struct wlr_surface *s);

/* MARK: xdg-shell */

struct wlr_surface *tw_xdg_toplevel_surface(const struct wlr_xdg_toplevel *t);
const char *tw_xdg_toplevel_app_id(const struct wlr_xdg_toplevel *t);   /* may be NULL */
const char *tw_xdg_toplevel_title(const struct wlr_xdg_toplevel *t);    /* may be NULL */
bool tw_xdg_toplevel_initial_commit(const struct wlr_xdg_toplevel *t);
bool tw_xdg_toplevel_initialized(const struct wlr_xdg_toplevel *t);
/* requested: 1 maximized, 2 minimized, 4 fullscreen. */
uint32_t tw_xdg_toplevel_requested(const struct wlr_xdg_toplevel *t);
/* The window geometry's offset in the surface. */
void tw_xdg_toplevel_geometry(const struct wlr_xdg_toplevel *t, int32_t out[2]);
/* request_resize's edges. */
uint32_t tw_xdg_resize_edges(const void *event);
/* Maximize, fullscreen and minimize: what undertow will do if asked. */
void tw_xdg_toplevel_offer_capabilities(struct wlr_xdg_toplevel *t);

struct wlr_surface *tw_xdg_popup_surface(const struct wlr_xdg_popup *p);
struct wlr_surface *tw_xdg_popup_parent(const struct wlr_xdg_popup *p);    /* may be NULL */
bool tw_xdg_popup_initial_commit(const struct wlr_xdg_popup *p);
/* Its position (relative to the parent's geometry) and its own geometry's
 * offset: x, y, own x, own y. */
void tw_xdg_popup_geometry(const struct wlr_xdg_popup *p, int32_t out[4]);
void tw_xdg_popup_unconstrain(struct wlr_xdg_popup *p, int32_t x, int32_t y, int32_t width, int32_t height);

/* MARK: layer shell */

struct wlr_surface *tw_layer_surface(const struct wlr_layer_surface_v1 *l);
const char *tw_layer_namespace(const struct wlr_layer_surface_v1 *l);
uint32_t tw_layer_layer(const struct wlr_layer_surface_v1 *l);
/* 0 none, 1 exclusive, 2 on demand. */
uint32_t tw_layer_keyboard_interactive(const struct wlr_layer_surface_v1 *l);
/* What it asks for: anchor, desired width, height, margins top right
 * bottom left, exclusive zone. */
struct tw_layer_request {
    uint32_t anchor;
    uint32_t desired_width, desired_height;
    int32_t margin_top, margin_right, margin_bottom, margin_left;
    int32_t exclusive_zone;
};
void tw_layer_request_read(const struct wlr_layer_surface_v1 *l, struct tw_layer_request *out);
struct wlr_output *tw_layer_output(const struct wlr_layer_surface_v1 *l);  /* may be NULL */
void tw_layer_set_output(struct wlr_layer_surface_v1 *l, struct wlr_output *o);

/* MARK: decorations */

struct wlr_xdg_toplevel *tw_decoration_toplevel(const struct wlr_xdg_toplevel_decoration_v1 *d);
/* We draw the frame (WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE). */
void tw_decoration_server_side(struct wlr_xdg_toplevel_decoration_v1 *d);

/* MARK: the session lock */

/* The manager's global, to keep it to the privileged socket (P16.2c). */
const struct wl_global *tw_session_lock_manager_global(const struct wlr_session_lock_manager_v1 *m);
struct wlr_surface *tw_lock_surface_surface(const struct wlr_session_lock_surface_v1 *s);
struct wlr_output *tw_lock_surface_output(const struct wlr_session_lock_surface_v1 *s);

/* MARK: explicit sync (linux-drm-syncobj-v1, U.3b) */

/* Why it cannot be offered: 0 it can, 1 the renderer takes no timeline
 * waits, 2 the backend's output commits take none. */
int tw_syncobj_unsupported(const struct wlr_renderer *r, const struct wlr_backend *b);
/* The manager on the renderer's DRM node; false if it refused. */
bool tw_syncobj_create(struct wl_display *d, struct wlr_renderer *r);
/* A commit brought a new buffer with an acquire point: arm its release
 * (wlroots 0.20 keeps the release point private; the protocol requires the
 * two together). True if one was armed. */
bool tw_syncobj_arm_release(struct wlr_surface *s);
/* The surface's acquire point, for the renderer to wait on. */
bool tw_syncobj_acquire(struct wlr_surface *s, struct wlr_drm_syncobj_timeline **timeline, uint64_t *point);

/* MARK: output management (wlr-output-management-v1, P14.7b) */

/* What one head of a configuration asks for. The mode is its chosen mode's,
 * else its custom mode's. */
struct tw_head_ask {
    struct wlr_output *output;
    bool enabled;
    int32_t mode_width, mode_height, refresh_mhz;
    int32_t x, y;
    double scale;
};
void tw_head_read(const struct wlr_output_configuration_head_v1 *h, struct tw_head_ask *out);
/* Apply the head's state to its output: test only, or commit. */
bool tw_head_try(struct wlr_output_configuration_head_v1 *h, bool commit);
/* Tell every client what is true: one head per output, at x, y and scale. */
void tw_output_manager_publish(struct wlr_output_manager_v1 *m, struct wlr_output **outputs,
                               const int32_t *x, const int32_t *y, const double *scale, size_t n);
void tw_output_state_set_scale(struct wlr_output_state *s, double scale);

/* MARK: display sleep (idle-inhibit-v1, ext-idle-notify-v1, U.9) */

struct wlr_surface *tw_idle_inhibitor_surface(const struct wlr_idle_inhibitor_v1 *i);

/* MARK: the seat (P6.4) */

/* Its pointer devices' events, as ours. */
struct tw_motion {
    uint32_t time_msec;
    double dx, dy, unaccel_dx, unaccel_dy;
};
void tw_pointer_motion_read(const void *event, struct tw_motion *out);
/* motion_absolute: x and y in 0…1 across the layout. */
void tw_pointer_motion_absolute_read(const void *event, uint32_t *time_msec, double *x, double *y);
/* button: 1 pressed, 0 released. */
void tw_pointer_button_read(const void *event, uint32_t *time_msec, uint32_t *button, uint32_t *pressed);
void tw_seat_pointer_axis(struct wlr_seat *seat, const void *axis_event);
/* key: 1 pressed, 0 released. */
void tw_keyboard_key_read(const void *event, uint32_t *time_msec, uint32_t *keycode, uint32_t *pressed);

/* 1 pointer, 2 keyboard, 0 another kind. */
int tw_input_device_kind(const struct wlr_input_device *d);
struct wlr_pointer *tw_input_device_pointer(struct wlr_input_device *d);
struct wlr_keyboard *tw_input_device_keyboard(struct wlr_input_device *d);
struct wlr_input_device *tw_pointer_device(struct wlr_pointer *p);
struct wlr_input_device *tw_keyboard_device(struct wlr_keyboard *k);
const char *tw_input_device_name(const struct wlr_input_device *d);
struct wlr_pointer *tw_virtual_pointer_from_event(const void *new_pointer_event);
struct wlr_keyboard *tw_virtual_keyboard_keyboard(void *virtual_keyboard);

/* The keyboard notifies, with the seat's current keyboard's keycodes and
 * modifiers; false if the seat has no keyboard yet. */
bool tw_seat_keyboard_enter(struct wlr_seat *seat, struct wlr_surface *s);
void tw_seat_keyboard_modifiers(struct wlr_seat *seat, struct wlr_keyboard *k);
struct wlr_surface *tw_seat_keyboard_focused(const struct wlr_seat *seat);
/* The client with the pointer, as an opaque identity. */
const void *tw_seat_pointer_focused_client(const struct wlr_seat *seat);
/* **No grab survives a lock**: end a keyboard grab (then re-enter
 * `lock_surface` if given) and a pointer grab. How many were ended. */
int tw_seat_break_grabs(struct wlr_seat *seat, struct wlr_surface *lock_surface);
/* request_set_selection / _primary_selection: accept (wlroots checks the
 * serial). */
void tw_seat_accept_selection(struct wlr_seat *seat, const void *event, bool primary);
/* request_start_drag: start it if the serial is a real press, else destroy
 * its source (a client waits on its own cancel). True if started. */
bool tw_seat_accept_drag(struct wlr_seat *seat, const void *event);
/* start_drag's icon (a wlr_drag_icon), or NULL; and its surface. */
struct wlr_drag_icon *tw_drag_icon(const void *drag);
struct wlr_surface *tw_drag_icon_surface(const struct wlr_drag_icon *icon);
/* request_set_cursor: the requesting client, surface (or NULL) and hotspot. */
const void *tw_set_cursor_read(const void *event, struct wlr_surface **surface, int32_t *hot_x, int32_t *hot_y);
/* request_set_shape: the shape's name if it is the pointer's, else NULL;
 * the requesting client in *client. */
const char *tw_set_shape_read(const void *event, const void **client);
/* pointer focus_change: whether the surface changed. */
bool tw_pointer_focus_changed(const void *event);
/* The surface's attach offset this commit (a cursor's hotspot moves by it). */
void tw_surface_offset(const struct wlr_surface *s, int32_t *dx, int32_t *dy);

/* Keymaps (xkbcommon): compile the layout (NULL or "" for xkbcommon's
 * default, which honours XKB_DEFAULT_*), give a keyboard with none one, at
 * wlroots' repeat. 1 given, 0 it had one, -1 nothing compiled, -2 refused. */
int tw_keyboard_give_keymap(struct wlr_keyboard *k, const char *layout, const char *variant);
/* Set a keymap compiled from layout/variant; false if it did not compile. */
bool tw_keyboard_set_layout(struct wlr_keyboard *k, const char *layout, const char *variant);
bool tw_keymap_compiles(const char *layout, const char *variant);
/* The name of the keyboard's keymap's first layout, or NULL. */
const char *tw_keyboard_layout_name(const struct wlr_keyboard *k);
uint32_t tw_keyboard_modifiers(struct wlr_keyboard *k);
/* The key's symbols: translated with the modifiers, then the raw level-0
 * ones not already there. How many, at most `max`, into out. */
size_t tw_keyboard_syms(struct wlr_keyboard *k, uint32_t keycode, uint32_t *out, size_t max);
uint32_t tw_keysym_from_name(const char *name);

/* MARK: pointer constraints (relative-pointer, pointer-constraints, U.6) */

/* The seat's pointer focus and where in it the pointer is. */
struct wlr_surface *tw_seat_pointer_focused(const struct wlr_seat *seat, double *sx, double *sy);
void tw_relative_motion(struct wlr_relative_pointer_manager_v1 *m, struct wlr_seat *seat, uint32_t time_msec,
                        double dx, double dy, double unaccel_dx, double unaccel_dy);
bool tw_constraint_locked(const struct wlr_pointer_constraint_v1 *c);
struct wlr_surface *tw_constraint_surface(const struct wlr_pointer_constraint_v1 *c);
bool tw_constraint_contains(struct wlr_pointer_constraint_v1 *c, double x, double y);
/* The region's nearest point to (x, y), box by box; false if it is empty. */
bool tw_constraint_nearest(struct wlr_pointer_constraint_v1 *c, double x, double y, double *nx, double *ny);
/* A lock's cursor-position hint, if the client gave one. */
bool tw_constraint_hint(const struct wlr_pointer_constraint_v1 *c, double *x, double *y);

/* MARK: text input and input methods (text-input-v3, input-method-v2, U.5) */

struct wlr_surface *tw_text_input_focused(const struct wlr_text_input_v3 *ti);
bool tw_text_input_enabled(const struct wlr_text_input_v3 *ti);
/* Whether the text input's client is the surface's. */
bool tw_text_input_same_client(const struct wlr_text_input_v3 *ti, struct wlr_surface *s);
void tw_text_input_cursor(const struct wlr_text_input_v3 *ti, int32_t out[4]);
/* The field's state to the method: surrounding text and content type when
 * the field offers them, the cause, then done. */
void tw_text_input_send_state(struct wlr_text_input_v3 *ti, struct wlr_input_method_v2 *im);
/* The method's commit to the field: preedit, commit string, deletion, done.
 * The sizes, never the text (it can be a password). */
void tw_input_method_relay(struct wlr_input_method_v2 *im, struct wlr_text_input_v3 *ti,
                           size_t *preedit_bytes, size_t *commit_bytes);
/* The method went: whatever preedit the field showed is withdrawn. */
void tw_text_input_clear_preedit(struct wlr_text_input_v3 *ti);
/* Whether `k` is the method's own virtual keyboard (its typing, which would
 * loop back to it). */
bool tw_keyboard_from_method(struct wlr_keyboard *k, const struct wlr_input_method_v2 *im);
void tw_grab_send_modifiers(struct wlr_input_method_keyboard_grab_v2 *g, struct wlr_keyboard *k);
struct wlr_surface *tw_input_popup_surface(const struct wlr_input_popup_surface_v2 *p);
void tw_input_popup_send_rectangle(struct wlr_input_popup_surface_v2 *p, const int32_t r[4]);

/* MARK: foreign toplevels, activation */

/* request_minimize / request_maximize's flag. */
bool tw_foreign_event_flag(const void *event, int maximize);
/* xdg_activation's request_activate: the surface to raise, or NULL. */
struct wlr_surface *tw_activation_surface(const void *event);

#endif /* ABYSS_TW_ACCESS_H */
