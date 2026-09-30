/* See ccap.h. Capsicum on FreeBSD; honest stubs elsewhere. */
#include <errno.h>
#include "ccap.h"

#if defined(__FreeBSD__)

#include <sys/capsicum.h>

int ap_sandbox_supported(void) { return 1; }

int ap_sandbox_enter(void) { return cap_enter(); }

int ap_sandbox_active(void) {
    unsigned int mode = 0;
    if (cap_getmode(&mode) != 0) {
        /* ENOSYS here means the kernel was built without CAPABILITY_MODE. */
        return -1;
    }
    return mode != 0 ? 1 : 0;
}

#else

int ap_sandbox_supported(void) { return 0; }

int ap_sandbox_enter(void) {
    errno = ENOSYS;
    return -1;
}

int ap_sandbox_active(void) { return 0; }

#endif
