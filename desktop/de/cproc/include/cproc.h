/*
 * CProc — process supervision primitives, portable behind one idea:
 * **every child is a pollable file descriptor**.
 *
 * That idea is the sibling `anchor`'s, and it is what makes a supervisor a
 * plain event loop instead of a tangle of SIGCHLD handlers and waitpid races:
 * the descriptor *is* the handle, it goes in the same poll() set as the control
 * socket, and it becomes ready exactly when the child dies.
 *
 *   FreeBSD: pdfork(2) — the process descriptor is the child's handle; it polls
 *            POLLHUP on exit and closing it reaps.
 *   Linux:   fork(2) + pidfd_open(2) — the pidfd polls POLLIN on exit; the pid
 *            is still needed for kill/waitpid.
 *
 * This lives in C because the two mechanisms differ, because a post-fork child
 * may only call async-signal-safe functions (so argv/envp must be built before
 * the fork — the same discipline as HANDOFF §2.25's launcher), and because
 * signal handling needs a handler function, which Swift should not be writing.
 */
#ifndef ABYSS_CPROC_H
#define ABYSS_CPROC_H

/* A supervised child. `fd` is pollable and becomes ready when the child exits;
 * On FreeBSD the descriptor is the only handle used — `pid` is there to be
 * reported, never to signal or wait on. */
typedef struct {
    int fd;
    int pid;
} ap_child;

/* Which poll(2) event means "this child exited", since the two mechanisms
 * differ (POLLHUP for a process descriptor, POLLIN for a pidfd). Callers should
 * treat any of POLLIN|POLLHUP|POLLERR as exit, but this says what to expect. */
int ap_child_exit_events(void);

/*
 * fork/pdfork + execve. `argv` and `envp` are NULL-terminated; argv[0] must be
 * an absolute path (no PATH search happens here — resolve before calling, so
 * the child does nothing that can allocate). If `stdout_fd` >= 0 the child's
 * stdout and stderr are dup2'd onto it.
 *
 * Returns 0 with *out filled in, or -1 with errno set.
 */
int ap_child_spawn(const char *const *argv, const char *const *envp,
                   int stdout_fd, ap_child *out);

/* Send `sig` to the child. Returns 0, or -1 with errno set. */
int ap_child_signal(const ap_child *c, int sig);

/*
 * Reap an exited child and release its handle. Writes the exit status to
 * *status (as from waitpid; 0 means a clean exit) when `status` is non-NULL.
 * Safe to call on an already-reaped child. Returns 0, or -1 with errno set.
 */
int ap_child_reap(ap_child *c, int *status);

/*
 * Run a command to completion and return its **exit status** (as from
 * WEXITSTATUS), or -1 with errno set. Writes 1 to *signalled when the child
 * died from a signal instead of exiting, which the caller must be able to tell
 * apart from an ordinary non-zero exit.
 *
 * Deliberately separate from ap_child_spawn's supervision model: that one hands
 * back a *pollable descriptor* and cannot report an exit status on FreeBSD,
 * where pdfork's status arrives only through a kqueue NOTE_EXIT that a poll()
 * loop never collects. A caller that runs one child and waits for the answer —
 * the portal running a file picker — wants a plain fork/waitpid instead, and
 * gets the status on both platforms.
 */
int ap_run_and_wait(const char *const *argv, const char *const *envp,
                    int *signalled);

/*
 * A self-pipe carrying signal numbers: installs a handler for each of the
 * `count` signals in `sigs` that writes the signal number as one byte to a
 * pipe, and returns the readable end.
 *
 * This is how a poll() loop learns about SIGTERM/SIGINT without a signal
 * handler touching anything it must not: the handler's whole body is one
 * write(2), which is async-signal-safe.
 *
 * Returns the read fd, or -1 with errno set.
 */
int ap_signal_pipe(const int *sigs, int count);

#endif /* ABYSS_CPROC_H */
