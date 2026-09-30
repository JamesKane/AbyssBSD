/* See cplatform.h. /proc/self/exe on Linux, KERN_PROC_PATHNAME on FreeBSD,
 * plus SCM_RIGHTS fd passing (cmsg is all macros, so Swift can't do it). */
#if defined(__linux__) && !defined(_GNU_SOURCE)
/* struct ucred (SO_PEERCRED) is behind _GNU_SOURCE, and this has to come before
 * any header is included or the declaration is simply absent. */
#define _GNU_SOURCE
#endif
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/uio.h>          /* struct iovec — pulled in by socket.h on Linux,
                                 not guaranteed elsewhere */
#include "cplatform.h"

#if defined(__linux__)

int ap_self_executable(char *buf, size_t len) {
    if (buf == NULL || len == 0) return -1;
    ssize_t n = readlink("/proc/self/exe", buf, len - 1);
    if (n <= 0) return -1;
    buf[n] = '\0';
    return (int)n;
}

#elif defined(__FreeBSD__)

#include <sys/types.h>
#include <sys/sysctl.h>

int ap_self_executable(char *buf, size_t len) {
    if (buf == NULL || len == 0) return -1;
    /* -1 means "the current process". procfs is not mounted by default on
     * FreeBSD, so this sysctl — not /proc/curproc/file — is the portable
     * answer. */
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
    size_t sz = len;
    if (sysctl(mib, 4, buf, &sz, NULL, 0) != 0) return -1;
    if (sz == 0 || sz > len) return -1;
    buf[sz < len ? sz : len - 1] = '\0';   /* sysctl includes the NUL; be sure */
    size_t n = 0;
    while (n < len && buf[n] != '\0') n++;
    return n > 0 ? (int)n : -1;
}

#else
#error "CPlatform: unsupported platform (need /proc/self/exe or KERN_PROC_PATHNAME)"
#endif

/* --- sockets ---------------------------------------------------------- */
/* Portable across Linux and FreeBSD: cmsg is POSIX, and both have MSG_NOSIGNAL
 * (FreeBSD additionally has SO_NOSIGPIPE, set via ap_socket_nosigpipe). Every
 * send here passes it, so a peer that has gone away yields EPIPE rather than
 * killing the process — see ap_send_all's comment for why that matters. */
#ifdef MSG_NOSIGNAL
#define AP_NOSIGNAL MSG_NOSIGNAL
#else
#define AP_NOSIGNAL 0
#endif

long ap_sendmsg_fds(int sock, const void *buf, size_t len, const int *fds, int nfds) {
    if (buf == NULL || len == 0 || nfds < 0 || nfds > AP_MAX_FDS) {
        errno = EINVAL;
        return -1;
    }
    struct iovec iov;
    iov.iov_base = (void *)buf;
    iov.iov_len = len;

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    /* Sized for the cap, not for nfds, so the buffer is a plain local. */
    union {
        struct cmsghdr align;
        char buf[CMSG_SPACE(sizeof(int) * AP_MAX_FDS)];
    } control;

    if (nfds > 0) {
        memset(&control, 0, sizeof(control));
        msg.msg_control = control.buf;
        msg.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)nfds);
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)nfds);
        memcpy(CMSG_DATA(c), fds, sizeof(int) * (size_t)nfds);
    }

    ssize_t n;
    do {
        n = sendmsg(sock, &msg, AP_NOSIGNAL);
    } while (n < 0 && errno == EINTR);
    return (long)n;
}

int ap_send_all(int sock, const void *buf, size_t len) {
    if (buf == NULL) {
        errno = EINVAL;
        return -1;
    }
    const char *p = (const char *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(sock, p + off, len - off, AP_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) {
            errno = EPIPE;
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

int ap_socket_nosigpipe(int sock) {
#ifdef SO_NOSIGPIPE
    int on = 1;
    return setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#else
    (void)sock;
    return 0;       /* Linux has no SO_NOSIGPIPE; MSG_NOSIGNAL covers it */
#endif
}

long ap_recvmsg_fds(int sock, void *buf, size_t len, int *fds, int max_fds, int *nfds_out) {
    if (nfds_out != NULL) *nfds_out = 0;
    if (buf == NULL || len == 0 || fds == NULL || max_fds < 0 || max_fds > AP_MAX_FDS) {
        errno = EINVAL;
        return -1;
    }
    struct iovec iov;
    iov.iov_base = buf;
    iov.iov_len = len;

    union {
        struct cmsghdr align;
        char buf[CMSG_SPACE(sizeof(int) * AP_MAX_FDS)];
    } control;
    memset(&control, 0, sizeof(control));

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.buf;
    msg.msg_controllen = sizeof(control.buf);

    ssize_t n;
    do {
        n = recvmsg(sock, &msg, 0);
    } while (n < 0 && errno == EINTR);
    if (n < 0) return -1;

    int got = 0;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c != NULL; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
        size_t payload = c->cmsg_len - CMSG_LEN(0);
        int count = (int)(payload / sizeof(int));
        for (int i = 0; i < count; i++) {
            int fd;
            memcpy(&fd, CMSG_DATA(c) + i * sizeof(int), sizeof(int));
            if (got < max_fds) {
                fds[got++] = fd;
            } else {
                /* Never leak a descriptor we refuse to hand back. */
                close(fd);
            }
        }
    }
    if (nfds_out != NULL) *nfds_out = got;
    return (long)n;
}

/* --------------------------------------------------------------- peer uid */

#if defined(__linux__)

#include <sys/socket.h>

int ap_peer_uid(int sock, unsigned int *uid) {
    struct ucred cred;
    socklen_t len = sizeof cred;
    if (getsockopt(sock, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) return -1;
    if (len != sizeof cred) { errno = EINVAL; return -1; }
    if (uid != NULL) *uid = (unsigned int)cred.uid;
    return 0;
}

#else   /* FreeBSD, Darwin, and the other BSDs */

int ap_peer_uid(int sock, unsigned int *uid) {
    uid_t u;
    gid_t g;
    if (getpeereid(sock, &u, &g) != 0) return -1;
    if (uid != NULL) *uid = (unsigned int)u;
    return 0;
}

#endif

/* ------------------------------------------------------------- passwords */

#include <stdlib.h>
#ifdef __linux__
#include <crypt.h>
#endif

int ap_crypt_sha512(const char *password, char *out, size_t len) {
    static const char alphabet[] =
        "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    unsigned char raw[16];
    char salt[3 + 16 + 1];

    if (password == NULL || out == NULL || len == 0) return -1;
    arc4random_buf(raw, sizeof raw);
    salt[0] = '$'; salt[1] = '6'; salt[2] = '$';
    for (size_t i = 0; i < sizeof raw; i++) {
        salt[3 + i] = alphabet[raw[i] % (sizeof alphabet - 1)];
    }
    salt[3 + sizeof raw] = '\0';

    char *hash = crypt(password, salt);
    if (hash == NULL) return -1;
    size_t n = strlen(hash);
    if (n + 1 > len) return -1;
    memcpy(out, hash, n + 1);
    return 0;
}

#if defined(__FreeBSD__)
#include <sys/rtprio.h>
int ap_request_realtime(int priority) {
    struct rtprio rtp;
    rtp.type = RTP_PRIO_REALTIME;
    rtp.prio = (u_short)priority;
    return rtprio(RTP_SET, 0, &rtp);
}
#else
#include <sched.h>
int ap_request_realtime(int priority) {
    struct sched_param sp;
    memset(&sp, 0, sizeof sp);
    sp.sched_priority = sched_get_priority_max(SCHED_FIFO) - priority;
    return sched_setscheduler(0, SCHED_FIFO, &sp);
}
#endif

/* ------------------------------------------------ pseudo-terminals (P15.4a) */
#include <fcntl.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>

int ap_pty_resize(int master, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows;
    ws.ws_col = cols;
    return ioctl(master, TIOCSWINSZ, &ws);
}

int ap_pty_spawn(const char *path, char *const argv[], char *const envp[],
                 unsigned short rows, unsigned short cols, int *master_out) {
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) return -1;
    if (grantpt(master) < 0 || unlockpt(master) < 0) { int e = errno; close(master); errno = e; return -1; }
    /* The slave's name, copied now: ptsname's buffer is static, and the child
     * may not call it. */
    char slave[128];
    const char *name = ptsname(master);
    if (!name || strlen(name) >= sizeof(slave)) { close(master); errno = ENAMETOOLONG; return -1; }
    strcpy(slave, name);
    /* Its size before the program starts, so the first thing it asks is true. */
    if (ap_pty_resize(master, rows, cols) < 0) { int e = errno; close(master); errno = e; return -1; }

    pid_t pid = fork();
    if (pid < 0) { int e = errno; close(master); errno = e; return -1; }
    if (pid == 0) {
        /* The child: async-signal-safe calls only. */
        if (setsid() < 0) _exit(126);
        int s = open(slave, O_RDWR);   /* the first tty a session leader opens */
        if (s < 0) _exit(126);
#ifdef TIOCSCTTY
        (void)ioctl(s, TIOCSCTTY, 0);  /* FreeBSD needs it said; Linux took it on open */
#endif
        if (dup2(s, 0) < 0 || dup2(s, 1) < 0 || dup2(s, 2) < 0) _exit(126);
        if (s > 2) close(s);
        close(master);
        execve(path, argv, envp);
        _exit(127);
    }
    /* The parent keeps the master, private to it and never blocking. */
    int fl = fcntl(master, F_GETFD);
    if (fl >= 0) fcntl(master, F_SETFD, fl | FD_CLOEXEC);
    fl = fcntl(master, F_GETFL);
    if (fl >= 0) fcntl(master, F_SETFL, fl | O_NONBLOCK);
    *master_out = master;
    return (int)pid;
}
