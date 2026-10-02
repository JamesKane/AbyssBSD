/* CTLS — see include/ctls.h. */
#include "ctls.h"

#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct ap_tls {
    SSL_CTX *ctx;
    SSL *ssl;
};

static void why(char *err, size_t errlen, const char *what, SSL *ssl) {
    if (err == NULL || errlen == 0) return;
    unsigned long e = ERR_get_error();
    char detail[256] = "";
    if (e != 0) ERR_error_string_n(e, detail, sizeof detail);
    long v = ssl ? SSL_get_verify_result(ssl) : X509_V_OK;
    if (v != X509_V_OK)
        snprintf(err, errlen, "%s: %s", what, X509_verify_cert_error_string(v));
    else
        snprintf(err, errlen, "%s%s%s", what, detail[0] ? ": " : "", detail);
}

ap_tls *ap_tls_open(int fd, const char *host, const char *cafile, char *err, size_t errlen) {
    ERR_clear_error();
    ap_tls *t = calloc(1, sizeof *t);
    if (t == NULL) { why(err, errlen, "out of memory", NULL); return NULL; }
    t->ctx = SSL_CTX_new(TLS_client_method());
    if (t->ctx == NULL) { why(err, errlen, "no TLS context", NULL); free(t); return NULL; }
    SSL_CTX_set_min_proto_version(t->ctx, TLS1_2_VERSION);
    SSL_CTX_set_verify(t->ctx, SSL_VERIFY_PEER, NULL);
    int loaded = cafile && cafile[0] ? SSL_CTX_load_verify_locations(t->ctx, cafile, NULL)
                                     : SSL_CTX_set_default_verify_paths(t->ctx);
    if (loaded != 1) { why(err, errlen, "cannot load the trusted certificates", NULL); ap_tls_close(t); return NULL; }
    t->ssl = SSL_new(t->ctx);
    if (t->ssl == NULL || SSL_set_fd(t->ssl, fd) != 1
        || SSL_set_tlsext_host_name(t->ssl, host) != 1   /* SNI */
        || SSL_set1_host(t->ssl, host) != 1) {            /* the name it must carry */
        why(err, errlen, "cannot set up TLS", t->ssl);
        ap_tls_close(t);
        return NULL;
    }
    if (SSL_connect(t->ssl) != 1) {
        why(err, errlen, "TLS handshake with the server failed", t->ssl);
        ap_tls_close(t);
        return NULL;
    }
    return t;
}

long ap_tls_read(ap_tls *t, void *buf, size_t len) {
    int n = SSL_read(t->ssl, buf, (int)(len > 0x7fffffff ? 0x7fffffff : len));
    if (n > 0) return n;
    int e = SSL_get_error(t->ssl, n);
    return (e == SSL_ERROR_ZERO_RETURN || e == SSL_ERROR_SYSCALL) ? 0 : -1;
}

long ap_tls_write(ap_tls *t, const void *buf, size_t len) {
    int n = SSL_write(t->ssl, buf, (int)(len > 0x7fffffff ? 0x7fffffff : len));
    return n > 0 ? n : -1;
}

void ap_tls_close(ap_tls *t) {
    if (t == NULL) return;
    if (t->ssl) { SSL_shutdown(t->ssl); SSL_free(t->ssl); }
    if (t->ctx) SSL_CTX_free(t->ctx);
    free(t);
}
