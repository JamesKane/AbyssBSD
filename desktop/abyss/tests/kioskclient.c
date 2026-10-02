// kioskclient — a window that asks for fullscreen before its first commit,
// and then unset_maximized, exactly as `firefox --kiosk` does (BACKLOG F.1).
//
// It prints every configure it is given ("configure W H fullscreen=0|1"),
// draws a buffer of the size it was told (1x1 when told 0x0 — what Firefox
// does), and stays up until stdin closes.
//
// Not part of the product: compiled on demand by live-kiosk.sh.
//
// Usage: kioskclient APP_ID [plain|max]
//   plain: no fullscreen request, only the stray unset_maximized;
//   max:   the mirror — set_maximized, then a stray unset_fullscreen.
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static struct wl_compositor *comp;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wl_surface *surf;
static int32_t want_w, want_h, fs;
static int configured;

static void reg(void *d, struct wl_registry *r, uint32_t n, const char *i, uint32_t v) {
    (void)d; (void)v;
    if (!strcmp(i, "wl_compositor")) comp = wl_registry_bind(r, n, &wl_compositor_interface, 4);
    else if (!strcmp(i, "wl_shm")) shm = wl_registry_bind(r, n, &wl_shm_interface, 1);
    else if (!strcmp(i, "xdg_wm_base")) wm = wl_registry_bind(r, n, &xdg_wm_base_interface, 1);
}
static void unreg(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener rl = { reg, unreg };
static void ping(void *d, struct xdg_wm_base *b, uint32_t s) { (void)d; xdg_wm_base_pong(b, s); }
static const struct xdg_wm_base_listener wl = { ping };

static void tl_conf(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *st) {
    (void)d; (void)t;
    want_w = w; want_h = h; fs = 0;
    uint32_t *s;
    wl_array_for_each(s, st) if (*s == XDG_TOPLEVEL_STATE_FULLSCREEN) fs = 1;
}
static void tl_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; }
static const struct xdg_toplevel_listener tll = { tl_conf, tl_close };

static void draw(void) {
    int32_t w = want_w > 0 ? want_w : 1, h = want_h > 0 ? want_h : 1;
    size_t size = (size_t)w * h * 4;
    char name[] = "/tmp/kioskclient-XXXXXX";
    int fd = mkstemp(name);
    unlink(name);
    if (fd < 0 || ftruncate(fd, (off_t)size) < 0) { perror("shm"); exit(1); }
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    for (size_t i = 0; i < size / 4; i++) px[i] = 0xff2e8b57;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    wl_surface_attach(surf, b, 0, 0);
    wl_surface_damage_buffer(surf, 0, 0, w, h);
    wl_surface_commit(surf);
}

static void xs_conf(void *d, struct xdg_surface *x, uint32_t serial) {
    (void)d;
    xdg_surface_ack_configure(x, serial);
    printf("configure %d %d fullscreen=%d\n", want_w, want_h, fs);
    fflush(stdout);
    configured = 1;
    draw();
}
static const struct xdg_surface_listener xsl = { xs_conf };

int main(int argc, char **argv) {
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "no display\n"); return 1; }
    struct wl_registry *r = wl_display_get_registry(dpy);
    wl_registry_add_listener(r, &rl, NULL);
    wl_display_roundtrip(dpy);
    xdg_wm_base_add_listener(wm, &wl, NULL);
    surf = wl_compositor_create_surface(comp);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm, surf);
    xdg_surface_add_listener(xs, &xsl, NULL);
    struct xdg_toplevel *tl = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(tl, &tll, NULL);
    xdg_toplevel_set_app_id(tl, argc > 1 ? argv[1] : "org.abyssbsd.kiosk");
    int plain = argc > 2 && !strcmp(argv[2], "plain");
    int max = argc > 2 && !strcmp(argv[2], "max");
    if (max) xdg_toplevel_set_maximized(tl);
    else if (!plain) xdg_toplevel_set_fullscreen(tl, NULL);
    wl_surface_commit(surf);
    /* Firefox's next request, before the first configure arrives — or its
     * mirror for a maximized window. */
    if (max) xdg_toplevel_unset_fullscreen(tl);
    else xdg_toplevel_unset_maximized(tl);
    wl_display_flush(dpy);
    struct pollfd p[2] = { { wl_display_get_fd(dpy), POLLIN, 0 }, { 0, POLLIN, 0 } };
    for (;;) {
        wl_display_flush(dpy);
        if (poll(p, 2, -1) < 0) break;
        if (p[0].revents && wl_display_dispatch(dpy) < 0) break;
        if (p[1].revents) { char c[64]; if (read(0, c, sizeof c) <= 0) break; }
    }
    return 0;
}
