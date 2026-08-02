/* CAllocProbe — see include/callocprobe.h for what this is and why. */
#define _GNU_SOURCE
#include "callocprobe.h"

#include <dlfcn.h>
#include <stddef.h>
#include <stdlib.h>

/* Per-thread, so a background thread's allocations can't pollute a reading. */
static __thread int ap_armed = 0;
static __thread unsigned long ap_count = 0;

static void *(*real_malloc)(size_t);
static void *(*real_calloc)(size_t, size_t);
static void *(*real_realloc)(void *, size_t);
static int (*real_posix_memalign)(void **, size_t, size_t);
static void *(*real_aligned_alloc)(size_t, size_t);

void ap_alloc_arm(void) { ap_count = 0; ap_armed = 1; }
void ap_alloc_disarm(void) { ap_armed = 0; }
unsigned long ap_alloc_count(void) { return ap_count; }

/*
 * calloc needs care: dlsym itself may call calloc on first use, which would
 * recurse. A small static block answers any allocation that arrives while we
 * are still resolving.
 */
static char bootstrap[4096];
static size_t bootstrap_used = 0;
static int resolving = 0;

static void *bootstrap_alloc(size_t n) {
    size_t aligned = (n + 15u) & ~(size_t)15u;
    if (bootstrap_used + aligned > sizeof bootstrap) return NULL;
    void *p = bootstrap + bootstrap_used;
    bootstrap_used += aligned;
    return p;
}

void *malloc(size_t n) {
    if (!real_malloc) {
        if (resolving) return bootstrap_alloc(n);
        resolving = 1;
        real_malloc = dlsym(RTLD_NEXT, "malloc");
        resolving = 0;
        if (!real_malloc) return bootstrap_alloc(n);
    }
    if (ap_armed) ap_count++;
    return real_malloc(n);
}

void *calloc(size_t a, size_t b) {
    if (!real_calloc) {
        if (resolving) {
            void *p = bootstrap_alloc(a * b);
            if (p) for (size_t i = 0; i < a * b; i++) ((char *)p)[i] = 0;
            return p;
        }
        resolving = 1;
        real_calloc = dlsym(RTLD_NEXT, "calloc");
        resolving = 0;
        if (!real_calloc) return NULL;
    }
    if (ap_armed) ap_count++;
    return real_calloc(a, b);
}

void *realloc(void *p, size_t n) {
    if (!real_realloc) real_realloc = dlsym(RTLD_NEXT, "realloc");
    if (ap_armed) ap_count++;
    return real_realloc(p, n);
}

/* THE ONE THAT MATTERS. Swift's runtime allocates through posix_memalign;
 * wrapping only malloc makes the probe blind to nearly every Swift allocation
 * and it reports a comfortable, wrong zero. */
int posix_memalign(void **p, size_t align, size_t n) {
    if (!real_posix_memalign) real_posix_memalign = dlsym(RTLD_NEXT, "posix_memalign");
    if (ap_armed) ap_count++;
    return real_posix_memalign(p, align, n);
}

void *aligned_alloc(size_t align, size_t n) {
    if (!real_aligned_alloc) real_aligned_alloc = dlsym(RTLD_NEXT, "aligned_alloc");
    if (ap_armed) ap_count++;
    return real_aligned_alloc(align, n);
}

int ap_alloc_probe_works(void) {
    ap_alloc_arm();
    /* Both paths, because which one a given libc/runtime takes is not ours to
     * assume — that assumption is exactly what made the first probe blind. */
    void *a = malloc(64);
    void *b = NULL;
    if (posix_memalign(&b, 64, 256) != 0) b = NULL;
    unsigned long seen = ap_alloc_count();
    ap_alloc_disarm();
    free(a);
    free(b);
    return seen >= 2 ? 1 : 0;
}
