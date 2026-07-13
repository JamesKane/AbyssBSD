#define _GNU_SOURCE
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
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
