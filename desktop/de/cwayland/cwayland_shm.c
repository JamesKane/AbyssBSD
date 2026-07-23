#define _GNU_SOURCE
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/timerfd.h>
#include "cwayland.h"

int aw_create_shm(size_t size) {
#if defined(__linux__)
    int fd = memfd_create("aqua-shm", MFD_CLOEXEC);
    if (fd < 0) return -1;
    if (ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        return -1;
    }
    return fd;
#else
    /* FreeBSD and other BSDs: anonymous POSIX shared memory. */
    int fd = shm_open(SHM_ANON, O_RDWR | O_CREAT, 0600);
    if (fd < 0) return -1;
    if (ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        return -1;
    }
    return fd;
#endif
}

int aw_create_interval_timer(unsigned int ms) {
    int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0) return -1;
    struct itimerspec its;
    its.it_interval.tv_sec = ms / 1000;
    its.it_interval.tv_nsec = (long)(ms % 1000) * 1000000L;
    its.it_value = its.it_interval;   /* first fire one interval from now */
    if (timerfd_settime(fd, 0, &its, NULL) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}
