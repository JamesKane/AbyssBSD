/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * Process-descriptor spawn shim for freebsd-procdesc-sys.
 *
 * pdfork(2) hands the child back as a file descriptor — kqueue-monitorable,
 * and closing it terminates the child. Doing the pdfork-then-execve here in
 * C keeps the window between fork and exec to async-signal-safe calls only,
 * which is the one safe way to fork a process that may be multi-threaded:
 * no Rust code ever runs in the forked child.
 */

#include <sys/param.h>
#include <sys/jail.h>
#include <sys/procdesc.h>
#include <sys/types.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

extern char **environ;

/* The child receives its bootstrap socket at this fixed descriptor
 * number (broker-and-transport.md §5.3). */
#define ABYSS_BOOTSTRAP_FD 3

/*
 * pdfork a child that immediately execs `path` with argument vector `argv`.
 * If `bootstrap_fd` is non-negative it becomes the child's fd 3 — its
 * bootstrap socket. If `jid` is non-negative the child attaches to that
 * jail before the exec, so the component lands confined. On success
 * returns the child's pid and writes its process descriptor to *pd_out;
 * on failure returns -1 with errno set.
 */
int
abyss_pdspawn(const char *path, char *const argv[], int jid, int bootstrap_fd,
    int *pd_out)
{
	int pd = -1;
	pid_t pid = pdfork(&pd, 0);
	if (pid < 0)
		return -1;
	if (pid == 0) {
		/* Child: only async-signal-safe calls until execve. */
		if (bootstrap_fd >= 0) {
			/*
			 * Hand the child its bootstrap socket as fd 3. dup2
			 * onto a fresh descriptor clears close-on-exec; but
			 * dup2(fd, fd) is a no-op that leaves the flag set,
			 * so when the socket is already fd 3 the flag has to
			 * be cleared by hand or the exec would close it.
			 */
			if (bootstrap_fd == ABYSS_BOOTSTRAP_FD) {
				if (fcntl(bootstrap_fd, F_SETFD, 0) < 0)
					_exit(125);
			} else {
				if (dup2(bootstrap_fd, ABYSS_BOOTSTRAP_FD) < 0)
					_exit(125);
				close(bootstrap_fd);
			}
		}
		if (jid >= 0 && jail_attach(jid) < 0)
			_exit(126); /* could not enter the jail */
		execve(path, argv, environ);
		_exit(127); /* execve returns only on failure */
	}
	*pd_out = pd;
	return (int)pid;
}

/*
 * Block until the process behind descriptor `pd` exits. Returns 0 once it
 * has, or -1 with errno set. A process descriptor becomes ready in poll(2)
 * when its process changes state; for a spawned child the awaited change
 * is its exit.
 */
int
abyss_pd_wait(int pd)
{
	struct pollfd pfd;
	pfd.fd = pd;
	pfd.events = POLLIN;
	for (;;) {
		pfd.revents = 0;
		int r = poll(&pfd, 1, -1);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (pfd.revents != 0)
			return 0;
	}
}
