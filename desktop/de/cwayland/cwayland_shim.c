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

void *aw_bind_output(void *registry, uint32_t name, uint32_t version) {
    return wl_registry_bind((struct wl_registry *)registry, name,
                            &wl_output_interface, version);
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

void *aw_xdg_wm_base_create_positioner(void *wm_base) {
    return xdg_wm_base_create_positioner((struct xdg_wm_base *)wm_base);
}

void aw_xdg_positioner_set_size(void *p, int32_t w, int32_t h) {
    xdg_positioner_set_size((struct xdg_positioner *)p, w, h);
}

void aw_xdg_positioner_set_anchor_rect(void *p, int32_t x, int32_t y,
                                       int32_t w, int32_t h) {
    xdg_positioner_set_anchor_rect((struct xdg_positioner *)p, x, y, w, h);
}

void aw_xdg_positioner_set_anchor(void *p, uint32_t anchor) {
    xdg_positioner_set_anchor((struct xdg_positioner *)p, anchor);
}

void aw_xdg_positioner_set_gravity(void *p, uint32_t gravity) {
    xdg_positioner_set_gravity((struct xdg_positioner *)p, gravity);
}

void aw_xdg_positioner_set_constraint_adjustment(void *p, uint32_t adj) {
    xdg_positioner_set_constraint_adjustment((struct xdg_positioner *)p, adj);
}

void aw_xdg_positioner_destroy(void *p) {
    xdg_positioner_destroy((struct xdg_positioner *)p);
}

void *aw_xdg_surface_get_popup(void *xdg_surface, void *parent, void *positioner) {
    return xdg_surface_get_popup((struct xdg_surface *)xdg_surface,
                                 (struct xdg_surface *)parent,
                                 (struct xdg_positioner *)positioner);
}

void *aw_xdg_surface_get_popup_no_parent(void *xdg_surface, void *positioner) {
    return xdg_surface_get_popup((struct xdg_surface *)xdg_surface, NULL,
                                 (struct xdg_positioner *)positioner);
}

void aw_xdg_popup_grab(void *popup, void *seat, uint32_t serial) {
    xdg_popup_grab((struct xdg_popup *)popup, (struct wl_seat *)seat, serial);
}

void aw_xdg_popup_destroy(void *popup) {
    xdg_popup_destroy((struct xdg_popup *)popup);
}

void *aw_bind_layer_shell(void *registry, uint32_t name, uint32_t version) {
    return wl_registry_bind((struct wl_registry *)registry, name,
                            &zwlr_layer_shell_v1_interface, version);
}

void *aw_layer_shell_get_layer_surface(void *shell, void *surface, void *output,
                                       uint32_t layer, const char *namespace) {
    return zwlr_layer_shell_v1_get_layer_surface(
        (struct zwlr_layer_shell_v1 *)shell, (struct wl_surface *)surface,
        (struct wl_output *)output, layer, namespace);
}

void aw_layer_surface_set_size(void *ls, uint32_t w, uint32_t h) {
    zwlr_layer_surface_v1_set_size((struct zwlr_layer_surface_v1 *)ls, w, h);
}

void aw_layer_surface_set_anchor(void *ls, uint32_t anchor) {
    zwlr_layer_surface_v1_set_anchor((struct zwlr_layer_surface_v1 *)ls, anchor);
}

void aw_layer_surface_set_exclusive_zone(void *ls, int32_t zone) {
    zwlr_layer_surface_v1_set_exclusive_zone((struct zwlr_layer_surface_v1 *)ls, zone);
}

void aw_layer_surface_set_margin(void *ls, int32_t top, int32_t right,
                                 int32_t bottom, int32_t left) {
    zwlr_layer_surface_v1_set_margin((struct zwlr_layer_surface_v1 *)ls,
                                     top, right, bottom, left);
}

void aw_layer_surface_set_keyboard_interactivity(void *ls, uint32_t ki) {
    zwlr_layer_surface_v1_set_keyboard_interactivity(
        (struct zwlr_layer_surface_v1 *)ls, ki);
}

void aw_layer_surface_ack_configure(void *ls, uint32_t serial) {
    zwlr_layer_surface_v1_ack_configure((struct zwlr_layer_surface_v1 *)ls, serial);
}

void aw_layer_surface_destroy(void *ls) {
    zwlr_layer_surface_v1_destroy((struct zwlr_layer_surface_v1 *)ls);
}

void aw_layer_surface_get_popup(void *ls, void *xdg_popup) {
    zwlr_layer_surface_v1_get_popup((struct zwlr_layer_surface_v1 *)ls,
                                    (struct xdg_popup *)xdg_popup);
}

void *aw_bind_foreign_toplevel_manager(void *registry, uint32_t name, uint32_t version) {
    return wl_registry_bind((struct wl_registry *)registry, name,
                            &zwlr_foreign_toplevel_manager_v1_interface, version);
}

void aw_foreign_toplevel_handle_activate(void *handle, void *seat) {
    zwlr_foreign_toplevel_handle_v1_activate(
        (struct zwlr_foreign_toplevel_handle_v1 *)handle, (struct wl_seat *)seat);
}

void aw_foreign_toplevel_handle_close(void *handle) {
    zwlr_foreign_toplevel_handle_v1_close(
        (struct zwlr_foreign_toplevel_handle_v1 *)handle);
}

void aw_foreign_toplevel_handle_destroy(void *handle) {
    zwlr_foreign_toplevel_handle_v1_destroy(
        (struct zwlr_foreign_toplevel_handle_v1 *)handle);
}

void *aw_bind_xdg_activation(void *registry, uint32_t name, uint32_t version) {
    return wl_registry_bind((struct wl_registry *)registry, name,
                            &xdg_activation_v1_interface, version);
}

void *aw_xdg_activation_get_token(void *activation) {
    return xdg_activation_v1_get_activation_token(
        (struct xdg_activation_v1 *)activation);
}

void aw_xdg_activation_token_set_serial(void *token, uint32_t serial, void *seat) {
    xdg_activation_token_v1_set_serial((struct xdg_activation_token_v1 *)token,
                                       serial, (struct wl_seat *)seat);
}

void aw_xdg_activation_token_set_surface(void *token, void *surface) {
    xdg_activation_token_v1_set_surface((struct xdg_activation_token_v1 *)token,
                                        (struct wl_surface *)surface);
}

void aw_xdg_activation_token_commit(void *token) {
    xdg_activation_token_v1_commit((struct xdg_activation_token_v1 *)token);
}

void aw_xdg_activation_token_destroy(void *token) {
    xdg_activation_token_v1_destroy((struct xdg_activation_token_v1 *)token);
}

void aw_xdg_activation_activate(void *activation, const char *token, void *surface) {
    xdg_activation_v1_activate((struct xdg_activation_v1 *)activation, token,
                               (struct wl_surface *)surface);
}

void *aw_seat_get_pointer(void *seat) {
    return wl_seat_get_pointer((struct wl_seat *)seat);
}

void *aw_seat_get_keyboard(void *seat) {
    return wl_seat_get_keyboard((struct wl_seat *)seat);
}
