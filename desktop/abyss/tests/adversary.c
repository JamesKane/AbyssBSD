/*
 * adversary.c — hostile Wayland clients, for undertow's C2 contract
 * (PHASE6.md P6.5; DESKTOP.md §0 C2: "no client can cause a missed flip").
 *
 * A REAL client process speaking the real protocol over the real socket. An
 * in-process fake would exercise none of the parts that actually threaten the
 * frame loop — libwayland's dispatch, the shm pool plumbing, connection setup
 * and teardown — which is the whole point: C2 is a claim about what a
 * *separate process* can do to us.
 *
 * Four modes, each a distinct threat, because "adversarial client" is not one
 * behaviour:
 *
 *   flood [n]   commit storm — attach + damage + commit, draining every 64 with
 *               a roundtrip. A well-behaved-but-greedy client.
 *   hard [n]    the same storm with NO roundtrip ever: write until the kernel
 *               refuses, poll for writability, write again. A roundtrip waits
 *               for the compositor to answer, which throttles the client to the
 *               compositor's own cadence — so `flood` cannot actually apply
 *               more pressure than we choose to accept, and only this mode
 *               tests what an outright hostile client can do.
 *   zombie      connect, commit once, then hang for ever holding the
 *               connection and the surface. The compositor must show its last
 *               buffer and never wait for another.
 *   churn [n]   connect / set up / commit / disconnect, over and over.
 *               Resource create-and-destroy pressure on the protocol side.
 *   deaf        connect, commit, then never read the socket again while
 *               spinning on the CPU. The compositor's events pile up in a
 *               socket nobody drains — it must not block writing to us.
 *
 * And one that is not hostile at all, but needs a real client to exercise:
 *
 *   move <app_id> <title> [w h]
 *               map an xdg_toplevel with that identity, then on the first
 *               pointer button press ask the compositor to MOVE it
 *               (xdg_toplevel.move) and keep dispatching. The drag itself is
 *               the compositor's; this client only asks. The oracle for
 *               remembered window positions (PHASE6.md P6.7).
 *
 * Deliberately NOT a library: this is a test tool, built by the harness the
 * same way vpointer.c is.
 *
 * Usage: adversary <flood|zombie|churn|deaf> [count]
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct wl_pointer *pointer;
static struct xdg_toplevel *g_toplevel;
static uint32_t last_serial;
static int moved;

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(iface, "wl_compositor"))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 1);
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

/* An anonymous shm buffer. Small: the point is protocol traffic, not pixels. */
static struct wl_buffer *make_buffer(int w, int h) {
    int stride = w * 4, size = stride * h;
    char name[64];
    snprintf(name, sizeof name, "/adversary-%d", (int)getpid());
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { perror("shm_open"); return NULL; }
    shm_unlink(name);
    if (ftruncate(fd, size) < 0) { perror("ftruncate"); close(fd); return NULL; }
    void *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { perror("mmap"); close(fd); return NULL; }
    memset(px, 0x40, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
                                                      WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buf;
}

static void wm_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
    (void)data; xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener wm_listener = { wm_ping };

static void xs_configure(void *data, struct xdg_surface *xs, uint32_t serial) {
    (void)data; xdg_surface_ack_configure(xs, serial);
}
static const struct xdg_surface_listener xs_listener = { xs_configure };

/* Every slot must be filled: libwayland aborts on a NULL listener the moment it
 * dispatches that event (HANDOFF §2.3). */
static void ptr_enter(void *d, struct wl_pointer *p, uint32_t serial,
                      struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)s; (void)x; (void)y; last_serial = serial;
}
static void ptr_leave(void *d, struct wl_pointer *p, uint32_t serial,
                      struct wl_surface *s) { (void)d; (void)p; (void)s; last_serial = serial; }
static void ptr_motion(void *d, struct wl_pointer *p, uint32_t t,
                       wl_fixed_t x, wl_fixed_t y) { (void)d; (void)p; (void)t; (void)x; (void)y; }
static void ptr_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t t,
                       uint32_t button, uint32_t state) {
    (void)d; (void)p; (void)t; (void)button;
    last_serial = serial;
    if (state == WL_POINTER_BUTTON_STATE_PRESSED && !moved && g_toplevel) {
        xdg_toplevel_move(g_toplevel, seat, serial);
        moved = 1;
        fprintf(stderr, "adversary: asked the compositor to move me\n");
    }
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
static const struct wl_pointer_listener ptr_listener;

/* The seat announces its capabilities ASYNCHRONOUSLY, and may have none when we
 * first bind it — the virtual pointer that will drive this test connects to the
 * compositor AFTER we do. Calling wl_seat.get_pointer before the capability
 * exists is a protocol error and kills the connection ("get_pointer called when
 * no pointer capability has existed"), so the pointer is created here, when the
 * seat says there is one. */
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

static const struct wl_pointer_listener ptr_listener = {
    /* Order is the protocol's, not alphabetical: enter, leave, motion, button,
     * AXIS, frame, ... — getting it wrong wires `frame` into the `axis` slot
     * and libwayland calls it with the wrong arguments (HANDOFF §2.3). */
    ptr_enter, ptr_leave, ptr_motion, ptr_button, ptr_axis,
    ptr_frame, ptr_axis_source, ptr_axis_stop, ptr_axis_discrete,
};

struct conn {
    struct wl_display *display;
    struct wl_surface *surface;
    struct wl_buffer *buffer;
};

static int setup(struct conn *c) {
    c->display = wl_display_connect(NULL);
    if (!c->display) { fprintf(stderr, "adversary: cannot connect\n"); return -1; }
    struct wl_registry *reg = wl_display_get_registry(c->display);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(c->display);
    if (!compositor || !shm) {
        fprintf(stderr, "adversary: compositor/shm missing\n");
        return -1;
    }
    c->surface = wl_compositor_create_surface(compositor);
    c->buffer = make_buffer(64, 64);
    if (!c->buffer) return -1;
    wl_surface_attach(c->surface, c->buffer, 0, 0);
    wl_surface_damage(c->surface, 0, 0, 64, 64);
    wl_surface_commit(c->surface);
    wl_display_roundtrip(c->display);
    return 0;
}

static void teardown(struct conn *c) {
    if (c->buffer) wl_buffer_destroy(c->buffer);
    if (c->surface) wl_surface_destroy(c->surface);
    if (c->display) wl_display_disconnect(c->display);
    memset(c, 0, sizeof *c);
    compositor = NULL;
    shm = NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: adversary <flood|hard|zombie|churn|deaf|move> ...\n");
        return 2;
    }
    const char *mode = argv[1];
    long count = argc > 2 ? strtol(argv[2], NULL, 10) : 0;

    if (!strcmp(mode, "flood")) {
        struct conn c = {0};
        if (setup(&c) < 0) return 1;
        fprintf(stderr, "adversary: flooding\n");
        for (long i = 0; count == 0 || i < count; i++) {
            wl_surface_attach(c.surface, c.buffer, 0, 0);
            wl_surface_damage(c.surface, 0, 0, 64, 64);
            wl_surface_commit(c.surface);
            /* Drain periodically so our own socket buffer cannot become the
             * limiting factor — we want the COMPOSITOR to be the one under
             * pressure, not us. */
            if ((i & 63) == 0) {
                if (wl_display_roundtrip(c.display) < 0) break;
            } else {
                if (wl_display_flush(c.display) < 0 && errno != EAGAIN) break;
            }
        }
        teardown(&c);
        return 0;
    }

    if (!strcmp(mode, "move")) {
        if (argc < 4) {
            fprintf(stderr, "usage: adversary move <app_id> <title> [w h]\n");
            return 2;
        }
        int mw = argc > 4 ? atoi(argv[4]) : 200;
        int mh = argc > 5 ? atoi(argv[5]) : 150;
        struct wl_display *d = wl_display_connect(NULL);
        if (!d) { fprintf(stderr, "adversary: cannot connect\n"); return 1; }
        struct wl_registry *reg = wl_display_get_registry(d);
        wl_registry_add_listener(reg, &reg_listener, NULL);
        wl_display_roundtrip(d);
        if (!compositor || !shm || !wm_base) {
            fprintf(stderr, "adversary: missing compositor/shm/xdg_wm_base\n");
            return 1;
        }
        xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);

        struct wl_surface *surf = wl_compositor_create_surface(compositor);
        struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surf);
        xdg_surface_add_listener(xs, &xs_listener, NULL);
        g_toplevel = xdg_surface_get_toplevel(xs);
        xdg_toplevel_set_app_id(g_toplevel, argv[2]);
        xdg_toplevel_set_title(g_toplevel, argv[3]);
        wl_surface_commit(surf);            /* the initial commit */
        wl_display_roundtrip(d);            /* ... answered with a configure */

        struct wl_buffer *buf = make_buffer(mw, mh);
        if (!buf) return 1;
        wl_surface_attach(surf, buf, 0, 0);
        wl_surface_damage(surf, 0, 0, mw, mh);
        wl_surface_commit(surf);
        wl_display_roundtrip(d);
        fprintf(stderr, "adversary: mapped %s/%s at %dx%d\n", argv[2], argv[3], mw, mh);

        if (seat) wl_seat_add_listener(seat, &seat_listener, NULL);
        /* Ask for the move on the first press, then just keep the connection
         * alive: the drag is entirely the compositor's from here. */
        while (wl_display_dispatch(d) != -1) { }
        return 0;
    }

    if (!strcmp(mode, "hard")) {
        struct conn c = {0};
        if (setup(&c) < 0) return 1;
        fprintf(stderr, "adversary: flooding hard (no roundtrips)\n");
        int fd = wl_display_get_fd(c.display);
        for (long i = 0; count == 0 || i < count; i++) {
            wl_surface_attach(c.surface, c.buffer, 0, 0);
            wl_surface_damage(c.surface, 0, 0, 64, 64);
            wl_surface_commit(c.surface);
            while (wl_display_flush(c.display) < 0) {
                if (errno != EAGAIN) goto done;
                /* The kernel's socket buffer is full: the compositor has not
                 * drained us. Wait for writability, never for a REPLY — that
                 * is the difference between greedy and hostile. */
                struct pollfd p = { .fd = fd, .events = POLLOUT };
                if (poll(&p, 1, 100) < 0) goto done;
            }
        }
    done:
        teardown(&c);
        return 0;
    }

    if (!strcmp(mode, "zombie")) {
        struct conn c = {0};
        if (setup(&c) < 0) return 1;
        fprintf(stderr, "adversary: zombie (committed once, now idle for ever)\n");
        for (;;) pause();
    }

    if (!strcmp(mode, "churn")) {
        fprintf(stderr, "adversary: churning\n");
        for (long i = 0; count == 0 || i < count; i++) {
            struct conn c = {0};
            if (setup(&c) < 0) return 1;
            teardown(&c);
        }
        return 0;
    }

    if (!strcmp(mode, "deaf")) {
        struct conn c = {0};
        if (setup(&c) < 0) return 1;
        fprintf(stderr, "adversary: deaf (spinning, never reading the socket)\n");
        /* Never dispatch again. The compositor's events — frame callbacks,
         * buffer releases, everything — queue up in a socket we will never
         * drain. Meanwhile burn a core, so we are also competing for CPU. */
        volatile unsigned long x = 0;
        for (;;) { for (int i = 0; i < 1000000; i++) x += i; }
    }

    fprintf(stderr, "adversary: unknown mode '%s'\n", mode);
    return 2;
}
