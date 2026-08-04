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

static struct wl_compositor *compositor;
static struct wl_shm *shm;

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(iface, "wl_compositor"))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 1);
    else if (!strcmp(iface, "wl_shm"))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
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
        fprintf(stderr, "usage: adversary <flood|hard|zombie|churn|deaf> [count]\n");
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
