/* See cproc.h. pdfork on FreeBSD, fork + pidfd_open on Linux. */
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include "cproc.h"

#if defined(__FreeBSD__)
#include <sys/procdesc.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#else
#error "CProc: unsupported platform (need pdfork or pidfd_open)"
#endif

int ap_child_exit_events(void) {
#if defined(__FreeBSD__)
    return POLLHUP;     /* a process descriptor hangs up when the process dies */
#else
    return POLLIN;      /* a pidfd becomes readable */
#endif
}

int ap_child_spawn(const char *const *argv, const char *const *envp,
                   int stdout_fd, ap_child *out) {
    if (argv == NULL || argv[0] == NULL || out == NULL) {
        errno = EINVAL;
        return -1;
    }
    out->fd = -1;
    out->pid = -1;

#if defined(__FreeBSD__)
    int pd = -1;
    pid_t pid = pdfork(&pd, PD_CLOEXEC);
    if (pid < 0) return -1;
    if (pid == 0) {
        /* CHILD — async-signal-safe calls only. Everything that could allocate
         * (argv, envp) was built by the caller before we got here. */
        if (stdout_fd >= 0) {
            dup2(stdout_fd, 1);
            dup2(stdout_fd, 2);
        }
        execve(argv[0], (char *const *)argv, (char *const *)envp);
        _exit(127);
    }
    out->fd = pd;
    out->pid = -1;      /* the descriptor is the handle; pdkill/close use it */
    return 0;
#else
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        /* CHILD — see above. */
        if (stdout_fd >= 0) {
            dup2(stdout_fd, 1);
            dup2(stdout_fd, 2);
        }
        execve(argv[0], (char *const *)argv, (char *const *)envp);
        _exit(127);
    }
    /* Safe against a fast-exiting child: we never reap implicitly, so the pid
     * is still valid (as a zombie at worst) until ap_child_reap. */
    int pidfd = (int)syscall(SYS_pidfd_open, pid, 0);
    if (pidfd < 0) {
        int e = errno;
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        errno = e;
        return -1;
    }
    (void)fcntl(pidfd, F_SETFD, FD_CLOEXEC);
    out->fd = pidfd;
    out->pid = (int)pid;
    return 0;
#endif
}

int ap_child_signal(const ap_child *c, int sig) {
    if (c == NULL || c->fd < 0) {
        errno = EINVAL;
        return -1;
    }
#if defined(__FreeBSD__)
    return pdkill(c->fd, sig);
#else
    if (c->pid <= 0) {
        errno = ESRCH;
        return -1;
    }
    return kill((pid_t)c->pid, sig);
#endif
}

int ap_child_reap(ap_child *c, int *status) {
    if (c == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (status != NULL) *status = 0;
    if (c->fd < 0) return 0;        /* already reaped — not an error */

#if defined(__FreeBSD__)
    /* Closing a process descriptor reaps the process; there is no zombie and
     * no waitpid race, which is the whole point of pdfork. The exit status is
     * only available via a kqueue NOTE_EXIT, which a poll()-based loop does not
     * collect — so report 0 and let the caller judge by behaviour. */
    close(c->fd);
    c->fd = -1;
    return 0;
#else
    int st = 0;
    pid_t r;
    do {
        r = waitpid((pid_t)c->pid, &st, 0);
    } while (r < 0 && errno == EINTR);
    close(c->fd);
    c->fd = -1;
    c->pid = -1;
    if (r < 0) return -1;
    if (status != NULL) *status = st;
    return 0;
#endif
}

int ap_run_and_wait(const char *const *argv, const char *const *envp, int *signalled) {
    if (signalled != NULL) *signalled = 0;
    if (argv == NULL || argv[0] == NULL) {
        errno = EINVAL;
        return -1;
    }
    /* Plain fork here, not pdfork: we want waitpid's status, and this child is
     * awaited immediately rather than supervised. */
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        /* CHILD — async-signal-safe only; argv/envp were built by the caller. */
        execve(argv[0], (char *const *)argv, (char *const *)envp);
        _exit(127);
    }
    int st = 0;
    pid_t r;
    do {
        r = waitpid(pid, &st, 0);
    } while (r < 0 && errno == EINTR);
    if (r < 0) return -1;
    if (WIFSIGNALED(st)) {
        if (signalled != NULL) *signalled = 1;
        return WTERMSIG(st);
    }
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/* The self-pipe. One per process is plenty; a second call replaces it. */
static int g_sig_pipe[2] = { -1, -1 };

static void ap_signal_handler(int sig) {
    /* Async-signal-safe: one write of one byte, and errno preserved so the
     * interrupted code sees what it expected. */
    int saved = errno;
    unsigned char b = (unsigned char)sig;
    ssize_t n;
    do {
        n = write(g_sig_pipe[1], &b, 1);
    } while (n < 0 && errno == EINTR);
    (void)n;
    errno = saved;
}

int ap_signal_pipe(const int *sigs, int count) {
    if (sigs == NULL || count <= 0) {
        errno = EINVAL;
        return -1;
    }
    if (g_sig_pipe[0] >= 0) {
        close(g_sig_pipe[0]);
        close(g_sig_pipe[1]);
        g_sig_pipe[0] = g_sig_pipe[1] = -1;
    }
    if (pipe(g_sig_pipe) != 0) return -1;
    for (int i = 0; i < 2; i++) {
        (void)fcntl(g_sig_pipe[i], F_SETFD, FD_CLOEXEC);
    }
    /* Non-blocking write end: if the reader ever falls that far behind, drop
     * the signal rather than block inside a handler. */
    (void)fcntl(g_sig_pipe[1], F_SETFL, O_NONBLOCK);

    for (int i = 0; i < count; i++) {
        struct sigaction sa;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESTART;
        sa.sa_handler = ap_signal_handler;
        if (sigaction(sigs[i], &sa, NULL) != 0) return -1;
    }
    return g_sig_pipe[0];
}
