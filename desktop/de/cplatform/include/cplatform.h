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

#endif /* ABYSS_CPLATFORM_H */
