// cursortest — a window that sets the pointer's picture, for undertow's U.7
// (docs/BACKLOG.md).
//
// Asks for a server-side frame (xdg-decoration), so the compositor's own edges
// can be pointed at, and sets its cursor the three ways a client can: a shape
// by name (cursor-shape-v1), a surface of its own (wl_pointer.set_cursor), or
// none. Whatever it was last told to do, it does again on every enter — as a
// toolkit does. It prints, a line each, flushed:
//
//     ready                     mapped
//     enter | leave             the pointer came or went
//
// And takes commands on stdin, one per line:
//
//     s <n>    a cursor-shape-v1 shape, by its enum value (1 default, 9 text…)
//     c        a surface of its own: 16x16, red, its hotspot at 3,4
//     x <name> the XCursor theme's <name>, loaded as GTK 3 and SDL load it
//              (libwayland-cursor: $XCURSOR_THEME, $XCURSOR_SIZE or 24,
//              from $XCURSOR_PATH); prints `xcursor <name> <w>x<h> hot <x>,<y>`
//     h        no cursor at all
//     q        quit
//
// A test helper, not part of the product; built by live-cursor.sh.
//
// Usage: cursortest [app-id]

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
#include "cursor-shape-proto.h"
#include "xdg-decoration-proto.h"
#include <wayland-cursor.h>

#define W 400
#define H 300

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct wl_pointer *pointer;
static struct wp_cursor_shape_manager_v1 *shapes;
static struct wp_cursor_shape_device_v1 *shape_device;
static struct zxdg_decoration_manager_v1 *decorations;

static struct wl_surface *surface, *cursor_surface;
static struct xdg_surface *xsurface;
static struct xdg_toplevel *toplevel;
static struct wl_buffer *buffer, *cursor_buffer;
static int ready;
static uint32_t enter_serial;
static int has_pointer;
static char mode = 0;        /* 's', 'c', 'h', 'x', or 0: never set */
static struct wl_cursor_theme *xtheme;
static struct wl_cursor_image *ximage;
static int mode_shape;

static void reg_global(void *d, struct wl_registry *r, uint32_t id, const char *iface, uint32_t v) {
    (void)d;
    if (!strcmp(iface, "wl_compositor"))
        compositor = wl_registry_bind(r, id, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_shm"))
        shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
    else if (!strcmp(iface, "xdg_wm_base"))
        wm_base = wl_registry_bind(r, id, &xdg_wm_base_interface, 1);
    else if (!strcmp(iface, "wl_seat") && !seat)
        seat = wl_registry_bind(r, id, &wl_seat_interface, v < 5 ? v : 5);
    else if (!strcmp(iface, wp_cursor_shape_manager_v1_interface.name))
        shapes = wl_registry_bind(r, id, &wp_cursor_shape_manager_v1_interface, 1);
    else if (!strcmp(iface, zxdg_decoration_manager_v1_interface.name))
        decorations = wl_registry_bind(r, id, &zxdg_decoration_manager_v1_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t id) { (void)d; (void)r; (void)id; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static struct wl_buffer *solid(int w, int h, uint32_t argb) {
    int stride = w * 4, size = stride * h;
    char name[64];
    snprintf(name, sizeof name, "/cursortest-%d-%d", (int)getpid(), w);
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { perror("shm_open"); exit(1); }
    shm_unlink(name);
    if (ftruncate(fd, size) < 0) { perror("ftruncate"); exit(1); }
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { perror("mmap"); exit(1); }
    for (int i = 0; i < w * h; i++) px[i] = argb;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    munmap(px, size);
    return b;
}

/* Do what we were last told, with the serial of the last enter. */
static void apply(void) {
    switch (mode) {
    case 's':
        wp_cursor_shape_device_v1_set_shape(shape_device, enter_serial, (uint32_t)mode_shape);
        break;
    case 'c':
        wl_pointer_set_cursor(pointer, enter_serial, cursor_surface, 3, 4);
        wl_surface_attach(cursor_surface, cursor_buffer, 0, 0);
        wl_surface_damage_buffer(cursor_surface, 0, 0, 16, 16);
        wl_surface_commit(cursor_surface);
        break;
    case 'h':
        wl_pointer_set_cursor(pointer, enter_serial, NULL, 0, 0);
        break;
    case 'x':
        if (!ximage) break;
        wl_pointer_set_cursor(pointer, enter_serial, cursor_surface, (int32_t)ximage->hotspot_x, (int32_t)ximage->hotspot_y);
        wl_surface_attach(cursor_surface, wl_cursor_image_get_buffer(ximage), 0, 0);
        wl_surface_damage_buffer(cursor_surface, 0, 0, (int32_t)ximage->width, (int32_t)ximage->height);
        wl_surface_commit(cursor_surface);
        break;
    }
}

static void p_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)sf; (void)x; (void)y;
    enter_serial = s; has_pointer = 1;
    printf("enter\n");
    apply();
}
static void p_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf) {
    (void)d; (void)p; (void)s; (void)sf; has_pointer = 0; printf("leave\n");
}
static void p_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)t; (void)x; (void)y;
}
static void p_button(void *d, struct wl_pointer *p, uint32_t s, uint32_t t, uint32_t b, uint32_t st) {
    (void)d; (void)p; (void)s; (void)t; (void)b; (void)st;
}
static void p_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) {
    (void)d; (void)p; (void)t; (void)a; (void)v;
}
static void p_frame(void *d, struct wl_pointer *p) { (void)d; (void)p; }
static void p_axis_source(void *d, struct wl_pointer *p, uint32_t s) { (void)d; (void)p; (void)s; }
static void p_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a) { (void)d; (void)p; (void)t; (void)a; }
static void p_axis_discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v) { (void)d; (void)p; (void)a; (void)v; }
static const struct wl_pointer_listener pointer_listener = {
    p_enter, p_leave, p_motion, p_button, p_axis, p_frame, p_axis_source, p_axis_stop, p_axis_discrete,
};

static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t s) { (void)d; xdg_wm_base_pong(b, s); }
static const struct xdg_wm_base_listener wm_listener = { wm_ping };
static void xs_configure(void *d, struct xdg_surface *xs, uint32_t s) {
    (void)d;
    xdg_surface_ack_configure(xs, s);
    if (!ready) {
        wl_surface_attach(surface, buffer, 0, 0);
        wl_surface_damage_buffer(surface, 0, 0, W, H);
    }
    wl_surface_commit(surface);
    if (!ready) { ready = 1; printf("ready\n"); }
}
static const struct xdg_surface_listener xs_listener = { xs_configure };
static void tl_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) {
    (void)d; (void)t; (void)w; (void)h; (void)s;
}
static void tl_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; exit(0); }
static const struct xdg_toplevel_listener tl_listener = { tl_configure, tl_close };

static void command(char *line) {
    line[strcspn(line, "\n")] = 0;
    switch (line[0]) {
    case 's':
        if (sscanf(line, "s %d", &mode_shape) != 1) return;
        mode = 's';
        break;
    case 'c': mode = 'c'; break;
    case 'h': mode = 'h'; break;
    case 'x': {
        const char *name = line + 2, *sz = getenv("XCURSOR_SIZE");
        if (!xtheme) xtheme = wl_cursor_theme_load(getenv("XCURSOR_THEME"), sz ? atoi(sz) : 24, shm);
        struct wl_cursor *c = xtheme ? wl_cursor_theme_get_cursor(xtheme, name) : NULL;
        if (!c) { printf("xcursor %s missing\n", name); return; }
        ximage = c->images[0];
        printf("xcursor %s %ux%u hot %u,%u\n", name, ximage->width, ximage->height, ximage->hotspot_x, ximage->hotspot_y);
        mode = 'x';
        break;
    }
    case 'q': exit(0);
    default: return;
    }
    // Asked with the last enter's serial even without the pointer: a window
    // that does not have it must be refused, and this is how one would ask.
    apply();
    (void)has_pointer;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "cursortest: cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !shm || !wm_base || !seat) { fprintf(stderr, "cursortest: missing a core global\n"); return 2; }
    if (!shapes) { fprintf(stderr, "cursortest: no wp_cursor_shape_manager_v1\n"); return 2; }
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    wl_display_roundtrip(dpy);
    pointer = wl_seat_get_pointer(seat);
    wl_pointer_add_listener(pointer, &pointer_listener, NULL);
    shape_device = wp_cursor_shape_manager_v1_get_pointer(shapes, pointer);

    buffer = solid(W, H, 0xff336699);
    cursor_buffer = solid(16, 16, 0xffff0000);
    cursor_surface = wl_compositor_create_surface(compositor);
    surface = wl_compositor_create_surface(compositor);
    xsurface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xsurface, &xs_listener, NULL);
    toplevel = xdg_surface_get_toplevel(xsurface);
    xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
    xdg_toplevel_set_app_id(toplevel, argc > 1 ? argv[1] : "org.abyssbsd.cursortest");
    if (decorations) {
        struct zxdg_toplevel_decoration_v1 *deco = zxdg_decoration_manager_v1_get_toplevel_decoration(decorations, toplevel);
        zxdg_toplevel_decoration_v1_set_mode(deco, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    }
    wl_surface_commit(surface);

    char line[256];
    struct pollfd fds[2] = { { wl_display_get_fd(dpy), POLLIN, 0 }, { 0, POLLIN, 0 } };
    for (;;) {
        wl_display_flush(dpy);
        if (poll(fds, 2, -1) < 0) break;
        if (fds[0].revents & POLLIN) { if (wl_display_dispatch(dpy) < 0) break; }
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            if (!fgets(line, sizeof line, stdin)) break;
            command(line);
        }
    }
    return 0;
}
