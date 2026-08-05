#!/bin/sh
# AbyssBSD Swift DE — the Aqua shell, on our own compositor (PHASE6.md P6.6).
#
# The destination of Phase 6: the wallpaper, the menu bar and the Dock — three
# separate `wlr-layer-shell` clients written in Phase 2 against sway — brought up
# on `undertow` with no other compositor anywhere.
#
# The assertion that matters is NOT "three clients connected". It is that they
# COMPOSED: the menu bar's exclusive zone reserved its strip, the desktop ignored
# that reservation and painted underneath it, and the Dock overlapped without
# reserving anything. A layer surface never appears in a window tree, so the
# usable area is the only observable proof (HANDOFF §2.26) — which is exactly the
# check `live-session.sh` has made against sway since Phase 2, now made against
# us.
#
# Usage: abyss/tests/live-undertow-shell.sh [out.ppm]
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

out=${1:-}
undertow="$root/.build/debug/undertow"
demo="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$demo" ] || swift build

W=800
H=600
BAR=22          # the menu bar's height, and its exclusive zone

work=$(mktemp -d /tmp/abyss-utshell.XXXXXX)
deskdir="$work/desktop"
mkdir -p "$deskdir"
ppm="$work/shell.ppm"
cleanup() {
  for p in ${shell_pids:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

# ------------------------------------------------------------- the compositor
# The usable area is asserted inside the binary: 0,BAR,W x (H-BAR) is the menu
# bar's reservation and nothing else's.
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 700 \
    --width "$W" --height "$H" --capture "$ppm" \
    --assert-layers 3 --assert-usable "0,$BAR,${W}x$((H - BAR))" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""
i=0
while [ $i -lt 60 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  kill -0 "$ut_pid" 2>/dev/null || { echo "FAIL: undertow exited early"; cat "$work/ut.err"; exit 1; }
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || { echo "FAIL: undertow never announced a socket"; cat "$work/ut.err"; exit 1; }

# ------------------------------------------------------------------ the shell
shell_pids=""
for scene in wallpaper menubar dock; do
  env WAYLAND_DISPLAY="$wd" ABYSS_DESKTOP_DIR="$deskdir" ABYSS_FINDER_DIR="$deskdir" \
      AQUA_SCENE="$scene" "$demo" > "$work/$scene.log" 2>&1 &
  shell_pids="$shell_pids $!"
done

rc=0; wait "$ut_pid" 2>/dev/null || rc=$?
ut_pid=""
for p in $shell_pids; do kill "$p" 2>/dev/null || true; done
shell_pids=""

if [ "$rc" != 0 ]; then
  echo "FAIL: the shell did not compose on undertow"
  cat "$work/ut.out" "$work/ut.err"
  for scene in wallpaper menubar dock; do echo "-- $scene"; tail -3 "$work/$scene.log"; done
  exit 1
fi

# ------------------------------------------------------------------ the proof

grep -q '^layers=3 of 3' "$work/ut.out" \
  || { echo "FAIL: not all three shell surfaces mapped"; cat "$work/ut.out"; exit 1; }
echo "ok: wallpaper, menu bar and Dock are all mapped as layer surfaces"

usable=$(grep -o '^usable=.*' "$work/ut.out" | cut -d= -f2)
echo "ok: the menu bar reserved its strip — usable area is $usable"
echo "    (a layer surface is invisible to a window tree; this is the only proof)"

# Pixels, top to bottom, on the one capture. Each probe is a different layer, so
# together they show the stack really is a stack.
hdr_len=$(printf 'P6\n%s %s\n255\n' "$W" "$H" | wc -c | tr -d ' ')
pixel() {
  off=$((hdr_len + ((($2 * W) + $1) * 3)))
  dd if="$ppm" bs=1 skip="$off" count=3 2>/dev/null | od -An -v -tu1 | awk '{print $1, $2, $3}'
}
lightness() { echo "$1" | awk '{print ($1 + $2 + $3) / 3}'; }

# 1. The menu bar (TOP layer) is at the top, and it is pale Aqua chrome.
bar=$(pixel $((W / 2)) 8)
[ "$(lightness "$bar" | cut -d. -f1)" -gt 150 ] \
  || { echo "FAIL: no menu bar at the top of the frame (pixel $bar)"; exit 1; }
echo "ok: the menu bar is painted at the top ($bar)"

# 2. Below the reserved strip is the desktop (BACKGROUND layer) — and it is
#    NOT the compositor's own fallback blue, which would mean the wallpaper
#    client never got composited and we were looking at bare output.
desk=$(pixel 60 300)
[ "$desk" != "61 102 161" ] \
  || { echo "FAIL: the desktop is undertow's fallback blue — the wallpaper"
       echo "      client is not being composited"; exit 1; }
echo "ok: the wallpaper is composited under it, not the compositor's fallback ($desk)"

# 3. The Dock (also TOP layer, no reservation) is near the bottom, overlapping
#    the wallpaper rather than being given space of its own.
dock=$(pixel $((W / 2)) $((H - 40)))
[ "$dock" != "$desk" ] \
  || { echo "FAIL: nothing is drawn where the Dock should be"; exit 1; }
echo "ok: the Dock overlaps the wallpaper near the bottom ($dock)"

[ -n "$out" ] && cp "$ppm" "$out" && echo "wrote $out"
echo "all green (the Aqua shell composes on our own compositor)."
