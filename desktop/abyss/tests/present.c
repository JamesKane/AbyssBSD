/*
 * present.c — a client that asks when its frames were shown, for undertow's U.4
 * (docs/BACKLOG.md).
 *
 * undertow offered no wp_presentation, so a toolkit could only estimate when a
 * frame reached the display (F-101: mpv, Chromium, GTK, Zed and LÖVE each build
 * an estimator) — while the compositor held the answer for its own frame
 * contract. This client draws on every frame callback, asks for presentation
 * feedback on every commit, and after 120 presented frames prints one line:
 *
 *   present: clock <id> mono <0|1> presented <n> discarded <n> refresh <ns>
 *            median <ns> min <ns> max <ns> monotonic <0|1> seq <0|1>
 *            oldest <ns> future <0|1> flags <hex>
 *
 * `mono` says whether the clock named is this platform's CLOCK_MONOTONIC —
 * the id itself differs (1 on Linux, 4 on FreeBSD). `oldest` is the most any feedback trailed its own frame's timestamp on
 * arrival, and `future` whether any timestamp was ahead of the client's own
 * clock — together, "the time is real and on the clock it was said to be on".
 *
 * Built by live-present.sh; not part of the product.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "presentation-time-client-protocol.h"

#define WANT 120

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wp_presentation *presentation;
static struct wl_surface *surface;
static struct wl_buffer *buffer;
static int configured;

static uint32_t clock_id = 0xffffffff;
static unsigned presented, discarded;
static uint64_t last_t, last_seq, intervals[WANT];
static unsigned n_intervals;
static uint32_t refresh, flags_seen;
static int monotonic = 1, seq_ok = 1, future = 0;
static uint64_t oldest;

static uint64_t now_on(clockid_t c) {
    struct timespec ts;
    clock_gettime(c, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(iface, "wl_compositor"))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_shm"))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, "xdg_wm_base"))
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (!strcmp(iface, "wp_presentation"))
        presentation = wl_registry_bind(reg, name, &wp_presentation_interface, 1);
}
static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static void pres_clock(void *d, struct wp_presentation *p, uint32_t clk) {
    (void)d; (void)p; clock_id = clk;
}
static const struct wp_presentation_listener pres_listener = { pres_clock };

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

static void finish(void) {
    qsort(intervals, n_intervals, sizeof intervals[0], cmp_u64);
    printf("present: clock %u mono %d presented %u discarded %u refresh %u median %llu "
           "min %llu max %llu monotonic %d seq %d oldest %llu future %d flags 0x%x\n",
           clock_id, clock_id == (uint32_t)CLOCK_MONOTONIC, presented, discarded, refresh,
           (unsigned long long)(n_intervals ? intervals[n_intervals / 2] : 0),
           (unsigned long long)(n_intervals ? intervals[0] : 0),
           (unsigned long long)(n_intervals ? intervals[n_intervals - 1] : 0),
           monotonic, seq_ok, (unsigned long long)oldest, future, flags_seen);
    fflush(stdout);
    exit(0);
}

/* ------------------------------------------------------------- the feedback */
static void fb_sync_output(void *d, struct wp_presentation_feedback *f,
                           struct wl_output *o) { (void)d; (void)f; (void)o; }
static void fb_presented(void *d, struct wp_presentation_feedback *f,
                         uint32_t sec_hi, uint32_t sec_lo, uint32_t nsec,
                         uint32_t refresh_ns, uint32_t seq_hi, uint32_t seq_lo,
                         uint32_t flags) {
    (void)d;
    wp_presentation_feedback_destroy(f);
    uint64_t t = (((uint64_t)sec_hi << 32) | sec_lo) * 1000000000ull + nsec;
    uint64_t seq = ((uint64_t)seq_hi << 32) | seq_lo;
    /* The clock the compositor named, read the moment the answer arrives. */
    uint64_t now = now_on((clockid_t)clock_id);
    if (t > now) future = 1;
    else if (now - t > oldest) oldest = now - t;
    if (presented > 0) {
        if (t <= last_t) monotonic = 0;
        else if (n_intervals < WANT) intervals[n_intervals++] = t - last_t;
        /* A counter the compositor does not know is 0 throughout; one it does
         * know must only go up. */
        if (seq != 0 && seq <= last_seq) seq_ok = 0;
    }
    last_t = t; last_seq = seq;
    refresh = refresh_ns;
    flags_seen |= flags;
    if (++presented == WANT) finish();
}
static void fb_discarded(void *d, struct wp_presentation_feedback *f) {
    (void)d;
    wp_presentation_feedback_destroy(f);
    discarded++;
    if (discarded > 3 * WANT) finish();      /* nothing is ever presented */
}
static const struct wp_presentation_feedback_listener fb_listener = {
    fb_sync_output, fb_presented, fb_discarded,
};

/* ------------------------------------------------------------ the frame loop */
static const struct wl_callback_listener frame_listener;
static void draw(void) {
    struct wl_callback *cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    struct wp_presentation_feedback *f = wp_presentation_feedback(presentation, surface);
    wp_presentation_feedback_add_listener(f, &fb_listener, NULL);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, 160, 120);
    wl_surface_commit(surface);
}
static void frame_done(void *data, struct wl_callback *cb, uint32_t time) {
    (void)data; (void)time;
    wl_callback_destroy(cb);
    draw();
}
static const struct wl_callback_listener frame_listener = { frame_done };

static void wm_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
    (void)data; xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener wm_listener = { wm_ping };
static void xs_configure(void *data, struct xdg_surface *xs, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xs, serial);
    if (!configured) { configured = 1; draw(); } else wl_surface_commit(surface);
}
static const struct xdg_surface_listener xs_listener = { xs_configure };
static void tl_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h,
                         struct wl_array *s) { (void)d; (void)t; (void)w; (void)h; (void)s; }
static void tl_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; exit(0); }
static void tl_bounds(void *d, struct xdg_toplevel *t, int32_t w, int32_t h) {
    (void)d; (void)t; (void)w; (void)h;
}
static void tl_caps(void *d, struct xdg_toplevel *t, struct wl_array *c) { (void)d; (void)t; (void)c; }
static const struct xdg_toplevel_listener tl_listener = { tl_configure, tl_close, tl_bounds, tl_caps };

static struct wl_buffer *solid(int w, int h) {
    int stride = w * 4, size = stride * h;
    char name[64];
    snprintf(name, sizeof name, "/present-%d", (int)getpid());
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { perror("shm_open"); exit(1); }
    shm_unlink(name);
    if (ftruncate(fd, size) < 0) { perror("ftruncate"); exit(1); }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return b;
}

int main(void) {
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "present: cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!presentation) { printf("present: no wp_presentation\n"); return 1; }
    if (!compositor || !shm || !wm_base) { fprintf(stderr, "present: missing a global\n"); return 1; }
    wp_presentation_add_listener(presentation, &pres_listener, NULL);
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);

    buffer = solid(160, 120);
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xs, &xs_listener, NULL);
    struct xdg_toplevel *tl = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(tl, &tl_listener, NULL);
    xdg_toplevel_set_app_id(tl, "org.abyssbsd.present");
    wl_surface_commit(surface);

    while (wl_display_dispatch(dpy) != -1) { }
    return 1;
}
