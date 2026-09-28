/*
 * hidden.c — a window that minimizes itself and counts, for undertow's U.2
 * (docs/BACKLOG.md).
 *
 * undertow withheld every frame callback from a minimized window, and a client
 * presenting in FIFO mode — Mesa's default, so SDL, Blender and zed — blocks in
 * its swap until the callback comes (API-STUDY §1.4). This client behaves the
 * way those do: it draws on every frame callback and on nothing else, so a
 * withheld clock is a stopped client.
 *
 *   1. map, bound at xdg-shell v6, and draw for about a second;
 *   2. minimize itself (xdg_toplevel.set_minimized);
 *   3. keep counting frame callbacks, and after 3.5 s of being hidden ask for
 *      its own window back — through wlr-foreign-toplevel-management, exactly
 *      as the Dock does, since xdg-shell has no way for a window to un-minimize
 *      itself;
 *   4. count the frames that follow.
 *
 * It logs, for the script to assert on:
 *
 *   hidden: capabilities <names...>      xdg_toplevel.wm_capabilities (v5)
 *   hidden: suspended <0|1>               each change of the v6 state
 *   hidden: minimized
 *   hidden: hidden frames <n> in <ms> ms  when it asks to come back
 *   hidden: restore requested
 *   hidden: frames after restore <n>      once, a second after coming back
 *
 * Built by live-hidden.sh; not part of the product.
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
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

#define APP_ID "org.abyssbsd.hidden"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct zwlr_foreign_toplevel_manager_v1 *ftm;
static struct zwlr_foreign_toplevel_handle_v1 *own;   /* our window, seen as the Dock sees it */

static struct wl_surface *surface;
static struct xdg_toplevel *toplevel;
static struct wl_buffer *buffer;
static int configured, suspended = -1;

static unsigned frames;              /* every callback, all phases */
static uint64_t minimized_at;        /* ns; 0 until we minimize */
static unsigned hidden_frames;
static int restore_requested;
static uint64_t restored_at;         /* ns; when the first unsuspend arrives */
static unsigned frames_after_restore;
static int reported;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* ------------------------------------------------------------------ registry */
static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version) {
    (void)data;
    if (!strcmp(iface, "wl_compositor"))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_shm"))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, "xdg_wm_base"))
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, version < 6 ? version : 6);
    else if (!strcmp(iface, "zwlr_foreign_toplevel_manager_v1"))
        ftm = wl_registry_bind(reg, name, &zwlr_foreign_toplevel_manager_v1_interface,
                               version < 3 ? version : 3);
}
static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static struct wl_buffer *solid(int w, int h, uint32_t xrgb) {
    int stride = w * 4, size = stride * h;
    char name[64];
    snprintf(name, sizeof name, "/hidden-%d", (int)getpid());
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

/* ------------------------------------------------------------ the frame loop */
static const struct wl_callback_listener frame_listener;
static void draw(void) {
    struct wl_callback *cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, 160, 120);
    wl_surface_commit(surface);
}
static void frame_done(void *data, struct wl_callback *cb, uint32_t time) {
    (void)data; (void)time;
    wl_callback_destroy(cb);
    frames++;
    uint64_t t = now_ns();

    if (!minimized_at && frames == 60) {
        minimized_at = t;
        xdg_toplevel_set_minimized(toplevel);
        fprintf(stderr, "hidden: minimized\n");
    } else if (minimized_at && !restore_requested) {
        hidden_frames++;
        if (t - minimized_at >= 3500000000ull) {
            fprintf(stderr, "hidden: hidden frames %u in %llu ms\n", hidden_frames,
                    (unsigned long long)((t - minimized_at) / 1000000));
            if (!own) { fprintf(stderr, "hidden: no foreign-toplevel handle for "
                                APP_ID "\n"); exit(1); }
            zwlr_foreign_toplevel_handle_v1_unset_minimized(own);
            restore_requested = 1;
            fprintf(stderr, "hidden: restore requested\n");
        }
    } else if (restored_at && !reported) {
        frames_after_restore++;
        if (t - restored_at >= 1000000000ull) {
            fprintf(stderr, "hidden: frames after restore %u\n", frames_after_restore);
            reported = 1;
        }
    }
    draw();
}
static const struct wl_callback_listener frame_listener = { frame_done };

/* --------------------------------------------------------------------- shell */
static void wm_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
    (void)data; xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener wm_listener = { wm_ping };

static void xs_configure(void *data, struct xdg_surface *xs, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xs, serial);
    if (!configured) { configured = 1; draw(); }
    else wl_surface_commit(surface);
}
static const struct xdg_surface_listener xs_listener = { xs_configure };

static void tl_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h,
                         struct wl_array *states) {
    (void)d; (void)t; (void)w; (void)h;
    int s = 0;
    uint32_t *st;
    wl_array_for_each(st, states) if (*st == XDG_TOPLEVEL_STATE_SUSPENDED) s = 1;
    if (s != suspended) {
        /* The first report is the initial state, not a change. */
        if (suspended != -1 || s) fprintf(stderr, "hidden: suspended %d\n", s);
        if (suspended == 1 && s == 0 && restore_requested) restored_at = now_ns();
        suspended = s;
    }
}
static void tl_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; exit(0); }
static void tl_bounds(void *d, struct xdg_toplevel *t, int32_t w, int32_t h) {
    (void)d; (void)t; (void)w; (void)h;
}
static void tl_caps(void *d, struct xdg_toplevel *t, struct wl_array *caps) {
    (void)d; (void)t;
    char line[128] = "hidden: capabilities";
    uint32_t *c;
    wl_array_for_each(c, caps) {
        const char *n = *c == XDG_TOPLEVEL_WM_CAPABILITIES_WINDOW_MENU ? "window_menu"
                      : *c == XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE ? "maximize"
                      : *c == XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN ? "fullscreen"
                      : *c == XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE ? "minimize" : "unknown";
        strncat(line, " ", sizeof line - strlen(line) - 1);
        strncat(line, n, sizeof line - strlen(line) - 1);
    }
    fprintf(stderr, "%s\n", line);
}
static const struct xdg_toplevel_listener tl_listener = {
    tl_configure, tl_close, tl_bounds, tl_caps,
};

/* ------------------------------------------------ foreign toplevel, as the Dock */
static void h_title(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *s) {
    (void)d; (void)h; (void)s;
}
static void h_app_id(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *s) {
    (void)d;
    if (!strcmp(s, APP_ID)) own = h;
}
static void h_output_enter(void *d, struct zwlr_foreign_toplevel_handle_v1 *h,
                           struct wl_output *o) { (void)d; (void)h; (void)o; }
static void h_output_leave(void *d, struct zwlr_foreign_toplevel_handle_v1 *h,
                           struct wl_output *o) { (void)d; (void)h; (void)o; }
static void h_state(void *d, struct zwlr_foreign_toplevel_handle_v1 *h,
                    struct wl_array *s) { (void)d; (void)h; (void)s; }
static void h_done(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) { (void)d; (void)h; }
static void h_closed(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) {
    (void)d;
    if (h == own) own = NULL;
}
static void h_parent(void *d, struct zwlr_foreign_toplevel_handle_v1 *h,
                     struct zwlr_foreign_toplevel_handle_v1 *p) { (void)d; (void)h; (void)p; }
static const struct zwlr_foreign_toplevel_handle_v1_listener handle_listener = {
    h_title, h_app_id, h_output_enter, h_output_leave, h_state, h_done, h_closed, h_parent,
};
static void m_toplevel(void *d, struct zwlr_foreign_toplevel_manager_v1 *m,
                       struct zwlr_foreign_toplevel_handle_v1 *h) {
    (void)d; (void)m;
    zwlr_foreign_toplevel_handle_v1_add_listener(h, &handle_listener, NULL);
}
static void m_finished(void *d, struct zwlr_foreign_toplevel_manager_v1 *m) { (void)d; (void)m; }
static const struct zwlr_foreign_toplevel_manager_v1_listener manager_listener = {
    m_toplevel, m_finished,
};

int main(void) {
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "hidden: cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !shm || !wm_base || !ftm) {
        fprintf(stderr, "hidden: missing a global (foreign-toplevel %p)\n", (void *)ftm);
        return 1;
    }
    fprintf(stderr, "hidden: xdg_wm_base v%u\n", wl_proxy_get_version((struct wl_proxy *)wm_base));
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    zwlr_foreign_toplevel_manager_v1_add_listener(ftm, &manager_listener, NULL);

    buffer = solid(160, 120, 0x00808080);
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xs, &xs_listener, NULL);
    toplevel = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
    xdg_toplevel_set_title(toplevel, "hidden");
    xdg_toplevel_set_app_id(toplevel, APP_ID);
    wl_surface_commit(surface);

    while (wl_display_dispatch(dpy) != -1) { }
    return 0;
}
