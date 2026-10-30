#!/bin/sh
# Move a role's qemu disk to the FreeBSD box as bhyve's raw disk (config.sh),
# state and all: a builder keeps its poudriere jails and packages, a build
# guest its toolchain. Sparse both ways: only the blocks in use travel.
#
#   ABYSS_VM_ROLE=builder abyss/vm/bhyve-migrate.sh
#
# The qemu VM must be off. The qcow2 is left where it is, as a fallback,
# until you remove it.
set -eu
ABYSS_VMM=bhyve
. "$(dirname "$0")/config.sh"
h=$ABYSS_BHYVE_HOST
[ -f "$ABYSS_DISK" ] || { echo "bhyve-migrate: no $ABYSS_DISK" >&2; exit 1; }
if [ -f "$ABYSS_PIDFILE" ] && kill -0 "$(cat "$ABYSS_PIDFILE")" 2>/dev/null; then
  echo "bhyve-migrate: the qemu VM is running (pid $(cat "$ABYSS_PIDFILE")); shut it down first" >&2
  exit 1
fi
if ssh -o BatchMode=yes "$h" "test -e $ABYSS_BHYVE_DISK"; then
  echo "bhyve-migrate: $h:$ABYSS_BHYVE_DISK exists; remove it to migrate again" >&2
  exit 1
fi
raw="$ABYSS_VM_HOME/$(basename "$ABYSS_BHYVE_DISK")"
echo "[migrate] $ABYSS_DISK -> $raw (sparse raw)"
qemu-img convert -p -O raw "$ABYSS_DISK" "$raw"
du -h --apparent-size "$raw"; du -h "$raw"
ssh -o BatchMode=yes "$h" "mkdir -p $ABYSS_BHYVE_HOME"
echo "[migrate] -> $h:$ABYSS_BHYVE_DISK"
rsync --sparse --progress -e "ssh -o BatchMode=yes" "$raw" "$h:$ABYSS_BHYVE_DISK"
rm -f "$raw"
echo "[migrate] done; start it with: ABYSS_VMM=bhyve ABYSS_VM_ROLE=$ABYSS_VM_ROLE abyss/vm/run.sh"
