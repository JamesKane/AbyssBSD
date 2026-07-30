/*
 * CPlatform — platform facts Swift cannot reach on its own.
 *
 * Swift's imported libc module (Glibc, on FreeBSD as on Linux) does not surface
 * <sys/sysctl.h>, so `sysctl`/`sysctlbyname` are simply invisible from Swift on
 * FreeBSD — the same class of problem as libwayland's static-inline requests
 * (HANDOFF §2.1). Anything that needs them goes through a shim like this one,
 * where the #ifdef is natural.
 *
 * Currently one call: "what is my own executable?", which is how the Dock
 * launches another copy of the shell. Linux answers with /proc/self/exe;
 * FreeBSD has no procfs mounted by default and answers with the
 * KERN_PROC_PATHNAME sysctl.
 */
#ifndef ABYSS_CPLATFORM_H
#define ABYSS_CPLATFORM_H

#include <stddef.h>

/* Write the absolute path of this process's executable into `buf` (NUL
 * terminated). Returns the length written (> 0), or -1 if it cannot be
 * determined. */
int ap_self_executable(char *buf, size_t len);

/*
 * File-descriptor passing over a unix socket (SCM_RIGHTS) — the reason the
 * control plane exists: a message can hand over an shm/dmabuf handle with no
 * pixel copies.
 *
 * This lives in C because the whole cmsg(3) interface is *macros*
 * (CMSG_FIRSTHDR, CMSG_DATA, CMSG_SPACE, CMSG_LEN) and Swift's C importer
 * cannot see macros — the same wall as libwayland's static-inline requests
 * (HANDOFF §2.1).
 */

/* Longest fd array either call will carry. A control message is a handful of
 * handles, never a bulk transfer; a fixed cap keeps the cmsg buffer on the
 * stack and bounds what a peer can make us allocate. */
#define AP_MAX_FDS 16

/* sendmsg(2) `buf` (which must be non-empty — SCM_RIGHTS needs at least one
 * byte of payload to ride with) plus `nfds` descriptors. Returns the number of
 * bytes sent, or -1 with errno set. */
long ap_sendmsg_fds(int sock, const void *buf, size_t len, const int *fds, int nfds);

/* recvmsg(2) up to `len` bytes into `buf`, collecting any descriptors into
 * `fds` (at most `max_fds`, which must be <= AP_MAX_FDS) and writing how many
 * arrived to `*nfds_out`. Returns bytes received (0 = peer closed), or -1 with
 * errno set. Descriptors that arrive beyond `max_fds` are closed rather than
 * leaked. */
long ap_recvmsg_fds(int sock, void *buf, size_t len, int *fds, int max_fds, int *nfds_out);

#endif /* ABYSS_CPLATFORM_H */
