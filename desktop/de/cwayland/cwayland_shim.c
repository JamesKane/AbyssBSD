/*
 * Real wrappers around libwayland's static-inline request/listener functions,
 * so the Swift side can call them. See cwayland.h for rationale.
 */
#include "cwayland.h"

int aw_add_listener(void *proxy, const void *listener, void *data) {
    return wl_proxy_add_listener((struct wl_proxy *)proxy,
                                 (void (**)(void))listener, data);
}

void aw_proxy_destroy(void *proxy) {
    wl_proxy_destroy((struct wl_proxy *)proxy);
}

void *aw_display_get_registry(void *display) {
    return wl_display_get_registry((struct wl_display *)display);
}

void *aw_bind_compositor(void *registry, uint32_t name, uint32_t version) {
    return wl_registry_bind((struct wl_registry *)registry, name,
                            &wl_compositor_interface, version);
}

void *aw_bind_shm(void *registry, uint32_t name, uint32_t version) {
    return wl_registry_bind((struct wl_registry *)registry, name,
                            &wl_shm_interface, version);
}

void *aw_bind_seat(void *registry, uint32_t name, uint32_t version) {
    return wl_registry_bind((struct wl_registry *)registry, name,
                            &wl_seat_interface, version);
}

void *aw_bind_xdg_wm_base(void *registry, uint32_t name, uint32_t version) {
    return wl_registry_bind((struct wl_registry *)registry, name,
                            &xdg_wm_base_interface, version);
}

void *aw_compositor_create_surface(void *compositor) {
    return wl_compositor_create_surface((struct wl_compositor *)compositor);
}

void *aw_shm_create_pool(void *shm, int fd, int32_t size) {
    return wl_shm_create_pool((struct wl_shm *)shm, fd, size);
}

void *aw_shm_pool_create_buffer(void *pool, int32_t offset, int32_t width,
                                int32_t height, int32_t stride, uint32_t format) {
    return wl_shm_pool_create_buffer((struct wl_shm_pool *)pool, offset, width,
                                     height, stride, format);
}

void aw_shm_pool_destroy(void *pool) {
    wl_shm_pool_destroy((struct wl_shm_pool *)pool);
}

void aw_surface_attach(void *surface, void *buffer, int32_t x, int32_t y) {
    wl_surface_attach((struct wl_surface *)surface, (struct wl_buffer *)buffer,
                      x, y);
}

void aw_surface_damage_buffer(void *surface, int32_t x, int32_t y,
                             int32_t w, int32_t h) {
    wl_surface_damage_buffer((struct wl_surface *)surface, x, y, w, h);
}

void aw_surface_set_buffer_scale(void *surface, int32_t scale) {
    wl_surface_set_buffer_scale((struct wl_surface *)surface, scale);
}

void aw_surface_commit(void *surface) {
    wl_surface_commit((struct wl_surface *)surface);
}

void *aw_surface_frame(void *surface) {
    return wl_surface_frame((struct wl_surface *)surface);
}

void aw_buffer_destroy(void *buffer) {
    wl_buffer_destroy((struct wl_buffer *)buffer);
}

void aw_xdg_wm_base_pong(void *wm_base, uint32_t serial) {
    xdg_wm_base_pong((struct xdg_wm_base *)wm_base, serial);
}

void *aw_xdg_wm_base_get_xdg_surface(void *wm_base, void *surface) {
    return xdg_wm_base_get_xdg_surface((struct xdg_wm_base *)wm_base,
                                       (struct wl_surface *)surface);
}

void *aw_xdg_surface_get_toplevel(void *xdg_surface) {
    return xdg_surface_get_toplevel((struct xdg_surface *)xdg_surface);
}

void aw_xdg_surface_ack_configure(void *xdg_surface, uint32_t serial) {
    xdg_surface_ack_configure((struct xdg_surface *)xdg_surface, serial);
}

void aw_xdg_toplevel_set_title(void *toplevel, const char *title) {
    xdg_toplevel_set_title((struct xdg_toplevel *)toplevel, title);
}

void aw_xdg_toplevel_set_app_id(void *toplevel, const char *app_id) {
    xdg_toplevel_set_app_id((struct xdg_toplevel *)toplevel, app_id);
}

void *aw_seat_get_pointer(void *seat) {
    return wl_seat_get_pointer((struct wl_seat *)seat);
}
