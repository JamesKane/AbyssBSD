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

#endif /* ABYSS_TW_ACCESS_H */
