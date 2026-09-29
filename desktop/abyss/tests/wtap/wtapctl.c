/*
 * wtapctl — create and delete wtap(4) radios, open the simulated medium and
 * link two radios so each hears the other (PHASE14 P14.5). FreeBSD keeps its
 * own tools for this in tools/tools/wtap, which no release installs; this is
 * the two of them in one, for the tests. Not part of the product.
 *
 * Usage: wtapctl create N | delete N | open | link A B
 */
#include <sys/types.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define WTAPIOCTLCRT _IOW('W', 1, int)
#define WTAPIOCTLDEL _IOW('W', 2, int)
struct link { int op; int id1; int id2; };
#define VISIOCTLOPEN _IOW('W', 3, int)
#define VISIOCTLLINK _IOW('W', 4, struct link)
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: wtapctl create N | delete N | open | link A B\n"); return 2; }
    if (!strcmp(argv[1], "create") || !strcmp(argv[1], "delete")) {
        int fd = open("/dev/wtapctl", O_RDONLY), id = atoi(argv[2]);
        if (fd < 0) { perror("/dev/wtapctl"); return 1; }
        if (ioctl(fd, argv[1][0] == 'c' ? WTAPIOCTLCRT : WTAPIOCTLDEL, &id) < 0) { perror(argv[1]); return 1; }
        return 0;
    }
    int fd = open("/dev/visctl", O_RDONLY);
    if (fd < 0) { perror("/dev/visctl"); return 1; }
    if (!strcmp(argv[1], "open")) { int on = 1; if (ioctl(fd, VISIOCTLOPEN, &on) < 0) { perror("open"); return 1; } return 0; }
    if (!strcmp(argv[1], "link")) {
        struct link l = { 1, atoi(argv[2]), atoi(argv[3]) };
        if (ioctl(fd, VISIOCTLLINK, &l) < 0) { perror("link"); return 1; }
        return 0;
    }
    return 2;
}
