#!/bin/sh
# AbyssBSD Swift DE — build + test loop.
#
# Default lane (fast, no compositor): build the SwiftPM package, run the unit
# tests, and render one headless Aqua frame as a smoke test. Exits non-zero on
# any failure (CI-friendly).
#
# Usage:
#   abyss/tests/run.sh              # build + unit tests + headless render
#   abyss/tests/run.sh --live       # ... and every live mode under headless sway
#   abyss/tests/run.sh --vm         # run this same script inside the FreeBSD VM
#   abyss/tests/run.sh --vm --live  # ... including the live modes, there
#
# The --vm lane is the Phase-3 addition: it syncs the tree into the build VM
# (abyss/vm/*) and runs the identical script there, because the target is
# FreeBSD and only FreeBSD can tell us the truth about kqueue, sysctl and the
# fonts. Swift lives off PATH in the guest, so the lane spells out where it is.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

live=0
vm=0
for arg in "$@"; do
  case "$arg" in
    --live) live=1 ;;
    --vm)   vm=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "usage: run.sh [--live] [--vm]" >&2; exit 2 ;;
  esac
done

if [ "$vm" -eq 1 ]; then
  # Sourced from outside abyss/vm, so tell config.sh where it lives ($0 is us).
  ABYSS_VM_DIR="$root/abyss/vm"
  export ABYSS_VM_DIR
  . "$root/abyss/vm/config.sh"
  echo "== syncing to the FreeBSD VM =="
  "$root/abyss/vm/sync.sh"
  echo "== abyss/tests/run.sh, in the guest =="
  remote="export PATH=$ABYSS_GUEST_SWIFT_BIN:\$PATH; cd $ABYSS_GUEST_SRC && sh abyss/tests/run.sh"
  [ "$live" -eq 1 ] && remote="$remote --live"
  # shellcheck disable=SC2046
  exec ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@127.0.0.1" "$remote"
fi

echo "== swift build =="
swift build

echo "== swift test =="
swift test

echo "== headless Aqua render (smoke) =="
out="${TMPDIR:-/tmp}/aqua-smoke-$$.png"
AQUA_RENDER_PNG="$out" AQUA_SCALE=2 .build/debug/AquaDemo
test -s "$out" && echo "ok: $out" || { echo "FAIL: no PNG produced"; exit 1; }
rm -f "$out"

# Two real processes handing a descriptor over the control plane. In the default
# lane because it needs no compositor and takes about a second.
echo "== control plane, two processes =="
sh "$root/abyss/tests/live-ipc.sh"

if [ "$live" -eq 1 ]; then
  echo "== live modes (headless sway + grim) =="
  sh "$root/abyss/tests/run-live.sh"
fi

echo "all green."
