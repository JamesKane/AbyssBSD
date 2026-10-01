#!/bin/sh
# AbyssBSD Swift DE — the login daemon's VT switch, on real vt(4) (PHASE16,
# found on the 12700KF; HANDOFF §2.116).
#
# The daemon puts the login window on VT 9 and sessions on 10–16. vt(4) only
# switches to a window somebody has open, and nothing holds VT 9 and up (no
# getty), so the switch was refused and the login window ran on whatever VT was
# current. live-greeter.sh and live-switchuser.sh record their switches instead
# of making them; this makes them, with cproc's own `ap_vt_activate`. Claims:
#
#   1. a plain VT_ACTIVATE to VT 9, as before, is refused (the control);
#   2. ap_vt_activate(9) brings VT 9 to the front;
#   3. ap_vt_activate(1) brings the console back.
#
# FreeBSD, as root (passwordless sudo, as the build VM has).
# Usage: abyss/tests/live-vtactivate.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
if [ "$(uname -s)" != FreeBSD ]; then echo "note: vt(4) is FreeBSD's; nothing to switch on $(uname -s)"; exit 0; fi
sudo -n true 2>/dev/null || { echo "SKIP: no passwordless sudo here — switching VTs needs root"; exit 0; }
[ -e /dev/ttyv8 ] || { echo "SKIP: no ttyv8 — this machine has no vt(4) windows"; exit 0; }

work=$(mktemp -d /tmp/abyss-vta.XXXXXX)
cleanup() { sudo vidcontrol -s 1 < /dev/null > /dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }

cat > "$work/vta.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/consio.h>
int ap_vt_activate(int vt);
static int active(void) {
    int fd = open("/dev/ttyv0", O_RDWR | O_NOCTTY), v = -1;
    if (fd >= 0) { ioctl(fd, VT_GETACTIVE, &v); close(fd); }
    return v;
}
int main(int argc, char **argv) {
    int vt = atoi(argv[2]);
    if (strcmp(argv[1], "plain") == 0) {
        int fd = open("/dev/ttyv0", O_RDWR | O_NOCTTY);
        int rc = ioctl(fd, VT_ACTIVATE, vt);
        printf("plain %d rc=%d errno=%s active=%d\n", vt, rc, rc ? strerror(errno) : "-", active());
    } else {
        int rc = ap_vt_activate(vt);
        printf("cproc %d rc=%d errno=%s active=%d\n", vt, rc, rc ? strerror(errno) : "-", active());
    }
    return 0;
}
EOF
cc -I"$root/de/cproc/include" "$work/vta.c" "$root/de/cproc/cproc.c" -lutil -o "$work/vta" || fail "could not build the harness"

sudo vidcontrol -s 1 < /dev/null > /dev/null 2>&1 || true
line=$(sudo "$work/vta" plain 9)
case "$line" in *"rc=-1"*"active=1") ;; *) fail "the control: a plain switch to VT 9 was not refused ($line)" ;; esac
echo "ok: 1. the control: a plain VT_ACTIVATE to VT 9 is refused — nobody has it open"

line=$(sudo "$work/vta" cproc 9)
case "$line" in *"rc=0 "*"active=9") ;; *) fail "ap_vt_activate(9): $line" ;; esac
echo "ok: 2. ap_vt_activate(9) brought VT 9 to the front"

line=$(sudo "$work/vta" cproc 1)
case "$line" in *"rc=0 "*"active=1") ;; *) fail "ap_vt_activate(1): $line" ;; esac
echo "ok: 3. ap_vt_activate(1) brought the console back"
echo "all green (the daemon's VT switch works on real vt(4), to VTs nobody holds)."
