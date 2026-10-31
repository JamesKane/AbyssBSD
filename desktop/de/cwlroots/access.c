/* CWlroots for Rust — see include/tw-access.h. Accessors, and nothing else. */
#include "tw-access.h"

#include <stdlib.h>
#include <time.h>
#include <math.h>
#include <xkbcommon/xkbcommon.h>

#define TW_SIGNAL(type, sig) \
    struct tw_listener *tw_##type##_on_##sig(struct wlr_##type *o, tw_notify_fn fn, void *ctx) { \
        return tw_listen(&o->events.sig, fn, ctx); \
    }
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
#undef TW_SIGNAL

struct tw_listener *tw_seat_on_pointer_focus_change(struct wlr_seat *s, tw_notify_fn fn, void *ctx) {
    return tw_listen(&s->pointer_state.events.focus_change, fn, ctx);
}

const char *tw_output_name(const struct wlr_output *o) { return o->name; }
int32_t tw_output_width(const struct wlr_output *o) { return o->width; }
int32_t tw_output_height(const struct wlr_output *o) { return o->height; }
int32_t tw_output_refresh(const struct wlr_output *o) { return o->refresh; }
uint32_t tw_output_commit_seq(const struct wlr_output *o) { return o->commit_seq; }
float tw_output_scale(const struct wlr_output *o) { return o->scale; }
int32_t tw_output_transform(const struct wlr_output *o) { return (int32_t)o->transform; }
bool tw_output_enabled(const struct wlr_output *o) { return o->enabled; }

const char *tw_output_backend_name(struct wlr_output *o) {
    if (wlr_output_is_drm(o)) return "drm";
    if (wlr_output_is_wl(o)) return "nested-wayland";
#if WLR_HAS_X11_BACKEND
    if (wlr_output_is_x11(o)) return "nested-x11";
#endif
    if (wlr_output_is_headless(o)) return "headless";
    return "unknown";
}

void tw_present_read(const void *event, struct tw_present *out) {
    const struct wlr_output_event_present *e = event;
    out->commit_seq = e->commit_seq;
    out->presented = e->presented;
    out->hw_clock = (e->flags & WLR_OUTPUT_PRESENT_HW_CLOCK) != 0;
    out->when_ns = (uint64_t)e->when.tv_sec * 1000000000u + (uint64_t)e->when.tv_nsec;
}

struct wlr_output_state *tw_output_state_new(void) {
    struct wlr_output_state *s = calloc(1, sizeof(*s));
    if (s) wlr_output_state_init(s);
    return s;
}

void tw_output_state_free(struct wlr_output_state *s) {
    if (!s) return;
    wlr_output_state_finish(s);
    free(s);
}

struct wlr_buffer *tw_output_state_buffer(const struct wlr_output_state *s) { return s->buffer; }

static enum wlr_render_blend_mode blend(int32_t b) {
    return b == 1 ? WLR_RENDER_BLEND_MODE_NONE : WLR_RENDER_BLEND_MODE_PREMULTIPLIED;
}

void tw_pass_add_rect(struct wlr_render_pass *pass, const struct tw_rect *r) {
    struct wlr_render_rect_options o = {
        .box = { .x = r->x, .y = r->y, .width = r->width, .height = r->height },
        .color = { .r = r->r, .g = r->g, .b = r->b, .a = r->a },
        .blend_mode = blend(r->blend),
    };
    wlr_render_pass_add_rect(pass, &o);
}

void tw_pass_add_texture(struct wlr_render_pass *pass, const struct tw_texture_draw *d) {
    struct wlr_render_texture_options o = {
        .texture = d->texture,
        .src_box = { .x = d->src_x, .y = d->src_y, .width = d->src_width, .height = d->src_height },
        .dst_box = { .x = d->x, .y = d->y, .width = d->width, .height = d->height },
        .transform = (enum wl_output_transform)d->transform,
        .alpha = d->alpha < 0 ? NULL : &d->alpha,
        .blend_mode = blend(d->blend),
        .wait_timeline = d->wait_timeline,
        .wait_point = d->wait_point,
    };
    wlr_render_pass_add_texture(pass, &o);
}

int32_t tw_surface_width(const struct wlr_surface *s) { return s->current.width; }
int32_t tw_surface_height(const struct wlr_surface *s) { return s->current.height; }
uint32_t tw_surface_seq(const struct wlr_surface *s) { return s->current.seq; }
int32_t tw_surface_transform(const struct wlr_surface *s) { return (int32_t)s->current.transform; }

void tw_surface_source_box(struct wlr_surface *s, double out[4]) {
    struct wlr_fbox b = { 0 };
    wlr_surface_get_buffer_source_box(s, &b);
    out[0] = b.x; out[1] = b.y; out[2] = b.width; out[3] = b.height;
}

bool tw_surface_committed_buffer(const struct wlr_surface *s) {
    return (s->current.committed & WLR_SURFACE_STATE_BUFFER) != 0;
}

static void frame_done(struct wlr_surface *s, int sx, int sy, void *data) {
    (void)sx; (void)sy;
    wlr_surface_send_frame_done(s, data);
}

void tw_surface_frame_done_tree(struct wlr_surface *s) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    wlr_surface_for_each_surface(s, frame_done, &now);
}

struct wl_client *tw_surface_client(struct wlr_surface *s) {
    return s->resource ? wl_resource_get_client(s->resource) : NULL;
}

int tw_surface_client_pid(struct wlr_surface *s) {
    if (!s->resource) return -1;
    pid_t pid = -1;
    wl_client_get_credentials(wl_resource_get_client(s->resource), &pid, NULL, NULL);
    return (int)pid;
}

struct wlr_surface *tw_xdg_toplevel_surface(const struct wlr_xdg_toplevel *t) { return t->base->surface; }
const char *tw_xdg_toplevel_app_id(const struct wlr_xdg_toplevel *t) { return t->app_id; }
const char *tw_xdg_toplevel_title(const struct wlr_xdg_toplevel *t) { return t->title; }
bool tw_xdg_toplevel_initial_commit(const struct wlr_xdg_toplevel *t) { return t->base->initial_commit; }
bool tw_xdg_toplevel_initialized(const struct wlr_xdg_toplevel *t) { return t->base->initialized; }

uint32_t tw_xdg_toplevel_requested(const struct wlr_xdg_toplevel *t) {
    return (t->requested.maximized ? 1u : 0u) | (t->requested.minimized ? 2u : 0u)
         | (t->requested.fullscreen ? 4u : 0u);
}

void tw_xdg_toplevel_geometry(const struct wlr_xdg_toplevel *t, int32_t out[2]) {
    out[0] = t->base->current.geometry.x;
    out[1] = t->base->current.geometry.y;
}

uint32_t tw_xdg_resize_edges(const void *event) {
    return ((const struct wlr_xdg_toplevel_resize_event *)event)->edges;
}

void tw_xdg_toplevel_offer_capabilities(struct wlr_xdg_toplevel *t) {
    wlr_xdg_toplevel_set_wm_capabilities(t, WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE
        | WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN | WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE);
}

struct wlr_surface *tw_xdg_popup_surface(const struct wlr_xdg_popup *p) { return p->base->surface; }
struct wlr_surface *tw_xdg_popup_parent(const struct wlr_xdg_popup *p) { return p->parent; }
bool tw_xdg_popup_initial_commit(const struct wlr_xdg_popup *p) { return p->base->initial_commit; }

void tw_xdg_popup_geometry(const struct wlr_xdg_popup *p, int32_t out[4]) {
    out[0] = p->current.geometry.x;
    out[1] = p->current.geometry.y;
    out[2] = p->base->current.geometry.x;
    out[3] = p->base->current.geometry.y;
}

void tw_xdg_popup_unconstrain(struct wlr_xdg_popup *p, int32_t x, int32_t y, int32_t width, int32_t height) {
    struct wlr_box box = { .x = x, .y = y, .width = width, .height = height };
    wlr_xdg_popup_unconstrain_from_box(p, &box);
}

struct wlr_surface *tw_layer_surface(const struct wlr_layer_surface_v1 *l) { return l->surface; }
const char *tw_layer_namespace(const struct wlr_layer_surface_v1 *l) { return l->namespace ? l->namespace : ""; }
uint32_t tw_layer_layer(const struct wlr_layer_surface_v1 *l) { return (uint32_t)l->current.layer; }
uint32_t tw_layer_keyboard_interactive(const struct wlr_layer_surface_v1 *l) {
    return (uint32_t)l->current.keyboard_interactive;
}

void tw_layer_request_read(const struct wlr_layer_surface_v1 *l, struct tw_layer_request *out) {
    const struct wlr_layer_surface_v1_state *s = &l->current;
    out->anchor = s->anchor;
    out->desired_width = s->desired_width;
    out->desired_height = s->desired_height;
    out->margin_top = s->margin.top;
    out->margin_right = s->margin.right;
    out->margin_bottom = s->margin.bottom;
    out->margin_left = s->margin.left;
    out->exclusive_zone = s->exclusive_zone;
}

struct wlr_output *tw_layer_output(const struct wlr_layer_surface_v1 *l) { return l->output; }
void tw_layer_set_output(struct wlr_layer_surface_v1 *l, struct wlr_output *o) { l->output = o; }

bool tw_foreign_event_flag(const void *event, int maximize) {
    if (maximize) return ((const struct wlr_foreign_toplevel_handle_v1_maximized_event *)event)->maximized;
    return ((const struct wlr_foreign_toplevel_handle_v1_minimized_event *)event)->minimized;
}

struct wlr_surface *tw_activation_surface(const void *event) {
    return ((const struct wlr_xdg_activation_v1_request_activate_event *)event)->surface;
}

struct wlr_xdg_toplevel *tw_decoration_toplevel(const struct wlr_xdg_toplevel_decoration_v1 *d) { return d->toplevel; }

void tw_decoration_server_side(struct wlr_xdg_toplevel_decoration_v1 *d) {
    wlr_xdg_toplevel_decoration_v1_set_mode(d, WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
}

const struct wl_global *tw_session_lock_manager_global(const struct wlr_session_lock_manager_v1 *m) { return m->global; }
struct wlr_surface *tw_lock_surface_surface(const struct wlr_session_lock_surface_v1 *s) { return s->surface; }
struct wlr_output *tw_lock_surface_output(const struct wlr_session_lock_surface_v1 *s) { return s->output; }

int tw_syncobj_unsupported(const struct wlr_renderer *r, const struct wlr_backend *b) {
    if (!r->features.timeline) return 1;
    if (!b->features.timeline) return 2;
    return 0;
}

bool tw_syncobj_create(struct wl_display *d, struct wlr_renderer *r) {
    int fd = wlr_renderer_get_drm_fd(r);
    return fd >= 0 && wlr_linux_drm_syncobj_manager_v1_create(d, 1, fd) != NULL;
}

bool tw_syncobj_arm_release(struct wlr_surface *s) {
    if (!(s->current.committed & WLR_SURFACE_STATE_BUFFER) || !s->buffer) return false;
    struct wlr_linux_drm_syncobj_surface_v1_state *st = wlr_linux_drm_syncobj_v1_get_surface_state(s);
    if (!st || !st->acquire_timeline) return false;
    return wlr_linux_drm_syncobj_v1_state_signal_release_with_buffer(st, &s->buffer->base);
}

bool tw_syncobj_acquire(struct wlr_surface *s, struct wlr_drm_syncobj_timeline **timeline, uint64_t *point) {
    struct wlr_linux_drm_syncobj_surface_v1_state *st = wlr_linux_drm_syncobj_v1_get_surface_state(s);
    if (!st || !st->acquire_timeline) return false;
    *timeline = st->acquire_timeline;
    *point = st->acquire_point;
    return true;
}

void tw_head_read(const struct wlr_output_configuration_head_v1 *h, struct tw_head_ask *out) {
    const struct wlr_output_head_v1_state *st = &h->state;
    out->output = st->output;
    out->enabled = st->enabled;
    out->mode_width = st->custom_mode.width;
    out->mode_height = st->custom_mode.height;
    out->refresh_mhz = st->custom_mode.refresh;
    if (st->mode) {
        out->mode_width = st->mode->width;
        out->mode_height = st->mode->height;
        out->refresh_mhz = st->mode->refresh;
    }
    out->x = st->x;
    out->y = st->y;
    out->scale = st->scale;
}

bool tw_head_try(struct wlr_output_configuration_head_v1 *h, bool commit) {
    if (!h->state.output) return false;
    struct wlr_output_state os;
    wlr_output_state_init(&os);
    wlr_output_head_v1_state_apply(&h->state, &os);
    bool ok = commit ? wlr_output_commit_state(h->state.output, &os) : wlr_output_test_state(h->state.output, &os);
    wlr_output_state_finish(&os);
    return ok;
}

void tw_output_manager_publish(struct wlr_output_manager_v1 *m, struct wlr_output **outputs,
                               const int32_t *x, const int32_t *y, const double *scale, size_t n) {
    struct wlr_output_configuration_v1 *config = wlr_output_configuration_v1_create();
    if (!config) return;
    for (size_t i = 0; i < n; i++) {
        struct wlr_output_configuration_head_v1 *head = wlr_output_configuration_head_v1_create(config, outputs[i]);
        if (!head) continue;
        head->state.x = x[i];
        head->state.y = y[i];
        head->state.scale = (float)scale[i];
    }
    wlr_output_manager_v1_set_configuration(m, config); /* takes ownership */
}

void tw_output_state_set_scale(struct wlr_output_state *s, double scale) { wlr_output_state_set_scale(s, (float)scale); }

struct wlr_surface *tw_idle_inhibitor_surface(const struct wlr_idle_inhibitor_v1 *i) { return i->surface; }

void tw_pointer_motion_read(const void *event, struct tw_motion *out) {
    const struct wlr_pointer_motion_event *e = event;
    out->time_msec = e->time_msec;
    out->dx = e->delta_x; out->dy = e->delta_y;
    out->unaccel_dx = e->unaccel_dx; out->unaccel_dy = e->unaccel_dy;
}

void tw_pointer_motion_absolute_read(const void *event, uint32_t *time_msec, double *x, double *y) {
    const struct wlr_pointer_motion_absolute_event *e = event;
    *time_msec = e->time_msec; *x = e->x; *y = e->y;
}

void tw_pointer_button_read(const void *event, uint32_t *time_msec, uint32_t *button, uint32_t *pressed) {
    const struct wlr_pointer_button_event *e = event;
    *time_msec = e->time_msec; *button = e->button;
    *pressed = e->state == WL_POINTER_BUTTON_STATE_PRESSED;
}

void tw_seat_pointer_axis(struct wlr_seat *seat, const void *axis_event) {
    const struct wlr_pointer_axis_event *e = axis_event;
    wlr_seat_pointer_notify_axis(seat, e->time_msec, e->orientation, e->delta, e->delta_discrete,
                                 e->source, e->relative_direction);
    wlr_seat_pointer_notify_frame(seat);
}

void tw_keyboard_key_read(const void *event, uint32_t *time_msec, uint32_t *keycode, uint32_t *pressed) {
    const struct wlr_keyboard_key_event *e = event;
    *time_msec = e->time_msec; *keycode = e->keycode;
    *pressed = e->state == WL_KEYBOARD_KEY_STATE_PRESSED;
}

int tw_input_device_kind(const struct wlr_input_device *d) {
    return d->type == WLR_INPUT_DEVICE_POINTER ? 1 : d->type == WLR_INPUT_DEVICE_KEYBOARD ? 2 : 0;
}
struct wlr_pointer *tw_input_device_pointer(struct wlr_input_device *d) { return wlr_pointer_from_input_device(d); }
struct wlr_keyboard *tw_input_device_keyboard(struct wlr_input_device *d) { return wlr_keyboard_from_input_device(d); }
struct wlr_input_device *tw_pointer_device(struct wlr_pointer *p) { return &p->base; }
struct wlr_input_device *tw_keyboard_device(struct wlr_keyboard *k) { return &k->base; }
const char *tw_input_device_name(const struct wlr_input_device *d) { return d->name ? d->name : "a device"; }

struct wlr_pointer *tw_virtual_pointer_from_event(const void *new_pointer_event) {
    const struct wlr_virtual_pointer_v1_new_pointer_event *e = new_pointer_event;
    return e->new_pointer ? &e->new_pointer->pointer : NULL;
}
struct wlr_keyboard *tw_virtual_keyboard_keyboard(void *virtual_keyboard) {
    return &((struct wlr_virtual_keyboard_v1 *)virtual_keyboard)->keyboard;
}

bool tw_seat_keyboard_enter(struct wlr_seat *seat, struct wlr_surface *s) {
    struct wlr_keyboard *k = wlr_seat_get_keyboard(seat);
    if (!k) return false;
    wlr_seat_keyboard_notify_enter(seat, s, k->keycodes, k->num_keycodes, &k->modifiers);
    return true;
}

void tw_seat_keyboard_modifiers(struct wlr_seat *seat, struct wlr_keyboard *k) {
    wlr_seat_keyboard_notify_modifiers(seat, &k->modifiers);
}

struct wlr_surface *tw_seat_keyboard_focused(const struct wlr_seat *seat) { return seat->keyboard_state.focused_surface; }
const void *tw_seat_pointer_focused_client(const struct wlr_seat *seat) { return seat->pointer_state.focused_client; }

int tw_seat_break_grabs(struct wlr_seat *seat, struct wlr_surface *lock_surface) {
    int n = 0;
    if (seat->keyboard_state.grab != seat->keyboard_state.default_grab) {
        wlr_seat_keyboard_end_grab(seat);
        n++;
        if (lock_surface) tw_seat_keyboard_enter(seat, lock_surface);
    }
    if (seat->pointer_state.grab != seat->pointer_state.default_grab) {
        wlr_seat_pointer_end_grab(seat);
        n++;
    }
    return n;
}

void tw_seat_accept_selection(struct wlr_seat *seat, const void *event, bool primary) {
    if (primary) {
        const struct wlr_seat_request_set_primary_selection_event *e = event;
        wlr_seat_set_primary_selection(seat, e->source, e->serial);
    } else {
        const struct wlr_seat_request_set_selection_event *e = event;
        wlr_seat_set_selection(seat, e->source, e->serial);
    }
}

bool tw_seat_accept_drag(struct wlr_seat *seat, const void *event) {
    const struct wlr_seat_request_start_drag_event *e = event;
    if (!e->drag) return false;
    if (wlr_seat_validate_pointer_grab_serial(seat, e->origin, e->serial)) {
        wlr_seat_start_pointer_drag(seat, e->drag, e->serial);
        return true;
    }
    if (e->drag->source) wlr_data_source_destroy(e->drag->source);
    return false;
}

struct wlr_drag_icon *tw_drag_icon(const void *drag) { return ((const struct wlr_drag *)drag)->icon; }
struct wlr_surface *tw_drag_icon_surface(const struct wlr_drag_icon *icon) { return icon->surface; }

const void *tw_set_cursor_read(const void *event, struct wlr_surface **surface, int32_t *hot_x, int32_t *hot_y) {
    const struct wlr_seat_pointer_request_set_cursor_event *e = event;
    *surface = e->surface; *hot_x = e->hotspot_x; *hot_y = e->hotspot_y;
    return e->seat_client;
}

const char *tw_set_shape_read(const void *event, const void **client) {
    const struct wlr_cursor_shape_manager_v1_request_set_shape_event *e = event;
    *client = e->seat_client;
    if (e->device_type != WLR_CURSOR_SHAPE_MANAGER_V1_DEVICE_TYPE_POINTER) return NULL;
    return wlr_cursor_shape_v1_name(e->shape);
}

bool tw_pointer_focus_changed(const void *event) {
    const struct wlr_seat_pointer_focus_change_event *e = event;
    return e->old_surface != e->new_surface;
}

void tw_surface_offset(const struct wlr_surface *s, int32_t *dx, int32_t *dy) { *dx = s->current.dx; *dy = s->current.dy; }

static struct xkb_keymap *compile(const char *layout, const char *variant) {
    struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!ctx) return NULL;
    struct xkb_keymap *km;
    if (!layout || !*layout) {
        km = xkb_keymap_new_from_names(ctx, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
    } else {
        struct xkb_rule_names names = { .layout = layout, .variant = (variant && *variant) ? variant : NULL };
        km = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    }
    xkb_context_unref(ctx);
    return km;
}

bool tw_keymap_compiles(const char *layout, const char *variant) {
    struct xkb_keymap *km = compile(layout, variant);
    if (!km) return false;
    xkb_keymap_unref(km);
    return true;
}

int tw_keyboard_give_keymap(struct wlr_keyboard *k, const char *layout, const char *variant) {
    if (k->keymap) return 0;
    struct xkb_keymap *km = compile(layout, variant);
    if (!km) return -1;
    bool ok = wlr_keyboard_set_keymap(k, km);
    xkb_keymap_unref(km);  /* the keyboard takes its own reference */
    if (!ok) return -2;
    /* wlroots' own defaults, stated: a rate of 0 tells clients not to repeat. */
    wlr_keyboard_set_repeat_info(k, 25, 600);
    return 1;
}

bool tw_keyboard_set_layout(struct wlr_keyboard *k, const char *layout, const char *variant) {
    struct xkb_keymap *km = compile(layout, variant);
    if (!km) return false;
    bool ok = wlr_keyboard_set_keymap(k, km);
    xkb_keymap_unref(km);
    return ok;
}

const char *tw_keyboard_layout_name(const struct wlr_keyboard *k) {
    return k->keymap ? xkb_keymap_layout_get_name(k->keymap, 0) : NULL;
}

uint32_t tw_keyboard_modifiers(struct wlr_keyboard *k) { return wlr_keyboard_get_modifiers(k); }

size_t tw_keyboard_syms(struct wlr_keyboard *k, uint32_t keycode, uint32_t *out, size_t max) {
    size_t n = 0;
    xkb_keycode_t code = keycode + 8;
    const xkb_keysym_t *syms = NULL;
    if (k->xkb_state) {
        int c = xkb_state_key_get_syms(k->xkb_state, code, &syms);
        for (int i = 0; i < c && n < max; i++) out[n++] = syms[i];
    }
    if (k->keymap) {
        xkb_layout_index_t layout = k->xkb_state ? xkb_state_key_get_layout(k->xkb_state, code) : 0;
        int c = xkb_keymap_key_get_syms_by_level(k->keymap, code, layout, 0, &syms);
        for (int i = 0; i < c && n < max; i++) {
            bool have = false;
            for (size_t j = 0; j < n; j++) have = have || out[j] == syms[i];
            if (!have) out[n++] = syms[i];
        }
    }
    return n;
}

uint32_t tw_keysym_from_name(const char *name) { return xkb_keysym_from_name(name, XKB_KEYSYM_CASE_INSENSITIVE); }

struct wlr_surface *tw_seat_pointer_focused(const struct wlr_seat *seat, double *sx, double *sy) {
    *sx = seat->pointer_state.sx; *sy = seat->pointer_state.sy;
    return seat->pointer_state.focused_surface;
}

void tw_relative_motion(struct wlr_relative_pointer_manager_v1 *m, struct wlr_seat *seat, uint32_t time_msec,
                        double dx, double dy, double unaccel_dx, double unaccel_dy) {
    wlr_relative_pointer_manager_v1_send_relative_motion(m, seat, (uint64_t)time_msec * 1000, dx, dy, unaccel_dx, unaccel_dy);
}

bool tw_constraint_locked(const struct wlr_pointer_constraint_v1 *c) { return c->type == WLR_POINTER_CONSTRAINT_V1_LOCKED; }
struct wlr_surface *tw_constraint_surface(const struct wlr_pointer_constraint_v1 *c) { return c->surface; }

bool tw_constraint_contains(struct wlr_pointer_constraint_v1 *c, double x, double y) {
    return pixman_region32_contains_point(&c->region, (int)floor(x), (int)floor(y), NULL);
}

bool tw_constraint_nearest(struct wlr_pointer_constraint_v1 *c, double x, double y, double *nx, double *ny) {
    int n = 0;
    pixman_box32_t *boxes = pixman_region32_rectangles(&c->region, &n);
    if (!boxes || n <= 0) return false;
    double best = INFINITY;
    for (int i = 0; i < n; i++) {
        double cx = fmin(fmax(x, boxes[i].x1), boxes[i].x2 - 1);
        double cy = fmin(fmax(y, boxes[i].y1), boxes[i].y2 - 1);
        double d = (cx - x) * (cx - x) + (cy - y) * (cy - y);
        if (d < best) { best = d; *nx = cx; *ny = cy; }
    }
    return true;
}

bool tw_constraint_hint(const struct wlr_pointer_constraint_v1 *c, double *x, double *y) {
    if (!c->current.cursor_hint.enabled) return false;
    *x = c->current.cursor_hint.x; *y = c->current.cursor_hint.y;
    return true;
}
