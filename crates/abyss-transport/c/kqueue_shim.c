/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * kqueue event-loop shim for abyss-transport.
 *
 * kqueue(2) and kevent(2) are ordinary libc functions, but EV_SET — which
 * fills a struct kevent — is a C macro, and struct kevent is a kernel
 * struct best not transcribed into Rust. This shim does the kevent work in
 * C and hands Rust a small fixed event struct. See
 * docs/design/broker-and-transport.md §2.3 and §6.
 *
 * Compiled by build.rs on FreeBSD only.
 */
#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <stdint.h>

/*
 * The EVFILT_USER ident reserved for abyss_kqueue_wake(). A kqueue keys on
 * the (ident, filter) pair, and EVFILT_USER is a different filter from the
 * EVFILT_READ/WRITE used for descriptors, so ident 0 cannot collide.
 */
#define ABYSS_WAKE_IDENT 0

#define ABYSS_MAX_EVENTS 64

/*
 * A flat readiness event handed back to Rust. The layout must match
 * `AbyssEvent` in src/freebsd/reactor.rs. `kind`: 0 readable, 1 writable,
 * 2 woken.
 */
struct abyss_event {
	int64_t ident;
	int kind;
};

int
abyss_kqueue(void)
{
	return kqueue();
}

/*
 * Add (add != 0) or remove a read/write interest for `fd`.
 * `interest`: 0 readable, 1 writable. Returns 0, or -1 with errno set.
 */
int
abyss_kqueue_ctl(int kq, int fd, int interest, int add)
{
	struct kevent kev;
	short filter = (interest == 1) ? EVFILT_WRITE : EVFILT_READ;
	unsigned short flags = add ? EV_ADD : EV_DELETE;

	EV_SET(&kev, (uintptr_t)fd, filter, flags, 0, 0, NULL);
	return kevent(kq, &kev, 1, NULL, 0, NULL);
}

/* Arm the EVFILT_USER channel that abyss_kqueue_wake() triggers. */
int
abyss_kqueue_arm_wake(int kq)
{
	struct kevent kev;

	EV_SET(&kev, ABYSS_WAKE_IDENT, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
	return kevent(kq, &kev, 1, NULL, 0, NULL);
}

/*
 * Trigger the wake channel; a blocked abyss_kqueue_wait() then returns a
 * woken event. Safe to call from any thread.
 */
int
abyss_kqueue_wake(int kq)
{
	struct kevent kev;

	EV_SET(&kev, ABYSS_WAKE_IDENT, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
	return kevent(kq, &kev, 1, NULL, 0, NULL);
}

/*
 * Wait for readiness. Blocks up to `timeout_ms` (negative blocks forever).
 * Writes up to `max` events into `out`; returns the count, or -1.
 */
int
abyss_kqueue_wait(int kq, struct abyss_event *out, int max, int timeout_ms)
{
	struct kevent evs[ABYSS_MAX_EVENTS];
	struct timespec ts;
	struct timespec *tp = NULL;

	if (max > ABYSS_MAX_EVENTS)
		max = ABYSS_MAX_EVENTS;
	if (timeout_ms >= 0) {
		ts.tv_sec = timeout_ms / 1000;
		ts.tv_nsec = (long)(timeout_ms % 1000) * 1000000L;
		tp = &ts;
	}

	int n = kevent(kq, NULL, 0, evs, max, tp);
	if (n < 0)
		return -1;

	for (int i = 0; i < n; i++) {
		out[i].ident = (int64_t)evs[i].ident;
		if (evs[i].filter == EVFILT_USER)
			out[i].kind = 2;
		else if (evs[i].filter == EVFILT_WRITE)
			out[i].kind = 1;
		else
			out[i].kind = 0;
	}
	return n;
}
