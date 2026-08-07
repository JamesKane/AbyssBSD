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

# FreeBSD has no pam_xdg, so nothing sets XDG_RUNTIME_DIR (HANDOFF §2.31) — and
# from Phase 6 the *unit tests* need one too, because `undertow` binds a Wayland
# socket and `wl_display_add_socket_auto` has nowhere to put it without one. The
# live scripts have sourced this helper since Phase 3; it belongs here as well
# now that `swift test` can care.
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

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

# The compositor's frame contract (C1 + the allocation-free present path). In
# the default lane on purpose: it needs no compositor, no GPU and no display,
# which is exactly why the contract is built before the pixels (PHASE6.md P6.1).
echo "== the frame contract =="
sh "$root/abyss/tests/bench-metronome.sh"

# A real client on our own compositor. Also in the default lane, and notable for
# being the first test here that starts no sway at all — undertow IS the
# compositor (PHASE6.md P6.3).
echo "== a real client on undertow =="
sh "$root/abyss/tests/live-undertow.sh"

# ...and input reaching that client through our own seat, driven by the same
# unmodified vpointer the harness points at sway (PHASE6.md P6.4).
echo "== input through undertow =="
sh "$root/abyss/tests/live-undertow-input.sh"

# C2 — the claim the architecture exists to make good: eleven hostile processes
# cannot make the compositor drop a frame, and the healthy client keeps working
# throughout (PHASE6.md P6.5).
echo "== C2: no client can make us miss a frame =="
sh "$root/abyss/tests/live-undertow-c2.sh"

# The destination of Phase 6: the Aqua shell — wallpaper, menu bar and Dock,
# three layer-shell clients from Phase 2 — composing on undertow (P6.6).
echo "== the Aqua shell on undertow =="
sh "$root/abyss/tests/live-undertow-shell.sh"

# What only a compositor can do: a window remembers where it was dragged to, and
# reopens there in a NEW session (HANDOFF §2.22's debt, paid in P6.7).
echo "== remembered window positions =="
sh "$root/abyss/tests/live-undertow-places.sh"

# The file-chooser portal, end to end: a client, a picker, and a descriptor for
# a file the client never named. Needs a compositor, so it sits in --live.
if [ "$live" -eq 1 ]; then
  echo "== the portal, end to end =="
  sh "$root/abyss/tests/live-portal.sh"
  # And the claim that makes it worth having: a client with no filesystem.
  echo "== the sandboxed client =="
  sh "$root/abyss/tests/live-sandbox.sh"
  echo "== notifications =="
  sh "$root/abyss/tests/live-notify.sh" >/dev/null
  # The same claim with a sharper control: a client that cannot call socket(2),
  # and therefore cannot reach the compositor, holding a picture of the screen.
  echo "== the screenshot portal =="
  sh "$root/abyss/tests/live-screenshot.sh"
fi

# The hardware bridges against the real kernel (sysctl + devd on FreeBSD; on
# Linux it asserts the stubs report themselves absent). No compositor needed.
echo "== hardware bridges =="
sh "$root/abyss/tests/live-vents.sh"

if [ "$live" -eq 1 ]; then
  echo "== live modes (headless sway + grim) =="
  sh "$root/abyss/tests/run-live.sh"
fi

echo "all green."
