// idletest — a window that holds the displays awake, asks about idleness and
// copies or pastes the primary selection, for undertow's U.9 (docs/BACKLOG.md).
//
// It draws on every frame callback and nothing else, as a video player does,
// so its frame count is the compositor's clock as a client feels it. It
// prints, a line each, flushed:
//
//     ready                   mapped
//     focus                   keyboard focus (the serial a selection needs)
//     frames <n>              callbacks since the last `f`
//     idled | resumed         ext-idle-notify: idle for the asked time / not
//     pasted <text>           the primary selection's text, when one arrives
//
// And takes commands on stdin:
//
//     i | I        take / drop an idle inhibitor on its surface
//     n <ms>       ask ext-idle-notify for <ms> of idleness
//     m            minimise itself
//     f            print the frame count, and start counting again
//     c <text>     offer <text> as the primary selection
//     q            quit
//
// Every received primary selection is read and printed. A test helper, not
// part of the product; built by live-idle.sh.
//
// Usage: idletest [app-id]

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
#include "idle-inhibit-proto.h"
#include "ext-idle-notify-proto.h"
#include "primary-selection-proto.h"

#define W 200
#define H 150
#define MIME "text/plain;charset=utf-8"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct wl_keyboard *keyboard;
static struct zwp_idle_inhibit_manager_v1 *inhibits;
static struct zwp_idle_inhibitor_v1 *inhibitor;
static struct ext_idle_notifier_v1 *notifier;
static struct zwp_primary_selection_device_manager_v1 *primaries;
static struct zwp_primary_selection_device_v1 *primary;
static struct zwp_primary_selection_source_v1 *source;

static struct wl_surface *surface;
static struct xdg_toplevel *toplevel;
static struct wl_buffer *buffer;
static int ready;
static unsigned frames;
static uint32_t focus_serial;
static char offered[256];

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
    else if (!strcmp(iface, zwp_idle_inhibit_manager_v1_interface.name))
        inhibits = wl_registry_bind(r, id, &zwp_idle_inhibit_manager_v1_interface, 1);
    else if (!strcmp(iface, ext_idle_notifier_v1_interface.name))
        notifier = wl_registry_bind(r, id, &ext_idle_notifier_v1_interface, 1);
    else if (!strcmp(iface, zwp_primary_selection_device_manager_v1_interface.name))
        primaries = wl_registry_bind(r, id, &zwp_primary_selection_device_manager_v1_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t id) { (void)d; (void)r; (void)id; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static struct wl_buffer *solid(uint32_t argb) {
    int stride = W * 4, size = stride * H;
    char name[64];
    snprintf(name, sizeof name, "/idletest-%d", (int)getpid());
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { perror("shm_open"); exit(1); }
    shm_unlink(name);
    if (ftruncate(fd, size) < 0) { perror("ftruncate"); exit(1); }
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { perror("mmap"); exit(1); }
    for (int i = 0; i < W * H; i++) px[i] = argb;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, W, H, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    munmap(px, size);
    return b;
}

/* ---------------------------------------------------------------- the clock */
static const struct wl_callback_listener frame_listener;
static void draw(void) {
    struct wl_callback *cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, W, H);
    wl_surface_commit(surface);
}
static void frame_done(void *d, struct wl_callback *cb, uint32_t t) {
    (void)d; (void)t;
    wl_callback_destroy(cb);
    frames++;
    draw();
}
static const struct wl_callback_listener frame_listener = { frame_done };

/* ------------------------------------------------------------------ idleness */
static void on_idled(void *d, struct ext_idle_notification_v1 *n) { (void)d; (void)n; printf("idled\n"); }
static void on_resumed(void *d, struct ext_idle_notification_v1 *n) { (void)d; (void)n; printf("resumed\n"); }
static const struct ext_idle_notification_v1_listener idle_listener = { on_idled, on_resumed };

/* ------------------------------------------------------- the primary selection */
static void src_send(void *d, struct zwp_primary_selection_source_v1 *s, const char *mime, int32_t fd) {
    (void)d; (void)s; (void)mime;
    ssize_t n = write(fd, offered, strlen(offered));
    (void)n;
    close(fd);
}
static void src_cancelled(void *d, struct zwp_primary_selection_source_v1 *s) {
    (void)d; zwp_primary_selection_source_v1_destroy(s);
    if (s == source) source = NULL;
}
static const struct zwp_primary_selection_source_v1_listener src_listener = { src_send, src_cancelled };

static void offer_mime(void *d, struct zwp_primary_selection_offer_v1 *o, const char *m) { (void)d; (void)o; (void)m; }
static const struct zwp_primary_selection_offer_v1_listener offer_listener = { offer_mime };
static void dev_offer(void *d, struct zwp_primary_selection_device_v1 *dev, struct zwp_primary_selection_offer_v1 *o) {
    (void)d; (void)dev; zwp_primary_selection_offer_v1_add_listener(o, &offer_listener, NULL);
}
static struct wl_display *dpy;
static void dev_selection(void *d, struct zwp_primary_selection_device_v1 *dev, struct zwp_primary_selection_offer_v1 *o) {
    (void)d; (void)dev;
    if (!o || source) return;                 /* nothing, or our own */
    int p[2];
    if (pipe(p) < 0) return;
    zwp_primary_selection_offer_v1_receive(o, MIME, p[1]);
    close(p[1]);
    // The request out, then a blocking read: the other client writes and
    // closes its end, in its own process.
    wl_display_flush(dpy);
    char buf[256] = {0};
    ssize_t n = read(p[0], buf, sizeof buf - 1);
    close(p[0]);
    if (n > 0) printf("pasted %s\n", buf);
    zwp_primary_selection_offer_v1_destroy(o);
}
static const struct zwp_primary_selection_device_v1_listener dev_listener = { dev_offer, dev_selection };

/* ------------------------------------------------------------------ keyboard */
static void k_keymap(void *d, struct wl_keyboard *k, uint32_t f, int32_t fd, uint32_t s) { (void)d; (void)k; (void)f; (void)s; close(fd); }
static void k_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf, struct wl_array *keys) {
    (void)d; (void)k; (void)sf; (void)keys; focus_serial = s; printf("focus\n");
}
static void k_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf) { (void)d; (void)k; (void)s; (void)sf; }
static void k_key(void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key, uint32_t st) { (void)d; (void)k; (void)s; (void)t; (void)key; (void)st; }
static void k_mods(void *d, struct wl_keyboard *k, uint32_t s, uint32_t a, uint32_t b, uint32_t c, uint32_t g) { (void)d; (void)k; (void)s; (void)a; (void)b; (void)c; (void)g; }
static void k_repeat(void *d, struct wl_keyboard *k, int32_t r, int32_t dl) { (void)d; (void)k; (void)r; (void)dl; }
static const struct wl_keyboard_listener kb_listener = { k_keymap, k_enter, k_leave, k_key, k_mods, k_repeat };

/* A keyboard once the seat has one: a run with no keyboard attached has none. */
static void seat_caps(void *d, struct wl_seat *s, uint32_t caps) {
    (void)d;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !keyboard) {
        keyboard = wl_seat_get_keyboard(s);
        wl_keyboard_add_listener(keyboard, &kb_listener, NULL);
    }
}
static void seat_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }
static const struct wl_seat_listener seat_listener = { seat_caps, seat_name };

/* --------------------------------------------------------------------- shell */
static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t s) { (void)d; xdg_wm_base_pong(b, s); }
static const struct xdg_wm_base_listener wm_listener = { wm_ping };
static void xs_configure(void *d, struct xdg_surface *xs, uint32_t s) {
    (void)d;
    xdg_surface_ack_configure(xs, s);
    if (!ready) { ready = 1; draw(); printf("ready\n"); }
}
static const struct xdg_surface_listener xs_listener = { xs_configure };
static void tl_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) {
    (void)d; (void)t; (void)w; (void)h; (void)s;
}
static void tl_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; exit(0); }
static const struct xdg_toplevel_listener tl_listener = { tl_configure, tl_close };

static void command(char *line) {
    line[strcspn(line, "\n")] = 0;
    int ms;
    switch (line[0]) {
    case 'i':
        if (!inhibitor) inhibitor = zwp_idle_inhibit_manager_v1_create_inhibitor(inhibits, surface);
        break;
    case 'I':
        if (inhibitor) { zwp_idle_inhibitor_v1_destroy(inhibitor); inhibitor = NULL; }
        break;
    case 'n':
        if (sscanf(line, "n %d", &ms) == 1) {
            struct ext_idle_notification_v1 *n = ext_idle_notifier_v1_get_idle_notification(notifier, (uint32_t)ms, seat);
            ext_idle_notification_v1_add_listener(n, &idle_listener, NULL);
        }
        break;
    case 'm':
        xdg_toplevel_set_minimized(toplevel);
        break;
    case 'f':
        printf("frames %u\n", frames);
        frames = 0;
        break;
    case 'c':
        snprintf(offered, sizeof offered, "%s", line + 2);
        source = zwp_primary_selection_device_manager_v1_create_source(primaries);
        zwp_primary_selection_source_v1_add_listener(source, &src_listener, NULL);
        zwp_primary_selection_source_v1_offer(source, MIME);
        zwp_primary_selection_device_v1_set_selection(primary, source, focus_serial);
        break;
    case 'q':
        exit(0);
    }
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "idletest: cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !shm || !wm_base || !seat) { fprintf(stderr, "idletest: missing a core global\n"); return 2; }
    if (!inhibits || !notifier || !primaries) {
        fprintf(stderr, "idletest: missing idle-inhibit (%d), ext-idle-notify (%d) or primary-selection (%d)\n",
                !!inhibits, !!notifier, !!primaries);
        return 2;
    }
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    wl_seat_add_listener(seat, &seat_listener, NULL);
    wl_display_roundtrip(dpy);
    primary = zwp_primary_selection_device_manager_v1_get_device(primaries, seat);
    zwp_primary_selection_device_v1_add_listener(primary, &dev_listener, NULL);

    buffer = solid(0xff808080);
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xs, &xs_listener, NULL);
    toplevel = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
    xdg_toplevel_set_app_id(toplevel, argc > 1 ? argv[1] : "org.abyssbsd.idletest");
    wl_surface_commit(surface);

    char line[512];
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
