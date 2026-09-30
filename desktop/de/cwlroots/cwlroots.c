/* CWlroots — see include/cwlroots.h. One mechanism, and it is the whole file. */
#include "cwlroots.h"

#include <stdlib.h>

static void tw_trampoline(struct wl_listener *listener, void *data) {
    /* wl_container_of is a macro; this line is the entire reason C is here. */
    struct tw_listener *l = wl_container_of(listener, l, listener);
    l->fn(l->ctx, data);
}

struct tw_listener *tw_listen(struct wl_signal *signal, tw_notify_fn fn, void *ctx) {
    struct tw_listener *l = calloc(1, sizeof(*l));
    if (!l) return NULL;
    l->fn = fn;
    l->ctx = ctx;
    l->listener.notify = tw_trampoline;
    wl_signal_add(signal, &l->listener);   /* static inline: also C-only */
    return l;
}

void tw_listener_free(struct tw_listener *l) {
    if (!l) return;
    wl_list_remove(&l->listener.link);
    free(l);
}

void tw_log_silence(void) { wlr_log_init(WLR_SILENT, NULL); }
void tw_log_verbose(void) { wlr_log_init(WLR_DEBUG, NULL); }

size_t tw_output_config_heads(struct wlr_output_configuration_v1 *config,
                              struct wlr_output_configuration_head_v1 **out, size_t max) {
    size_t n = 0;
    struct wlr_output_configuration_head_v1 *h;
    wl_list_for_each(h, &config->heads, link) {
        if (n < max) out[n] = h;
        n++;
    }
    return n;
}

/* A stand-in for a hardware keyboard (BACKLOG T.2): a wlr_keyboard undertow
 * owns, with no keymap of its own — which is what libinput hands a compositor
 * on metal, and what a headless run otherwise never has. */
static const struct wlr_keyboard_impl stand_in_impl = { .name = "stand-in-keyboard" };

struct wlr_keyboard *tw_stand_in_keyboard_create(void) {
    struct wlr_keyboard *k = calloc(1, sizeof(*k));
    if (!k) return NULL;
    wlr_keyboard_init(k, &stand_in_impl, "stand-in keyboard");
    return k;
}

void tw_stand_in_keyboard_key(struct wlr_keyboard *k, uint32_t keycode, bool pressed, uint32_t time_msec) {
    struct wlr_keyboard_key_event e = {
        .time_msec = time_msec,
        .keycode = keycode,
        .update_state = true,
        .state = pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED,
    };
    wlr_keyboard_notify_key(k, &e);
}
