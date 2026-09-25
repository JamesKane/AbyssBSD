/*
 * CWayland — C interop umbrella for the AbyssBSD Swift desktop.
 *
 * Exposes libwayland-client + scanner-generated protocol clients to Swift,
 * plus a couple of small portable helpers that are awkward to express in
 * Swift's imported Glibc/FreeBSD module (anonymous shm fd creation).
 *
 * Phase 1 ships xdg-shell only; layer-shell / foreign-toplevel / xdg-activation
 * are vendored under protocols/ and will be generated in here for Phase 2.
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
#include "abyss-menu-v1-client-protocol.h"

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
 * Shim wrappers.
 *
 * libwayland's generated request/add_listener functions are all `static inline`
 * in the protocol headers, so Swift cannot call them directly. These real
 * (exported) wrappers forward to them, encoding the correct opcodes/interfaces.
 * Opaque wl_* pointers are passed as void* so the Swift side sees OpaquePointer.
 */

/* Generic: works for every proxy — add_listener is always the same forward. */
int aw_add_listener(void *proxy, const void *listener, void *data);
/* **Frees the local proxy and tells the compositor NOTHING.** `wl_proxy_destroy`
 * sends no request: the destructor request is in the generated per-interface
 * function, and skipping it leaves the server-side object alive for the life of
 * the connection. Use it only for objects with no destructor request; every
 * object that has one gets a wrapper below. */
void aw_proxy_destroy(void *proxy);
/* Destructor requests — the ones a client must actually send. */
void aw_surface_destroy(void *surface);
void aw_xdg_surface_destroy(void *xdg_surface);
void aw_xdg_toplevel_destroy(void *toplevel);

/* Registry + typed binds (avoids passing wl_interface pointers from Swift). */
void *aw_display_get_registry(void *display);
void *aw_bind_compositor(void *registry, uint32_t name, uint32_t version);
void *aw_bind_shm(void *registry, uint32_t name, uint32_t version);
void *aw_bind_seat(void *registry, uint32_t name, uint32_t version);
void *aw_bind_xdg_wm_base(void *registry, uint32_t name, uint32_t version);
void *aw_bind_output(void *registry, uint32_t name, uint32_t version);

/* Compositor / surface / shm / buffer. */
void *aw_compositor_create_surface(void *compositor);
void *aw_shm_create_pool(void *shm, int fd, int32_t size);
void *aw_shm_pool_create_buffer(void *pool, int32_t offset, int32_t width,
                                int32_t height, int32_t stride, uint32_t format);
void aw_shm_pool_destroy(void *pool);
void aw_surface_attach(void *surface, void *buffer, int32_t x, int32_t y);
void aw_surface_damage_buffer(void *surface, int32_t x, int32_t y,
                             int32_t w, int32_t h);
void aw_surface_set_buffer_scale(void *surface, int32_t scale);
void aw_surface_commit(void *surface);
void *aw_surface_frame(void *surface);
void aw_buffer_destroy(void *buffer);

/* xdg-shell. */
void aw_xdg_wm_base_pong(void *wm_base, uint32_t serial);
void *aw_xdg_wm_base_get_xdg_surface(void *wm_base, void *surface);
void *aw_xdg_surface_get_toplevel(void *xdg_surface);
void aw_xdg_surface_ack_configure(void *xdg_surface, uint32_t serial);
void aw_xdg_toplevel_set_title(void *toplevel, const char *title);
void aw_xdg_toplevel_set_app_id(void *toplevel, const char *app_id);
/* The requests a window makes about itself (P9.4). `move` and `resize` hand the
 * pointer to the compositor for the duration — only it can place a window — and
 * both carry the serial of the press that started them, which is what stops a
 * program grabbing a pointer nobody handed it. `set_fullscreen` takes a NULL
 * output to mean "you choose". */
void aw_xdg_toplevel_move(void *toplevel, void *seat, uint32_t serial);
void aw_xdg_toplevel_resize(void *toplevel, void *seat, uint32_t serial,
                            uint32_t edges);
void aw_xdg_toplevel_set_maximized(void *toplevel);
void aw_xdg_toplevel_unset_maximized(void *toplevel);
void aw_xdg_toplevel_set_minimized(void *toplevel);
void aw_xdg_toplevel_set_fullscreen(void *toplevel, void *output);
void aw_xdg_toplevel_unset_fullscreen(void *toplevel);

/* xdg-shell popups (menus): a positioner anchors a child popup surface to a
 * rect in the parent, and grab routes input to it + dismisses on outside click. */
void *aw_xdg_wm_base_create_positioner(void *wm_base);
void aw_xdg_positioner_set_size(void *p, int32_t w, int32_t h);
void aw_xdg_positioner_set_anchor_rect(void *p, int32_t x, int32_t y,
                                       int32_t w, int32_t h);
void aw_xdg_positioner_set_anchor(void *p, uint32_t anchor);
void aw_xdg_positioner_set_gravity(void *p, uint32_t gravity);
void aw_xdg_positioner_set_constraint_adjustment(void *p, uint32_t adj);
void aw_xdg_positioner_destroy(void *p);
void *aw_xdg_surface_get_popup(void *xdg_surface, void *parent, void *positioner);
/* A popup with no xdg parent, to be parented to a layer surface instead. */
void *aw_xdg_surface_get_popup_no_parent(void *xdg_surface, void *positioner);
void aw_xdg_popup_grab(void *popup, void *seat, uint32_t serial);
void aw_xdg_popup_destroy(void *popup);

/* wlr-layer-shell: an anchored/exclusive surface role (wallpaper, menu bar,
 * Dock) placed by the compositor into a layer, instead of a floating toplevel.
 * The layer_surface itself carries configure/ack (there's no xdg_surface). */
void *aw_bind_layer_shell(void *registry, uint32_t name, uint32_t version);
void *aw_layer_shell_get_layer_surface(void *shell, void *surface, void *output,
                                       uint32_t layer, const char *ns);
void aw_layer_surface_set_size(void *ls, uint32_t w, uint32_t h);
void aw_layer_surface_set_anchor(void *ls, uint32_t anchor);
void aw_layer_surface_set_exclusive_zone(void *ls, int32_t zone);
void aw_layer_surface_set_margin(void *ls, int32_t top, int32_t right,
                                 int32_t bottom, int32_t left);
void aw_layer_surface_set_keyboard_interactivity(void *ls, uint32_t ki);
void aw_layer_surface_ack_configure(void *ls, uint32_t serial);
void aw_layer_surface_destroy(void *ls);
/* Parent an xdg_popup to a layer surface (its menus/tooltips). */
void aw_layer_surface_get_popup(void *ls, void *xdg_popup);

/* wlr-foreign-toplevel-management: the compositor advertises a handle per open
 * toplevel (title/app_id/state); the Dock/menu track running apps and can
 * activate one. */
void *aw_bind_foreign_toplevel_manager(void *registry, uint32_t name, uint32_t version);
void aw_foreign_toplevel_handle_activate(void *handle, void *seat);
void aw_foreign_toplevel_handle_close(void *handle);
void aw_foreign_toplevel_handle_destroy(void *handle);

/* xdg-activation: the client asks the compositor for an activation token (tied
 * to a real input serial), then activates a surface with it — the sanctioned way
 * to raise/focus one of your own windows. The Finder uses it in spatial mode to
 * bring an already-open folder's window forward. */
/* abyss-menu-v1 (PHASE10.md P10.3): an application says where a surface's
 * menus are published; the menu bar — on undertow's privileged socket — is told
 * where the focused surface's are. Requests are static inline, hence these. */
void *aw_bind_menu_manager(void *registry, uint32_t name, uint32_t version);
void aw_menu_manager_set_address(void *manager, void *surface, const char *address);
void *aw_bind_menubar(void *registry, uint32_t name, uint32_t version);
void aw_menubar_destroy(void *menubar);
void *aw_bind_xdg_activation(void *registry, uint32_t name, uint32_t version);
void *aw_xdg_activation_get_token(void *activation);
void aw_xdg_activation_token_set_serial(void *token, uint32_t serial, void *seat);
void aw_xdg_activation_token_set_surface(void *token, void *surface);
void aw_xdg_activation_token_commit(void *token);
void aw_xdg_activation_token_destroy(void *token);
void aw_xdg_activation_activate(void *activation, const char *token, void *surface);

/* wlr-screencopy: the compositor copies an output's contents into a buffer the
 * client supplies. The frame object describes what buffer it wants (format,
 * size, stride) and reports ready/failed once the copy is done. This is how
 * grim takes every screenshot in docs/screenshots/, and it is what lets the
 * screenshot portal be an ordinary client rather than compositor code. */
void *aw_bind_screencopy_manager(void *registry, uint32_t name, uint32_t version);
void *aw_screencopy_capture_output(void *manager, int32_t overlay_cursor,
                                   void *output);
void aw_screencopy_frame_copy(void *frame, void *buffer);
void aw_screencopy_frame_destroy(void *frame);
void aw_screencopy_manager_destroy(void *manager);

/* Seat. */
void *aw_seat_get_pointer(void *seat);

/* --- the clipboard (P9.1) ------------------------------------------------
 *
 * `wl_data_device` is CORE wayland, so there is no protocol XML and no scanner
 * line here — but every request below is a `static inline` in the generated
 * header, which is §2.1 for the sixth time. The listener structs are ordinary
 * C and Swift sees them directly; only the requests need wrapping.
 */
void *aw_bind_data_device_manager(void *registry, uint32_t name, uint32_t version);
void *aw_data_device_manager_get_data_device(void *manager, void *seat);
void *aw_data_device_manager_create_data_source(void *manager);
void aw_data_device_set_selection(void *device, void *source, uint32_t serial);
void aw_data_source_offer(void *source, const char *mime);
void aw_data_source_destroy(void *source);
void aw_data_offer_receive(void *offer, const char *mime, int fd);
void aw_data_offer_destroy(void *offer);

/* --- drag and drop (P9.3), the same objects with a grab on them ---------- */
void aw_data_device_start_drag(void *device, void *source, void *origin,
                               void *icon, uint32_t serial);
void aw_data_offer_accept(void *offer, uint32_t serial, const char *mime);
void aw_data_offer_set_actions(void *offer, uint32_t actions, uint32_t preferred);
void aw_data_offer_finish(void *offer);
void aw_data_source_set_actions(void *source, uint32_t actions);
void *aw_seat_get_keyboard(void *seat);

#endif /* ABYSS_CWAYLAND_H */
