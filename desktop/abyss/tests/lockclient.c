/*
 * lockclient — both sides of a session lock, for undertow's PHASE16 P16.2.
 *
 *   lockclient lock ARGB [last]
 *                             a lock client: on `l`, locks, and covers every
 *                             output with a surface of colour ARGB — or only
 *                             the last, leaving the others standing in for a display that
 *                             arrives while locked and has no lock surface yet
 *   lockclient window ARGB APP_ID
 *                             an ordinary window of colour ARGB, which logs
 *                             any input that reaches it
 *
 * It prints, a line each, flushed:
 *
 *   ready                     bound
 *   locked | finished         the compositor said so (lock mode)
 *   enter | button | key N    input reached this client
 *   popup grabbed | popup done
 *
 * Commands on stdin:
 *
 *   l   lock (lock mode)            u   unlock and destroy (lock mode)
 *   p   open a popup that grabs the keyboard, with the last serial this
 *       client was given (window mode) — the attack a lock must survive
 *   f   ask a frame callback on the first lock surface (lock mode): prints
 *       `frame` when it comes — a lock screen that animates needs a clock
 *   q   quit — in lock mode, WITHOUT unlocking: the abandoned lock
 *
 * A test helper, not part of the product; built by live-sessionlock.sh.
 */
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
#include "ext-session-lock-proto.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct ext_session_lock_manager_v1 *lock_manager;
static struct ext_session_lock_v1 *lock;
static struct wl_output *outputs[8];
static int noutputs;
static uint32_t colour, last_serial;
static int lock_mode, last_only;
static struct wl_surface *lock_surfaces[8];
static int nlock_surfaces;

static void reg_global(void *d, struct wl_registry *r, uint32_t id, const char *iface, uint32_t v) {
    (void)d;
    if (!strcmp(iface, "wl_compositor")) compositor = wl_registry_bind(r, id, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_shm")) shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
    else if (!strcmp(iface, "xdg_wm_base")) wm_base = wl_registry_bind(r, id, &xdg_wm_base_interface, 1);
    else if (!strcmp(iface, "wl_seat") && !seat) seat = wl_registry_bind(r, id, &wl_seat_interface, v < 5 ? v : 5);
    else if (!strcmp(iface, ext_session_lock_manager_v1_interface.name))
        lock_manager = wl_registry_bind(r, id, &ext_session_lock_manager_v1_interface, 1);
    else if (!strcmp(iface, "wl_output") && noutputs < 8)
        outputs[noutputs++] = wl_registry_bind(r, id, &wl_output_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t id) { (void)d; (void)r; (void)id; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static struct wl_buffer *solid(int w, int h, uint32_t argb) {
    int stride = w * 4, size = stride * h;
    char name[64];
    static int n;
    snprintf(name, sizeof name, "/lockclient-%d-%d", (int)getpid(), n++);
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

/* ---------------------------------------------------------------- input */
static void p_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)sf; (void)x; (void)y; last_serial = s; printf("enter\n");
}
static void p_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf) { (void)d; (void)p; (void)s; (void)sf; }
static void p_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) { (void)d; (void)p; (void)t; (void)x; (void)y; }
static void p_button(void *d, struct wl_pointer *p, uint32_t s, uint32_t t, uint32_t b, uint32_t st) {
    (void)d; (void)p; (void)t; (void)b; last_serial = s; if (st) printf("button\n");
}
static void p_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) { (void)d; (void)p; (void)t; (void)a; (void)v; }
static void p_frame(void *d, struct wl_pointer *p) { (void)d; (void)p; }
static void p_src(void *d, struct wl_pointer *p, uint32_t s) { (void)d; (void)p; (void)s; }
static void p_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a) { (void)d; (void)p; (void)t; (void)a; }
static void p_disc(void *d, struct wl_pointer *p, uint32_t a, int32_t v) { (void)d; (void)p; (void)a; (void)v; }
static const struct wl_pointer_listener pointer_listener = { p_enter, p_leave, p_motion, p_button, p_axis, p_frame, p_src, p_stop, p_disc };

static void k_keymap(void *d, struct wl_keyboard *k, uint32_t f, int32_t fd, uint32_t s) { (void)d; (void)k; (void)f; (void)s; close(fd); }
static void k_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf, struct wl_array *a) { (void)d; (void)k; (void)sf; (void)a; last_serial = s; }
static void k_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf) { (void)d; (void)k; (void)s; (void)sf; }
static void k_key(void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key, uint32_t st) {
    (void)d; (void)k; (void)t; last_serial = s; if (st) printf("key %u\n", key);
}
static void k_mods(void *d, struct wl_keyboard *k, uint32_t s, uint32_t a, uint32_t b, uint32_t c, uint32_t g) { (void)d; (void)k; (void)s; (void)a; (void)b; (void)c; (void)g; }
static void k_repeat(void *d, struct wl_keyboard *k, int32_t r, int32_t dl) { (void)d; (void)k; (void)r; (void)dl; }
static const struct wl_keyboard_listener keyboard_listener = { k_keymap, k_enter, k_leave, k_key, k_mods, k_repeat };

static struct wl_pointer *pointer;
static struct wl_keyboard *keyboard;
static void seat_caps(void *d, struct wl_seat *s, uint32_t caps) {
    (void)d;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
        pointer = wl_seat_get_pointer(s); wl_pointer_add_listener(pointer, &pointer_listener, NULL);
    }
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !keyboard) {
        keyboard = wl_seat_get_keyboard(s); wl_keyboard_add_listener(keyboard, &keyboard_listener, NULL);
    }
}
static void seat_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }
static const struct wl_seat_listener seat_listener = { seat_caps, seat_name };

/* ---------------------------------------------------------------- lock */
static void lock_locked(void *d, struct ext_session_lock_v1 *l) { (void)d; (void)l; printf("locked\n"); }
static void lock_finished(void *d, struct ext_session_lock_v1 *l) { (void)d; (void)l; printf("finished\n"); }
static const struct ext_session_lock_v1_listener lock_listener = { lock_locked, lock_finished };

static void ls_configure(void *d, struct ext_session_lock_surface_v1 *ls, uint32_t serial, uint32_t w, uint32_t h) {
    struct wl_surface *sf = d;
    ext_session_lock_surface_v1_ack_configure(ls, serial);
    wl_surface_attach(sf, solid((int)w, (int)h, colour), 0, 0);
    wl_surface_damage_buffer(sf, 0, 0, (int32_t)w, (int32_t)h);
    wl_surface_commit(sf);
}
static const struct ext_session_lock_surface_v1_listener ls_listener = { ls_configure };

static void do_lock(void) {
    lock = ext_session_lock_manager_v1_lock(lock_manager);
    ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
    for (int i = last_only ? noutputs - 1 : 0; i < noutputs; i++) {
        struct wl_surface *sf = wl_compositor_create_surface(compositor);
        if (nlock_surfaces < 8) lock_surfaces[nlock_surfaces++] = sf;
        struct ext_session_lock_surface_v1 *ls = ext_session_lock_v1_get_lock_surface(lock, sf, outputs[i]);
        ext_session_lock_surface_v1_add_listener(ls, &ls_listener, sf);
    }
}

static void frame_done(void *d, struct wl_callback *cb, uint32_t t) { (void)d; (void)t; wl_callback_destroy(cb); printf("frame\n"); }
static const struct wl_callback_listener frame_listener = { frame_done };

/* ---------------------------------------------------------------- window */
static struct wl_surface *window;
static struct xdg_surface *window_xs;
static int window_ready;
static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t s) { (void)d; xdg_wm_base_pong(b, s); }
static const struct xdg_wm_base_listener wm_listener = { wm_ping };
static void xs_configure(void *d, struct xdg_surface *xs, uint32_t s) {
    struct wl_surface *sf = d;
    xdg_surface_ack_configure(xs, s);
    if (sf == window && !window_ready) {
        window_ready = 1;
        wl_surface_attach(sf, solid(300, 200, colour), 0, 0);
        wl_surface_damage_buffer(sf, 0, 0, 300, 200);
    } else if (sf != window) {
        wl_surface_attach(sf, solid(100, 60, 0xffff00ff), 0, 0);   /* the popup: magenta */
        wl_surface_damage_buffer(sf, 0, 0, 100, 60);
    }
    wl_surface_commit(sf);
}
static const struct xdg_surface_listener xs_listener = { xs_configure };
static void tl_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) { (void)d; (void)t; (void)w; (void)h; (void)s; }
static void tl_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; exit(0); }
static const struct xdg_toplevel_listener tl_listener = { tl_configure, tl_close };

static void pp_configure(void *d, struct xdg_popup *p, int32_t x, int32_t y, int32_t w, int32_t h) { (void)d; (void)p; (void)x; (void)y; (void)w; (void)h; }
static void pp_done(void *d, struct xdg_popup *p) { (void)d; (void)p; printf("popup done\n"); }
static void pp_repositioned(void *d, struct xdg_popup *p, uint32_t t) { (void)d; (void)p; (void)t; }
static const struct xdg_popup_listener popup_listener = { pp_configure, pp_done, pp_repositioned };

static void open_grabbing_popup(void) {
    struct wl_surface *sf = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, sf);
    struct xdg_positioner *pos = xdg_wm_base_create_positioner(wm_base);
    xdg_positioner_set_size(pos, 100, 60);
    xdg_positioner_set_anchor_rect(pos, 10, 10, 1, 1);
    struct xdg_popup *popup = xdg_surface_get_popup(xs, window_xs, pos);
    xdg_positioner_destroy(pos);
    xdg_popup_add_listener(popup, &popup_listener, NULL);
    xdg_surface_add_listener(xs, &xs_listener, sf);
    xdg_popup_grab(popup, seat, last_serial);
    wl_surface_commit(sf);
    printf("popup grabbed\n");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 3) { fprintf(stderr, "usage: lockclient lock ARGB | window ARGB APP_ID\n"); return 2; }
    lock_mode = !strcmp(argv[1], "lock");
    last_only = lock_mode && argc > 3 && !strcmp(argv[3], "last");
    colour = (uint32_t)strtoul(argv[2], NULL, 16);
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "lockclient: cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !shm || !seat || (lock_mode && !lock_manager) || (!lock_mode && !wm_base)) {
        fprintf(stderr, "lockclient: missing a global (ext_session_lock_manager_v1: %s)\n", lock_manager ? "yes" : "no");
        return 2;
    }
    wl_seat_add_listener(seat, &seat_listener, NULL);
    if (!lock_mode) {
        xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
        window = wl_compositor_create_surface(compositor);
        window_xs = xdg_wm_base_get_xdg_surface(wm_base, window);
        xdg_surface_add_listener(window_xs, &xs_listener, window);
        struct xdg_toplevel *tl = xdg_surface_get_toplevel(window_xs);
        xdg_toplevel_add_listener(tl, &tl_listener, NULL);
        xdg_toplevel_set_app_id(tl, argc > 3 ? argv[3] : "org.abyssbsd.lockwindow");
        wl_surface_commit(window);
    }
    wl_display_roundtrip(dpy);
    printf("ready\n");

    char line[64];
    struct pollfd fds[2] = { { wl_display_get_fd(dpy), POLLIN, 0 }, { 0, POLLIN, 0 } };
    for (;;) {
        wl_display_flush(dpy);
        if (poll(fds, 2, -1) < 0) break;
        if (fds[0].revents & POLLIN) { if (wl_display_dispatch(dpy) < 0) break; }
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            if (!fgets(line, sizeof line, stdin)) break;
            switch (line[0]) {
            case 'l': if (lock_mode && !lock) do_lock(); break;
            case 'u': if (lock) { ext_session_lock_v1_unlock_and_destroy(lock); lock = NULL; wl_display_roundtrip(dpy); printf("unlocked\n"); } break;
            case 'p': if (!lock_mode) open_grabbing_popup(); break;
            case 'f':
                if (lock && nlock_surfaces) {
                    struct wl_callback *cb = wl_surface_frame(lock_surfaces[0]);
                    wl_callback_add_listener(cb, &frame_listener, NULL);
                    wl_surface_commit(lock_surfaces[0]);
                }
                break;
            case 'q': exit(0);
            }
        }
    }
    return 0;
}
