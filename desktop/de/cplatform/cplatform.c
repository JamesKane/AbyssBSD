/* See cplatform.h. /proc/self/exe on Linux, KERN_PROC_PATHNAME on FreeBSD. */
#include <stddef.h>
#include <unistd.h>
#include "cplatform.h"

#if defined(__linux__)

int ap_self_executable(char *buf, size_t len) {
    if (buf == NULL || len == 0) return -1;
    ssize_t n = readlink("/proc/self/exe", buf, len - 1);
    if (n <= 0) return -1;
    buf[n] = '\0';
    return (int)n;
}

#elif defined(__FreeBSD__)

#include <sys/types.h>
#include <sys/sysctl.h>

int ap_self_executable(char *buf, size_t len) {
    if (buf == NULL || len == 0) return -1;
    /* -1 means "the current process". procfs is not mounted by default on
     * FreeBSD, so this sysctl — not /proc/curproc/file — is the portable
     * answer. */
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
    size_t sz = len;
    if (sysctl(mib, 4, buf, &sz, NULL, 0) != 0) return -1;
    if (sz == 0 || sz > len) return -1;
    buf[sz < len ? sz : len - 1] = '\0';   /* sysctl includes the NUL; be sure */
    size_t n = 0;
    while (n < len && buf[n] != '\0') n++;
    return n > 0 ? (int)n : -1;
}

#else
#error "CPlatform: unsupported platform (need /proc/self/exe or KERN_PROC_PATHNAME)"
#endif
