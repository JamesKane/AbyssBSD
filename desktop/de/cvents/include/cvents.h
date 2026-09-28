/*
 * CVents — the C floor under the FreeBSD hardware bridges.
 *
 * The desktop reads the machine through native facilities rather than the Linux
 * stack: **sysctl** (not sysfs), **OSS** (not ALSA), **devd** (not udev). Two of
 * those are unreachable from Swift and so live here:
 *
 *   - `sysctlbyname(3)` is declared in <sys/sysctl.h>, which Swift's libc module
 *     does not surface at all (HANDOFF §2.30) — the same reason
 *     `ap_self_executable` exists.
 *   - `ioctl(2)` is variadic, and Swift cannot call C variadics.
 *
 * devd needs no C: it is a unix socket carrying newline-delimited text, which
 * Swift handles directly.
 *
 * Everything here is a **read** except `av_mixer_set_volume`, which is the one
 * thing a desktop legitimately changes. Privileged writes are deliberately not
 * offered: a status item that needs root is a status item designed wrong.
 */
#ifndef ABYSS_CVENTS_H
#define ABYSS_CVENTS_H

#include <stddef.h>

/* ---- sysctl ---------------------------------------------------------- */

/*
 * Read a sysctl by name into `buf`. Returns the number of bytes written, or -1
 * with errno set (ENOENT for an unknown name).
 *
 * Pass buf=NULL/len=0 to ask only for the size — the standard two-call dance.
 */
long av_sysctl_read(const char *name, void *buf, size_t len);

/* Read a kernel-environment variable into `buf`. Returns the length written
 * (excluding the NUL) or -1. `kenv` is a different namespace from sysctl, and
 * the machine's own identity lives only there. */
long av_kenv_read(const char *name, char *buf, size_t len);

/* Is this platform able to answer sysctl queries at all? 1 on FreeBSD, 0 where
 * the bridge is a stub (Linux), so callers can hide a status item rather than
 * report a fake reading. */
int av_sysctl_supported(void);

/* ---- OSS mixer ------------------------------------------------------- */

/*
 * Open an OSS mixer (`/dev/mixer`, then `/dev/mixer0` when `path` is NULL).
 * Returns a fd >= 0, or -1 with errno set — which is the normal answer on a
 * machine with no sound card, and on Linux.
 */
int av_mixer_open(const char *path);

/*
 * Master ("vol") level. OSS packs stereo into one int: low byte left, next byte
 * right, each 0..100. Both calls return 0, or -1 with errno set.
 *
 * `av_mixer_set_volume` uses the read/write ioctl, so *level is updated with
 * what the kernel actually applied — which need not be what was asked for.
 */
int av_mixer_get_volume(int fd, int *level);
int av_mixer_set_volume(int fd, int *level);

/* ---- network status (PHASE14 P14.4) ----------------------------------- */
/*
 * Real on both platforms, not stubbed: the Network pane shows the machine's
 * state on Linux too, where the settings it writes are refused.
 *
 * Whether `ifname` has a link: 1 up, 0 down, -1 unknown (or no such
 * interface). FreeBSD: the interface's if_data link state. Linux: IFF_LOWER_UP.
 */
int av_if_link(const char *ifname);

/* The interface's hardware address into `out` (6 bytes). 0, or -1 if none. */
int av_if_mac(const char *ifname, unsigned char out[6]);

/*
 * A descriptor that becomes readable when an interface, an address or a
 * route changes: a routing socket on FreeBSD, rtnetlink on Linux. Neither needs
 * privilege to listen. Non-blocking; -1 on failure.
 */
int av_route_watch_open(void);

/* Read everything waiting; 1 if anything was, 0 if not. */
int av_route_watch_drain(int fd);

#endif /* ABYSS_CVENTS_H */
