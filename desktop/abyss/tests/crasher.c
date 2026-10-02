/* A program that crashes on purpose, for live-crash.sh (PHASE18 P18.9): a
 * null pointer read in a function with a name to look for in a backtrace. */
#include <stdio.h>

static int kaboom(volatile int *p) {
    return *p + 1;   /* the faulting line */
}

int main(void) {
    printf("about to crash\n");
    fflush(stdout);
    return kaboom((volatile int *)0);
}
