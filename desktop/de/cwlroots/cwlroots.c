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
