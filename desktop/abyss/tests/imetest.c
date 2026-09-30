// imetest — an input method for the tests (BACKLOG U.5).
//
// Binds zwp_input_method_manager_v2 and becomes the seat's input method, the
// way fcitx5 or ibus would, and prints what the compositor tells it, a line
// each, flushed:
//
//     ready                     bound
//     activate | deactivate     a field became (in)active — applied at `done`
//     surrounding <bytes>       the field's text around the cursor (length only)
//     done active=<0|1>         the end of a batch
//     key <code> <pressed>      a key, while it holds the keyboard
//     unavailable               another input method already has the seat
//
// And takes commands on stdin, one per line:
//
//     p <text>     show <text> as preedit (composing, not yet text)
//     c <text>     commit <text> to the field (clears the preedit)
//     g            grab the keyboard      u  release it
//     q            quit
//
// A test helper, not part of the product; built on demand against the
// vendored input-method-unstable-v2.xml.
//
// Usage: imetest

#define _GNU_SOURCE
#include <wayland-client.h>
#include "imetest-proto.h"

#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct wl_seat *seat;
static struct zwp_input_method_manager_v2 *manager;
static struct zwp_input_method_v2 *im;
static struct zwp_input_method_keyboard_grab_v2 *grab;
static uint32_t serial;      /* `done` events seen: what commit must quote */
static int pending_active, active;

static void reg_global(void *d, struct wl_registry *r, uint32_t id, const char *iface, uint32_t v) {
    (void)d; (void)v;
    if (strcmp(iface, wl_seat_interface.name) == 0 && !seat)
        seat = wl_registry_bind(r, id, &wl_seat_interface, 1);
    else if (strcmp(iface, zwp_input_method_manager_v2_interface.name) == 0)
        manager = wl_registry_bind(r, id, &zwp_input_method_manager_v2_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t id) { (void)d; (void)r; (void)id; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static void im_activate(void *d, struct zwp_input_method_v2 *m) { (void)d; (void)m; pending_active = 1; printf("activate\n"); }
static void im_deactivate(void *d, struct zwp_input_method_v2 *m) { (void)d; (void)m; pending_active = 0; printf("deactivate\n"); }
static void im_surrounding(void *d, struct zwp_input_method_v2 *m, const char *text, uint32_t c, uint32_t a) {
    (void)d; (void)m; (void)c; (void)a; printf("surrounding %zu\n", text ? strlen(text) : 0);
}
static void im_cause(void *d, struct zwp_input_method_v2 *m, uint32_t cause) { (void)d; (void)m; (void)cause; }
static void im_content(void *d, struct zwp_input_method_v2 *m, uint32_t h, uint32_t p) { (void)d; (void)m; (void)h; (void)p; }
static void im_done(void *d, struct zwp_input_method_v2 *m) {
    (void)d; (void)m; serial++; active = pending_active; printf("done active=%d\n", active);
}
static void im_unavailable(void *d, struct zwp_input_method_v2 *m) { (void)d; (void)m; printf("unavailable\n"); }
static const struct zwp_input_method_v2_listener im_listener = {
    im_activate, im_deactivate, im_surrounding, im_cause, im_content, im_done, im_unavailable,
};

static void kg_keymap(void *d, struct zwp_input_method_keyboard_grab_v2 *g, uint32_t f, int32_t fd, uint32_t s) {
    (void)d; (void)g; (void)f; (void)s; close(fd);
}
static void kg_key(void *d, struct zwp_input_method_keyboard_grab_v2 *g, uint32_t ser, uint32_t t, uint32_t key, uint32_t state) {
    (void)d; (void)g; (void)ser; (void)t; printf("key %u %u\n", key, state);
}
static void kg_mods(void *d, struct zwp_input_method_keyboard_grab_v2 *g, uint32_t s, uint32_t a, uint32_t b, uint32_t c, uint32_t e) {
    (void)d; (void)g; (void)s; (void)a; (void)b; (void)c; (void)e;
}
static void kg_repeat(void *d, struct zwp_input_method_keyboard_grab_v2 *g, int32_t r, int32_t dl) { (void)d; (void)g; (void)r; (void)dl; }
static const struct zwp_input_method_keyboard_grab_v2_listener kg_listener = { kg_keymap, kg_key, kg_mods, kg_repeat };

static void command(char *line, struct wl_display *dpy) {
    line[strcspn(line, "\n")] = 0;
    char *arg = line[0] && line[1] == ' ' ? line + 2 : "";
    switch (line[0]) {
    case 'p':
        zwp_input_method_v2_set_preedit_string(im, arg, (int32_t)strlen(arg), (int32_t)strlen(arg));
        zwp_input_method_v2_commit(im, serial);
        break;
    case 'c':
        zwp_input_method_v2_commit_string(im, arg);
        zwp_input_method_v2_commit(im, serial);
        break;
    case 'g':
        if (!grab) { grab = zwp_input_method_v2_grab_keyboard(im); zwp_input_method_keyboard_grab_v2_add_listener(grab, &kg_listener, NULL); }
        break;
    case 'u':
        if (grab) { zwp_input_method_keyboard_grab_v2_release(grab); grab = NULL; }
        break;
    case 'q':
        exit(0);
    }
    wl_display_flush(dpy);
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "imetest: cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!seat || !manager) { fprintf(stderr, "imetest: no seat, or no zwp_input_method_manager_v2\n"); return 2; }
    im = zwp_input_method_manager_v2_get_input_method(manager, seat);
    zwp_input_method_v2_add_listener(im, &im_listener, NULL);
    wl_display_roundtrip(dpy);
    printf("ready\n");

    char line[512];
    struct pollfd fds[2] = { { wl_display_get_fd(dpy), POLLIN, 0 }, { 0, POLLIN, 0 } };
    for (;;) {
        wl_display_flush(dpy);
        if (poll(fds, 2, -1) < 0) break;
        if (fds[0].revents & POLLIN) { if (wl_display_dispatch(dpy) < 0) break; }
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            if (!fgets(line, sizeof line, stdin)) break;
            command(line, dpy);
        }
    }
    return 0;
}
