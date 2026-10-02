/*
 * aw_jail_listen — register a jail's Wayland socket (PHASE18 P18.5).
 *
 * The session's half of wp_security_context_v1: bind a listening socket at
 * `path` (inside the jail's root, from outside it), hand it to the compositor
 * with the jail's engine, app id and instance, and keep the write end of
 * close_fd. Every client that connects to `path` is then that context's —
 * jailed. Closing *close_out stops the compositor listening.
 *
 * Its own registry and roundtrips, on a connection the caller owns: it does
 * not disturb whatever else that connection is doing.
 */
#include "cwayland.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

struct find { struct wp_security_context_manager_v1 *mgr; };

static void found(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
    struct find *f = data;
    (void)version;
    if (!f->mgr && strcmp(iface, wp_security_context_manager_v1_interface.name) == 0)
        f->mgr = wl_registry_bind(reg, name, &wp_security_context_manager_v1_interface, 1);
}
static void gone(void *data, struct wl_registry *reg, uint32_t name) { (void)data; (void)reg; (void)name; }
static const struct wl_registry_listener find_listener = { found, gone };

int aw_jail_listen(struct wl_display *d, const char *path, const char *engine,
                   const char *app_id, const char *instance, int *close_out) {
    struct find f = { NULL };
    struct wl_registry *reg = wl_display_get_registry(d);
    wl_registry_add_listener(reg, &find_listener, &f);
    if (wl_display_roundtrip(d) < 0) { wl_registry_destroy(reg); return -EIO; }
    if (!f.mgr) { wl_registry_destroy(reg); return -ENOENT; }

    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof sa.sun_path) { wp_security_context_manager_v1_destroy(f.mgr); wl_registry_destroy(reg); return -ENAMETOOLONG; }
    strcpy(sa.sun_path, path);
    int ls = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    int closer[2] = { -1, -1 };
    int err = 0;
    unlink(path);
    if (ls < 0 || bind(ls, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(ls, 16) < 0 || pipe(closer) < 0) {
        err = -errno;
        if (ls >= 0) close(ls);
        wp_security_context_manager_v1_destroy(f.mgr);
        wl_registry_destroy(reg);
        return err;
    }
    struct wp_security_context_v1 *ctx = wp_security_context_manager_v1_create_listener(f.mgr, ls, closer[0]);
    if (engine) wp_security_context_v1_set_sandbox_engine(ctx, engine);
    if (app_id) wp_security_context_v1_set_app_id(ctx, app_id);
    if (instance) wp_security_context_v1_set_instance_id(ctx, instance);
    wp_security_context_v1_commit(ctx);
    wp_security_context_v1_destroy(ctx);
    close(ls);
    close(closer[0]);
    wp_security_context_manager_v1_destroy(f.mgr);
    wl_registry_destroy(reg);
    if (wl_display_roundtrip(d) < 0) { close(closer[1]); return -EPROTO; }
    *close_out = closer[1];
    return 0;
}
