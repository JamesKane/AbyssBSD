// See include/cpam.h.
#include "cpam.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

void abyss_wipe(void *p, size_t n) {
    volatile unsigned char *v = p;
    while (n--) *v++ = 0;
}

#if __has_include(<security/pam_appl.h>)
#include <security/pam_appl.h>

struct secret { const unsigned char *bytes; size_t length; };

/* Answer every password prompt with the secret, every other prompt with
 * nothing. PAM frees the answers; the copies are wiped first by pam itself on
 * OpenPAM (openpam_free_data), and by abyss_wipe here on failure. */
static int conversation(int n, const struct pam_message **msg,
                        struct pam_response **resp, void *data) {
    const struct secret *s = data;
    struct pam_response *r = calloc((size_t)n, sizeof *r);
    if (!r) return PAM_BUF_ERR;
    for (int i = 0; i < n; i++) {
        if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF || msg[i]->msg_style == PAM_PROMPT_ECHO_ON) {
            char *copy = malloc(s->length + 1);
            if (!copy) {
                for (int j = 0; j < i; j++)
                    if (r[j].resp) { abyss_wipe(r[j].resp, strlen(r[j].resp)); free(r[j].resp); }
                free(r);
                return PAM_BUF_ERR;
            }
            memcpy(copy, s->bytes, s->length);
            copy[s->length] = 0;
            r[i].resp = copy;
        }
    }
    *resp = r;
    return PAM_SUCCESS;
}

int abyss_pam_check(const char *service, const char *user,
                    const unsigned char *password, size_t length,
                    char *why, size_t whylen) {
    struct secret s = { password, length };
    struct pam_conv conv = { conversation, &s };
    pam_handle_t *h = NULL;
    int rc = pam_start(service, user, &conv, &h);
    if (rc != PAM_SUCCESS) {
        snprintf(why, whylen, "pam_start: %s", pam_strerror(h, rc));
        return -2;
    }
    rc = pam_authenticate(h, PAM_SILENT);
    if (rc == PAM_SUCCESS) rc = pam_acct_mgmt(h, PAM_SILENT);
    int out;
    if (rc == PAM_SUCCESS) out = 1;
    else if (rc == PAM_AUTH_ERR || rc == PAM_USER_UNKNOWN || rc == PAM_PERM_DENIED
             || rc == PAM_ACCT_EXPIRED || rc == PAM_NEW_AUTHTOK_REQD
             || rc == PAM_MAXTRIES || rc == PAM_CRED_INSUFFICIENT) {
        snprintf(why, whylen, "%s", pam_strerror(h, rc));
        out = 0;
    } else {
        snprintf(why, whylen, "%s", pam_strerror(h, rc));
        out = -2;
    }
    pam_end(h, rc);
    return out;
}

#else

int abyss_pam_check(const char *service, const char *user,
                    const unsigned char *password, size_t length,
                    char *why, size_t whylen) {
    (void)service; (void)user; (void)password; (void)length;
    snprintf(why, whylen, "this platform has no PAM headers (the authenticator is FreeBSD's)");
    return -1;
}

#endif
