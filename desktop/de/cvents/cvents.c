/* See cvents.h. FreeBSD-native; a stub elsewhere so the shell still builds and
 * simply hides the status items it cannot feed. */
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <unistd.h>
#include "cvents.h"

#if defined(__FreeBSD__)

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/ioctl.h>
#include <sys/soundcard.h>

int av_sysctl_supported(void) { return 1; }

long av_sysctl_read(const char *name, void *buf, size_t len) {
    if (name == NULL) {
        errno = EINVAL;
        return -1;
    }
    size_t n = (buf == NULL) ? 0 : len;
    if (sysctlbyname(name, buf, &n, NULL, 0) != 0) return -1;
    return (long)n;
}

int av_mixer_open(const char *path) {
    if (path != NULL) return open(path, O_RDWR);
    int fd = open("/dev/mixer", O_RDWR);
    if (fd < 0) fd = open("/dev/mixer0", O_RDWR);
    return fd;
}

int av_mixer_get_volume(int fd, int *level) {
    if (level == NULL) {
        errno = EINVAL;
        return -1;
    }
    /* The real macros from <sys/soundcard.h>, rather than the ioctl numbers
     * spelled out in hex: C can see them, so there is no reason to hard-code. */
    return ioctl(fd, MIXER_READ(SOUND_MIXER_VOLUME), level);
}

int av_mixer_set_volume(int fd, int *level) {
    if (level == NULL) {
        errno = EINVAL;
        return -1;
    }
    return ioctl(fd, MIXER_WRITE(SOUND_MIXER_VOLUME), level);
}

#else   /* not FreeBSD — the bridges have nothing to bridge to */

int av_sysctl_supported(void) { return 0; }

long av_sysctl_read(const char *name, void *buf, size_t len) {
    (void)name; (void)buf; (void)len;
    errno = ENOSYS;
    return -1;
}

int av_mixer_open(const char *path) {
    (void)path;
    errno = ENOSYS;
    return -1;
}

int av_mixer_get_volume(int fd, int *level) {
    (void)fd; (void)level;
    errno = ENOSYS;
    return -1;
}

int av_mixer_set_volume(int fd, int *level) {
    (void)fd; (void)level;
    errno = ENOSYS;
    return -1;
}

#endif
