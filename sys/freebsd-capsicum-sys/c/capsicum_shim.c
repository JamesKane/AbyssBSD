/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * Capsicum C shim for freebsd-capsicum-sys.
 *
 * FreeBSD's capability-rights API (cap_rights_init, cap_rights_set) is
 * built from C macros that cannot be called over Rust's C FFI. This shim
 * exposes the pieces the broker needs as a flat, callable C ABI. See
 * docs/design/broker-and-transport.md §3.3 and §6.
 *
 * Compiled by build.rs on FreeBSD only.
 */
#include <sys/types.h>
#include <sys/capsicum.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Object-rights flags the broker passes in; translated to a cap_rights_t
 * here. Kept in lock-step with the `Rights` constants in src/freebsd.rs.
 */
#define ABYSS_CAP_READ  (1u << 0)
#define ABYSS_CAP_WRITE (1u << 1)
#define ABYSS_CAP_MMAP  (1u << 2)
#define ABYSS_CAP_IOCTL (1u << 3)
#define ABYSS_CAP_EVENT (1u << 4)
#define ABYSS_CAP_FSTAT (1u << 5)
#define ABYSS_CAP_SEND  (1u << 6)
#define ABYSS_CAP_RECV  (1u << 7)

/* sizeof(cap_rights_t), so the Rust side can allocate the opaque struct
 * exactly rather than hard-coding a width that the kernel may version. */
size_t
abyss_cap_rights_size(void)
{
	return sizeof(cap_rights_t);
}

/*
 * Build a cap_rights_t into `out` (which must be abyss_cap_rights_size()
 * bytes) from a bitmask of ABYSS_CAP_* flags. The cap_rights_set calls are
 * the macros that force this shim to exist.
 */
void
abyss_cap_rights_build(void *out, uint64_t flags)
{
	cap_rights_t *rights = (cap_rights_t *)out;

	cap_rights_init(rights);
	if (flags & ABYSS_CAP_READ)
		cap_rights_set(rights, CAP_READ);
	if (flags & ABYSS_CAP_WRITE)
		cap_rights_set(rights, CAP_WRITE);
	if (flags & ABYSS_CAP_MMAP)
		cap_rights_set(rights, CAP_MMAP);
	if (flags & ABYSS_CAP_IOCTL)
		cap_rights_set(rights, CAP_IOCTL);
	if (flags & ABYSS_CAP_EVENT)
		cap_rights_set(rights, CAP_EVENT);
	if (flags & ABYSS_CAP_FSTAT)
		cap_rights_set(rights, CAP_FSTAT);
	if (flags & ABYSS_CAP_SEND)
		cap_rights_set(rights, CAP_SEND);
	if (flags & ABYSS_CAP_RECV)
		cap_rights_set(rights, CAP_RECV);
}

/* Limit `fd` to the rights in `rights`. Wraps cap_rights_limit(2). */
int
abyss_cap_rights_limit(int fd, const void *rights)
{
	return cap_rights_limit(fd, (const cap_rights_t *)rights);
}

/* Enter Capsicum capability mode. Wraps cap_enter(2) — irreversible. */
int
abyss_cap_enter(void)
{
	return cap_enter();
}
