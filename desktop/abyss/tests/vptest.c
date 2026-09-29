// vptest — a window that crops, turns and scales its buffer, for undertow's
// U.8 (docs/BACKLOG.md).
//
// One mode per run:
//
//   crop   a 200x100 buffer, red left half, green right half with a blue
//          stripe down its middle (x 145..154); a viewport shows only the
//          green half (source 100,0 100x100), stretched to 300x200.
//   turn   a 100x200 buffer, red top half, green bottom half, with buffer
//          transform 90: the surface is 200x100, the picture turned.
//   frac   binds fractional-scale-v1 and wl_surface v6; on each preferred
//          scale it renders its 200x100 surface at that scale — a one-pixel
//          checkerboard — and says through a viewport how big it is. On a
//          display at that scale every buffer pixel is one screen pixel.
//
// It prints, a line each, flushed:
//
//     ready                   mapped
//     scale <n>               wp_fractional_scale_v1.preferred_scale (n/120)
//     bufscale <n>            wl_surface.preferred_buffer_scale
//     drew <w>x<h>            a buffer of that size attached (frac)
//
// A test helper, not part of the product; built by live-viewport.sh.
//
// Usage: vptest crop|turn|frac

#define _GNU_SOURCE
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "viewporter-proto.h"
#include "fractional-scale-proto.h"

#define RED   0xffff0000u
#define GREEN 0xff00ff00u
#define BLUE  0xff0000ffu

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wp_viewporter *viewporter;
static struct wp_fractional_scale_manager_v1 *fractions;
static struct wl_surface *surface;
static struct wp_viewport *viewport;
static struct xdg_surface *xsurface;
static struct xdg_toplevel *toplevel;
static const char *mode;
static int ready;
static unsigned compositor_version;

static void reg_global(void *d, struct wl_registry *r, uint32_t id, const char *iface, uint32_t v) {
    (void)d;
    if (!strcmp(iface, "wl_compositor")) {
        compositor_version = v < 6 ? v : 6;
        compositor = wl_registry_bind(r, id, &wl_compositor_interface, compositor_version);
    } else if (!strcmp(iface, "wl_shm"))
        shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
    else if (!strcmp(iface, "xdg_wm_base"))
        wm_base = wl_registry_bind(r, id, &xdg_wm_base_interface, 1);
    else if (!strcmp(iface, wp_viewporter_interface.name))
        viewporter = wl_registry_bind(r, id, &wp_viewporter_interface, 1);
    else if (!strcmp(iface, wp_fractional_scale_manager_v1_interface.name))
        fractions = wl_registry_bind(r, id, &wp_fractional_scale_manager_v1_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t id) { (void)d; (void)r; (void)id; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

/* A w×h buffer, each pixel from `paint`. */
static struct wl_buffer *buffer(int w, int h, uint32_t (*paint)(int, int)) {
    int stride = w * 4, size = stride * h;
    char name[64];
    static int n;
    snprintf(name, sizeof name, "/vptest-%d-%d", (int)getpid(), n++);
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { perror("shm_open"); exit(1); }
    shm_unlink(name);
    if (ftruncate(fd, size) < 0) { perror("ftruncate"); exit(1); }
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { perror("mmap"); exit(1); }
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) px[y * w + x] = paint(x, y);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    munmap(px, size);
    return b;
}
static uint32_t crop_paint(int x, int y) { (void)y; return x < 100 ? RED : (x >= 145 && x < 155 ? BLUE : GREEN); }
static uint32_t turn_paint(int x, int y) { (void)x; return y < 100 ? RED : GREEN; }
static uint32_t check_paint(int x, int y) { return (x + y) % 2 ? 0xff000000u : 0xffffffffu; }

static double frac_scale = 1.0;
static void draw(void) {
    if (!strcmp(mode, "crop")) {
        wl_surface_attach(surface, buffer(200, 100, crop_paint), 0, 0);
        wp_viewport_set_source(viewport, wl_fixed_from_int(100), 0, wl_fixed_from_int(100), wl_fixed_from_int(100));
        wp_viewport_set_destination(viewport, 300, 200);
    } else if (!strcmp(mode, "turn")) {
        wl_surface_attach(surface, buffer(100, 200, turn_paint), 0, 0);
        wl_surface_set_buffer_transform(surface, WL_OUTPUT_TRANSFORM_90);
    } else {
        int w = (int)(200 * frac_scale + 0.5), h = (int)(100 * frac_scale + 0.5);
        wl_surface_attach(surface, buffer(w, h, check_paint), 0, 0);
        wp_viewport_set_destination(viewport, 200, 100);
        printf("drew %dx%d\n", w, h);
    }
    wl_surface_damage_buffer(surface, 0, 0, INT32_MAX, INT32_MAX);
    wl_surface_commit(surface);
}

static void on_preferred(void *d, struct wp_fractional_scale_v1 *f, uint32_t scale) {
    (void)d; (void)f;
    printf("scale %u\n", scale);
    frac_scale = scale / 120.0;
    if (ready) draw();
}
static const struct wp_fractional_scale_v1_listener frac_listener = { on_preferred };

static void s_enter(void *d, struct wl_surface *s, struct wl_output *o) { (void)d; (void)s; (void)o; }
static void s_leave(void *d, struct wl_surface *s, struct wl_output *o) { (void)d; (void)s; (void)o; }
static void s_bufscale(void *d, struct wl_surface *s, int32_t f) { (void)d; (void)s; printf("bufscale %d\n", f); }
static void s_buftransform(void *d, struct wl_surface *s, uint32_t t) { (void)d; (void)s; (void)t; }
static const struct wl_surface_listener surface_listener = { s_enter, s_leave, s_bufscale, s_buftransform };

static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t s) { (void)d; xdg_wm_base_pong(b, s); }
static const struct xdg_wm_base_listener wm_listener = { wm_ping };
static void xs_configure(void *d, struct xdg_surface *xs, uint32_t s) {
    (void)d;
    xdg_surface_ack_configure(xs, s);
    if (!ready) { ready = 1; draw(); printf("ready\n"); }
    else wl_surface_commit(surface);
}
static const struct xdg_surface_listener xs_listener = { xs_configure };
static void tl_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) {
    (void)d; (void)t; (void)w; (void)h; (void)s;
}
static void tl_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; exit(0); }
static const struct xdg_toplevel_listener tl_listener = { tl_configure, tl_close };

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    mode = argc > 1 ? argv[1] : "crop";
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "vptest: cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !shm || !wm_base) { fprintf(stderr, "vptest: missing a core global\n"); return 2; }
    if (!viewporter) { fprintf(stderr, "vptest: no wp_viewporter\n"); return 2; }
    if (!strcmp(mode, "frac") && !fractions) { fprintf(stderr, "vptest: no wp_fractional_scale_manager_v1\n"); return 2; }
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);

    surface = wl_compositor_create_surface(compositor);
    wl_surface_add_listener(surface, &surface_listener, NULL);
    viewport = wp_viewporter_get_viewport(viewporter, surface);
    if (!strcmp(mode, "frac")) {
        struct wp_fractional_scale_v1 *f = wp_fractional_scale_manager_v1_get_fractional_scale(fractions, surface);
        wp_fractional_scale_v1_add_listener(f, &frac_listener, NULL);
    }
    xsurface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xsurface, &xs_listener, NULL);
    toplevel = xdg_surface_get_toplevel(xsurface);
    xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
    xdg_toplevel_set_app_id(toplevel, "org.abyssbsd.vptest");
    wl_surface_commit(surface);

    while (wl_display_dispatch(dpy) >= 0) {}
    return 0;
}
