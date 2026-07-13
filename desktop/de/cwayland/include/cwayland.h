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

/*
 * Create an anonymous, writable shared-memory fd of `size` bytes, suitable for
 * wl_shm_create_pool. Linux: memfd_create; FreeBSD: shm_open(SHM_ANON).
 * Returns a fd >= 0 on success, -1 on failure (errno set).
 */
int aw_create_shm(size_t size);

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
void aw_proxy_destroy(void *proxy);

/* Registry + typed binds (avoids passing wl_interface pointers from Swift). */
void *aw_display_get_registry(void *display);
void *aw_bind_compositor(void *registry, uint32_t name, uint32_t version);
void *aw_bind_shm(void *registry, uint32_t name, uint32_t version);
void *aw_bind_seat(void *registry, uint32_t name, uint32_t version);
void *aw_bind_xdg_wm_base(void *registry, uint32_t name, uint32_t version);

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

/* Seat. */
void *aw_seat_get_pointer(void *seat);

#endif /* ABYSS_CWAYLAND_H */
