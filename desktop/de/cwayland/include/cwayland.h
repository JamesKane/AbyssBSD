/*
 * CWayland — C interop umbrella for the AbyssBSD Swift desktop.
 *
 * Exposes libwayland-client + scanner-generated protocol clients to Swift,
 * plus a couple of small portable helpers that are awkward to express in
 * Swift's imported Glibc/FreeBSD module (anonymous shm fd creation).
 *
 * Requests are called from Swift as libwayland spells them; see the interface
 * pointers at the end for the one exception.
 */
#ifndef ABYSS_CWAYLAND_H
#define ABYSS_CWAYLAND_H

#include <stddef.h>
#include <stdint.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "xdg-activation-v1-client-protocol.h"
#include "wlr-screencopy-unstable-v1-client-protocol.h"
#include "wlr-output-management-unstable-v1-client-protocol.h"
#include "ext-session-lock-v1-client-protocol.h"
#include "ext-idle-notify-v1-client-protocol.h"
#include "security-context-v1-client-protocol.h"
#include "abyss-menu-v1-client-protocol.h"
#include "abyss-window-v1-client-protocol.h"

/*
 * Create an anonymous, writable shared-memory fd of `size` bytes, suitable for
 * wl_shm_create_pool. Linux: memfd_create; FreeBSD: shm_open(SHM_ANON).
 * Returns a fd >= 0 on success, -1 on failure (errno set).
 */
int aw_create_shm(size_t size);

/*
 * Create a periodic timerfd firing every `ms` milliseconds (CLOCK_MONOTONIC,
 * non-blocking). Pollable; read 8 bytes to clear each expiry. For the menu-bar
 * clock tick. Returns a fd >= 0, or -1 on failure.
 */
int aw_create_interval_timer(unsigned int ms);

/*
 * The globals the toolkit binds, as pointers to their interface tables.
 *
 * Every libwayland request and `*_add_listener` is a `static inline` in the
 * generated headers, and Swift calls those directly (HANDOFF §2.1). The one
 * thing it cannot do is `wl_registry_bind`'s interface argument: libwayland
 * keeps that pointer as the new proxy's interface, and Swift has no way to
 * take the address of a C global. `withUnsafePointer(to: wl_seat_interface)`
 * gives the real address in a debug build and a pointer to a stack copy in a
 * release build. A pointer *value* is copied faithfully, so these are what
 * `wlBind` takes. Binding a new global needs one line here and nothing else.
 */
static const struct wl_interface *const wl_compositor_iface = &wl_compositor_interface;
static const struct wl_interface *const wl_shm_iface = &wl_shm_interface;
static const struct wl_interface *const wl_seat_iface = &wl_seat_interface;
static const struct wl_interface *const wl_output_iface = &wl_output_interface;
static const struct wl_interface *const wl_data_device_manager_iface = &wl_data_device_manager_interface;
static const struct wl_interface *const xdg_wm_base_iface = &xdg_wm_base_interface;
static const struct wl_interface *const xdg_activation_v1_iface = &xdg_activation_v1_interface;
static const struct wl_interface *const zwlr_layer_shell_v1_iface = &zwlr_layer_shell_v1_interface;
static const struct wl_interface *const zwlr_foreign_toplevel_manager_v1_iface = &zwlr_foreign_toplevel_manager_v1_interface;
static const struct wl_interface *const zwlr_screencopy_manager_v1_iface = &zwlr_screencopy_manager_v1_interface;
static const struct wl_interface *const ext_session_lock_manager_v1_iface = &ext_session_lock_manager_v1_interface;
static const struct wl_interface *const ext_idle_notifier_v1_iface = &ext_idle_notifier_v1_interface;
static const struct wl_interface *const zwlr_output_manager_v1_iface = &zwlr_output_manager_v1_interface;
static const struct wl_interface *const abyss_menu_manager_v1_iface = &abyss_menu_manager_v1_interface;
static const struct wl_interface *const abyss_window_manager_v1_iface = &abyss_window_manager_v1_interface;
static const struct wl_interface *const abyss_menubar_v1_iface = &abyss_menubar_v1_interface;

/*
 * Register a jail's Wayland socket at `path` with the compositor's
 * wp_security_context_manager_v1 (PHASE18 P18.5). 0 and *close_out (close it
 * to stop the compositor listening), or -errno: -ENOENT when the compositor
 * offers no security contexts.
 */
int aw_jail_listen(struct wl_display *d, const char *path, const char *engine,
                   const char *app_id, const char *instance, int *close_out);

#endif /* ABYSS_CWAYLAND_H */
