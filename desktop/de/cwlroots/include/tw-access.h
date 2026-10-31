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
#undef TW_SIGNAL

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

/* MARK: foreign toplevels, activation */

/* request_minimize / request_maximize's flag. */
bool tw_foreign_event_flag(const void *event, int maximize);
/* xdg_activation's request_activate: the surface to raise, or NULL. */
struct wlr_surface *tw_activation_surface(const void *event);

#endif /* ABYSS_TW_ACCESS_H */
