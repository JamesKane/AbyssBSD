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

/* kqueue watches a vnode, not a directory's contents. The directory's own
 * NOTE_WRITE fires when an entry is added, removed or renamed — so the Pool's
 * atomic writes (a rename into place) were seen — but a file edited IN PLACE
 * (`printf > jails.ini`, most editors) changes only the file, and was missed
 * on FreeBSD while inotify saw it on Linux (HANDOFF §2.124). So every regular
 * file in the directory is watched too, and the set is rescanned whenever the
 * directory itself changes. The descriptors live as long as the watch. */
#include <dirent.h>
#include <string.h>
#include <sys/stat.h>

#define AWC_MAX 16
#define AWC_FILES 128
static struct {
    int kq; int dirfd; int nfiles; int files[AWC_FILES];
} g_watch[AWC_MAX];

static void awc_rescan(int i) {
    for (int k = 0; k < g_watch[i].nfiles; k++) close(g_watch[i].files[k]);   /* drops its kevent */
    g_watch[i].nfiles = 0;
    int d = dup(g_watch[i].dirfd);
    if (d < 0) return;
    DIR *dir = fdopendir(d);
    if (!dir) { close(d); return; }
    rewinddir(dir);
    struct dirent *e;
    while ((e = readdir(dir)) != NULL && g_watch[i].nfiles < AWC_FILES) {
        if (e->d_name[0] == '.') continue;
        int f = openat(g_watch[i].dirfd, e->d_name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW);
        if (f < 0) continue;
        struct stat st;
        if (fstat(f, &st) != 0 || !S_ISREG(st.st_mode)) { close(f); continue; }
        struct kevent kev;
        EV_SET(&kev, f, EVFILT_VNODE, EV_ADD | EV_CLEAR,
               NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB, 0, NULL);
        if (kevent(g_watch[i].kq, &kev, 1, NULL, 0, NULL) < 0) { close(f); continue; }
        g_watch[i].files[g_watch[i].nfiles++] = f;
    }
    closedir(dir);
}

int awc_watch_open(const char *dir) {
    int dirfd = open(dir, O_RDONLY | O_CLOEXEC | O_DIRECTORY);
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
        if (g_watch[i].kq == 0) {
            g_watch[i].kq = kq; g_watch[i].dirfd = dirfd; g_watch[i].nfiles = 0;
            awc_rescan(i);
            break;
        }
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
    struct kevent ev[16];
    int r = kevent(kq, NULL, 0, ev, 16, tp);
    if (r < 0) return errno == EINTR ? 0 : -1;
    if (r == 0) return 0;
    /* Drain what else is queued, and rescan if the directory changed: a file
     * that arrived is watched from now on, one that went is let go. */
    int dirchanged = 0;
    for (;;) {
        for (int k = 0; k < r; k++)
            for (int i = 0; i < AWC_MAX; i++)
                if (g_watch[i].kq == kq && (int)ev[k].ident == g_watch[i].dirfd) dirchanged = 1;
        struct timespec zero = { 0, 0 };
        r = kevent(kq, NULL, 0, ev, 16, &zero);
        if (r <= 0) break;
    }
    for (int i = 0; i < AWC_MAX; i++)
        if (g_watch[i].kq == kq && dirchanged) awc_rescan(i);
    return 1;
}

void awc_watch_close(int kq) {
    for (int i = 0; i < AWC_MAX; i++) {
        if (g_watch[i].kq == kq) {
            for (int k = 0; k < g_watch[i].nfiles; k++) close(g_watch[i].files[k]);
            close(g_watch[i].dirfd); g_watch[i].kq = 0; g_watch[i].nfiles = 0; break;
        }
    }
    if (kq >= 0) close(kq);
}

#else
#error "CPoolWatch: unsupported platform (need inotify or kqueue)"
#endif
