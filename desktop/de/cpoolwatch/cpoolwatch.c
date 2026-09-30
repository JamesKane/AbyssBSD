/* See cpoolwatch.h. inotify on Linux, kqueue on FreeBSD. */
#include "cpoolwatch.h"

#include <poll.h>
#include <unistd.h>
#include <errno.h>

#if defined(__linux__)

#include <sys/inotify.h>

int awc_watch_open(const char *dir) {
    int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (fd < 0) return -1;
    /* Atomic writes arrive as rename() -> IN_MOVED_TO; catch in-place edits and
     * the lock/tmp churn too so a rewrite always wakes us. */
    if (inotify_add_watch(fd, dir,
            IN_MODIFY | IN_MOVED_TO | IN_CREATE | IN_DELETE) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int awc_watch_wait(int fd, int timeout_ms) {
    struct pollfd p = { .fd = fd, .events = POLLIN, .revents = 0 };
    int r = poll(&p, 1, timeout_ms);
    if (r < 0) return errno == EINTR ? 0 : -1;
    if (r == 0) return 0;
    /* Drain all queued events; we only report "something changed". */
    char buf[4096];
    while (read(fd, buf, sizeof buf) > 0) { }
    return 1;
}

void awc_watch_close(int fd) {
    if (fd >= 0) close(fd);
}

#elif defined(__FreeBSD__)

#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <fcntl.h>

/* kqueue watches the directory *fd*, so we must keep it open for the watch's
 * life. Stash it alongside the kq fd (returned to the caller) in a small table.
 * Exercised on FreeBSD in Phase 3; the Linux path above is what CI runs today. */
#define AWC_MAX 16
static struct { int kq; int dirfd; } g_watch[AWC_MAX];

int awc_watch_open(const char *dir) {
    int dirfd = open(dir, O_RDONLY | O_CLOEXEC);
    if (dirfd < 0) return -1;
    int kq = kqueue();
    if (kq < 0) { close(dirfd); return -1; }
    struct kevent kev;
    EV_SET(&kev, dirfd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
           NOTE_WRITE | NOTE_RENAME | NOTE_DELETE | NOTE_EXTEND, 0, NULL);
    if (kevent(kq, &kev, 1, NULL, 0, NULL) < 0) {
        close(dirfd); close(kq); return -1;
    }
    for (int i = 0; i < AWC_MAX; i++) {
        if (g_watch[i].kq == 0) { g_watch[i].kq = kq; g_watch[i].dirfd = dirfd; break; }
    }
    return kq;
}

int awc_watch_wait(int kq, int timeout_ms) {
    struct timespec ts, *tp = NULL;
    if (timeout_ms >= 0) {
        ts.tv_sec = timeout_ms / 1000;
        ts.tv_nsec = (long)(timeout_ms % 1000) * 1000000L;
        tp = &ts;
    }
    struct kevent ev;
    int r = kevent(kq, NULL, 0, &ev, 1, tp);
    if (r < 0) return errno == EINTR ? 0 : -1;
    return r == 0 ? 0 : 1;
}

void awc_watch_close(int kq) {
    for (int i = 0; i < AWC_MAX; i++) {
        if (g_watch[i].kq == kq) { close(g_watch[i].dirfd); g_watch[i].kq = 0; break; }
    }
    if (kq >= 0) close(kq);
}

#else
#error "CPoolWatch: unsupported platform (need inotify or kqueue)"
#endif
