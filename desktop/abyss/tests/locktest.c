// locktest — a window that locks and confines the pointer, for undertow's U.6
// (docs/BACKLOG.md).
//
// Behaves the way a game or Blender does: binds relative-pointer and
// pointer-constraints, and asks for a lock or a confinement when told to. It
// prints what the compositor tells it, a line each, flushed:
//
//     ready                     mapped
//     enter <sx> <sy>           the pointer entered, surface coordinates
//     motion <sx> <sy>          wl_pointer.motion
//     rel <dx> <dy>             zwp_relative_pointer_v1.relative_motion
//     locked | unlocked         the lock took effect / ended
//     confined | unconfined     the confinement took effect / ended
//
// And takes commands on stdin, one per line:
//
//     l                 lock the pointer (persistent, the whole surface)
//     h <x> <y>         while locked: hint where the cursor is drawn
//     c <x> <y> <w> <h> confine the pointer to that rectangle (persistent)
//     u                 destroy the constraint
//     q                 quit
//
// A test helper, not part of the product; built by live-lock.sh against the
// vendored protocol XMLs.
//
// Usage: locktest [app-id]

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
#include "relative-pointer-proto.h"
#include "pointer-constraints-proto.h"

#define W 400
#define H 300

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct wl_pointer *pointer;
static struct zwp_relative_pointer_manager_v1 *relmgr;
static struct zwp_pointer_constraints_v1 *constraints;
static struct zwp_locked_pointer_v1 *lock;
static struct zwp_confined_pointer_v1 *confine;

static struct wl_surface *surface;
static struct xdg_surface *xsurface;
static struct xdg_toplevel *toplevel;
static struct wl_buffer *buffer;
static int ready;

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
    else if (!strcmp(iface, zwp_relative_pointer_manager_v1_interface.name))
        relmgr = wl_registry_bind(r, id, &zwp_relative_pointer_manager_v1_interface, 1);
    else if (!strcmp(iface, zwp_pointer_constraints_v1_interface.name))
        constraints = wl_registry_bind(r, id, &zwp_pointer_constraints_v1_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t id) { (void)d; (void)r; (void)id; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static struct wl_buffer *solid(uint32_t xrgb) {
    int stride = W * 4, size = stride * H;
    char name[64];
    snprintf(name, sizeof name, "/locktest-%d", (int)getpid());
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { perror("shm_open"); exit(1); }
    shm_unlink(name);
    if (ftruncate(fd, size) < 0) { perror("ftruncate"); exit(1); }
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { perror("mmap"); exit(1); }
    for (int i = 0; i < W * H; i++) px[i] = xrgb;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, W, H, stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    munmap(px, size);
    return b;
}

/* ------------------------------------------------------------------- pointer */
static void p_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)s; (void)sf;
    printf("enter %d %d\n", wl_fixed_to_int(x), wl_fixed_to_int(y));
}
static void p_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf) {
    (void)d; (void)p; (void)s; (void)sf; printf("leave\n");
}
static void p_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)t;
    printf("motion %d %d\n", wl_fixed_to_int(x), wl_fixed_to_int(y));
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

static void rel_motion(void *d, struct zwp_relative_pointer_v1 *r, uint32_t hi, uint32_t lo,
                       wl_fixed_t dx, wl_fixed_t dy, wl_fixed_t udx, wl_fixed_t udy) {
    (void)d; (void)r; (void)hi; (void)lo; (void)udx; (void)udy;
    printf("rel %d %d\n", wl_fixed_to_int(dx), wl_fixed_to_int(dy));
}
static const struct zwp_relative_pointer_v1_listener rel_listener = { rel_motion };

static void on_locked(void *d, struct zwp_locked_pointer_v1 *l) { (void)d; (void)l; printf("locked\n"); }
static void on_unlocked(void *d, struct zwp_locked_pointer_v1 *l) { (void)d; (void)l; printf("unlocked\n"); }
static const struct zwp_locked_pointer_v1_listener lock_listener = { on_locked, on_unlocked };
static void on_confined(void *d, struct zwp_confined_pointer_v1 *c) { (void)d; (void)c; printf("confined\n"); }
static void on_unconfined(void *d, struct zwp_confined_pointer_v1 *c) { (void)d; (void)c; printf("unconfined\n"); }
static const struct zwp_confined_pointer_v1_listener confine_listener = { on_confined, on_unconfined };

/* --------------------------------------------------------------------- shell */
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
    int x, y, w, h;
    switch (line[0]) {
    case 'l':
        if (lock || confine) break;
        lock = zwp_pointer_constraints_v1_lock_pointer(constraints, surface, pointer, NULL,
                                                       ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
        zwp_locked_pointer_v1_add_listener(lock, &lock_listener, NULL);
        // The region is double-buffered state: it exists from the next commit.
        wl_surface_commit(surface);
        break;
    case 'h':
        if (lock && sscanf(line, "h %d %d", &x, &y) == 2) {
            // Double-buffered: it applies on the surface's next commit.
            zwp_locked_pointer_v1_set_cursor_position_hint(lock, wl_fixed_from_int(x), wl_fixed_from_int(y));
            wl_surface_commit(surface);
        }
        break;
    case 'c':
        if (lock || confine || sscanf(line, "c %d %d %d %d", &x, &y, &w, &h) != 4) break;
        {
            struct wl_region *r = wl_compositor_create_region(compositor);
            wl_region_add(r, x, y, w, h);
            confine = zwp_pointer_constraints_v1_confine_pointer(constraints, surface, pointer, r,
                                                                 ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
            zwp_confined_pointer_v1_add_listener(confine, &confine_listener, NULL);
            wl_region_destroy(r);
            wl_surface_commit(surface);
        }
        break;
    case 'u':
        if (lock) { zwp_locked_pointer_v1_destroy(lock); lock = NULL; }
        if (confine) { zwp_confined_pointer_v1_destroy(confine); confine = NULL; }
        break;
    case 'q':
        exit(0);
    }
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "locktest: cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !shm || !wm_base || !seat) { fprintf(stderr, "locktest: missing a core global\n"); return 2; }
    if (!relmgr || !constraints) {
        fprintf(stderr, "locktest: no zwp_relative_pointer_manager_v1 or zwp_pointer_constraints_v1\n");
        return 2;
    }
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    // The seat's pointer capability comes from the harness's virtual pointer,
    // which the script attaches first.
    wl_display_roundtrip(dpy);
    pointer = wl_seat_get_pointer(seat);
    wl_pointer_add_listener(pointer, &pointer_listener, NULL);
    struct zwp_relative_pointer_v1 *rel = zwp_relative_pointer_manager_v1_get_relative_pointer(relmgr, pointer);
    zwp_relative_pointer_v1_add_listener(rel, &rel_listener, NULL);

    buffer = solid(0xff336699);
    surface = wl_compositor_create_surface(compositor);
    xsurface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xsurface, &xs_listener, NULL);
    toplevel = xdg_surface_get_toplevel(xsurface);
    xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
    xdg_toplevel_set_app_id(toplevel, argc > 1 ? argv[1] : "org.abyssbsd.locktest");
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
