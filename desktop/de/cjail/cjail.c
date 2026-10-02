/* CJail — see include/cjail.h. */
#include "cjail.h"

#include <errno.h>
#include <string.h>

#ifdef __FreeBSD__
#include <sys/param.h>
#include <sys/event.h>
#include <sys/jail.h>
#include <sys/procdesc.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/ucred.h>
#include <sys/uio.h>
#include <fcntl.h>
#include <grp.h>
#include <jail.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern char **environ;

int ap_jail_create(const char *const *keys, const char *const *values, int n,
                   int *owning_desc, char *err, size_t errlen) {
    if (n <= 0 || n > 32) { errno = EINVAL; return -1; }
    struct jailparam jp[32];
    struct iovec iov[2 * 32 + 4];
    char kmsg[256] = "";
    int ni = 0, made = 0, jid = -1;
    if (err && errlen) err[0] = '\0';
    for (int i = 0; i < n; i++) {
        if (jailparam_init(&jp[i], keys[i]) < 0) {
            if (err) snprintf(err, errlen, "%s: %s", keys[i], jail_errmsg);
            goto out;
        }
        made = i + 1;
        if (jailparam_import(&jp[i], values[i]) < 0) {
            if (err) snprintf(err, errlen, "%s: %s", keys[i], jail_errmsg);
            goto out;
        }
        /*
         * As jailparam_set(3) sends them, not as jailparam_import leaves
         * them: a string's jp_valuelen is the parameter's MAXIMUM (256 for
         * name, 1024 for path) while jp_value is a strdup of the string, so
         * sending jp_valuelen read past the copy and handed the kernel heap
         * garbage — EINVAL whenever the byte at the end was not zero, which
         * depended on what the daemon had allocated before (HANDOFF §2.122).
         * A boolean is its name alone.
         */
        iov[ni].iov_base = jp[i].jp_name; iov[ni++].iov_len = strlen(jp[i].jp_name) + 1;
        if (jp[i].jp_flags & (JP_BOOL | JP_NOBOOL)) {
            iov[ni].iov_base = NULL; iov[ni++].iov_len = 0;
        } else if ((jp[i].jp_ctltype & CTLTYPE) == CTLTYPE_STRING) {
            iov[ni].iov_base = jp[i].jp_value; iov[ni++].iov_len = strlen(jp[i].jp_value) + 1;
        } else {
            iov[ni].iov_base = jp[i].jp_value; iov[ni++].iov_len = jp[i].jp_valuelen;
        }
    }
    *owning_desc = -1;
    iov[ni].iov_base = (void *)"desc"; iov[ni++].iov_len = sizeof "desc";
    iov[ni].iov_base = owning_desc; iov[ni++].iov_len = sizeof *owning_desc;
    /* The kernel says why it refused, here, when it can (vfs_opterror). */
    iov[ni].iov_base = (void *)"errmsg"; iov[ni++].iov_len = sizeof "errmsg";
    iov[ni].iov_base = kmsg; iov[ni++].iov_len = sizeof kmsg;
    jid = jail_set(iov, ni, JAIL_CREATE | JAIL_OWN_DESC);
    if (jid < 0 && err)
        snprintf(err, errlen, "jail_set: %s%s%s", strerror(errno), kmsg[0] ? ": " : "", kmsg);
out:
    jailparam_free(jp, made);
    return jid;
}

int ap_jail_desc_by_name(const char *name) {
    int desc = -1;
    struct iovec iov[4];
    iov[0].iov_base = (void *)"name"; iov[0].iov_len = sizeof "name";
    iov[1].iov_base = (void *)name; iov[1].iov_len = strlen(name) + 1;
    iov[2].iov_base = (void *)"desc"; iov[2].iov_len = sizeof "desc";
    iov[3].iov_base = &desc; iov[3].iov_len = sizeof desc;
    if (jail_get(iov, 4, JAIL_GET_DESC) < 0) return -1;
    return desc;
}

int ap_jail_identify(int desc, int *jid, char *name, size_t namelen) {
    struct iovec iov[6];
    iov[0].iov_base = (void *)"desc"; iov[0].iov_len = sizeof "desc";
    iov[1].iov_base = &desc; iov[1].iov_len = sizeof desc;
    iov[2].iov_base = (void *)"jid"; iov[2].iov_len = sizeof "jid";
    iov[3].iov_base = jid; iov[3].iov_len = sizeof *jid;
    iov[4].iov_base = (void *)"name"; iov[4].iov_len = sizeof "name";
    iov[5].iov_base = name; iov[5].iov_len = namelen;
    return jail_get(iov, 6, JAIL_USE_DESC) < 0 ? -1 : 0;
}

int ap_kqueue(void) { return kqueuex(KQUEUE_CLOEXEC); }

int ap_jail_watch(int kq, int desc) {
    struct kevent ev;
    EV_SET(&ev, desc, EVFILT_JAILDESC, EV_ADD | EV_CLEAR, NOTE_JAIL_REMOVE, 0, NULL);
    return kevent(kq, &ev, 1, NULL, 0, NULL);
}

int ap_jail_removed(int kq) {
    struct timespec zero = { 0, 0 };
    struct kevent got;
    for (;;) {
        int r = kevent(kq, NULL, 0, &got, 1, &zero);
        if (r <= 0) return -1;
        if (got.filter == EVFILT_JAILDESC && (got.fflags & NOTE_JAIL_REMOVE)) return (int)got.ident;
    }
}

int ap_jail_spawn(int desc, unsigned uid, unsigned gid,
                  const char *const *argv, const char *const *envp, const char *cwd,
                  int in, int out, int err, int daemon, int *procfd) {
    if (uid == 0 || argv == NULL || argv[0] == NULL) { errno = EPERM; return -1; }
    int pfd = -1;
    pid_t pid = pdfork(&pfd, PD_CLOEXEC | (daemon ? PD_DAEMON : 0));
    if (pid < 0) return -1;
    if (pid > 0) { *procfd = pfd; return pid; }

    /* The child: only async-signal-safe calls, then exec. */
    int null = open("/dev/null", O_RDWR);
    int fds[3] = { in >= 0 ? in : null, out >= 0 ? out : null, err >= 0 ? err : null };
    /* Lift the three above 2 first, so dup2 never overwrites one it needs. */
    for (int i = 0; i < 3; i++) if (fds[i] >= 0 && fds[i] < 3) fds[i] = fcntl(fds[i], F_DUPFD, 3);
    if (jail_attach_jd(desc) < 0) _exit(126);
    setsid();
    gid_t g = (gid_t)gid;
    if (setgroups(1, &g) < 0 || setgid(g) < 0 || setuid((uid_t)uid) < 0) _exit(126);
    if (getuid() != (uid_t)uid || geteuid() != (uid_t)uid || setuid(0) == 0) _exit(126);
    for (int i = 0; i < 3; i++) if (fds[i] >= 0) dup2(fds[i], i);
    closefrom(3);
    umask(022);
    if (chdir(cwd && cwd[0] ? cwd : "/") < 0 && chdir("/") < 0) _exit(126);
    environ = (char **)envp;
    execvp(argv[0], (char *const *)argv);
    _exit(127);
}

long ap_mount_points(char *buf, size_t len) {
    struct statfs *m;
    int n = getmntinfo(&m, MNT_NOWAIT);
    if (n <= 0) return -1;
    size_t used = 0;
    for (int i = 0; i < n; i++) {
        size_t l = strlen(m[i].f_mntonname) + 1;
        if (used + l > len) { errno = ERANGE; return -1; }
        memcpy(buf + used, m[i].f_mntonname, l);
        used += l;
    }
    return (long)used;
}

int ap_procdesc_exited(int procfd) {
    struct pollfd p = { procfd, POLLHUP, 0 };
    return poll(&p, 1, 0) > 0 && (p.revents & POLLHUP) ? 1 : 0;
}

int ap_procdesc_wait(int procfd) {
    int kq = kqueuex(KQUEUE_CLOEXEC);
    if (kq < 0) return -1;
    struct kevent ev, got;
    EV_SET(&ev, procfd, EVFILT_PROCDESC, EV_ADD, NOTE_EXIT, 0, NULL);
    int r;
    do { r = kevent(kq, &ev, 1, &got, 1, NULL); } while (r < 0 && errno == EINTR);
    close(kq);
    if (r <= 0) return -1;
    return (int)got.data;
}

#else /* not FreeBSD: no jails */

int ap_jail_create(const char *const *keys, const char *const *values, int n,
                   int *owning_desc, char *err, size_t errlen) {
    (void)keys; (void)values; (void)n; (void)owning_desc;
    if (err && errlen) strncpy(err, "this platform has no jails", errlen - 1);
    errno = ENOSYS; return -1;
}
int ap_jail_desc_by_name(const char *name) { (void)name; errno = ENOSYS; return -1; }
int ap_jail_identify(int desc, int *jid, char *name, size_t namelen) {
    (void)desc; (void)jid; (void)name; (void)namelen; errno = ENOSYS; return -1;
}
int ap_kqueue(void) { errno = ENOSYS; return -1; }
int ap_jail_watch(int kq, int desc) { (void)kq; (void)desc; errno = ENOSYS; return -1; }
int ap_jail_removed(int kq) { (void)kq; return -1; }
int ap_jail_spawn(int desc, unsigned uid, unsigned gid,
                  const char *const *argv, const char *const *envp, const char *cwd,
                  int in, int out, int err, int daemon, int *procfd) {
    (void)desc; (void)daemon; (void)uid; (void)gid; (void)argv; (void)envp; (void)cwd;
    (void)in; (void)out; (void)err; (void)procfd;
    errno = ENOSYS; return -1;
}
int ap_procdesc_exited(int procfd) { (void)procfd; return 0; }
long ap_mount_points(char *buf, size_t len) { (void)buf; (void)len; errno = ENOSYS; return -1; }
int ap_procdesc_wait(int procfd) { (void)procfd; errno = ENOSYS; return -1; }

#endif
