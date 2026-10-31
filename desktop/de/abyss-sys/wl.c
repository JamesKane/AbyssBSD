/*
 * The Wayland requests ADE's Rust calls, as exported functions.
 *
 * wayland-scanner emits every request as a `static inline` in its headers,
 * which Swift calls directly (HANDOFF §2.1) and Rust cannot call at all. Each
 * one here is the generated inline, given a name Rust can link; the opcodes
 * and argument packing stay the scanner's, from its generated headers
 * (RUST.md §6.4). One line per request as Rust starts using it.
 */
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

struct wl_registry *
abw_display_get_registry(struct wl_display *d)
{
	return (wl_display_get_registry(d));
}

void *
abw_registry_bind(struct wl_registry *r, uint32_t name,
    const struct wl_interface *iface, uint32_t version)
{
	return (wl_registry_bind(r, name, iface, version));
}

struct wl_surface *
abw_compositor_create_surface(struct wl_compositor *c)
{
	return (wl_compositor_create_surface(c));
}

struct wl_shm_pool *
abw_shm_create_pool(struct wl_shm *shm, int32_t fd, int32_t size)
{
	return (wl_shm_create_pool(shm, fd, size));
}

struct wl_buffer *
abw_shm_pool_create_buffer(struct wl_shm_pool *p, int32_t offset, int32_t w,
    int32_t h, int32_t stride, uint32_t format)
{
	return (wl_shm_pool_create_buffer(p, offset, w, h, stride, format));
}

void
abw_shm_pool_destroy(struct wl_shm_pool *p)
{
	wl_shm_pool_destroy(p);
}

void
abw_buffer_destroy(struct wl_buffer *b)
{
	wl_buffer_destroy(b);
}

void
abw_surface_attach(struct wl_surface *s, struct wl_buffer *b, int32_t x,
    int32_t y)
{
	wl_surface_attach(s, b, x, y);
}

void
abw_surface_damage_buffer(struct wl_surface *s, int32_t x, int32_t y,
    int32_t w, int32_t h)
{
	wl_surface_damage_buffer(s, x, y, w, h);
}

void
abw_surface_set_buffer_scale(struct wl_surface *s, int32_t scale)
{
	wl_surface_set_buffer_scale(s, scale);
}

void
abw_surface_commit(struct wl_surface *s)
{
	wl_surface_commit(s);
}

void
abw_surface_destroy(struct wl_surface *s)
{
	wl_surface_destroy(s);
}

void
abw_xdg_wm_base_pong(struct xdg_wm_base *b, uint32_t serial)
{
	xdg_wm_base_pong(b, serial);
}

struct xdg_surface *
abw_xdg_wm_base_get_xdg_surface(struct xdg_wm_base *b, struct wl_surface *s)
{
	return (xdg_wm_base_get_xdg_surface(b, s));
}

struct xdg_toplevel *
abw_xdg_surface_get_toplevel(struct xdg_surface *s)
{
	return (xdg_surface_get_toplevel(s));
}

void
abw_xdg_surface_ack_configure(struct xdg_surface *s, uint32_t serial)
{
	xdg_surface_ack_configure(s, serial);
}

void
abw_xdg_surface_destroy(struct xdg_surface *s)
{
	xdg_surface_destroy(s);
}

void
abw_xdg_toplevel_set_title(struct xdg_toplevel *t, const char *title)
{
	xdg_toplevel_set_title(t, title);
}

void
abw_xdg_toplevel_set_app_id(struct xdg_toplevel *t, const char *app_id)
{
	xdg_toplevel_set_app_id(t, app_id);
}

void
abw_xdg_toplevel_destroy(struct xdg_toplevel *t)
{
	xdg_toplevel_destroy(t);
}

/* The interface tables, whose addresses Rust passes to bind. */
const struct wl_interface *const abw_compositor_iface = &wl_compositor_interface;
const struct wl_interface *const abw_shm_iface = &wl_shm_interface;
const struct wl_interface *const abw_xdg_wm_base_iface = &xdg_wm_base_interface;
