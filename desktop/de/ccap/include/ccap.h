/*
 * CCapsicum — entering FreeBSD's capability mode from Swift.
 *
 * `cap_enter(2)` irreversibly drops a process into a world with **no global
 * namespace**: no `open` by path, no `socket`, no `connect`, no anything that
 * names a resource rather than holding one. From that point a process can only
 * use descriptors it already has, and descriptors it is handed.
 *
 * That is the sandbox the portal's design assumes, and the reason "the
 * descriptor is the capability" is a security claim rather than a slogan: an app
 * in capability mode *cannot* open the file it was given, only read the fd it
 * received.
 *
 * It lives in C because <sys/capsicum.h> is not something Swift's libc module
 * surfaces (HANDOFF §2.30), and it is its own target rather than part of
 * CPlatform so the Aqua toolkit doesn't link sandbox code it never uses.
 *
 * FreeBSD-only by nature. Elsewhere these report "unsupported" — a client must
 * then say it is unsandboxed rather than imply a confinement it doesn't have.
 */
#ifndef ABYSS_CCAP_H
#define ABYSS_CCAP_H

/* 1 where capability mode exists (FreeBSD), 0 elsewhere. */
int ap_sandbox_supported(void);

/* Enter capability mode. Returns 0 on success, -1 with errno set (ENOSYS where
 * unsupported). THERE IS NO WAY BACK — that is the point. */
int ap_sandbox_enter(void);

/* 1 when this process is already in capability mode, 0 if not, -1 on error. */
int ap_sandbox_active(void);

#endif /* ABYSS_CCAP_H */
