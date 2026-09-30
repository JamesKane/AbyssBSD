/*
 * CPoolWatch — a portable "config directory changed" watch for PoolConfig.
 *
 * pool's atomic writes land as a rename() into the config directory, so
 * watching the directory catches every update (no per-file registration, no
 * polling). The mechanism is platform-specific — inotify on Linux, kqueue
 * EVFILT_VNODE on FreeBSD — so it lives here in C, where the #ifdef is natural,
 * behind a tiny three-call API. The returned fd is directly pollable, so a shell
 * component can fold config-change wakeups into its own poll()/kqueue loop
 * alongside the Wayland fd.
 */
#ifndef ABYSS_CPOOLWATCH_H
#define ABYSS_CPOOLWATCH_H

/* Open a watch on directory `dir`. Returns a pollable fd (>= 0) that becomes
 * readable when a file in the directory changes, or -1 on error (errno set). */
int awc_watch_open(const char *dir);

/* Block up to `timeout_ms` (negative = forever) for a change, draining any
 * pending events. Returns 1 if the directory changed, 0 on timeout, -1 on
 * error. Pass 0 for a non-blocking drain/poll. */
int awc_watch_wait(int fd, int timeout_ms);

/* Close a watch fd (and any auxiliary state). */
void awc_watch_close(int fd);

#endif /* ABYSS_CPOOLWATCH_H */
