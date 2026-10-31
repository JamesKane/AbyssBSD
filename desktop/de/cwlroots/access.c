/* CWlroots for Rust — see include/tw-access.h. Accessors, and nothing else. */
#include "tw-access.h"

#include <stdlib.h>

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
#undef TW_SIGNAL

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
