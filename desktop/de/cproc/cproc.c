/* See cproc.h. pdfork on FreeBSD, fork + pidfd_open on Linux. */
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <pwd.h>
#include <sys/ioctl.h>
#include <grp.h>
#include "cproc.h"

#if defined(__FreeBSD__)
#include <sys/procdesc.h>
#include <login_cap.h>
#include <sys/consio.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#include <linux/vt.h>
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

/*
 * In the child, before execve: become `pw`'s account, and start in its home.
 * Only when this process is not that account already — a test running as its
 * own user spawns "as" itself with nothing to change (PHASE16 P16.5b).
 */
static int become(const struct passwd *pw) {
    if (getuid() != pw->pw_uid || geteuid() != pw->pw_uid) {
#if defined(__FreeBSD__)
        /* Groups, resource limits, umask, the login class's environment and
         * finally the uid — login(1)'s own way, from login.conf. */
        if (setusercontext(NULL, (struct passwd *)pw, pw->pw_uid, LOGIN_SETALL) != 0) return -1;
#else
        if (initgroups(pw->pw_name, pw->pw_gid) != 0) return -1;
        if (setgid(pw->pw_gid) != 0) return -1;
        if (setuid(pw->pw_uid) != 0) return -1;
#endif
        if (getuid() != pw->pw_uid || geteuid() != pw->pw_uid) return -1;   /* never go on as root */
    }
    if (pw->pw_dir == NULL || chdir(pw->pw_dir) != 0) (void)chdir("/");
    return 0;
}

static int spawn_impl(const char *const *argv, const char *const *envp,
                      int stdout_fd, ap_child *out, const struct passwd *as) {
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
        if (as != NULL && become(as) != 0) _exit(126);
        execve(argv[0], (char *const *)argv, (char *const *)envp);
        _exit(127);
    }
    out->fd = pd;
    /* The descriptor is the handle (pdkill and close use it); the pid is kept
     * only to be reported — a log that names the process (P16.2c). */
    out->pid = (int)pid;
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
        if (as != NULL && become(as) != 0) _exit(126);
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

int ap_child_spawn(const char *const *argv, const char *const *envp,
                   int stdout_fd, ap_child *out) {
    return spawn_impl(argv, envp, stdout_fd, out, NULL);
}

int ap_child_spawn_as(const char *user, const char *const *argv, const char *const *envp,
                      int stdout_fd, ap_child *out) {
    if (user == NULL) { errno = EINVAL; return -1; }
    /* Looked up here, in the parent: after the fork the child does as little
     * as it can. getpwnam's storage is copied into the child with the rest. */
    struct passwd *pw = getpwnam(user);
    if (pw == NULL) { errno = ENOENT; return -1; }
    if (geteuid() != 0 && geteuid() != pw->pw_uid) { errno = EPERM; return -1; }
    return spawn_impl(argv, envp, stdout_fd, out, pw);
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
    /* **Closing a process descriptor does not reap the process.** A pdfork
     * child is still this process's child, and once it has exited it stays a
     * zombie until waited for: every child anchor and the login daemon ever
     * "reaped" here — each restarted lock screen, each session — was left as
     * one, until a test that asked waitpid(-1) found it (PHASE16 P16.5b,
     * HANDOFF §2.108). So: close the descriptor (which ends a child still
     * running — no PD_DAEMON), then wait for that pid. The pid is recorded
     * since P16.2c; with it, FreeBSD has an exit status too. */
    pid_t pid = (pid_t)c->pid;
    close(c->fd);
    c->fd = -1;
    c->pid = -1;
    if (pid > 0) {
        int st = 0;
        pid_t r;
        do { r = waitpid(pid, &st, 0); } while (r < 0 && errno == EINTR);
        if (r == pid && status != NULL) *status = st;
    }
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

/*
 * Bring virtual terminal `vt` (1-based, as vidcontrol -s counts) to the front
 * and wait until it is (PHASE16 P16.6b): fast user switching's one console
 * act. Root's: the console is root's to switch.
 */
int ap_vt_activate(int vt) {
#if defined(__FreeBSD__)
    int fd = open("/dev/ttyv0", O_RDWR | O_CLOEXEC);
#else
    int fd = open("/dev/tty0", O_RDWR | O_CLOEXEC);
#endif
    if (fd < 0) return -1;
    int rc = ioctl(fd, VT_ACTIVATE, vt);
    if (rc == 0) rc = ioctl(fd, VT_WAITACTIVE, vt);
    int e = errno;
    close(fd);
    errno = e;
    return rc;
}
