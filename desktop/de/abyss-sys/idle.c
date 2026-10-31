/*
 * ext-idle-notify v1 for Rust (abyss-idle, PHASE16 P16.3): the notifier and
 * a seat, bound on their own registry, and two notification slots whose
 * `idled` events set a bit for Rust to take. In C because the listener
 * tables are C's to write; the requests are the scanner's inlines.
 */
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include "ext-idle-notify-v1-client-protocol.h"

#define ABW_IDLE_SLOTS 2

struct abw_idle {
	struct wl_registry *reg;
	struct wl_seat *seat;
	struct ext_idle_notifier_v1 *notifier;
	struct ext_idle_notification_v1 *slot[ABW_IDLE_SLOTS];
	unsigned fired;
};

static void
found(void *data, struct wl_registry *reg, uint32_t name, const char *iface,
    uint32_t version)
{
	struct abw_idle *i = data;

	(void)version;
	if (i->notifier == NULL &&
	    strcmp(iface, ext_idle_notifier_v1_interface.name) == 0)
		i->notifier = wl_registry_bind(reg, name,
		    &ext_idle_notifier_v1_interface, 1);
	else if (i->seat == NULL && strcmp(iface, wl_seat_interface.name) == 0)
		i->seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
}

static void
gone(void *data, struct wl_registry *reg, uint32_t name)
{
	(void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener registry_listener = { found, gone };

static void idled0(void *d, struct ext_idle_notification_v1 *n) { (void)n; ((struct abw_idle *)d)->fired |= 1; }
static void idled1(void *d, struct ext_idle_notification_v1 *n) { (void)n; ((struct abw_idle *)d)->fired |= 2; }
static void resumed(void *d, struct ext_idle_notification_v1 *n) { (void)d; (void)n; }

static const struct ext_idle_notification_v1_listener slot_listener[ABW_IDLE_SLOTS] = {
	{ idled0, resumed }, { idled1, resumed },
};

/* NULL when the compositor offers no ext-idle-notify. */
struct abw_idle *
abw_idle_new(struct wl_display *d)
{
	struct abw_idle *i = calloc(1, sizeof *i);

	if (i == NULL)
		return (NULL);
	i->reg = wl_display_get_registry(d);
	wl_registry_add_listener(i->reg, &registry_listener, i);
	if (wl_display_roundtrip(d) < 0 || i->notifier == NULL) {
		if (i->seat != NULL)
			wl_seat_destroy(i->seat);
		wl_registry_destroy(i->reg);
		free(i);
		return (NULL);
	}
	return (i);
}

void
abw_idle_disarm(struct abw_idle *i, int slot)
{
	if (slot < 0 || slot >= ABW_IDLE_SLOTS || i->slot[slot] == NULL)
		return;
	ext_idle_notification_v1_destroy(i->slot[slot]);
	i->slot[slot] = NULL;
	i->fired &= ~(1u << slot);
}

/* Replace `slot` with a notification after `ms`; -1 with no seat to watch. */
int
abw_idle_arm(struct abw_idle *i, int slot, uint32_t ms)
{
	if (slot < 0 || slot >= ABW_IDLE_SLOTS)
		return (-1);
	abw_idle_disarm(i, slot);
	if (i->seat == NULL)
		return (-1);
	i->slot[slot] = ext_idle_notifier_v1_get_idle_notification(i->notifier,
	    ms, i->seat);
	if (i->slot[slot] == NULL)
		return (-1);
	ext_idle_notification_v1_add_listener(i->slot[slot],
	    &slot_listener[slot], i);
	return (0);
}

/* The slots that went idle since the last take, as bits. */
unsigned
abw_idle_take(struct abw_idle *i)
{
	unsigned f = i->fired;

	i->fired = 0;
	return (f);
}

void
abw_idle_free(struct abw_idle *i)
{
	for (int s = 0; s < ABW_IDLE_SLOTS; s++)
		abw_idle_disarm(i, s);
	ext_idle_notifier_v1_destroy(i->notifier);
	if (i->seat != NULL)
		wl_seat_destroy(i->seat);
	wl_registry_destroy(i->reg);
	free(i);
}
