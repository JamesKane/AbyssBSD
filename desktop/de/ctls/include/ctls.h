/*
 * CTLS — a TLS client over an open socket, from the OpenSSL in the base
 * system (PHASE18 P18.12a; the remote model, P18.7c, uses it too).
 *
 * One idea: **verify, or fail with why.** The peer's certificate must chain
 * to a trusted CA (the system's, or `cafile` for a test) and name `host`;
 * TLS 1.2 at least; SNI sent. There is no switch to skip verification.
 */
#ifndef ABYSS_CTLS_H
#define ABYSS_CTLS_H

#include <stddef.h>

typedef struct ap_tls ap_tls;

/* Handshake on connected socket `fd` (not taken over: the caller closes it
 * after ap_tls_close). NULL on failure, with why in `err`. */
ap_tls *ap_tls_open(int fd, const char *host, const char *cafile, char *err, size_t errlen);

/* Bytes read (0 at the peer's close), or -1. */
long ap_tls_read(ap_tls *t, void *buf, size_t len);
/* Bytes written, or -1. */
long ap_tls_write(ap_tls *t, const void *buf, size_t len);
void ap_tls_close(ap_tls *t);

#endif
