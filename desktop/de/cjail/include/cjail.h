/*
 * CJail — jail(2), jail descriptors and process descriptors, for abyss-jaild
 * (PHASE18 P18.2). FreeBSD only: elsewhere every call fails with ENOSYS, so
 * the library above it compiles and is tested on Linux, and the daemon says
 * in words that it cannot run there.
 */
#ifndef CJAIL_H
#define CJAIL_H

#include <stddef.h>

/*
 * Create a jail from `n` parameters given as strings (libjail converts each
 * to its type: "ip4" = "disable", "persist" = "true"), and return its jid.
 * *owning_desc receives an OWNING jail descriptor: closing every copy of it
 * removes the jail and kills what runs in it. On failure, -1 and libjail's
 * message in `err`.
 */
int ap_jail_create(const char *const *keys, const char *const *values, int n,
                   int *owning_desc, char *err, size_t errlen);

/* A NON-owning descriptor for the jail named `name`, or -1 with errno. */
int ap_jail_desc_by_name(const char *name);

/* The jid and name of the jail a descriptor refers to; 0, or -1 with errno. */
int ap_jail_identify(int desc, int *jid, char *name, size_t namelen);

/*
 * Watch a jail descriptor on kqueue `kq` for the jail's removal. ap_jail_removed
 * then returns, without blocking, one watched descriptor whose jail is gone, or
 * -1 when there is none. `kq` is pollable: readable when one is waiting.
 */
int ap_kqueue(void);
int ap_jail_watch(int kq, int desc);
int ap_jail_removed(int kq);

/*
 * Start argv in the jail `desc` as uid/gid (no supplementary groups), with
 * exactly `envp` as its environment, `cwd` as its directory, and in/out/err
 * as its 0, 1 and 2 (-1: /dev/null). argv[0] is looked up on envp's PATH,
 * inside the jail. Returns the pid; *procfd receives its process descriptor
 * (pdfork): the process is the holder's, and closing the last copy kills it —
 * unless `daemon`, when it runs on after (PD_DAEMON) and the descriptor only
 * watches it. Either way it dies with its jail.
 */
int ap_jail_spawn(int desc, unsigned uid, unsigned gid,
                  const char *const *argv, const char *const *envp, const char *cwd,
                  int in, int out, int err, int daemon, int *procfd);

/* Whether a process descriptor's process has exited (POLLHUP). */
int ap_procdesc_exited(int procfd);

/*
 * Wait for a process descriptor's process to exit and return its wait(2)
 * status (EVFILT_PROCDESC, NOTE_EXIT) — which the holder gets, parent or not.
 * -1 with errno on failure.
 */
int ap_procdesc_wait(int procfd);

#endif
