#ifndef ABYSS_CPAM_H
#define ABYSS_CPAM_H

#include <stddef.h>

/*
 * PAM for the authenticator (PHASE16 P16.1), in C because PAM's conversation
 * is a callback taking a struct of function pointers and handing back
 * malloc'd answers — not something to build from Swift.
 *
 * Returns:
 *    1  the password is the user's
 *    0  it is not (or the account may not log in: pam_acct_mgmt)
 *   -1  PAM is not available on this platform (Linux without its headers)
 *   -2  PAM failed for another reason; *why says which
 *
 * The password is read from `password` (`length` bytes, not NUL-terminated)
 * and every copy this code makes is wiped before it returns.
 */
int abyss_pam_check(const char *service, const char *user,
                    const unsigned char *password, size_t length,
                    char *why, size_t whylen);

/* Wipe memory the compiler may not optimise away. */
void abyss_wipe(void *p, size_t n);

#endif
