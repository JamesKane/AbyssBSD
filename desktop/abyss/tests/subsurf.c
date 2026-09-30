/*
 * subsurf.c — a window made of subsurfaces, for undertow's U.1 (docs/BACKLOG.md).
 *
 * undertow advertised wl_subcompositor from Phase 6 and never drew, framed or
 * hit-tested a subsurface (API-STUDY §1.3). Our own toolkit never makes one, so
 * nothing in the harness could see it; Firefox puts its whole page in one. This
 * client makes a window that is mostly subsurfaces, each placed to catch a
 * different wrong implementation:
 *
 *   parent  red    200x150, the xdg_toplevel
 *   A       blue    60x40 at ( 40, 30), above, DESYNCHRONISED, and redrawn on
 *                   every frame callback it gets — so "drawn once" and
 *                   "framed" are separate claims
 *   B       green   60x40 at (170,-20), above, half OUTSIDE the parent — a
 *                   hit-test that only knows the parent's rectangle misses it
 *   C       yellow  60x40 at (-30, 90), placed BELOW the parent, half outside —
 *                   "parent, then children" paints it on top, wrongly
 *
 * It logs what the compositor tells it, for the script to assert on:
 *
 *   subsurf: mapped
 *   subsurf: enter <parent|A|B|C> <x> <y>     surface-local, whole pixels
 *   subsurf: A frames <n>                      every 30 frame callbacks on A
 *
 * Built by live-subsurface.sh; not part of the product.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *compositor;
static struct wl_subcompositor *subcompositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct wl_pointer *pointer;

static struct wl_surface *parent, *sa, *sb, *sc;
static struct wl_buffer *buf_a;
static int configured, mapped;
static unsigned frames_a;

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(iface, "wl_compositor"))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_subcompositor"))
        subcompositor = wl_registry_bind(reg, name, &wl_subcompositor_interface, 1);
    else if (!strcmp(iface, "wl_shm"))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, "xdg_wm_base"))
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (!strcmp(iface, "wl_seat"))
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 3);
}
static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

/* One solid colour, XRGB8888. */
static struct wl_buffer *solid(int w, int h, uint32_t xrgb) {
    int stride = w * 4, size = stride * h;
    char name[64];
    snprintf(name, sizeof name, "/subsurf-%d-%08x", (int)getpid(), xrgb);
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { perror("shm_open"); exit(1); }
    shm_unlink(name);
    if (ftruncate(fd, size) < 0) { perror("ftruncate"); exit(1); }
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { perror("mmap"); exit(1); }
    for (int i = 0; i < w * h; i++) px[i] = xrgb;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
                                                    WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    munmap(px, size);
    return b;
}

static const char *name_of(struct wl_surface *s) {
    if (s == parent) return "parent";
    if (s == sa) return "A";
    if (s == sb) return "B";
    if (s == sc) return "C";
    return "unknown";
}

/* ---------------------------------------------------------------- A's clock */
static const struct wl_callback_listener frame_listener;
static void redraw_a(void) {
    struct wl_callback *cb = wl_surface_frame(sa);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    wl_surface_attach(sa, buf_a, 0, 0);
    wl_surface_damage_buffer(sa, 0, 0, 60, 40);
    wl_surface_commit(sa);          /* desynchronised: applies on its own */
}
static void frame_done(void *data, struct wl_callback *cb, uint32_t time) {
    (void)data; (void)time;
    wl_callback_destroy(cb);
    if (++frames_a % 30 == 0) {
        fprintf(stderr, "subsurf: A frames %u\n", frames_a);
    }
    redraw_a();
}
static const struct wl_callback_listener frame_listener = { frame_done };

/* ------------------------------------------------------------------- shell */
static void wm_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
    (void)data; xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener wm_listener = { wm_ping };

static void xs_configure(void *data, struct xdg_surface *xs, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xs, serial);
    if (configured) { wl_surface_commit(parent); return; }
    configured = 1;
    /* The children's state is cached (synchronised) until the parent commits,
     * except A's, which is desynchronised — so its first frame is asked for
     * here and answered only once the tree is mapped. */
    wl_surface_attach(parent, solid(200, 150, 0x00ff0000), 0, 0);
    wl_surface_damage_buffer(parent, 0, 0, 200, 150);
    redraw_a();
    wl_surface_commit(parent);
    if (!mapped) { mapped = 1; fprintf(stderr, "subsurf: mapped\n"); }
}
static const struct xdg_surface_listener xs_listener = { xs_configure };

static void tl_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h,
                         struct wl_array *s) { (void)d; (void)t; (void)w; (void)h; (void)s; }
static void tl_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; exit(0); }
static void tl_bounds(void *d, struct xdg_toplevel *t, int32_t w, int32_t h) {
    (void)d; (void)t; (void)w; (void)h;
}
static void tl_caps(void *d, struct xdg_toplevel *t, struct wl_array *c) {
    (void)d; (void)t; (void)c;
}
static const struct xdg_toplevel_listener tl_listener = {
    tl_configure, tl_close, tl_bounds, tl_caps,
};

/* ------------------------------------------------------------------ pointer */
/* Every slot filled, in the protocol's order (HANDOFF §2.3). */
static void ptr_enter(void *d, struct wl_pointer *p, uint32_t serial,
                      struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)serial;
    fprintf(stderr, "subsurf: enter %s %d %d\n", name_of(s),
            wl_fixed_to_int(x), wl_fixed_to_int(y));
}
static void ptr_leave(void *d, struct wl_pointer *p, uint32_t serial,
                      struct wl_surface *s) { (void)d; (void)p; (void)serial; (void)s; }
static void ptr_motion(void *d, struct wl_pointer *p, uint32_t t,
                       wl_fixed_t x, wl_fixed_t y) { (void)d; (void)p; (void)t; (void)x; (void)y; }
static void ptr_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t t,
                       uint32_t b, uint32_t st) {
    (void)d; (void)p; (void)serial; (void)t; (void)b; (void)st;
}
static void ptr_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a,
                     wl_fixed_t v) { (void)d; (void)p; (void)t; (void)a; (void)v; }
static void ptr_frame(void *d, struct wl_pointer *p) { (void)d; (void)p; }
static void ptr_axis_source(void *d, struct wl_pointer *p, uint32_t s) { (void)d; (void)p; (void)s; }
static void ptr_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a) {
    (void)d; (void)p; (void)t; (void)a;
}
static void ptr_axis_discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v) {
    (void)d; (void)p; (void)a; (void)v;
}
static const struct wl_pointer_listener ptr_listener = {
    ptr_enter, ptr_leave, ptr_motion, ptr_button, ptr_axis,
    ptr_frame, ptr_axis_source, ptr_axis_stop, ptr_axis_discrete,
};

/* The pointer capability arrives when the virtual pointer connects, which is
 * after us; asking before it exists is a protocol error (adversary.c). */
static void seat_caps(void *data, struct wl_seat *s, uint32_t caps) {
    (void)data;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
        pointer = wl_seat_get_pointer(s);
        wl_pointer_add_listener(pointer, &ptr_listener, NULL);
    }
}
static void seat_name(void *data, struct wl_seat *s, const char *n) {
    (void)data; (void)s; (void)n;
}
static const struct wl_seat_listener seat_listener = { seat_caps, seat_name };

/* --------------------------------------------------------------------- main */
static struct wl_subsurface *child(struct wl_surface *s, int x, int y,
                                   int w, int h, uint32_t xrgb) {
    struct wl_subsurface *sub = wl_subcompositor_get_subsurface(subcompositor, s, parent);
    wl_subsurface_set_position(sub, x, y);
    wl_surface_attach(s, solid(w, h, xrgb), 0, 0);
    wl_surface_damage_buffer(s, 0, 0, w, h);
    wl_surface_commit(s);           /* cached until the parent commits */
    return sub;
}

int main(void) {
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "subsurf: cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !subcompositor || !shm || !wm_base) {
        fprintf(stderr, "subsurf: missing a global (compositor %p, subcompositor %p, "
                "shm %p, xdg_wm_base %p)\n", (void *)compositor,
                (void *)subcompositor, (void *)shm, (void *)wm_base);
        return 1;
    }
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    if (seat) wl_seat_add_listener(seat, &seat_listener, NULL);

    parent = wl_compositor_create_surface(compositor);
    sa = wl_compositor_create_surface(compositor);
    sb = wl_compositor_create_surface(compositor);
    sc = wl_compositor_create_surface(compositor);

    buf_a = solid(60, 40, 0x000000ff);
    struct wl_subsurface *suba = wl_subcompositor_get_subsurface(subcompositor, sa, parent);
    wl_subsurface_set_position(suba, 40, 30);
    wl_subsurface_set_desync(suba);
    (void)child(sb, 170, -20, 60, 40, 0x0000ff00);
    struct wl_subsurface *subc = child(sc, -30, 90, 60, 40, 0x00ffff00);
    wl_subsurface_place_below(subc, parent);

    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, parent);
    xdg_surface_add_listener(xs, &xs_listener, NULL);
    struct xdg_toplevel *tl = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(tl, &tl_listener, NULL);
    xdg_toplevel_set_title(tl, "subsurf");
    xdg_toplevel_set_app_id(tl, "org.abyssbsd.subsurf");
    wl_surface_commit(parent);      /* the initial commit: no buffer yet */

    while (wl_display_dispatch(dpy) != -1) { }
    return 0;
}
