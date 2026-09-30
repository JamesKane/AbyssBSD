/*
 * CAllocProbe — count heap allocations made by the calling thread.
 *
 * PLAN.md's risk 4 is "Swift ARC vs. the latency contract". PHASE6.md §4.2
 * answered it with a measurement; this target is what keeps that answer true,
 * by making it a **test that runs every build** rather than a number somebody
 * once observed (PHASE6.md §7.2).
 *
 * How it works: symbol interposition. These definitions live in the executable,
 * so the dynamic linker resolves libswiftCore's allocation calls here first, and
 * we forward to the real implementation via dlsym(RTLD_NEXT).
 *
 * TWO THINGS THAT WILL BITE (both cost time on the way in — HANDOFF §2.37):
 *
 *  1. **Swift allocates through posix_memalign, not malloc.** A probe that
 *     wraps only malloc/calloc/realloc sees almost nothing a Swift program does
 *     and reports a comfortable zero. Every allocator entry point libswiftCore
 *     imports has to be here.
 *
 *  2. **This only works in an EXECUTABLE.** Inside a .xctest bundle — a shared
 *     object loaded by a test runner — libc wins the symbol lookup and the probe
 *     is blind. That is why the allocation assertion is a bench binary driven by
 *     the harness rather than an XCTest case.
 *
 * Both failure modes are silent and both look like success, so ap_alloc_probe_works()
 * exists: no measurement here is meaningful without its positive control.
 */
#ifndef ABYSS_CALLOCPROBE_H
#define ABYSS_CALLOCPROBE_H

/* Start counting allocations on THIS thread, from zero. Per-thread so another
 * thread in the process cannot pollute the reading. */
void ap_alloc_arm(void);
void ap_alloc_disarm(void);
unsigned long ap_alloc_count(void);

/* The positive control: allocate deliberately with the probe armed and report
 * whether it was seen. Returns 1 if the probe is live, 0 if it is blind.
 * A zero-allocation result means nothing unless this returns 1. */
int ap_alloc_probe_works(void);

#endif /* ABYSS_CALLOCPROBE_H */
