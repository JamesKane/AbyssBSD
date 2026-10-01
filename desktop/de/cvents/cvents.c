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


/* ---- sound (PHASE14 P14.6) ------------------------------------------ */

#include <stdio.h>
#include <stdarg.h>
#include <string.h>

/* Append to a bounded buffer; the total is kept even past the end, so a
 * caller can see it was cut. */
static void sb_add(char *buf, size_t len, size_t *at, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(*at < len ? buf + *at : NULL, *at < len ? len - *at : 0, fmt, ap);
    va_end(ap);
    if (n > 0) *at += (size_t)n;
}

/* Tabs and newlines inside a kernel string would break the line format. */
static void sb_clean(char *dst, size_t n, const char *src) {
    size_t i = 0;
    for (; src != NULL && src[i] != '\0' && i + 1 < n; i++)
        dst[i] = (src[i] == '\t' || src[i] == '\n') ? ' ' : src[i];
    dst[i] = '\0';
}

#if defined(__FreeBSD__)
#include <stdlib.h>
#include <sys/nv.h>
#include <sys/sndstat.h>
#include <mixer.h>

long av_sndstat_read(char *buf, size_t len) {
    if (buf == NULL || len == 0) { errno = EINVAL; return -1; }
    buf[0] = '\0';
    int fd = open("/dev/sndstat", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    struct sndstioc_nv_arg arg = { .nbytes = 0, .buf = NULL };
    long out = -1;
    nvlist_t *nvl = NULL;
    if (ioctl(fd, SNDSTIOC_REFRESH_DEVS, NULL) < 0) goto done;
    if (ioctl(fd, SNDSTIOC_GET_DEVS, &arg) < 0) goto done;
    arg.buf = malloc(arg.nbytes);
    if (arg.buf == NULL) goto done;
    if (ioctl(fd, SNDSTIOC_GET_DEVS, &arg) < 0) goto done;
    nvl = nvlist_unpack(arg.buf, arg.nbytes, 0);
    if (nvl == NULL) { errno = EIO; goto done; }
    size_t at = 0;
    if (nvlist_exists_nvlist_array(nvl, SNDST_DSPS)) {
        size_t nd;
        const nvlist_t * const *d = nvlist_get_nvlist_array(nvl, SNDST_DSPS, &nd);
        for (size_t i = 0; i < nd; i++) {
            char nameunit[64], desc[256], devnode[64];
            sb_clean(nameunit, sizeof nameunit, nvlist_get_string(d[i], SNDST_DSPS_NAMEUNIT));
            sb_clean(desc, sizeof desc, nvlist_get_string(d[i], SNDST_DSPS_DESC));
            sb_clean(devnode, sizeof devnode, nvlist_get_string(d[i], SNDST_DSPS_DEVNODE));
            int unit = -1;
            const nvlist_t *pi = NULL;
            if (nvlist_exists_nvlist(d[i], SNDST_DSPS_PROVIDER_INFO)) {
                pi = nvlist_get_nvlist(d[i], SNDST_DSPS_PROVIDER_INFO);
                if (nvlist_exists_number(pi, SNDST_DSPS_SOUND4_UNIT))
                    unit = (int)nvlist_get_number(pi, SNDST_DSPS_SOUND4_UNIT);
            }
            int play = nvlist_exists_number(d[i], SNDST_DSPS_PCHAN) && nvlist_get_number(d[i], SNDST_DSPS_PCHAN) > 0;
            int rec = nvlist_exists_number(d[i], SNDST_DSPS_RCHAN) && nvlist_get_number(d[i], SNDST_DSPS_RCHAN) > 0;
            int user = nvlist_exists_bool(d[i], SNDST_DSPS_FROM_USER) && nvlist_get_bool(d[i], SNDST_DSPS_FROM_USER);
            sb_add(buf, len, &at, "dev\t%d\t%s\t%s\t%s\t%d\t%d\t%d\n", unit, nameunit, desc, devnode, play, rec, user);
            if (pi == NULL || !nvlist_exists_nvlist_array(pi, SNDST_DSPS_SOUND4_CHAN_INFO)) continue;
            size_t nc;
            const nvlist_t * const *c = nvlist_get_nvlist_array(pi, SNDST_DSPS_SOUND4_CHAN_INFO, &nc);
            for (size_t k = 0; k < nc; k++) {
                char cname[64], comm[64];
                sb_clean(cname, sizeof cname, nvlist_get_string(c[k], SNDST_DSPS_SOUND4_CHAN_NAME));
                sb_clean(comm, sizeof comm, nvlist_get_string(c[k], SNDST_DSPS_SOUND4_CHAN_COMM));
                sb_add(buf, len, &at, "chan\t%d\t%s\t%d\t%s\t%d\t%d\n", unit, cname,
                       (int)nvlist_get_number(c[k], SNDST_DSPS_SOUND4_CHAN_PID), comm,
                       (int)nvlist_get_number(c[k], SNDST_DSPS_SOUND4_CHAN_LEFTVOL),
                       (int)nvlist_get_number(c[k], SNDST_DSPS_SOUND4_CHAN_RIGHTVOL));
            }
        }
    }
    out = (long)(at < len ? at : len - 1);
done:
    if (nvl != NULL) nvlist_destroy(nvl);
    free(arg.buf);
    close(fd);
    return out;
}

static struct mixer *open_unit(int unit) {
    char path[32];
    snprintf(path, sizeof path, "/dev/mixer%d", unit);
    return mixer_open(path);
}

long av_mixer_describe(int unit, char *buf, size_t len) {
    if (buf == NULL || len == 0) { errno = EINVAL; return -1; }
    buf[0] = '\0';
    struct mixer *m = open_unit(unit);
    if (m == NULL) return -1;
    size_t at = 0;
    struct mix_dev *dp;
    TAILQ_FOREACH(dp, &m->devs, devs) {
        sb_add(buf, len, &at, "ctl\t%s\t%d\t%d\t%d\t%d\n", dp->name,
               MIX_VOLDENORM(dp->vol.left), MIX_VOLDENORM(dp->vol.right),
               MIX_ISMUTE(m, dp->devno), MIX_ISREC(m, dp->devno));
    }
    mixer_close(m);
    return (long)(at < len ? at : len - 1);
}

int av_mixer_set(int unit, const char *control, int left, int right) {
    struct mixer *m = open_unit(unit);
    if (m == NULL) return -1;
    int r = -1;
    /* libmixer acts on the *selected* control (m->dev), and looking one up
     * by name does not select it: without this, every set lands on `vol`. */
    struct mix_dev *d = mixer_get_dev_byname(m, control);
    if (d == NULL) { errno = ENOENT; goto out; }
    m->dev = d;
    mix_volume_t v = { .left = MIX_VOLNORM(left < 0 ? 0 : left > 100 ? 100 : left),
                       .right = MIX_VOLNORM(right < 0 ? 0 : right > 100 ? 100 : right) };
    r = mixer_set_vol(m, v);
out:
    mixer_close(m);
    return r;
}

int av_mixer_mute(int unit, const char *control, int muted) {
    struct mixer *m = open_unit(unit);
    if (m == NULL) return -1;
    int r = -1;
    /* libmixer acts on the *selected* control (m->dev), and looking one up
     * by name does not select it: without this, every set lands on `vol`. */
    struct mix_dev *d = mixer_get_dev_byname(m, control);
    if (d == NULL) { errno = ENOENT; goto out; }
    m->dev = d;
    r = mixer_set_mute(m, muted ? MIX_MUTE : MIX_UNMUTE);
out:
    mixer_close(m);
    return r;
}

#else   /* no OSS here: the machine has no sound this bridge can see */

long av_sndstat_read(char *buf, size_t len) {
    if (buf != NULL && len > 0) buf[0] = '\0';
    errno = ENOSYS;
    return -1;
}
long av_mixer_describe(int unit, char *buf, size_t len) {
    (void)unit;
    if (buf != NULL && len > 0) buf[0] = '\0';
    errno = ENOSYS;
    return -1;
}
int av_mixer_set(int unit, const char *control, int left, int right) {
    (void)unit; (void)control; (void)left; (void)right;
    errno = ENOSYS;
    return -1;
}
int av_mixer_mute(int unit, const char *control, int muted) {
    (void)unit; (void)control; (void)muted;
    errno = ENOSYS;
    return -1;
}

#endif

/* ------------------------------------------------------------ processes (P15.7) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dirent.h>

#if defined(__FreeBSD__)
#include <sys/param.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <sys/proc.h>

int av_proc_list(struct av_proc *out, int max) {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_PROC };
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) < 0) return -1;
    len += len / 4 + 16 * sizeof(struct kinfo_proc);   /* it grows while we ask */
    struct kinfo_proc *kp = malloc(len);
    if (!kp) return -1;
    if (sysctl(mib, 3, kp, &len, NULL, 0) < 0) { int e = errno; free(kp); errno = e; return -1; }
    int n = (int)(len / sizeof(struct kinfo_proc));
    long page = sysconf(_SC_PAGESIZE);
    int count = 0;
    for (int i = 0; i < n && count < max; i++) {
        struct kinfo_proc *k = &kp[i];
        struct av_proc *p = &out[count++];
        memset(p, 0, sizeof(*p));
        p->pid = k->ki_pid;
        p->ppid = k->ki_ppid;
        p->uid = k->ki_ruid;
        p->threads = k->ki_numthreads;
        p->rss_bytes = (uint64_t)k->ki_rssize * (uint64_t)page;
        p->vsize_bytes = (uint64_t)k->ki_size;
        p->cpu_usec = (uint64_t)k->ki_runtime;
        p->start_sec = (int64_t)k->ki_start.tv_sec;
        static const char states[] = " IRSTZWL";   /* SIDL SRUN SSLEEP SSTOP SZOMB SWAIT SLOCK */
        p->state = (k->ki_stat > 0 && k->ki_stat < (int)sizeof(states) - 1) ? states[(int)k->ki_stat] : '?';
        p->system = (k->ki_flag & P_SYSTEM) ? 1 : 0;
        strncpy(p->name, k->ki_comm, sizeof(p->name) - 1);
    }
    free(kp);
    return count;
}

int av_memory(uint64_t *total, uint64_t *available) {
    unsigned long phys = 0; size_t l = sizeof(phys);
    sysctlbyname("hw.physmem", &phys, &l, NULL, 0);
    unsigned int freep = 0, inact = 0, laund = 0; l = sizeof(freep);
    sysctlbyname("vm.stats.vm.v_free_count", &freep, &l, NULL, 0); l = sizeof(inact);
    sysctlbyname("vm.stats.vm.v_inactive_count", &inact, &l, NULL, 0); l = sizeof(laund);
    sysctlbyname("vm.stats.vm.v_laundry_count", &laund, &l, NULL, 0);
    long page = sysconf(_SC_PAGESIZE);
    *total = phys;
    /* Free and inactive pages can be had without paging anything out. */
    *available = ((uint64_t)freep + inact) * (uint64_t)page;
    (void)laund;
    return 0;
}

#elif defined(__linux__)

static int64_t linux_btime(void) {
    FILE *f = fopen("/proc/stat", "r");
    if (!f) return 0;
    char line[256]; int64_t bt = 0;
    while (fgets(line, sizeof(line), f)) { if (sscanf(line, "btime %lld", (long long *)&bt) == 1) break; }
    fclose(f);
    return bt;
}

int av_proc_list(struct av_proc *out, int max) {
    DIR *d = opendir("/proc");
    if (!d) return -1;
    long hz = sysconf(_SC_CLK_TCK), page = sysconf(_SC_PAGESIZE);
    int64_t btime = linux_btime();
    int count = 0;
    struct dirent *e;
    while ((e = readdir(d)) && count < max) {
        char *end; long pid = strtol(e->d_name, &end, 10);
        if (*end || pid <= 0) continue;
        char path[64], buf[2048];
        snprintf(path, sizeof(path), "/proc/%ld/stat", pid);
        FILE *f = fopen(path, "r");
        if (!f) continue;                         /* gone since the listing */
        size_t n = fread(buf, 1, sizeof(buf) - 1, f); fclose(f);
        buf[n] = 0;
        /* "pid (comm) state ppid …": comm may hold spaces and parentheses, so
         * it ends at the LAST ')'. */
        char *lp = strchr(buf, '('), *rp = strrchr(buf, ')');
        if (!lp || !rp || rp < lp) continue;
        struct av_proc *p = &out[count];
        memset(p, 0, sizeof(*p));
        p->pid = (int32_t)pid;
        size_t cl = (size_t)(rp - lp - 1); if (cl > sizeof(p->name) - 1) cl = sizeof(p->name) - 1;
        memcpy(p->name, lp + 1, cl);
        char state; int ppid; unsigned long flags, utime, stime, vsize; long nthr, rss; unsigned long long start;
        /* fields after comm: 3 state, 4 ppid, 5-8 skipped, 9 flags, 10-13 skipped,
         * 14 utime, 15 stime, 16-19 skipped, 20 num_threads, 21 skipped,
         * 22 starttime, 23 vsize, 24 rss */
        if (sscanf(rp + 2, "%c %d %*d %*d %*d %*d %lu %*u %*u %*u %*u %lu %lu %*d %*d %*d %*d %ld %*d %llu %lu %ld",
                   &state, &ppid, &flags, &utime, &stime, &nthr, &start, &vsize, &rss) != 9) continue;
        p->state = state;
        p->ppid = ppid;
        p->threads = (int32_t)nthr;
        p->cpu_usec = (uint64_t)(utime + stime) * 1000000ULL / (uint64_t)hz;
        p->start_sec = btime + (int64_t)(start / (unsigned long long)hz);
        p->vsize_bytes = vsize;
        p->rss_bytes = (uint64_t)(rss > 0 ? rss : 0) * (uint64_t)page;
        p->system = (flags & 0x00200000) ? 1 : 0;  /* PF_KTHREAD */
        snprintf(path, sizeof(path), "/proc/%ld/status", pid);
        if ((f = fopen(path, "r"))) {
            char line[256];
            while (fgets(line, sizeof(line), f)) {
                unsigned int ruid;
                if (sscanf(line, "Uid: %u", &ruid) == 1) { p->uid = ruid; break; }
            }
            fclose(f);
        }
        count++;
    }
    closedir(d);
    return count;
}

int av_memory(uint64_t *total, uint64_t *available) {
    *total = 0; *available = 0;
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return 0;
    char line[256]; unsigned long long v;
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "MemTotal: %llu kB", &v) == 1) *total = v * 1024ULL;
        else if (sscanf(line, "MemAvailable: %llu kB", &v) == 1) *available = v * 1024ULL;
    }
    fclose(f);
    return 0;
}

#else
int av_proc_list(struct av_proc *out, int max) { (void)out; (void)max; errno = ENOSYS; return -1; }
int av_memory(uint64_t *t, uint64_t *a) { *t = 0; *a = 0; return 0; }
#endif
