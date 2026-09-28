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
#include <kenv.h>

int av_sysctl_supported(void) { return 1; }

/* The kernel environment, which is NOT the sysctl tree — and the difference is
 * the reason this exists. `smbios.system.maker` and `smbios.system.product` name
 * the machine, and `sysctl -aN | grep smbios` finds only `dev.smbios.*` device
 * nodes. Phase 12 needs the machine's identity to stop handing a Mac Pro
 * accommodation to every machine we install (PHASE4 §5.2), and this is the only
 * way to ask. */
long av_kenv_read(const char *name, char *buf, size_t len) {
    if (name == NULL || buf == NULL) {
        errno = EINVAL;
        return -1;
    }
    /* kenv(2) returns the length written, not counting the NUL, or -1. */
    int n = kenv(KENV_GET, name, buf, (int)len);
    if (n < 0) return -1;
    return (long)n;
}

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

long av_kenv_read(const char *name, char *buf, size_t len) {
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

/* ---- network status: both platforms ------------------------------------- */

#include <ifaddrs.h>
#include <net/if.h>
#include <string.h>
#include <sys/socket.h>
#if defined(__FreeBSD__)
#include <net/if_dl.h>
#include <net/route.h>
#else
#include <linux/if_packet.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#ifndef IFF_LOWER_UP
#define IFF_LOWER_UP 0x10000
#endif
#endif

int av_if_link(const char *ifname) {
    struct ifaddrs *all = NULL, *a;
    int state = -1;
    if (getifaddrs(&all) != 0) return -1;
    for (a = all; a; a = a->ifa_next) {
        if (!a->ifa_name || strcmp(a->ifa_name, ifname) != 0) continue;
#if defined(__FreeBSD__)
        if (a->ifa_addr && a->ifa_addr->sa_family == AF_LINK && a->ifa_data) {
            struct if_data *d = (struct if_data *)a->ifa_data;
            state = d->ifi_link_state == LINK_STATE_UP ? 1
                  : d->ifi_link_state == LINK_STATE_DOWN ? 0 : -1;
            break;
        }
#else
        state = (a->ifa_flags & IFF_LOWER_UP) ? 1 : 0;
        break;
#endif
    }
    freeifaddrs(all);
    return state;
}

int av_if_mac(const char *ifname, unsigned char out[6]) {
    struct ifaddrs *all = NULL, *a;
    int rc = -1;
    if (getifaddrs(&all) != 0) return -1;
    for (a = all; a; a = a->ifa_next) {
        if (!a->ifa_name || !a->ifa_addr || strcmp(a->ifa_name, ifname) != 0) continue;
#if defined(__FreeBSD__)
        if (a->ifa_addr->sa_family == AF_LINK) {
            struct sockaddr_dl *dl = (struct sockaddr_dl *)a->ifa_addr;
            if (dl->sdl_alen == 6) { memcpy(out, LLADDR(dl), 6); rc = 0; }
            break;
        }
#else
        if (a->ifa_addr->sa_family == AF_PACKET) {
            struct sockaddr_ll *ll = (struct sockaddr_ll *)a->ifa_addr;
            if (ll->sll_halen == 6) { memcpy(out, ll->sll_addr, 6); rc = 0; }
            break;
        }
#endif
    }
    freeifaddrs(all);
    return rc;
}

int av_route_watch_open(void) {
#if defined(__FreeBSD__)
    int fd = socket(PF_ROUTE, SOCK_RAW, 0);
#else
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (fd >= 0) {
        struct sockaddr_nl nl;
        memset(&nl, 0, sizeof nl);
        nl.nl_family = AF_NETLINK;
        nl.nl_groups = RTMGRP_LINK | RTMGRP_IPV4_IFADDR | RTMGRP_IPV4_ROUTE;
        if (bind(fd, (struct sockaddr *)&nl, sizeof nl) != 0) { close(fd); return -1; }
    }
#endif
    if (fd < 0) return -1;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}

int av_route_watch_drain(int fd) {
    char buf[8192];
    int any = 0;
    for (;;) {
        ssize_t n = read(fd, buf, sizeof buf);
        if (n > 0) { any = 1; continue; }
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    return any;
}
