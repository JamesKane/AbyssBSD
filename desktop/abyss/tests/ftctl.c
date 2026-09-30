/*
 * ftctl — minimise or restore a window by its app id, the way the Dock does:
 * through wlr-foreign-toplevel-management (T.3's test).
 *
 * A window cannot un-minimise itself — xdg-shell has no request for it — so
 * the way back is the compositor's, and the Dock asks for it with this
 * protocol. A test that wants a window hidden and back again without drawing
 * a Dock uses this instead.
 *
 *   ftctl APP_ID minimize | restore
 *
 * Exits 0 when it found the window and asked, 1 when no window has that app
 * id, 2 when the compositor lacks the protocol. Built by the test that uses
 * it; not part of the product.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

static struct zwlr_foreign_toplevel_manager_v1 *ftm;
static struct wl_seat *seat;
static struct zwlr_foreign_toplevel_handle_v1 *found;
static const char *want;

static void h_title(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *t) { (void)d; (void)h; (void)t; }
static void h_app_id(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *id) {
    (void)d;
    if (id && !strcmp(id, want)) found = h;
}
static void h_output_enter(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o) { (void)d; (void)h; (void)o; }
static void h_output_leave(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o) { (void)d; (void)h; (void)o; }
static void h_state(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *s) { (void)d; (void)h; (void)s; }
static void h_done(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) { (void)d; (void)h; }
static void h_closed(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) { (void)d; if (found == h) found = NULL; }
static void h_parent(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct zwlr_foreign_toplevel_handle_v1 *p) { (void)d; (void)h; (void)p; }
static const struct zwlr_foreign_toplevel_handle_v1_listener handle_listener = {
    h_title, h_app_id, h_output_enter, h_output_leave, h_state, h_done, h_closed, h_parent,
};

static void m_toplevel(void *d, struct zwlr_foreign_toplevel_manager_v1 *m, struct zwlr_foreign_toplevel_handle_v1 *h) {
    (void)d; (void)m;
    zwlr_foreign_toplevel_handle_v1_add_listener(h, &handle_listener, NULL);
}
static void m_finished(void *d, struct zwlr_foreign_toplevel_manager_v1 *m) { (void)d; (void)m; }
static const struct zwlr_foreign_toplevel_manager_v1_listener manager_listener = { m_toplevel, m_finished };

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t v) {
    (void)d;
    if (!strcmp(iface, zwlr_foreign_toplevel_manager_v1_interface.name))
        ftm = wl_registry_bind(r, name, &zwlr_foreign_toplevel_manager_v1_interface, v < 3 ? v : 3);
    else if (!strcmp(iface, "wl_seat") && !seat)
        seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[2], "minimize") && strcmp(argv[2], "restore"))) {
        fprintf(stderr, "usage: ftctl APP_ID minimize|restore\n");
        return 2;
    }
    want = argv[1];
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "ftctl: cannot connect\n"); return 2; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!ftm || !seat) { fprintf(stderr, "ftctl: no zwlr_foreign_toplevel_manager_v1\n"); return 2; }
    zwlr_foreign_toplevel_manager_v1_add_listener(ftm, &manager_listener, NULL);
    wl_display_roundtrip(dpy);
    wl_display_roundtrip(dpy);
    if (!found) { fprintf(stderr, "ftctl: no window with app id %s\n", want); return 1; }
    if (!strcmp(argv[2], "minimize")) {
        zwlr_foreign_toplevel_handle_v1_set_minimized(found);
    } else {
        zwlr_foreign_toplevel_handle_v1_unset_minimized(found);
        zwlr_foreign_toplevel_handle_v1_activate(found, seat);
    }
    wl_display_roundtrip(dpy);
    printf("ftctl: asked %s to %s\n", want, argv[2]);
    return 0;
}
